import Foundation

/// One command handler, in the shape of the original dispatch table.
typealias CommandHandler = (Shell) -> (Ctx) -> Void

/// Every feature lives in its own file and contributes here. The core table comes first;
/// a later group with the same name is the override (that is how SCANDISK gets its screen
/// and WIN gets its blue screen without touching Utils.swift).
extension Shell {
    /// Internal commands are the classic 40 plus any hidden guest (BSOD). External utilities
    /// still have to exist as stubs; this table is only for commands that are part of the shell.
    static var commands: [String: CommandHandler] {
        var t = table
        for (name, fn) in BlueScreen.commands { t[name] = fn }
        return t
    }

    static var utilities: [String: CommandHandler] {
        var t = coreUtilities
        for group in [
            QBasic.utilities,
            DebugTool.utilities,
            Defrag.utilities,
            ScanDisk.utilities,
            ColorTool.utilities,
            BlueScreen.utilities,
        ] {
            for (name, fn) in group { t[name] = fn }
        }
        return t
    }

    static var stubFiles: [(String, String, Int)] {
        coreStubFiles
            + QBasic.stubFiles
            + DebugTool.stubFiles
            + Defrag.stubFiles
            + ScanDisk.stubFiles
            + ColorTool.stubFiles
            + BlueScreen.stubFiles
    }

    /// Changing any feature's stub list changes the marker, so an existing sandbox picks up
    /// the new utilities without ever resurrecting the ones the user deleted.
    static var stubVersion: String {
        ["2", QBasic.stubVersion, DebugTool.stubVersion, Defrag.stubVersion,
         ScanDisk.stubVersion, ColorTool.stubVersion, BlueScreen.stubVersion].joined(separator: ".")
    }

    static var featureHelp: [String: String] {
        var t: [String: String] = [:]
        for group in [
            QBasic.help,
            DebugTool.help,
            Defrag.help,
            ScanDisk.help,
            ColorTool.help,
            BlueScreen.help,
        ] {
            for (name, text) in group { t[name] = text }
        }
        return t
    }
}
