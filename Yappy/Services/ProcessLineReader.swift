//
//  ProcessLineReader.swift
//  Yappy
//
//  Shared newline-framed stdout readers and stderr drains for JSON-RPC /
//  stdio client processes. Loop, buffering, cancellation, and
//  availableData-empty-break semantics match the prior per-client copies.
//

import Foundation

/// Detached task that reads newline-delimited frames from `handle` and invokes
/// `onLine` for each non-empty line (excluding the newline itself).
func makeLineReader(
    _ handle: FileHandle,
    onLine: @escaping @Sendable (Data) -> Void
) -> Task<Void, Never> {
    Task.detached(priority: .userInitiated) {
        var buffer = Data()
        while !Task.isCancelled {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: buffer.startIndex..<newline)
                buffer.removeSubrange(buffer.startIndex...newline)
                guard !line.isEmpty else { continue }
                onLine(line)
            }
        }
    }
}

/// Detached task that drains newline-framed stderr so the child does not block
/// on a full pipe. Invokes `onLine` for each frame (including empty ones — the
/// caller decides whether to log).
func makeStderrDrain(
    _ handle: FileHandle,
    onLine: @escaping @Sendable (Data) -> Void
) -> Task<Void, Never> {
    Task.detached(priority: .utility) {
        var buffer = Data()
        while !Task.isCancelled {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: buffer.startIndex..<newline)
                buffer.removeSubrange(buffer.startIndex...newline)
                onLine(line)
            }
        }
    }
}
