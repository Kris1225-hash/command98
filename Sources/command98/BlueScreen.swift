import Foundation

/// Feature 8 replaces this file. Boot and WIN call it; it draws on the same Screen buffer
/// as the other full-screen tools.
enum BlueScreen {
    static let utilities: [String: CommandHandler] = [:]
    static let stubFiles: [(String, String, Int)] = []
    static let help: [String: String] = [:]
    static let stubVersion = "0"

    static func show(_ out: Out, reason: String = "") {}
}
