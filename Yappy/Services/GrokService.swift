//
//  GrokService.swift
//  Yappy
//
//  Created on 2026-01-04.
//

import Foundation

/// Errors that can occur during Grok API interactions.
enum GrokError: LocalizedError {
    case invalidAPIKey
    case networkError(Error)
    case invalidResponse
    case rateLimitExceeded
    case serverError(String)
    case emptyInput
    case jsonEncodingFailed
    case jsonDecodingFailed

    var errorDescription: String? {
        switch self {
        case .invalidAPIKey:
            return "Invalid X.AI API key. Please check your API key in settings."
        case .networkError(let error):
            return "Network error occurred: \(error.localizedDescription)"
        case .invalidResponse:
            return "Received invalid response from Grok API."
        case .rateLimitExceeded:
            return "Rate limit exceeded. Please try again in a moment."
        case .serverError(let message):
            return "Server error: \(message)"
        case .emptyInput:
            return "No text provided for cleanup."
        case .jsonEncodingFailed:
            return "Failed to encode request data."
        case .jsonDecodingFailed:
            return "Failed to decode response data."
        }
    }
}

/// Client for X.AI Grok chat completion API.
/// Handles text cleanup and enhancement with proper error handling.
final class GrokService {
    // MARK: - Properties

    private let apiKey: String
    private let session: URLSession

    // MARK: - Request/Response Models

    private struct ChatRequest: Codable {
        let model: String
        let messages: [Message]
        let temperature: Double
        let maxTokens: Int

        enum CodingKeys: String, CodingKey {
            case model
            case messages
            case temperature
            case maxTokens = "max_tokens"
        }
    }

    private struct Message: Codable {
        let role: String
        let content: String
    }

    private struct ChatResponse: Codable {
        let choices: [Choice]
    }

    private struct Choice: Codable {
        let message: MessageContent
    }

    private struct MessageContent: Codable {
        let role: String
        let content: String
    }

    private struct ErrorResponse: Codable {
        let error: ErrorDetail
    }

    private struct ErrorDetail: Codable {
        let message: String
    }

    // MARK: - Initialization

    /// Creates a new Grok service client.
    ///
    /// - Parameter apiKey: X.AI API key for authentication.
    init(apiKey: String) {
        self.apiKey = apiKey

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30.0
        configuration.timeoutIntervalForResource = 60.0

        self.session = URLSession(configuration: configuration)
    }

    // MARK: - Public Methods

    /// Cleans up transcribed text by fixing capitalization and punctuation.
    ///
    /// - Parameter text: Raw transcription text to clean up.
    /// - Returns: Cleaned text with proper capitalization and punctuation.
    /// - Throws: `GrokError` if cleanup fails.
    func cleanup(text: String) async throws -> String {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedText.isEmpty else {
            throw GrokError.emptyInput
        }

        // Try cleanup with retry logic for transient failures
        var lastError: Error?

        for attempt in 0..<2 {
            do {
                let cleanedText = try await performCleanup(text: trimmedText)
                return cleanedText
            } catch let error as GrokError {
                // Don't retry on permanent failures
                switch error {
                case .invalidAPIKey, .emptyInput, .jsonEncodingFailed:
                    throw error
                case .rateLimitExceeded:
                    // Retry rate limits with backoff
                    if attempt == 0 {
                        try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
                        lastError = error
                        continue
                    }
                    throw error
                case .networkError, .invalidResponse, .serverError, .jsonDecodingFailed:
                    // Retry transient errors
                    if attempt == 0 {
                        try? await Task.sleep(nanoseconds: 500_000_000) // 500ms
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

        throw lastError ?? GrokError.invalidResponse
    }

    // MARK: - Private Methods

    private func performCleanup(text: String) async throws -> String {
        guard let url = URL(string: Constants.grokAPIEndpoint) else {
            throw GrokError.serverError("Invalid API endpoint")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Build request body
        let chatRequest = ChatRequest(
            model: Constants.grokModel,
            messages: [
                Message(
                    role: "system",
                    content: "Fix capitalization and punctuation. Output only the corrected text, nothing else."
                ),
                Message(
                    role: "user",
                    content: text
                )
            ],
            temperature: 0,
            maxTokens: 2048
        )

        // Encode request
        let encoder = JSONEncoder()
        guard let requestData = try? encoder.encode(chatRequest) else {
            throw GrokError.jsonEncodingFailed
        }
        request.httpBody = requestData

        // Perform request
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw GrokError.networkError(error)
        }

        // Handle HTTP response
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GrokError.invalidResponse
        }

        // Check status code
        switch httpResponse.statusCode {
        case 200:
            // Success - parse response
            return try parseCleanupResponse(data: data)

        case 401:
            throw GrokError.invalidAPIKey

        case 429:
            throw GrokError.rateLimitExceeded

        case 400...499:
            // Client error - extract error message
            let errorMessage = extractErrorMessage(from: data) ?? "Client error (status \(httpResponse.statusCode))"
            throw GrokError.serverError(errorMessage)

        case 500...599:
            // Server error
            let errorMessage = extractErrorMessage(from: data) ?? "Server error (status \(httpResponse.statusCode))"
            throw GrokError.serverError(errorMessage)

        default:
            throw GrokError.serverError("Unexpected status code: \(httpResponse.statusCode)")
        }
    }

    private func parseCleanupResponse(data: Data) throws -> String {
        let decoder = JSONDecoder()

        guard let response = try? decoder.decode(ChatResponse.self, from: data) else {
            throw GrokError.jsonDecodingFailed
        }

        guard let firstChoice = response.choices.first else {
            throw GrokError.invalidResponse
        }

        let cleanedText = firstChoice.message.content.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleanedText.isEmpty else {
            throw GrokError.invalidResponse
        }

        return cleanedText
    }

    private func extractErrorMessage(from data: Data) -> String? {
        let decoder = JSONDecoder()

        // Try to decode structured error response
        if let errorResponse = try? decoder.decode(ErrorResponse.self, from: data) {
            return errorResponse.error.message
        }

        // Fallback: try generic JSON parsing
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = json["error"] as? [String: Any],
           let message = error["message"] as? String {
            return message
        }

        return nil
    }
}
