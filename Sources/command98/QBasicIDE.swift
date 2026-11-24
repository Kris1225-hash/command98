import Foundation

/// The blue full-screen editor. Feature 1's IDE half replaces this file. The interpreter
/// half calls `run` for an interactive launch; keeping the placeholder here lets both
/// halves compile on their own branches.
enum QBasicIDE {
    static func run(_ shell: Shell, _ io: IO, file: String?) -> Int32 {
        io.out.line("QBASIC editor not built yet.")
        return 1
    }
}
