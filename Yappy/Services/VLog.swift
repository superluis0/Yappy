//
//  VLog.swift
//  Yappy
//
//  Lightweight logger for the "Ask" feature (Fn-key voice questions). Mirrors
//  every line to Apple's unified log, to stderr (with a relative-ms timestamp),
//  and to a persistent file at ~/Library/Logs/Yappy/ask.log so cold-start and
//  hotkey issues can be diagnosed without attaching `log stream`.
//
//  Non-actor-isolated throughout: called from the CGEvent tap C callback (no
//  Swift actor) and from @MainActor code alike. All state is immutable after
//  module load (Swift 6 strict-concurrency-safe).
//

import Foundation
import os
import QuartzCore

enum VLog {

    enum Cat: String {
        case app
        case hotkey
        case audio
        case pill
        case store
        case codex
        case grok
        case tts
        case ask
    }

    /// Absolute time captured when this module first loads — the basis for the
    /// relative "ms since launch" stderr timestamps.
    private static let launchTime: Double = CACurrentMediaTime()

    private static let stderrHandle = FileHandle.standardError

    /// Opt-in diagnostics: raw provider stderr and frame content are logged
    /// only when this defaults flag is set - the default keeps the "logs never
    /// contain your words" promise while preserving a debugging path:
    ///   defaults write com.yappy.app com.yappy.askDebugLogging -bool YES
    static let contentLoggingEnabled = UserDefaults.standard.bool(forKey: "com.yappy.askDebugLogging")

    /// Persistent log file, truncated fresh on each launch. Owner-only.
    private static let fileHandle: FileHandle? = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Yappy", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("ask.log")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return try? FileHandle(forWritingTo: url)
    }()

    /// Serializes file writes coming from the audio thread, the CGEvent tap C
    /// callback, and the main actor.
    private static let fileLock = NSLock()

    static func log(_ cat: Cat, _ message: @autoclosure () -> String) {
        let msg = message()

        Logger(subsystem: "com.yappy.app", category: "ask.\(cat.rawValue)")
            .log("\(msg, privacy: .private)")

        let elapsedMs = Int((CACurrentMediaTime() - launchTime) * 1000)
        let line = "[+\(elapsedMs)ms][ask.\(cat.rawValue)] \(msg)\n"
        let data = Data(line.utf8)
        stderrHandle.write(data)

        if let fileHandle {
            fileLock.lock()
            fileHandle.write(data)
            fileLock.unlock()
        }
    }

    static func app(_ message: @autoclosure () -> String)    { log(.app, message()) }
    static func hotkey(_ message: @autoclosure () -> String) { log(.hotkey, message()) }
    static func audio(_ message: @autoclosure () -> String)  { log(.audio, message()) }
    static func pill(_ message: @autoclosure () -> String)   { log(.pill, message()) }
    static func store(_ message: @autoclosure () -> String)  { log(.store, message()) }
    static func codex(_ message: @autoclosure () -> String)  { log(.codex, message()) }
    static func grok(_ message: @autoclosure () -> String)   { log(.grok, message()) }
    static func tts(_ message: @autoclosure () -> String)    { log(.tts, message()) }
    static func ask(_ message: @autoclosure () -> String)    { log(.ask, message()) }
}
