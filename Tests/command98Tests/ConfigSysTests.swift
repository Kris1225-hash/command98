import Foundation
import XCTest
@testable import command98

/// CONFIG.SYS acknowledgement. The shell never refuses to boot over a bad line, so every
/// test here checks that a value was either taken or set aside verbatim.
final class ConfigSysTests: XCTestCase {
    override func tearDown() {
        AnsiSys.loaded = true
        AnsiSys.reset()
        super.tearDown()
    }

    private func sample(_ eol: String = "\r\n") -> String {
        [
            "REM a sample machine",
            "; semicolon comment",
            "",
            "  FILES=40  ",
            "BUFFERS = 20",
            "DEVICE=C:\\WINDOWS\\HIMEM.SYS",
            "DEVICE=C:\\WINDOWS\\COMMAND\\ANSI.SYS",
            "DEVICEHIGH=C:\\WINDOWS\\COMMAND\\OAKCDROM.SYS /D:MSCD001",
            "LASTDRIVE=Z",
            "STACKS=9,256",
            "SHELL=C:\\WINDOWS\\COMMAND.COM /P /E:512",
            "SET TMP=C:\\TMP",
            "DOS=HIGH,UMB",
            "FOO=1",
            "FILES=abc",
            "\u{001A}",
            "BUFFERS=99",
            "",
        ].joined(separator: eol)
    }

    func testFullFile() {
        AnsiSys.loaded = false
        let v = ConfigSys.parse(sample())
        XCTAssertEqual(v.files, 40)
        XCTAssertEqual(v.buffers, 20)
        XCTAssertNil(v.buffersHigh)
        XCTAssertEqual(v.fcbs, "4,0")
        XCTAssertEqual(v.lastDrive, "Z")
        XCTAssertEqual(v.stacks, "9,256")
        XCTAssertEqual(v.shellCommand, "C:\\WINDOWS\\COMMAND.COM /P /E:512")
        XCTAssertNil(v.country)
        XCTAssertTrue(v.breakOn == false)
        XCTAssertTrue(v.dosHigh)
        XCTAssertTrue(v.dosUMB)
        XCTAssertEqual(v.devices, ["C:\\WINDOWS\\HIMEM.SYS"])
        XCTAssertEqual(v.devicesHigh, ["C:\\WINDOWS\\COMMAND\\OAKCDROM.SYS /D:MSCD001"])
        XCTAssertEqual(v.installs, [])
        XCTAssertEqual(v.sets["TMP"], "C:\\TMP")
        XCTAssertEqual(v.unknown, ["FOO=1"])
        XCTAssertEqual(v.errors, ["FILES=abc"])
        XCTAssertFalse(v.bootGui)
        XCTAssertTrue(AnsiSys.loaded)
    }

    func testFullFileWithLineFeeds() {
        let v = ConfigSys.parse(sample("\n"))
        XCTAssertEqual(v.files, 40)
        XCTAssertEqual(v.buffers, 20)
        XCTAssertEqual(v.lastDrive, "Z")
        XCTAssertEqual(v.unknown, ["FOO=1"])
        XCTAssertEqual(v.errors, ["FILES=abc"])
    }

    func testEmptyTextGivesDefaults() {
        let v = ConfigSys.parse("")
        XCTAssertEqual(v.files, 30)
        XCTAssertEqual(v.buffers, 30)
        XCTAssertNil(v.buffersHigh)
        XCTAssertEqual(v.fcbs, "4,0")
        XCTAssertEqual(v.lastDrive, "Z")
        XCTAssertEqual(v.stacks, "9,256")
        XCTAssertNil(v.shellCommand)
        XCTAssertNil(v.country)
        XCTAssertFalse(v.breakOn)
        XCTAssertFalse(v.dosHigh)
        XCTAssertFalse(v.dosUMB)
        XCTAssertTrue(v.devices.isEmpty)
        XCTAssertTrue(v.devicesHigh.isEmpty)
        XCTAssertTrue(v.installs.isEmpty)
        XCTAssertTrue(v.sets.isEmpty)
        XCTAssertTrue(v.unknown.isEmpty)
        XCTAssertTrue(v.errors.isEmpty)
        XCTAssertFalse(v.bootGui)
    }

    func testCommentsBlankLinesAndBareRemAreIgnored() {
        let v = ConfigSys.parse("   ; first\n\t; second\n\n   \t \nREM\nREM more text\n")
        XCTAssertTrue(v.unknown.isEmpty)
        XCTAssertTrue(v.errors.isEmpty)
        XCTAssertEqual(v.files, 30)
    }

    func testSpacingAndCaseAreFlexible() {
        let v = ConfigSys.parse("fIlEs\t=\t42\nbreak = ON\nlastdrive = c\n")
        XCTAssertEqual(v.files, 42)
        XCTAssertTrue(v.breakOn)
        XCTAssertEqual(v.lastDrive, "C")
        XCTAssertTrue(v.unknown.isEmpty)
        XCTAssertTrue(v.errors.isEmpty)
    }

    func testBuffersHighKeepsItsOwnNumber() {
        let v = ConfigSys.parse("BUFFERS=10\nBUFFERSHIGH=24\n")
        XCTAssertEqual(v.buffers, 10)
        XCTAssertEqual(v.buffersHigh, 24)
        let bad = ConfigSys.parse("BUFFERSHIGH=plenty\n")
        XCTAssertNil(bad.buffersHigh)
        XCTAssertEqual(bad.errors, ["BUFFERSHIGH=plenty"])
        XCTAssertEqual(bad.buffers, 30)
    }

    func testFcbsPair() {
        let v = ConfigSys.parse("FCBS=8,16\n")
        XCTAssertEqual(v.fcbs, "8,16")
        let spaced = ConfigSys.parse("FCBS = 8, 16\n")
        XCTAssertEqual(spaced.fcbs, "8,16")
        XCTAssertTrue(spaced.errors.isEmpty)
        let bad = ConfigSys.parse("FCBS=8\n")
        XCTAssertEqual(bad.fcbs, "4,0")
        XCTAssertEqual(bad.errors, ["FCBS=8"])
    }

    func testStacksPair() {
        let v = ConfigSys.parse("STACKS=4,512\n")
        XCTAssertEqual(v.stacks, "4,512")
        let bad = ConfigSys.parse("STACKS=4\n")
        XCTAssertEqual(bad.stacks, "9,256")
        XCTAssertEqual(bad.errors, ["STACKS=4"])
    }

    func testLastDriveMustBeOneLetter() {
        XCTAssertEqual(ConfigSys.parse("LASTDRIVE=z\n").lastDrive, "Z")
        let bad = ConfigSys.parse("LASTDRIVE=ZZ\nLASTDRIVE=1\nLASTDRIVE=\n")
        XCTAssertEqual(bad.lastDrive, "Z")
        XCTAssertEqual(bad.errors.count, 3)
    }

    func testDosFlagCombinations() {
        XCTAssertTrue(ConfigSys.parse("DOS=HIGH\n").dosHigh)
        XCTAssertFalse(ConfigSys.parse("DOS=HIGH\n").dosUMB)

        let umb = ConfigSys.parse("DOS=UMB\n")
        XCTAssertTrue(umb.dosUMB)
        XCTAssertFalse(umb.dosHigh)

        let bad = ConfigSys.parse("DOS=HIGH,LOW\n")
        XCTAssertFalse(bad.dosHigh)
        XCTAssertFalse(bad.dosUMB)
        XCTAssertEqual(bad.errors, ["DOS=HIGH,LOW"])

        XCTAssertEqual(ConfigSys.parse("DOS=\n").errors, ["DOS="])
    }

    func testBreakToggles() {
        XCTAssertTrue(ConfigSys.parse("BREAK=ON\n").breakOn)
        XCTAssertFalse(ConfigSys.parse("BREAK=OFF\n").breakOn)
        XCTAssertFalse(ConfigSys.parse("BREAK=ON\nBREAK=OFF\n").breakOn)
        XCTAssertEqual(ConfigSys.parse("BREAK=maybe\n").errors, ["BREAK=maybe"])
    }

    func testCountryRecorded() {
        let v = ConfigSys.parse("COUNTRY=044,437,C:\\DOS\n")
        XCTAssertEqual(v.country, "044,437,C:\\DOS")
        XCTAssertTrue(v.errors.isEmpty)

        XCTAssertEqual(ConfigSys.parse("COUNTRY=044\n").country, "044")
        XCTAssertEqual(ConfigSys.parse("COUNTRY=abc\n").errors, ["COUNTRY=abc"])
        XCTAssertEqual(ConfigSys.parse("COUNTRY=044,,437\n").errors, ["COUNTRY=044,,437"])
        XCTAssertEqual(ConfigSys.parse("COUNTRY=044,437,extra,field\n").errors.count, 1)
    }

    func testSetPairs() {
        let v = ConfigSys.parse("SET TMP=C:\\TMP\nset two = a=b\nSET EMPTY=\n")
        XCTAssertEqual(v.sets["TMP"], "C:\\TMP")
        XCTAssertEqual(v.sets["TWO"], "a=b")
        XCTAssertEqual(v.sets["EMPTY"], "")
        XCTAssertTrue(v.errors.isEmpty)

        let bad = ConfigSys.parse("SET NOEQUALS\nSET =x\n")
        XCTAssertEqual(bad.errors, ["SET NOEQUALS", "SET =x"])
    }

    func testDeviceAndInstallLists() {
        let v = ConfigSys.parse("""
        DEVICE=C:\\WINDOWS\\HIMEM.SYS
        DEVICEHIGH=C:\\WINDOWS\\EMM386.EXE NOEMS
        INSTALL=C:\\DOS\\KEYB.COM
        INSTALL=C:\\DOS\\SHARE.EXE /L:500
        """)
        XCTAssertEqual(v.devices, ["C:\\WINDOWS\\HIMEM.SYS"])
        XCTAssertEqual(v.devicesHigh, ["C:\\WINDOWS\\EMM386.EXE NOEMS"])
        XCTAssertEqual(v.installs, ["C:\\DOS\\KEYB.COM", "C:\\DOS\\SHARE.EXE /L:500"])
        XCTAssertTrue(v.errors.isEmpty)
    }

    func testAnsiDeviceLoadsAndIsNotADeviceEntry() {
        AnsiSys.loaded = false
        let v = ConfigSys.parse("DEVICE=C:\\WINDOWS\\COMMAND\\ANSI.SYS\n")
        XCTAssertTrue(AnsiSys.loaded)
        XCTAssertTrue(v.devices.isEmpty)
        XCTAssertTrue(v.errors.isEmpty)
    }

    func testAnsiDeviceWithUnixSlashesAndCase() {
        AnsiSys.loaded = false
        let v = ConfigSys.parse("device=c:/windows/command/ansi.sys\n")
        XCTAssertTrue(AnsiSys.loaded)
        XCTAssertTrue(v.devices.isEmpty)
    }

    func testAnsiDeviceHighAlsoLoads() {
        AnsiSys.loaded = false
        _ = ConfigSys.parse("DEVICEHIGH=ANSI.SYS\n")
        XCTAssertTrue(AnsiSys.loaded)
    }

    func testEmptyDeviceShellAndInstallAreErrors() {
        let v = ConfigSys.parse("DEVICE=\nDEVICEHIGH=\nINSTALL=\nSHELL=\n")
        XCTAssertEqual(v.errors, ["DEVICE=", "DEVICEHIGH=", "INSTALL=", "SHELL="])
        XCTAssertNil(v.shellCommand)
        XCTAssertTrue(v.devices.isEmpty)
        XCTAssertTrue(v.devicesHigh.isEmpty)
        XCTAssertTrue(v.installs.isEmpty)
    }

    func testUnknownDirectivesAndMalformedSyntax() {
        let v = ConfigSys.parse("GARBAGE\nFILES 40\nREMARK=1\n=5\n\n")
        XCTAssertEqual(v.unknown, ["GARBAGE", "FILES 40", "REMARK=1", "=5"])
        XCTAssertEqual(v.files, 30)
        XCTAssertTrue(v.errors.isEmpty)
    }

    func testControlZEndsTheFile() {
        XCTAssertEqual(ConfigSys.parse("FILES=40\n\u{001A}\nFILES=99\n").files, 40)
        let atStart = ConfigSys.parse("\u{001A}FILES=99\n")
        XCTAssertEqual(atStart.files, 30)
        XCTAssertTrue(atStart.unknown.isEmpty)
    }

    func testUTF8BOMIsIgnored() {
        let v = ConfigSys.parse("\u{FEFF}FILES=12\n")
        XCTAssertEqual(v.files, 12)
        XCTAssertTrue(v.unknown.isEmpty)
    }

    func testReadReturnsFileText() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("c98-config-read-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertNil(ConfigSys.read(root: root))
        try? "FILES=44\r\n".write(to: root.appendingPathComponent("CONFIG.SYS"), atomically: true, encoding: .utf8)
        XCTAssertEqual(ConfigSys.read(root: root), "FILES=44\r\n")
    }

    func testReadFindsLowercaseName() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("c98-config-case-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try? "BUFFERS=9\n".write(to: root.appendingPathComponent("config.sys"), atomically: true, encoding: .utf8)
        XCTAssertEqual(ConfigSys.read(root: root), "BUFFERS=9\n")
    }

    func testApplyReadsSandboxConfig() {
        let t = TestShell()
        t.write("CONFIG.SYS", "FILES=60\r\nBUFFERS=12\r\nBREAK=ON\r\nFILES=abc\r\n")
        AnsiSys.loaded = false
        let v = ConfigSys.apply(t.shell)
        XCTAssertEqual(v.files, 60)
        XCTAssertEqual(v.buffers, 12)
        XCTAssertTrue(v.breakOn)
        XCTAssertEqual(v.errors, ["FILES=abc"])
        XCTAssertFalse(AnsiSys.loaded)
    }

    func testApplyWithoutConfigUsesDefaults() {
        let t = TestShell()
        let v = ConfigSys.apply(t.shell)
        XCTAssertEqual(v.files, 30)
        XCTAssertEqual(v.buffers, 30)
        XCTAssertEqual(v.lastDrive, "Z")
        XCTAssertNil(v.shellCommand)
        XCTAssertTrue(v.unknown.isEmpty)
        XCTAssertTrue(v.errors.isEmpty)
    }

    func testApplyWithUnreadableConfigUsesDefaults() {
        let t = TestShell()
        try? FileManager.default.createDirectory(
            at: t.root.appendingPathComponent("CONFIG.SYS"), withIntermediateDirectories: true)
        let v = ConfigSys.apply(t.shell)
        XCTAssertEqual(v.files, 30)
        XCTAssertEqual(v.stacks, "9,256")
    }
}
