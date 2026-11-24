import Foundation
#if canImport(Glibc)
import Glibc
#endif
import XCTest
@testable import command98

/// A sandbox shell for tests. Output goes to a file (never the test's terminal), input can
/// be a file, and every test gets its own C: so nothing leaks between them.
final class TestShell {
    let root: URL
    let shell: Shell
    private let outPath: String

    init() {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("command98-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let drives = Drives()
        drives.mount("C", root.path, sandbox: true)
        drives.current = "C"
        shell = Shell(drives: drives)
        outPath = root.appendingPathComponent(".stdout").path
        gInterrupted = 0
        Doskey.installed = false
        Doskey.history.removeAll()
        Doskey.macros.removeAll()
        AnsiSys.loaded = true
        AnsiSys.reset()
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    func write(_ name: String, _ text: String) -> URL {
        let u = root.appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? text.write(to: u, atomically: true, encoding: .utf8)
        return u
    }

    func read(_ name: String) -> String {
        (try? String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)) ?? ""
    }

    /// Runs one line. `typed` applies the interactive `%VAR%` pass; `input` becomes stdin.
    func run(_ line: String, input: String = "", typed: Bool = false) -> String {
        let outFD = open(outPath, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        precondition(outFD >= 0)
        var inFD: Int32 = 0
        var inPath: String? = nil
        if !input.isEmpty {
            let p = root.appendingPathComponent(".stdin-\(UUID().uuidString)").path
            try? input.write(toFile: p, atomically: true, encoding: .utf8)
            inFD = open(p, O_RDONLY)
            inPath = p
        }
        let text = typed ? shell.expandTyped(line) : line
        shell.runLine(text, io: IO(inFD: inFD, out: Out(outFD)))
        close(outFD)
        if inFD != 0 {
            close(inFD)
            if let p = inPath { unlink(p) }
        }
        return (try? String(contentsOfFile: outPath, encoding: .utf8)) ?? ""
    }
}
