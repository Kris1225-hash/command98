import Foundation

/// ANSI.SYS. The host terminal already speaks the same language, so once the driver is
/// loaded the escape stream goes through. Before that, an escape is just a character.
/// Feature 5 replaces this file; the rest of the shell only calls it.
enum AnsiSys {
    /// Every terminal on these platforms is an ANSI terminal. CONFIG.SYS can say so too.
    static var loaded = true
    static var foreground: UInt8 = 7
    static var background: UInt8 = 0

    static func load() { loaded = true }

    static func reset() {
        foreground = 7
        background = 0
    }

    /// Called by Out.write for every normal write. `control` output skips this.
    static func encode(_ s: String, fd: Int32) -> String {
        guard !loaded, s.contains("\u{1B}") else { return s }
        return s.replacingOccurrences(of: "\u{1B}", with: "\u{2190}")
    }
}
