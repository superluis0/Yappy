//
//  WhisperService.swift
//  Yappy
//
//  Created on 2026-01-04.
//

import Foundation

/// Errors that can occur during Whisper API interactions.
enum WhisperError: LocalizedError {
    case invalidAPIKey
    case networkError(Error)
    case invalidResponse
    case rateLimitExceeded
    case serverError(String)
    case emptyAudioData
    case requestCreationFailed

    var errorDescription: String? {
        switch self {
        case .invalidAPIKey:
            return "Invalid OpenAI API key. Please check your API key in settings."
        case .networkError(let error):
            return "Network error occurred: \(error.localizedDescription)"
        case .invalidResponse:
            return "Received invalid response from Whisper API."
        case .rateLimitExceeded:
            return "Rate limit exceeded. Please try again in a moment."
        case .serverError(let message):
            return "Server error: \(message)"
        case .emptyAudioData:
            return "No audio data provided for transcription."
        case .requestCreationFailed:
            return "Failed to create API request."
        }
    }
}

/// Client for OpenAI Whisper speech-to-text API.
/// Handles audio transcription with automatic retry logic and comprehensive error handling.
final class WhisperService {
    // MARK: - Properties

    private let apiKey: String
    private let session: URLSession

    // MARK: - Initialization

    /// Creates a new Whisper service client.
    ///
    /// - Parameter apiKey: OpenAI API key for authentication.
    init(apiKey: String) {
        self.apiKey = apiKey

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60.0  // 60s for upload + processing
        configuration.timeoutIntervalForResource = 120.0

        self.session = URLSession(configuration: configuration)
    }

    // MARK: - Public Methods

    /// Transcribes audio data to text using OpenAI Whisper.
    ///
    /// - Parameter audioData: Audio data in WAV, MP3, or M4A format.
    /// - Returns: Transcribed text from the audio.
    /// - Throws: `WhisperError` if transcription fails.
    func transcribe(audioData: Data) async throws -> String {
        guard !audioData.isEmpty else {
            throw WhisperError.emptyAudioData
        }

        // Try transcription with one retry on transient failures
        var lastError: Error?

        for attempt in 0..<2 {
            do {
                let transcription = try await performTranscription(audioData: audioData)
                return transcription
            } catch let error as WhisperError {
                // Don't retry on permanent failures
                switch error {
                case .invalidAPIKey, .emptyAudioData, .requestCreationFailed:
                    throw error
                case .rateLimitExceeded:
                    // Retry rate limits with backoff
                    if attempt == 0 {
                        try? await Task.sleep(nanoseconds: 500_000_000) // 500ms
                        lastError = error
                        continue
                    }
                    throw error
                case .networkError, .invalidResponse, .serverError:
                    // Retry transient errors
                    if attempt == 0 {
                        try? await Task.sleep(nanoseconds: 500_000_000)
                        lastError = error
                        continue
                    }
                    throw error
                }
            } catch {
                lastError = error
                if attempt == 0 {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    continue
                }
            }
        }

        throw lastError ?? WhisperError.invalidResponse
    }

    // MARK: - Private Methods

    private func performTranscription(audioData: Data) async throws -> String {
        guard let url = URL(string: Constants.whisperAPIEndpoint) else {
            throw WhisperError.requestCreationFailed
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"

        // Create multipart/form-data request
        let boundary = UUID().uuidString
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        // Build multipart body
        let httpBody = createMultipartBody(
            audioData: audioData,
            boundary: boundary
        )
        request.httpBody = httpBody

        // Perform request
        let (data, response) = try await session.data(for: request)

        // Handle HTTP response
        guard let httpResponse = response as? HTTPURLResponse else {
            throw WhisperError.invalidResponse
        }

        // Check status code
        switch httpResponse.statusCode {
        case 200:
            // Success - parse response
            return try parseTranscriptionResponse(data: data)

        case 401:
            throw WhisperError.invalidAPIKey

        case 429:
            throw WhisperError.rateLimitExceeded

        case 400...499:
            // Client error - extract error message
            let errorMessage = extractErrorMessage(from: data) ?? "Client error (status \(httpResponse.statusCode))"
            throw WhisperError.serverError(errorMessage)

        case 500...599:
            // Server error
            let errorMessage = extractErrorMessage(from: data) ?? "Server error (status \(httpResponse.statusCode))"
            throw WhisperError.serverError(errorMessage)

        default:
            throw WhisperError.serverError("Unexpected status code: \(httpResponse.statusCode)")
        }
    }

    private func createMultipartBody(audioData: Data, boundary: String) -> Data {
        var body = Data()
        let crlf = "\r\n"

        // Add file field
        body.append("--\(boundary)\(crlf)".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\(crlf)".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\(crlf)\(crlf)".data(using: .utf8)!)
        body.append(audioData)
        body.append(crlf.data(using: .utf8)!)

        // Add model field
        body.append("--\(boundary)\(crlf)".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"model\"\(crlf)\(crlf)".data(using: .utf8)!)
        body.append("whisper-1\(crlf)".data(using: .utf8)!)

        // Add response_format field
        body.append("--\(boundary)\(crlf)".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"response_format\"\(crlf)\(crlf)".data(using: .utf8)!)
        body.append("text\(crlf)".data(using: .utf8)!)

        // Final boundary
        body.append("--\(boundary)--\(crlf)".data(using: .utf8)!)

        return body
    }

    private func parseTranscriptionResponse(data: Data) throws -> String {
        // For "text" response format, the response is plain text
        guard let transcription = String(data: data, encoding: .utf8) else {
            throw WhisperError.invalidResponse
        }

        let trimmedTranscription = transcription.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedTranscription.isEmpty else {
            throw WhisperError.invalidResponse
        }

        return trimmedTranscription
    }

    private func extractErrorMessage(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = json["error"] as? [String: Any],
              let message = error["message"] as? String else {
            return nil
        }
        return message
    }
}
