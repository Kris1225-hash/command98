import Foundation
#if canImport(Glibc)
import Glibc
#endif
import XCTest
@testable import command98

final class ScanDiskTests: XCTestCase {
    // MARK: helpers

    private func rows(_ screen: Screen) -> [String] {
        (0..<screen.height).map { y in
            String((0..<screen.width).map { screen[$0, y].ch })
        }
    }

    private func text(_ screen: Screen) -> String {
        rows(screen).joined(separator: "\n")
    }

    private func temporaryOutput() -> (Out, String, Int32) {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("command98-scandisk-\(UUID().uuidString)").path
        let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        precondition(fd >= 0)
        return (Out(fd), path, fd)
    }

    private func finishOutput(_ out: (Out, String, Int32)) -> String {
        close(out.2)
        defer { unlink(out.1) }
        return (try? String(contentsOfFile: out.1, encoding: .utf8)) ?? ""
    }

    private func listing(_ root: URL) -> [String] {
        guard let walk = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        var names: [String] = []
        for case let url as URL in walk { names.append(url.path) }
        return names.sorted()
    }

    // MARK: plan

    func testPlanCountsKnownFilesAndDirectories() {
        let t = TestShell()
        t.write("A.TXT", "one")
        t.write("SUB/B.TXT", "two")
        t.write("SUB/DEEP/C.TXT", "three")

        let plan = ScanDisk.plan(drive: "C", shell: t.shell)

        XCTAssertEqual(plan.drive, "C")
        XCTAssertEqual(plan.files, 3)
        XCTAssertEqual(plan.directories, 2)
        XCTAssertFalse(plan.truncated)
        XCTAssertGreaterThanOrEqual(plan.freeBytes, 0)
        XCTAssertEqual(plan.phases, [
            "Scanning file allocation table",
            "Checking directory structure",
            "Checking for cross-linked files",
            "Scanning for lost clusters",
        ])
    }

    func testSurfaceAddsASurfacePhase() {
        let t = TestShell()
        let plan = ScanDisk.plan(drive: "C", shell: t.shell, surface: true)
        XCTAssertEqual(plan.phases.count, 5)
        XCTAssertTrue(plan.phases.last?.localizedCaseInsensitiveContains("surface") == true)
        XCTAssertFalse(ScanDisk.plan(drive: "C", shell: t.shell).surface)
    }

    func testPlanIsDeterministic() {
        let t = TestShell()
        t.write("ONE.TXT", "1")
        t.write("DIR/TWO.TXT", "2")
        let a = ScanDisk.plan(drive: "C", shell: t.shell)
        let b = ScanDisk.plan(drive: "C", shell: t.shell)
        XCTAssertEqual(a.files, b.files)
        XCTAssertEqual(a.directories, b.directories)
        XCTAssertEqual(a.phases, b.phases)
    }

    // MARK: render

    func testRenderIsBlueEverywhereWithTitleAndPhases() {
        let t = TestShell()
        t.write("A.TXT", "one")
        t.write("SUB/B.TXT", "two")
        let plan = ScanDisk.plan(drive: "C", shell: t.shell, surface: true)
        let screen = ScanDisk.render(plan: plan, progress: 0.5)

        for y in 0..<screen.height {
            for x in 0..<screen.width {
                XCTAssertEqual(screen[x, y].bg, 1, "cell \(x),\(y) is not blue")
                XCTAssertTrue(screen[x, y].fg == 7 || screen[x, y].fg == 15,
                              "cell \(x),\(y) uses an unexpected colour")
            }
        }

        let body = text(screen)
        XCTAssertTrue(body.contains("ScanDisk"))
        XCTAssertTrue(body.contains("Drive C:"))
        XCTAssertTrue(body.contains("2 files"))
        XCTAssertTrue(body.contains("1 directories"))
        XCTAssertTrue(body.contains("bytes free"))
        for phase in plan.phases {
            XCTAssertTrue(body.contains(phase), "missing phase \(phase)")
        }
        XCTAssertEqual(ScanDisk.percent(0.5), 50)
        XCTAssertTrue(body.contains("50%"))
    }

    func testProgressBarIsMonotonic() {
        let t = TestShell()
        t.write("A.TXT", "one")
        let plan = ScanDisk.plan(drive: "C", shell: t.shell)
        let points = [0.0, 0.1, 0.25, 0.5, 0.75, 1.0]
        var lastFill = -1
        var lastPercent = -1
        for p in points {
            let screen = ScanDisk.render(plan: plan, progress: p)
            let fill = rows(screen).joined().filter { $0 == "\u{2588}" }.count
            XCTAssertGreaterThanOrEqual(fill, lastFill)
            XCTAssertGreaterThanOrEqual(ScanDisk.percent(p), lastPercent)
            lastFill = fill
            lastPercent = ScanDisk.percent(p)
        }
        XCTAssertEqual(lastFill, ScanDisk.barFill(1.0))
        XCTAssertEqual(lastPercent, 100)
        XCTAssertEqual(ScanDisk.barFill(0), 0)
    }

    func testSummaryKeepsBlueBackgroundAndHonestWording() {
        let t = TestShell()
        let plan = ScanDisk.plan(drive: "C", shell: t.shell)
        let screen = ScanDisk.renderSummary(plan: plan, outcome: .completed)
        for y in 0..<screen.height {
            for x in 0..<screen.width {
                XCTAssertEqual(screen[x, y].bg, 1)
            }
        }
        let body = text(screen)
        XCTAssertTrue(body.contains("ScanDisk found no errors on drive C:"))
        XCTAssertTrue(body.contains("No errors found by this read-only pass."))
        XCTAssertTrue(body.contains("This build only looks. Use the host disk repair tool to fix anything."))
        XCTAssertTrue(body.contains("Press any key to continue"))
        XCTAssertFalse(body.localizedCaseInsensitiveContains("repaired"))
    }

    // MARK: command loop

    func testCompletionShowsSummary() {
        let t = TestShell()
        t.write("A.TXT", "one")
        let plan = ScanDisk.plan(drive: "C", shell: t.shell)
        let out = temporaryOutput()
        let outcome = ScanDisk.show(plan: plan, out: out.0, driver: .init(
            poll: { .char(" ") },
            wait: {}
        ))
        let shown = finishOutput(out)

        XCTAssertEqual(outcome, .completed)
        XCTAssertTrue(shown.contains("ScanDisk found no errors on drive C:"))
        XCTAssertTrue(shown.contains("No errors found by this read-only pass."))
        XCTAssertTrue(shown.contains("This build only looks. Use the host disk repair tool to fix anything."))
        XCTAssertTrue(shown.contains("Press any key to continue"))
    }

    func testEscapeCancelsAndSaysSo() {
        let t = TestShell()
        let plan = ScanDisk.plan(drive: "C", shell: t.shell)
        var keys: [Key] = [.escape]
        let out = temporaryOutput()
        let outcome = ScanDisk.show(plan: plan, out: out.0, driver: .init(
            poll: {
                if keys.isEmpty { return .char(" ") }
                return keys.removeFirst()
            },
            wait: {}
        ))
        let shown = finishOutput(out)

        XCTAssertEqual(outcome, .cancelled)
        XCTAssertTrue(shown.contains("ScanDisk was cancelled on drive C:"))
        XCTAssertTrue(shown.contains("No changes were made to the disk."))
        XCTAssertTrue(shown.contains("Press any key to continue"))
    }

    func testCtrlCStopsThePass() {
        let t = TestShell()
        let plan = ScanDisk.plan(drive: "C", shell: t.shell)
        let out = temporaryOutput()
        let outcome = ScanDisk.show(plan: plan, out: out.0, driver: .init(
            poll: { .interrupt },
            wait: {}
        ))
        _ = finishOutput(out)
        XCTAssertEqual(outcome, .cancelled)
    }

    func testInterruptFlagStopsTheWalkAndThePass() {
        let t = TestShell()
        t.write("A.TXT", "one")
        gInterrupted = 1
        let plan = ScanDisk.plan(drive: "C", shell: t.shell)
        XCTAssertTrue(plan.truncated)
        let out = temporaryOutput()
        let outcome = ScanDisk.show(plan: plan, out: out.0, driver: .init(
            poll: { .char(" ") },
            wait: {}
        ))
        _ = finishOutput(out)
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(gInterrupted, 0)
    }

    // MARK: read-only guarantees

    func testPassLeavesEverySentinelUntouched() throws {
        let t = TestShell()
        let sentinel = t.write("KEEP.TXT", "do not touch me\r\n")
        t.write("SUB/OTHER.TXT", "other")
        let beforeList = listing(t.root)
        let beforeData = try Data(contentsOf: sentinel)
        let beforeAttrs = try FileManager.default.attributesOfItem(atPath: sentinel.path)
        let beforeDate = beforeAttrs[.modificationDate] as? Date
        let beforeSize = beforeAttrs[.size] as? Int

        let plan = ScanDisk.plan(drive: "C", shell: t.shell, surface: true)
        let out = temporaryOutput()
        _ = ScanDisk.show(plan: plan, out: out.0, driver: .init(
            poll: { .char(" ") },
            wait: {}
        ))
        _ = finishOutput(out)

        XCTAssertEqual(try Data(contentsOf: sentinel), beforeData)
        let afterAttrs = try FileManager.default.attributesOfItem(atPath: sentinel.path)
        XCTAssertEqual(afterAttrs[.modificationDate] as? Date, beforeDate)
        XCTAssertEqual(afterAttrs[.size] as? Int, beforeSize)
        XCTAssertEqual(listing(t.root), beforeList)
        XCTAssertEqual(ScanDisk.plan(drive: "C", shell: t.shell).files, 2)
    }

    func testNonTTYReportIsOnePlainLine() throws {
        let t = TestShell()
        t.write("A.TXT", "one")
        t.write("SUB/B.TXT", "two")
        let target = temporaryOutput()
        let c = Ctx(name: "SCANDISK", rest: " C:", args: ["C:"],
                    io: IO(inFD: 0, out: target.0))
        t.shell.uScanDisk(c)
        let shown = finishOutput(target)

        XCTAssertFalse(shown.contains("\u{1B}"))
        XCTAssertEqual(shown.filter { $0 == "\n" }.count, 1)
        XCTAssertTrue(shown.contains("ScanDisk: drive C:"))
        XCTAssertTrue(shown.contains("2 files, 1 directories"))
        XCTAssertTrue(shown.contains("bytes free"))
        XCTAssertTrue(shown.contains("No errors found by this read-only pass."))
        XCTAssertTrue(shown.contains("Nothing was changed."))
    }

    func testInvalidDriveIsRejectedBeforeAnyScreen() {
        let t = TestShell()
        let target = temporaryOutput()
        t.shell.uScanDisk(Ctx(name: "SCANDISK", rest: " Z:", args: ["Z:"],
                              io: IO(inFD: 0, out: target.0)))
        let shown = finishOutput(target)
        XCTAssertEqual(shown, "Invalid drive specification\n")
    }

    func testRegistrationOverridesTheRetiredStub() {
        XCTAssertNotNil(ScanDisk.utilities["SCANDISK"])
        XCTAssertNotNil(Shell.utilities["SCANDISK"])
        XCTAssertTrue(ScanDisk.stubFiles.contains { $0.1 == "SCANDISK.INI" && $0.0 == "WINDOWS\\COMMAND" })
        XCTAssertEqual(ScanDisk.stubVersion, "1")
        XCTAssertTrue(ScanDisk.help["SCANDISK"]?.contains("/SURFACE") == true)
        XCTAssertTrue(Shell.helpText("SCANDISK").contains("SCANDISK [drive:] [/SURFACE]"))
        XCTAssertTrue(Shell.helpText("SCANDISK").contains("fsck"))
    }
}
