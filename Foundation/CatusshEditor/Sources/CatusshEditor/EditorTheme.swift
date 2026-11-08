#if os(iOS)
import CatusshDesign
import Runestone
import SwiftUI
import UIKit

/// Editor colours drawn from the app's tokens, so the editor reads as part of
/// catussh in light and dark mode rather than as a separate tool.
final class EditorTheme: Runestone.Theme {
    let font: UIFont
    let lineNumberFont: UIFont

    init(size: CGFloat) {
        font = .monospacedSystemFont(ofSize: size, weight: .regular)
        lineNumberFont = .monospacedDigitSystemFont(ofSize: size * 0.85, weight: .regular)
    }

    private static func dynamic(light: UIColor, dark: UIColor) -> UIColor {
        UIColor { $0.userInterfaceStyle == .dark ? dark : light }
    }

    private static func hex(_ value: UInt32) -> UIColor {
        UIColor(
            red: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }

    let textColor = UIColor(Color.rxInk)
    let gutterBackgroundColor = UIColor.clear
    let gutterHairlineColor = UIColor(Color.rxHairline)
    let lineNumberColor = UIColor(Color.rxInkTertiary)
    let selectedLineBackgroundColor = UIColor(Color.rxAccent).withAlphaComponent(0.07)
    let selectedLinesLineNumberColor = UIColor(Color.rxInk)
    let selectedLinesGutterBackgroundColor = UIColor.clear
    let invisibleCharactersColor = UIColor(Color.rxInkTertiary).withAlphaComponent(0.6)
    let pageGuideHairlineColor = UIColor(Color.rxHairline)
    let pageGuideBackgroundColor = UIColor.clear
    let markedTextBackgroundColor = UIColor(Color.rxAccent).withAlphaComponent(0.15)

    // Syntax colours: muted enough for long reading, distinct in both modes.
    private let keyword = dynamic(light: hex(0x9B2393), dark: hex(0xFC5FA3))
    private let string = dynamic(light: hex(0xC41A16), dark: hex(0xFC6A5D))
    private let number = dynamic(light: hex(0x1C00CF), dark: hex(0xD0BF69))
    private let comment = dynamic(light: hex(0x5D6C79), dark: hex(0x7F8C98))
    private let type = dynamic(light: hex(0x0B4F79), dark: hex(0x5DD8FF))
    private let function = dynamic(light: hex(0x326D74), dark: hex(0x67B7A4))
    private let property = dynamic(light: hex(0x3E8087), dark: hex(0x9EF1DD))
    private let constant = dynamic(light: hex(0x6C36A9), dark: hex(0xD0A8FF))

    func textColor(for highlightName: String) -> UIColor? {
        if highlightName.hasPrefix("variable.builtin") { return constant }
        switch highlightName.split(separator: ".").first.map(String.init) ?? highlightName {
        case "keyword", "include", "conditional", "repeat", "exception", "storageclass": return keyword
        case "string", "character", "escape": return string
        case "number", "float", "boolean": return number
        case "comment": return comment
        case "type", "constructor", "namespace", "tag": return type
        case "function", "method": return function
        case "property", "field", "attribute", "label": return property
        case "constant": return constant
        case "operator", "punctuation": return UIColor(Color.rxInkSecondary)
        default: return nil
        }
    }

    func fontTraits(for highlightName: String) -> FontTraits {
        highlightName.hasPrefix("comment") ? [.italic] : []
    }
}
#endif
