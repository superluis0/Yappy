//
//  TranscriptionService.swift
//  Yappy
//
//  Created on 2026-01-04.
//

import Foundation
import AVFoundation

/// Service for transcribing audio using OpenAI Whisper API and cleaning up with Grok.
final class TranscriptionService {
    // MARK: - Properties
    
    private let settings: Settings
    
    /// Optimized URLSession for low latency
    private lazy var urlSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral // Use ephemeral for faster startup
        config.timeoutIntervalForRequest = 15 // Reduced from 30
        config.timeoutIntervalForResource = 30 // Reduced from 60
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.httpMaximumConnectionsPerHost = 6 // Increased for better throughput
        config.waitsForConnectivity = false
        config.allowsCellularAccess = true
        config.allowsExpensiveNetworkAccess = true
        config.allowsConstrainedNetworkAccess = true
        
        // HTTP/2 and connection reuse for faster requests
        config.httpShouldUsePipelining = true
        config.shouldUseExtendedBackgroundIdleMode = false
        
        return URLSession(configuration: config)
    }()
    
    // MARK: - Initialization
    
    init(settings: Settings) {
        self.settings = settings
    }
    
    // MARK: - Public Methods
    
    /// Transcribes an audio file using OpenAI Whisper API.
    /// - Parameter audioURL: URL of the audio file to transcribe.
    /// - Returns: The transcribed text.
    func transcribe(audioURL: URL) async throws -> String {
        guard !settings.openAIAPIKey.isEmpty else {
            throw TranscriptionError.missingAPIKey("OpenAI API key is not configured")
        }
        
        // Load audio data directly (WAV is supported by Whisper)
        let audioData = try Data(contentsOf: audioURL)
        
        // Create the request
        var request = URLRequest(url: URL(string: Constants.whisperAPIEndpoint)!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(settings.openAIAPIKey)", forHTTPHeaderField: "Authorization")
        
        // Create multipart form data
        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        
        var body = Data()
        
        // Add audio file in WAV format (supported by Whisper)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(audioData)
        body.append("\r\n".data(using: .utf8)!)
        
        // Add model parameter
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"model\"\r\n\r\n".data(using: .utf8)!)
        body.append("whisper-1\r\n".data(using: .utf8)!)
        
        // Add response format for faster parsing
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"response_format\"\r\n\r\n".data(using: .utf8)!)
        body.append("json\r\n".data(using: .utf8)!)
        
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        
        request.httpBody = body
        
        // Send the request with optimized session
        let (data, response) = try await urlSession.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw TranscriptionError.invalidResponse
        }
        
        guard httpResponse.statusCode == 200 else {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw TranscriptionError.apiError("Whisper API error (\(httpResponse.statusCode)): \(errorMessage)")
        }
        
        // Parse the response
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let text = json?["text"] as? String else {
            throw TranscriptionError.invalidResponse
        }
        
        print("✅ Transcription successful: \(text)")
        return text
    }
    
    /// Cleans up transcription using Grok AI via OpenRouter.
    /// - Parameter transcription: The raw transcription text to clean up.
    /// - Returns: The cleaned up text.
    func cleanupTranscription(_ transcription: String) async throws -> String {
        guard !settings.openRouterAPIKey.isEmpty else {
            throw TranscriptionError.missingAPIKey("OpenRouter API key is not configured")
        }
        
        // Trim whitespace from API key to avoid issues
        let apiKey = settings.openRouterAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Create the request
        var request = URLRequest(url: URL(string: Constants.grokAPIEndpoint)!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://github.com/yourusername/yappy", forHTTPHeaderField: "HTTP-Referer")
        request.setValue("Yappy", forHTTPHeaderField: "X-Title")
        
        // Create the prompt
        let prompt = """
        Clean up the following voice transcription. Fix any grammar, punctuation, and formatting issues. \
        Remove filler words like "um", "uh", "like", etc. Make it clear and professional. \
        Return ONLY the cleaned text without any additional commentary.
        
        Transcription: \(transcription)
        """
        
        // Create the request body
        let requestBody: [String: Any] = [
            "model": Constants.grokModel,
            "messages": [
                ["role": "user", "content": prompt]
            ],
            "temperature": 0.3
        ]
        
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
        
        // Send the request with optimized session
        let (data, response) = try await urlSession.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw TranscriptionError.invalidResponse
        }
        
        guard httpResponse.statusCode == 200 else {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw TranscriptionError.apiError("OpenRouter API error (\(httpResponse.statusCode)): \(errorMessage)")
        }
        
        // Parse the response
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let choices = json?["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw TranscriptionError.invalidResponse
        }
        
        print("✅ Cleanup successful: \(content)")
        return content
    }
}

// MARK: - Errors

enum TranscriptionError: LocalizedError {
    case missingAPIKey(String)
    case apiError(String)
    case invalidResponse
    
    var errorDescription: String? {
        switch self {
        case .missingAPIKey(let message):
            return message
        case .apiError(let message):
            return message
        case .invalidResponse:
            return "Invalid API response"
        }
    }
}
