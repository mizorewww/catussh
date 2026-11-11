import Foundation

/// The terminal's settings as the app's iCloud sync sees them: each one that
/// was set, by its Ghostty name, and a way to take those another device set.
@MainActor
public enum TerminalConfigurationSync {
    /// What is set here, including an edit not saved yet: it is saved in a
    /// moment, and a setting that cannot be saved is not taken for removed.
    public static var overrides: [String: [String]] {
        ConfigEditorModel.shared.document.overrides
    }

    /// Sets (or, for nil, resets) settings and applies them to every terminal.
    public static func adopt(_ changes: [String: [String]?]) {
        guard !changes.isEmpty else { return }
        ConfigEditorModel.shared.adopt(changes)
    }
}
