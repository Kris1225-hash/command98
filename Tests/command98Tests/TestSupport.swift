import Foundation
import XCTest
@testable import command98

/// Captured output is compared as text. Windows descriptors opened in text mode hand
/// back CRLF, while every assertion is written against the DOS shell's LF stream, so the
/// reader normalises it. POSIX output is already LF and passes through unchanged.
func normalizedCapture(_ s: String) -> String {
    s.contains("\r\n") ? s.replacingOccurrences(of: "\r\n", with: "\n") : s
}

/// A temporary file opened for raw bytes. Tests hand its descriptor to `Out`. On Windows
/// FileHandle has no descriptor, so the portable Platform entry points do the work.
final class CaptureFile {
    let url: URL
    private let descriptor: Int32
    private var isClosed = false

    init(prefix: String) {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)")
        guard let fd = Platform.openWrite(url.path, append: false) else {
            fatalError("could not create capture file at \(url.path)")
        }
        descriptor = fd
    }

    var fd: Int32 { descriptor }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        Platform.closeFD(descriptor)
    }

    func text() -> String {
        normalizedCapture((try? String(contentsOf: url, encoding: .utf8)) ?? "")
    }

    func remove() {
        close()
        try? FileManager.default.removeItem(at: url)
    }
}

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

    /// Relative names in the tests use forward slashes on every platform, so append each
    /// component instead of asking URL to interpret the separators.
    private func testURL(_ name: String) -> URL {
        name.split(separator: "/").reduce(root) { $0.appendingPathComponent(String($1)) }
    }

    @discardableResult
    func write(_ name: String, _ text: String) -> URL {
        let u = testURL(name)
        try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? text.write(to: u, atomically: true, encoding: .utf8)
        return u
    }

    func read(_ name: String) -> String {
        (try? String(contentsOf: testURL(name), encoding: .utf8)) ?? ""
    }

    /// Runs one line. `typed` applies the interactive `%VAR%` pass; `input` becomes stdin.
    func run(_ line: String, input: String = "", typed: Bool = false) -> String {
        guard let outFD = Platform.openWrite(outPath, append: false) else { return "" }
        var inFD: Int32 = 0
        var inPath: String? = nil
        if !input.isEmpty {
            let p = root.appendingPathComponent(".stdin-\(UUID().uuidString)").path
            try? input.write(toFile: p, atomically: true, encoding: .utf8)
            inFD = Platform.openRead(p) ?? 0
            inPath = p
        }
        let text = typed ? shell.expandTyped(line) : line
        shell.runLine(text, io: IO(inFD: inFD, out: Out(outFD)))
        Platform.closeFD(outFD)
        if inFD != 0 { Platform.closeFD(inFD) }
        if let p = inPath { try? FileManager.default.removeItem(atPath: p) }
        return normalizedCapture((try? String(contentsOfFile: outPath, encoding: .utf8)) ?? "")
    }
}
