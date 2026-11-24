import Foundation

/// QBASIC.EXE. Feature 1 replaces this file with the interpreter and the blue IDE.
enum QBasic {
    static let utilities: [String: CommandHandler] = [:]
    static let stubFiles: [(String, String, Int)] = []
    static let help: [String: String] = [:]
    static let stubVersion = "0"

    /// Feature 1's interpreter half replaces this. Runs a program to completion and
    /// returns the ERRORLEVEL. The IDE supplies its own QBasicIO.
    static func run(source: String, io: QBasicIO) -> Int32 { 1 }
}
