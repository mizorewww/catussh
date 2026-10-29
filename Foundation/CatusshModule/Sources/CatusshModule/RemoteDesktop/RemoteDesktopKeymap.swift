//
//  RemoteDesktopKeymap.swift
//  CatusshModule
//
//  Key-code translation for the remote-desktop canvas and the UU Remote
//  driver. UIKit delivers `UIKeyboardHIDUsage` values (USB HID); VNC's
//  `VNCKeySyms` tables and macOS UU targets take Carbon virtual keycodes;
//  Windows UU targets take Windows virtual-key codes.
//

import Foundation

#if canImport(UIKit)
    import UIKit
#endif

enum RemoteDesktopKeymap {
    /// `UIKeyboardHIDUsage.rawValue` -> Carbon virtual keycode, for keys
    /// that do not reliably produce `characters` (arrows, function keys,
    /// modifiers). Text keys fall back to `key.characters` anyway, so only
    /// the well-known entries need to live here.
    static let carbonForHID: [Int: UInt16] = [
        // Letters A-Z: HID 0x04-0x1D.
        0x04: 0, 0x05: 11, 0x06: 8, 0x07: 2, 0x08: 14, 0x09: 3,
        0x0A: 5, 0x0B: 4, 0x0C: 34, 0x0D: 38, 0x0E: 40, 0x0F: 37,
        0x10: 46, 0x11: 45, 0x12: 31, 0x13: 35, 0x14: 12, 0x15: 15,
        0x16: 1, 0x17: 17, 0x18: 32, 0x19: 9, 0x1A: 13, 0x1B: 7,
        0x1C: 16, 0x1D: 6,
        // Number row 1-0: HID 0x1E-0x27.
        0x1E: 18, 0x1F: 19, 0x20: 20, 0x21: 21, 0x22: 23,
        0x23: 22, 0x24: 26, 0x25: 28, 0x26: 25, 0x27: 29,
        // Editing & navigation.
        0x28: 36, // Return
        0x29: 53, // Escape
        0x2A: 51, // Backspace
        0x2B: 48, // Tab
        0x2C: 49, // Space
        0x2D: 27, // -_
        0x2E: 24, // =+
        0x2F: 33, // [{
        0x30: 30, // ]}
        0x31: 42, // \|
        0x33: 41, // ;:
        0x34: 39, // '"
        0x35: 50, // `~
        0x36: 43, // ,<
        0x37: 47, // .>
        0x38: 44, // /?
        0x39: 57, // Caps Lock
        // F1-F12: HID 0x3A-0x45.
        0x3A: 122, 0x3B: 120, 0x3C: 99, 0x3D: 118,
        0x3E: 96, 0x3F: 97, 0x40: 98, 0x41: 100,
        0x42: 101, 0x43: 109, 0x44: 103, 0x45: 111,
        // PrintScreen / ScrollLock / Pause ride the F13-F15 slots macOS uses.
        0x46: 105, 0x47: 107, 0x48: 113,
        0x49: 114, // Insert
        0x4A: 115, // Home
        0x4B: 116, // Page Up
        0x4C: 117, // Forward Delete
        0x4D: 119, // End
        0x4E: 121, // Page Down
        0x4F: 124, // Right
        0x50: 123, // Left
        0x51: 125, // Down
        0x52: 126, // Up
        // Keypad.
        0x53: 71, // Num Lock / Clear
        0x54: 75, // KP /
        0x55: 67, // KP *
        0x56: 78, // KP -
        0x57: 69, // KP +
        0x58: 76, // KP Enter
        0x59: 83, 0x5A: 84, 0x5B: 85, 0x5C: 86, 0x5D: 87,
        0x5E: 88, 0x5F: 89, 0x60: 91, 0x61: 92, 0x62: 82,
        0x63: 65, // KP .
        0x64: 10, // Non-US \| (ISO section key)
        // Modifiers.
        0xE0: 59, // Left Control
        0xE1: 56, // Left Shift
        0xE2: 58, // Left Alt/Option
        0xE3: 55, // Left GUI/Command
        0xE4: 62, // Right Control
        0xE5: 60, // Right Shift
        0xE6: 61, // Right Alt/Option
        0xE7: 54, // Right GUI/Command
    ]

    /// Carbon virtual keycode -> Windows virtual-key code, used when a UU
    /// Remote target runs Windows (its `kbd_press` wants VK_* values).
    static let windowsVKForCarbon: [UInt16: Int32] = [
        // Letters.
        0: 0x41, 11: 0x42, 8: 0x43, 2: 0x44, 14: 0x45, 3: 0x46,
        5: 0x47, 4: 0x48, 34: 0x49, 38: 0x4A, 40: 0x4B, 37: 0x4C,
        46: 0x4D, 45: 0x4E, 31: 0x4F, 35: 0x50, 12: 0x51, 15: 0x52,
        1: 0x53, 17: 0x54, 32: 0x55, 9: 0x56, 13: 0x57, 7: 0x58,
        16: 0x59, 6: 0x5A,
        // Digits 1-0.
        18: 0x31, 19: 0x32, 20: 0x33, 21: 0x34, 23: 0x35,
        22: 0x36, 26: 0x37, 28: 0x38, 25: 0x39, 29: 0x30,
        // Editing & navigation.
        36: 0x0D, // Return
        53: 0x1B, // Escape
        51: 0x08, // Back
        48: 0x09, // Tab
        49: 0x20, // Space
        27: 0xBD, // OEM_MINUS
        24: 0xBB, // OEM_PLUS
        33: 0xDB, // OEM_4 [
        30: 0xDD, // OEM_6 ]
        42: 0xDC, // OEM_5 \
        41: 0xBA, // OEM_1 ;
        39: 0xDE, // OEM_7 '
        50: 0xC0, // OEM_3 `
        43: 0xBC, // OEM_COMMA
        47: 0xBE, // OEM_PERIOD
        44: 0xBF, // OEM_2 /
        10: 0xE2, // OEM_102
        57: 0x14, // Caps Lock
        // F1-F12.
        122: 0x70, 120: 0x71, 99: 0x72, 118: 0x73,
        96: 0x74, 97: 0x75, 98: 0x76, 100: 0x77,
        101: 0x78, 109: 0x79, 103: 0x7A, 111: 0x7B,
        // F13 slot keys.
        105: 0x2C, // PrintScreen -> VK_SNAPSHOT
        107: 0x91, // Scroll Lock
        113: 0x13, // Pause
        114: 0x2D, // Insert
        115: 0x24, // Home
        116: 0x21, // Page Up
        117: 0x2E, // Delete
        119: 0x23, // End
        121: 0x22, // Page Down
        124: 0x27, 123: 0x25, 125: 0x28, 126: 0x26, // Arrows
        // Keypad.
        71: 0x90, // Num Lock
        75: 0x6F, 67: 0x6A, 78: 0x6D, 69: 0x6B, 76: 0x0D,
        83: 0x61, 84: 0x62, 85: 0x63, 86: 0x64, 87: 0x65,
        88: 0x66, 89: 0x67, 91: 0x68, 92: 0x69, 82: 0x60,
        65: 0x6E, // KP decimal
        // Modifiers.
        59: 0xA2, // VK_LCONTROL
        56: 0xA0, // VK_LSHIFT
        58: 0xA4, // VK_LMENU
        55: 0x5B, // VK_LWIN
        62: 0xA3, // VK_RCONTROL
        60: 0xA1, // VK_RSHIFT
        61: 0xA5, // VK_RMENU
        54: 0x5C, // VK_RWIN
    ]

    /// The Carbon virtual keycode for a UIKit `UIKey`, or nil when the key
    /// is not in the table (callers then rely on `characters`).
    #if canImport(UIKit)
        static func carbonKeyCode(for key: UIKey) -> UInt16? {
            carbonForHID[Int(key.keyCode.rawValue)]
        }
    #endif
}
