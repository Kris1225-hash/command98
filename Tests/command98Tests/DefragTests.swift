import Foundation
import XCTest
@testable import command98

final class DefragTests: XCTestCase {
    private func capture(_ body: (Out) -> Void) -> String {
        let file = CaptureFile(prefix: "command98-defrag")
        body(Out(file.fd))
        file.close()
        let text = file.text()
        file.remove()
        return text
    }

    private func row(_ screen: Screen, _ y: Int) -> String {
        String((0..<screen.width).map { screen[$0, y].ch })
    }

    func testPlanIsDeterministicSyntheticAndOnPage() {
        let first = Defrag.plan(drive: "C")
        let second = Defrag.plan(drive: "C")

        XCTAssertEqual(first.used, second.used)
        XCTAssertEqual(first.used.count, Defrag.columns * Defrag.rows)
        XCTAssertEqual(first.blockCount, 200)
        XCTAssertGreaterThan(first.usedCount, 0)
        XCTAssertLessThan(first.usedCount, first.blockCount)
        XCTAssertEqual(first.totalClusters, first.blockCount * Defrag.clustersPerBlock)

        // The picture is seeded from the letter, so another drive is another map.
        XCTAssertNotEqual(first.used, Defrag.plan(drive: "D").used)

        for progress in [0.0, 0.5, 1.0] {
            let screen = Defrag.frame(first, progress: progress)
            XCTAssertEqual(screen.width, 80)
            XCTAssertEqual(screen.height, 25)
            XCTAssertEqual(screen.cells.count, 2000)
        }
    }

    func testFramePaintsBluePageTitleLegendAndProgress() {
        let plan = Defrag.plan(drive: "C")
        let screen = Defrag.frame(plan, progress: 0.5)

        XCTAssertEqual(screen[0, 0].bg, 1)
        XCTAssertEqual(screen[79, 24].bg, 1)
        XCTAssertTrue(row(screen, 1).contains("Drive C: Defragmentation"))
        XCTAssertEqual(screen[40, 1].bg, 1)

        let legend = row(screen, 4)
        for label in ["Used", "Free", "Moving", "Done"] {
            XCTAssertTrue(legend.contains(label), "legend is missing \(label)")
        }

        XCTAssertEqual(screen[Defrag.mapX, Defrag.barY].bg, 2)
        XCTAssertEqual(screen[Defrag.mapX + Defrag.barWidth - 1, Defrag.barY].bg, 8)
        XCTAssertTrue(row(screen, 18).contains("50% complete"))
        XCTAssertTrue(row(screen, 19).contains("Cluster"))
        XCTAssertTrue(row(screen, 19).contains("of \(plan.totalClusters)"))
        XCTAssertTrue(row(screen, 20).contains("Press Esc to cancel"))
    }

    func testAnimationFramesChangeAndFinishGreen() {
        let plan = Defrag.plan(drive: "C")
        let start = Defrag.frame(plan, progress: 0)
        let middle = Defrag.frame(plan, progress: 0.5)
        let end = Defrag.frame(plan, progress: 1)

        XCTAssertNotEqual(start.cells, middle.cells)
        XCTAssertNotEqual(middle.cells, end.cells)
        XCTAssertTrue(row(start, 18).contains("0% complete"))
        XCTAssertTrue(row(end, 18).contains("100% complete"))
        XCTAssertTrue(row(end, 19).contains("of \(plan.totalClusters)"))

        // At the end every occupied slot in the packed front is green.
        let states = Defrag.blockStates(plan, progress: 1)
        XCTAssertEqual(Array(states.prefix(plan.usedCount)), Array(repeating: .done, count: plan.usedCount))
        XCTAssertEqual(states.filter { $0 == .done }.count, plan.usedCount)
        XCTAssertEqual(states.filter { $0 == .free }.count, plan.blockCount - plan.usedCount)
    }

    func testAnimateRendersFramesAndRestoresTheScreen() {
        let plan = Defrag.plan(drive: "C")
        var screens: [Screen] = []
        let bytes = capture { out in
            let outcome = Defrag.animate(plan, out: out, frames: 4, tick: { _ in }, key: { nil }) { screen, _ in
                screens.append(screen)
            }
            XCTAssertEqual(outcome, .complete)
        }

        XCTAssertEqual(screens.count, 4)
        XCTAssertNotEqual(screens[0].cells, screens[3].cells)
        XCTAssertTrue(bytes.contains("\u{1B}[?1049h"), "the alternate screen was never entered")
        XCTAssertTrue(bytes.contains("\u{1B}[?1049l"), "the alternate screen was never left")
        XCTAssertTrue(bytes.contains("\u{1B}[?25h"), "the cursor was never restored")
        XCTAssertTrue(bytes.contains("Drive C: Defragmentation"))
        XCTAssertTrue(bytes.contains("Press Esc to cancel"))
    }

    func testRunCompletesWithOneSummaryLine() {
        let bytes = capture { out in
            let outcome = Defrag.run(drive: "C", out: out, frames: 3, tick: { _ in }, key: { nil })
            XCTAssertEqual(outcome, .complete)
        }

        XCTAssertTrue(bytes.contains("\u{1B}[?1049l"))
        XCTAssertTrue(bytes.contains("Defragmentation complete. No files were moved."))
        XCTAssertFalse(bytes.contains("Defrag cancelled"))
    }

    func testRunCancelsOnEscapeAndRestoresTheScreen() {
        var polls = 0
        let bytes = capture { out in
            let outcome = Defrag.run(drive: "C", out: out, frames: 5, tick: { _ in }, key: {
                polls += 1
                return polls == 2 ? .escape : nil
            })
            XCTAssertEqual(outcome, .cancelled)
        }

        XCTAssertTrue(bytes.contains("\u{1B}[?1049l"))
        XCTAssertTrue(bytes.contains("\u{1B}[?25h"))
        XCTAssertTrue(bytes.contains("Defrag cancelled. No files were moved."))
        XCTAssertFalse(bytes.contains("Defragmentation complete."))
    }

    /// The command is cosmetic. If it ever reached for a file, this would notice.
    func testSentinelFilesAreUntouched() throws {
        let t = TestShell()
        let one = t.write("KEEP.TXT", "do not touch\n")
        let two = t.write("NOTES/PLAN.TXT", "still here\n")
        let before = try Data(contentsOf: one)
        let beforeTwo = try Data(contentsOf: two)
        let mtime = try FileManager.default.attributesOfItem(atPath: one.path)[.modificationDate] as? Date
        let mtimeTwo = try FileManager.default.attributesOfItem(atPath: two.path)[.modificationDate] as? Date
        let listing = try FileManager.default.contentsOfDirectory(atPath: t.root.path).sorted()

        _ = capture { out in
            _ = Defrag.run(drive: "C", out: out, frames: 4, tick: { _ in }, key: { nil })
        }

        XCTAssertEqual(try Data(contentsOf: one), before)
        XCTAssertEqual(try Data(contentsOf: two), beforeTwo)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: one.path)[.modificationDate] as? Date, mtime)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: two.path)[.modificationDate] as? Date, mtimeTwo)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: t.root.path).sorted(), listing)
    }

    func testRegistrationAndHelp() {
        XCTAssertNotNil(Defrag.utilities["DEFRAG"])
        XCTAssertTrue(Defrag.stubFiles.contains {
            $0.0 == "WINDOWS\\COMMAND" && $0.1 == "DEFRAG.EXE" && $0.2 > 100_000
        })
        XCTAssertEqual(Defrag.stubVersion, "1")
        XCTAssertNotNil(Defrag.help["DEFRAG"])
        XCTAssertTrue(Shell.featureHelp["DEFRAG"]?.contains("DEFRAG [drive:]") == true)
    }

    func testInvalidDriveIsRefusedBeforeAnyDrawing() {
        let t = TestShell()
        let output = capture { out in
            let ctx = Ctx(name: "DEFRAG", rest: " Z:", args: ["Z:"], io: IO(inFD: 0, out: out))
            Defrag.utilities["DEFRAG"]?(t.shell)(ctx)
        }
        XCTAssertTrue(output.contains("Invalid drive specification"))
        XCTAssertFalse(output.contains("\u{1B}[?1049h"))
    }
}
