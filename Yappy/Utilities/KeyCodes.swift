//
//  KeyCodes.swift
//  Yappy
//
//  Created on 2026-01-04.
//

import Foundation

/// macOS virtual key code constants for modifier keys.
/// These codes are used to distinguish between left and right modifier keys
/// when monitoring keyboard events via CGEvent.
enum KeyCode {
    /// Virtual key code for the right Command (⌘) key.
    static let rightCommand: UInt16 = 54

    /// Virtual key code for the right Option (⌥) key.
    static let rightOption: UInt16 = 61

    /// Virtual key code for the right Control (⌃) key.
    static let rightControl: UInt16 = 62

    /// Virtual key code for the left Command (⌘) key.
    static let leftCommand: UInt16 = 55

    /// Virtual key code for the left Option (⌥) key.
    static let leftOption: UInt16 = 58

    /// Virtual key code for the left Control (⌃) key.
    static let leftControl: UInt16 = 59
}
