//
//  VNCKeySyms.swift
//  CatusshModule
//
//  Maps UIKit/AppKit key codes and characters to the X11 KeySyms RFB
//  KeyEvent messages carry. Key codes follow the Carbon HIToolbox layout
//  (the values `UIKeyboardHIDUsage` and AppKit `keyCode` share).
//

import Foundation

enum VNCKeySyms {
    // Selected X11 KeySyms (see keysymdef.h).
    static let backSpace: UInt32 = 0xFF08
    static let tab: UInt32 = 0xFF09
    static let `return`: UInt32 = 0xFF0D
    static let escape: UInt32 = 0xFF1B
    static let insert: UInt32 = 0xFF63
    static let delete: UInt32 = 0xFFFF
    static let home: UInt32 = 0xFF50
    static let left: UInt32 = 0xFF51
    static let up: UInt32 = 0xFF52
    static let right: UInt32 = 0xFF53
    static let down: UInt32 = 0xFF54
    static let pageUp: UInt32 = 0xFF55
    static let pageDown: UInt32 = 0xFF56
    static let end: UInt32 = 0xFF57
    static let numLock: UInt32 = 0xFF7F
    static let f1: UInt32 = 0xFFBE
    // F2...F12 are f1 + 1 ... f1 + 11.
    static let shiftL: UInt32 = 0xFFE1
    static let shiftR: UInt32 = 0xFFE2
    static let controlL: UInt32 = 0xFFE3
    static let controlR: UInt32 = 0xFFE4
    static let capsLock: UInt32 = 0xFFE5
    static let altL: UInt32 = 0xFFE9
    static let altR: UInt32 = 0xFFEA
    static let superL: UInt32 = 0xFFEB
    static let superR: UInt32 = 0xFFEC
    static let space: UInt32 = 0x20

    /// Physical key -> KeySym, for keys that do not produce text.
    private static let byKeyCode: [UInt16: UInt32] = [
        36: `return`, // Return
        76: `return`, // Keypad Enter
        48: tab,
        51: backSpace,
        53: escape,
        49: space,
        117: delete, // Forward delete
        114: insert, // Help / Insert
        115: home,
        119: end,
        116: pageUp,
        121: pageDown,
        123: left,
        126: up,
        124: right,
        125: down,
        122: f1, 120: f1 + 1, 99: f1 + 2, 118: f1 + 3,
        96: f1 + 4, 97: f1 + 5, 98: f1 + 6, 100: f1 + 7,
        101: f1 + 8, 109: f1 + 9, 103: f1 + 10, 111: f1 + 11,
        105: f1 + 12, // F13 shows as F13 on some layouts; send F13 keysym
        107: f1 + 13, // F14
        113: f1 + 14, // F15
        56: shiftL, 60: shiftR,
        59: controlL, 62: controlR,
        58: altL, 61: altR,
        55: superL, 54: superR, // Command -> Super
        57: capsLock,
        71: numLock, // Clear / Num Lock
    ]

    /// The KeySym for a key event: the physical code first (so Escape is
    /// Escape even when IME would turn its character into something else),
    /// then the produced text.
    static func keySym(forKeyCode keyCode: UInt16, characters: String) -> UInt32? {
        if let sym = byKeyCode[keyCode] {
            return sym
        }
        return keySym(forCharacter: characters)
    }

    /// The KeySym for a produced character: control characters get their
    /// special names, ASCII stays ASCII, the Latin-1 supplement maps to the
    /// same KeySym value (per keysymdef.h, U+00A0...U+00FF keep their
    /// codepoint), and other Unicode scalars become 0x01000000 | scalar
    /// per the RFB convention.
    static func keySym(forCharacter characters: String) -> UInt32? {
        guard let scalar = characters.unicodeScalars.first else { return nil }
        switch scalar.value {
        case 0x08, 0x7F: return backSpace
        case 0x09: return tab
        case 0x0A, 0x0D: return `return`
        case 0x1B: return escape
        case 0x20 ... 0x7E: return scalar.value // printable ASCII
        case 0xA0 ... 0xFF: return scalar.value // Latin-1 supplement
        default:
            return 0x0100_0000 | scalar.value
        }
    }
}
