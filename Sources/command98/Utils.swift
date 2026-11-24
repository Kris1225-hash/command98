import Foundation


/// Extra DOS attributes the host may have no flag for (system, cleared archive, hidden on
/// Linux) and volume labels live in extended attributes, so they survive across sessions.
enum Attr {
    static let key = "com.command98.attr"
    static let labelKey = "com.command98.label"

    static func read(_ path: String, _ name: String) -> String? {
        Platform.xattrGet(path, Platform.xattrName(name))
    }

    @discardableResult
    static func write(_ path: String, _ name: String, _ value: String?) -> Bool {
        Platform.xattrSet(path, name, value)
    }

    /// "S" = system, "-A" = archive bit cleared, "H" = hidden (where the OS has no hidden flag)
    static func get(_ path: String) -> String { read(path, key) ?? "" }
    @discardableResult
    static func set(_ path: String, system: Bool, noArchive: Bool, hidden: Bool = false) -> Bool {
        let v = (system ? "S" : "") + (hidden ? "H" : "") + (noArchive ? "-A" : "")
        return write(path, key, v.isEmpty ? nil : v)
    }

    /// nil = never labelled (fall back to the folder name), "" = label deliberately removed
    static func label(_ path: String) -> String? { read(path, labelKey) }
}

/// Which keyboard KEYB last claimed to load. Purely for show.
var gKeyb = "US"

extension Shell {
    // MARK: stubs and dispatch

    static let coreUtilities: [String: (Shell) -> (Ctx) -> Void] = [
        "ATTRIB": Shell.uAttrib, "CHKDSK": Shell.uChkdsk, "CHOICE": Shell.uChoice, "DELTREE": Shell.uDeltree,
        "DISKCOPY": Shell.uDiskcopy, "DOSKEY": Shell.uDoskey, "EDIT": Shell.uEdit, "FC": Shell.uFc,
        "FDISK": Shell.uFdisk, "FIND": Shell.uFind, "FORMAT": Shell.uFormat, "KEYB": Shell.uKeyb,
        "LABEL": Shell.uLabel, "MEM": Shell.uMem, "MODE": Shell.uMode, "MORE": Shell.uMore, "MOVE": Shell.uMove,
        "NLSFUNC": Shell.uNlsfunc, "SCANDISK": Shell.uScandisk, "SORT": Shell.uSort, "START": Shell.uStart,
        "SUBST": Shell.uSubst, "SYS": Shell.uSys, "XCOPY": Shell.uXcopy, "XCOPY32": Shell.uXcopy,
        "COMMAND": Shell.uCommand, "WIN": Shell.uWin, "SETVER": Shell.uSetver, "EMM386": Shell.uEmm386,
        "SMARTDRV": Shell.uSmartdrv, "MAC": Shell.uMac, "LINUX": Shell.uMac,
    ]

    /// (folder under the drive root, file name, size of the real Win98 SE file in bytes)
    static let coreStubFiles: [(String, String, Int)] = [
        ("", "COMMAND.COM", 93890),
        ("WINDOWS", "COMMAND.COM", 93890), ("WINDOWS", "WIN.COM", 24791), ("WINDOWS", "SETVER.EXE", 18939),
        ("WINDOWS", "EMM386.EXE", 125495), ("WINDOWS", "SMARTDRV.EXE", 45379),
        ("WINDOWS\\COMMAND", "ATTRIB.EXE", 15252), ("WINDOWS\\COMMAND", "CHKDSK.EXE", 28096),
        ("WINDOWS\\COMMAND", "CHOICE.COM", 5239), ("WINDOWS\\COMMAND", "DELTREE.EXE", 19083),
        ("WINDOWS\\COMMAND", "DISKCOPY.COM", 21975), ("WINDOWS\\COMMAND", "DOSKEY.COM", 15495),
        ("WINDOWS\\COMMAND", "EDIT.COM", 69902), ("WINDOWS\\COMMAND", "FC.EXE", 20574),
        ("WINDOWS\\COMMAND", "FDISK.EXE", 63916), ("WINDOWS\\COMMAND", "FIND.EXE", 6658),
        ("WINDOWS\\COMMAND", "FORMAT.COM", 49575), ("WINDOWS\\COMMAND", "KEYB.COM", 19927),
        ("WINDOWS\\COMMAND", "LABEL.EXE", 9324), ("WINDOWS\\COMMAND", "MEM.EXE", 32146),
        ("WINDOWS\\COMMAND", "MODE.COM", 29271), ("WINDOWS\\COMMAND", "MORE.COM", 10471),
        ("WINDOWS\\COMMAND", "MOVE.EXE", 27299), ("WINDOWS\\COMMAND", "NLSFUNC.EXE", 6940),
        ("WINDOWS\\COMMAND", "SCANDISK.EXE", 143818), ("WINDOWS\\COMMAND", "SORT.EXE", 25882),
        ("WINDOWS\\COMMAND", "START.EXE", 28672), ("WINDOWS\\COMMAND", "SUBST.EXE", 17904),
        ("WINDOWS\\COMMAND", "SYS.COM", 18967), ("WINDOWS\\COMMAND", "XCOPY.EXE", 3878),
        ("WINDOWS\\COMMAND", "XCOPY32.EXE", 3878), ("WINDOWS\\COMMAND", Platform.hostUtility + ".COM", 2026),
    ]

    /// A stub starts with "C98U NAME". Rename it and it still runs NAME, like renaming a real .EXE.
    static func stubName(_ d: Data) -> String? {
        let b = [UInt8](d)
        guard b.count > 6, b.starts(with: Array("C98U ".utf8)) else { return nil }
        let name = String(decoding: b[5...].prefix { $0 > 32 }, as: UTF8.self)
        return Shell.utilities[name] != nil ? name : nil
    }

    /// Lays down \COMMAND.COM, \WINDOWS and \WINDOWS\COMMAND on the sandbox drive. Only on a fresh
    /// sandbox or a new stub set, so a utility you deleted stays deleted.
    static func installStubs(root: URL) {
        let fm = FileManager.default
        let cmdDir = root.appendingPathComponent("WINDOWS/COMMAND")
        let markerKey = "com.command98.stubs"
        if Attr.read(cmdDir.path, markerKey) == Shell.stubVersion { return }
        var dc = DateComponents()
        (dc.year, dc.month, dc.day, dc.hour, dc.minute) = (1999, 4, 23, 22, 22)
        let stamp = Calendar.current.date(from: dc) ?? Date()
        for (folder, file, size) in Shell.stubFiles {
            let dir = folder.split(separator: "\\").reduce(root) { $0.appendingPathComponent(String($1)) }
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let u = dir.appendingPathComponent(file)
            if fm.fileExists(atPath: u.path) { continue }
            let name = String(file.split(separator: ".")[0])
            var text = "C98U \(name)\r\n"
            text += "command98 utility stub. When command98 finds this file it runs \(name) itself.\r\n"
            text += "Delete it and \(name) is gone, same as deleting the real one in 1998.\r\n\u{1A}"
            var data = Data(text.utf8)
            if data.count < size { data.append(Data(count: size - data.count)) }
            _ = fm.createFile(atPath: u.path, contents: data)
            try? fm.setAttributes([.modificationDate: stamp], ofItemAtPath: u.path)
        }
        Attr.write(cmdDir.path, markerKey, Shell.stubVersion)
    }

    func runUtility(_ name: String, _ rest: String, _ io: IO) {
        errorLevel = 0
        let args = Tok.args(rest)
        if args.first == "/?" {
            io.out.write(Shell.helpText(name))
            return
        }
        Shell.utilities[name]?(self)(Ctx(name: name, rest: rest, args: args, io: io))
    }

    // MARK: shared helpers

    func hostWhich(_ name: String) -> String? {
        if name.hasPrefix("/") { return access(name, X_OK) == 0 ? name : nil }
        for dir in hostPath.split(separator: ":") {
            let p = "\(dir)/\(name)"
            var st = stat()
            if stat(p, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, access(p, X_OK) == 0 { return p }
        }
        return nil
    }

    func dosShow(_ r: Resolved) -> String { drives.dosPath(r.letter, r.comps, long: true) }

    func dosShow(_ u: URL) -> String {
        guard let (l, c) = drives.hostToDos(u.standardizedFileURL.path) else { return u.path }
        return drives.dosPath(l, c, long: true)
    }

    static func cutZ(_ d: Data) -> Data {
        if let z = d.firstIndex(of: 0x1A) { return d[d.startIndex..<z] }
        return d
    }

    /// Standard input as text: the keyboard until ^Z/^D, or whatever was piped or redirected in.
    /// nil means the user hit ^C.
    func readAllText(_ c: Ctx) -> String? {
        if c.io.inFD == 0 && Console.isTTY {
            var text = ""
            while true {
                switch Console.readLine(template: "") {
                case .interrupt: return nil
                case .eof: return text
                case .line(let l):
                    if let z = l.firstIndex(of: "\u{1A}") { return text + l[..<z] }
                    text += l + "\n"
                }
            }
        }
        let d = FileHandle(fileDescriptor: c.io.inFD, closeOnDealloc: false).readDataToEndOfFile()
        return String(decoding: Shell.cutZ(d), as: UTF8.self)
    }

    static func textLines(_ s: String, keepLast: Bool = false) -> [String] {
        // by unicode scalar: Swift counts "\r\n" as ONE Character, so splitting on "\n" misses it
        var ls: [String] = []
        var cur = String.UnicodeScalarView()
        var prevCR = false
        for u in s.unicodeScalars {
            if u == "\n" {
                if prevCR { cur.removeLast() }
                ls.append(String(cur))
                cur = String.UnicodeScalarView()
            } else {
                cur.append(u)
            }
            prevCR = u == "\r"
        }
        if keepLast || !cur.isEmpty { ls.append(String(cur)) }
        return ls
    }

    /// Files (no directories) matching a DOS spec, with how the spec's path part should be shown.
    func matchFiles(_ spec: String, hidden: Bool = false) -> (dir: Resolved, entries: [DirEntry])? {
        guard let r = try? drives.resolve(spec) else { return nil }
        if Wild.has(r.last) {
            guard r.parentExists else { return nil }
            let es = readEntries(drives.url(r.parent), dots: false).filter {
                !$0.isDir && (hidden || (!$0.hidden && !$0.system)) && matches($0, r.last)
            }
            return (r.parent, es)
        }
        guard r.exists, !isDir(drives.url(r)) else { return nil }
        let es = readEntries(drives.url(r.parent), dots: false).filter { $0.name == r.last }
        return (r.parent, es)
    }

    func askYN(_ prompt: String) -> Bool? {
        guard let a = Console.ask(prompt, "YN") else { return nil }
        return a == "Y"
    }

    // MARK: CHOICE

    func uChoice(_ c: Ctx) {
        var keys = "YN"
        var showKeys = true, caseSensitive = false
        var timeout: (Character, Int)? = nil
        var text: [String] = []
        let syntax = "CHOICE [/C[:]choices] [/N] [/S] [/T[:]c,nn] [text]"
        for w in Tok.words(c.rest, seps: [" ", "\t"]) {
            let t = w.text
            guard !w.quoted, t.hasPrefix("/"), t.count >= 2 else {
                text.append(t)
                continue
            }
            var val = t.dropFirst(2)
            if val.hasPrefix(":") { val = val.dropFirst() }
            switch Character(t.dropFirst().prefix(1).uppercased()) {
            case "C":
                guard !val.isEmpty else {
                    c.out.line("CHOICE: invalid choice switch syntax. Expected form: /C[:]choices")
                    errorLevel = 255
                    return
                }
                keys = String(val)
            case "N": showKeys = false
            case "S": caseSensitive = true
            case "T":
                let p = val.split(separator: ",")
                guard p.count == 2, p[0].count == 1, let n = Int(p[1]), (0...99).contains(n) else {
                    c.out.line("CHOICE: Incorrect timeout syntax.  Expected form Tc,nn or T:c,nn")
                    errorLevel = 255
                    return
                }
                timeout = (p[0].first!, n)
            default:
                c.out.line("Invalid switch on command line. Expected form:")
                c.out.line("    " + syntax)
                errorLevel = 255
                return
            }
        }
        let norm: (Character) -> Character = { caseSensitive ? $0 : Character($0.uppercased()) }
        let opts = keys.map(norm)
        if let (d, _) = timeout, !opts.contains(norm(d)) {
            c.out.line("CHOICE: Timeout default not in specified (or default) choices.")
            errorLevel = 255
            return
        }
        let shown = text.joined(separator: " ")
        var prompt = shown
        if showKeys { prompt += (shown.isEmpty ? "" : " ") + "[" + keys.map(String.init).joined(separator: ",") + "]?" }
        c.out.write(prompt)

        func pick(_ ch: Character) {
            c.out.line(String(ch))
            errorLevel = Int32((opts.firstIndex(of: norm(ch)) ?? 0) + 1)
        }
        if c.io.inFD != 0 || !Console.isTTY {
            while true {
                let k = Console.readByte(c.io.inFD)
                if k < 0 {
                    c.out.line()
                    if let (d, _) = timeout { pick(d) } else { errorLevel = 255 }
                    return
                }
                let ch = Character(UnicodeScalar(UInt8(k)))
                if opts.contains(norm(ch)) { pick(ch); return }
            }
        }
        let deadline = timeout.map { Date().addingTimeInterval(Double($0.1)) }
        let result: Character? = Console.withRaw {
            while true {
                if let dl = deadline {
                    let ms = Int32(max(0, dl.timeIntervalSinceNow * 1000))
                    if ms == 0 || !Console.pending(ms) { return timeout!.0 }
                }
                let k = Console.readByte()
                if k == -2 { gInterrupted = 0; return nil }
                if k < 0 { return nil }
                guard k < 128 else { continue }
                let ch = Character(UnicodeScalar(UInt8(k)))
                if opts.contains(norm(ch)) { return ch }
                c.out.write("\u{7}")
            }
        }
        guard let r = result else {
            c.out.line("^C")
            errorLevel = 0
            return
        }
        pick(r)
    }

    // MARK: MEM

    func uMem(_ c: Ctx) {
        let (phys, freeK) = Platform.memoryK()
        let xmsTotal = phys - 1024
        let xmsFree = min(freeK, xmsTotal)
        let convUsed: Int64 = Doskey.installed ? 71 : 64

        func k(_ n: Int64) -> String { Fmt.num(n) + "K" }
        func row(_ name: String, _ t: Int64, _ u: Int64, _ f: Int64) -> String {
            Fmt.pad(name, 16) + Fmt.lpad(k(t), 14) + Fmt.lpad(k(u), 13) + Fmt.lpad(k(f), 13)
        }
        let rule = "----------------  ------------  -----------  -----------"

        if c.has("/C") || c.has("/CLASSIFY") || c.has("/D") || c.has("/DEBUG") {
            c.out.line()
            c.out.line("Modules using memory below 1 MB:")
            c.out.line()
            c.out.line("  Name           Total           Conventional       Upper Memory")
            c.out.line("  --------  ----------------   ----------------   ----------------")
            var mods: [(String, Int64)] = [("SYSTEM", 38), ("HIMEM", 1), ("COMMAND", 7)]
            if Doskey.installed { mods.append(("DOSKEY", 7)) }
            if nlsLoaded { mods.append(("NLSFUNC", 3)) }
            mods.append(("Free", 640 - mods.reduce(0) { $0 + $1.1 }))
            for (n, kb) in mods {
                let b = Fmt.lpad(Fmt.num(kb * 1024), 8)
                c.out.line("  " + Fmt.pad(n, 8) + Fmt.lpad(b, 8) + "   (\(Fmt.lpad(k(kb), 4)))"
                    + Fmt.lpad(b, 10) + "   (\(Fmt.lpad(k(kb), 4)))" + Fmt.lpad("0", 10) + "   (   0K)")
            }
        }
        c.out.line()
        c.out.line("Memory Type           Total         Used         Free")
        c.out.line(rule)
        c.out.line(row("Conventional", 640, convUsed, 640 - convUsed))
        c.out.line(row("Upper", 0, 0, 0))
        c.out.line(row("Reserved", 384, 384, 0))
        c.out.line(row("Extended (XMS)", xmsTotal, xmsTotal - xmsFree, xmsFree))
        c.out.line(rule)
        c.out.line(row("Total memory", phys, phys - xmsFree - (640 - convUsed), xmsFree + 640 - convUsed))
        c.out.line()
        c.out.line(row("Total under 1 MB", 640, convUsed, 640 - convUsed))
        c.out.line()
        let big = 640 - convUsed
        c.out.line("Largest executable program size     " + Fmt.lpad(k(big), 7) + " (" + Fmt.num(big * 1024) + " bytes)")
        c.out.line("Largest free upper memory block     " + Fmt.lpad(k(0), 7) + "       (0 bytes)")
        c.out.line("Command98 is resident in the high memory area.")
    }

    // MARK: MODE

    func uMode(_ c: Ctx) {
        func status() {
            let sz = Platform.termSize()
            c.out.line()
            c.out.line("Status for device CON:")
            c.out.line("----------------------")
            c.out.line("Columns=\(sz?.cols ?? 80)")
            c.out.line("Lines=\(sz?.rows ?? 25)")
            c.out.line()
            c.out.line("Code page operation not supported on this device")
        }
        func resize(cols: Int?, lines: Int?) {
            let sz = Platform.termSize()
            let r = lines ?? sz?.rows ?? 25, cl = cols ?? sz?.cols ?? 80
            Console.tty.write("\u{1B}[8;\(r);\(cl)t")
        }
        let p = Tok.words(c.rest, seps: [" ", "\t", ","]).map { $0.text.uppercased() }
        guard let dev = p.first else { status(); return }
        switch dev.trimmingCharacters(in: CharacterSet(charactersIn: ":")) {
        case "CON":
            if p.count == 1 { status(); return }
            var cols: Int? = nil, lines: Int? = nil
            for a in p.dropFirst() {
                let kv = a.split(separator: "=")
                guard kv.count == 2, let n = Int(kv[1]) else {
                    c.out.line("Invalid parameter - \(a)")
                    return
                }
                if kv[0] == "COLS" { cols = n } else if kv[0] == "LINES" { lines = n } else {
                    c.out.line("Invalid parameter - \(a)")
                    return
                }
            }
            resize(cols: cols, lines: lines)
        case "80", "CO80", "BW80", "MONO":
            resize(cols: 80, lines: nil)
            cmdCls(c)
        case "40", "CO40", "BW40":
            resize(cols: 40, lines: nil)
            cmdCls(c)
        case let d where d.hasPrefix("COM") || d.hasPrefix("LPT") || d == "PRN" || d == "AUX":
            c.out.line("Illegal device name - \(d)")
            errorLevel = 1
        default:
            c.out.line("Invalid parameter - \(dev)")
            errorLevel = 1
        }
    }

    // MARK: the small ones

    func uKeyb(_ c: Ctx) {
        if let p = c.params.first {
            gKeyb = String(p.uppercased().prefix(2))
            return
        }
        c.out.line("Current keyboard code: \(gKeyb)  code page: \(codePage)")
        c.out.line("Current CON code page: \(codePage)")
    }

    func uNlsfunc(_ c: Ctx) {
        if nlsLoaded {
            c.out.line("NLSFUNC already installed")
            errorLevel = 1
            return
        }
        nlsLoaded = true
    }

    func uSetver(_ c: Ctx) {
        c.out.line()
        c.out.line("Nothing here needs lying to about the DOS version anymore.")
        c.out.line("The version table is empty.")
    }

    func uEmm386(_ c: Ctx) { c.out.line("EMM386 driver not installed.") }

    func uSmartdrv(_ c: Ctx) {
        c.out.line("SMARTDrive is retired. \(Platform.name) already caches every disk it can see.")
    }

    func uFormat(_ c: Ctx) {
        guard let d = c.params.first, d.count == 2, d.hasSuffix(":") else {
            c.out.line("Required parameter missing")
            errorLevel = 4
            return
        }
        let l = d.uppercased()
        c.out.line()
        c.out.line("WARNING: every file on drive \(l) would be gone for good.")
        guard askYN("Proceed with Format (Y/N)?") == true else {
            errorLevel = 3
            return
        }
        c.out.line()
        c.out.line("No. Formatting disks is Disk Utility's job, and it asks more questions first.")
        errorLevel = 4
    }

    func uFdisk(_ c: Ctx) {
        c.out.line("FDISK can't see any disks from in here, and that's for the best.")
        errorLevel = 1
    }

    func uSys(_ c: Ctx) {
        c.out.line("No system to transfer. \(Platform.name) boots itself these days.")
        errorLevel = 1
    }

    func uDiskcopy(_ c: Ctx) {
        c.out.line("There are no floppy drives left to copy. DISKCOPY has retired.")
        errorLevel = 1
    }

    func uScandisk(_ c: Ctx) {
        c.out.line("ScanDisk only knows FAT. On Linux, use fsck to fix a disk.")
        errorLevel = 1
    }

    func uWin(_ c: Ctx) {
        #if os(Linux)
        guard let o = Platform.opener(hostWhich) else {
            c.out.line("Cannot find WIN.COM, unable to continue loading Windows")
            return
        }
        spawn(o, [envGet("HOME") ?? "/"], c.io)
        #else
        guard FileManager.default.fileExists(atPath: "/System/Library/CoreServices/Finder.app") else {
            c.out.line("Cannot find WIN.COM, unable to continue loading Windows")
            return
        }
        spawn("/usr/bin/open", ["-a", "Finder"], c.io)
        #endif
    }

    /// LINUX command [args] (also MAC): run a Linux program straight from the host PATH,
    /// skipping the DOS search order (so `LINUX find . -name x` gets the Unix find, not FIND.EXE).
    func uMac(_ c: Ctx) {
        let w = Tok.posix(c.tail)
        guard let prog = w.first else {
            c.out.line("Runs a \(Platform.name) program directly: \(Platform.hostUtility) command [arguments]")
            return
        }
        guard let p = hostWhich(prog) else {
            c.out.line("Bad command or file name")
            errorLevel = 1
            return
        }
        spawn(p, w.dropFirst().map(translateArg), c.io)
    }

    func uEdit(_ c: Ctx) {
        let file = Tok.posix(c.tail).first(where: { !$0.hasPrefix("/") }).map(translateArg)
        let candidates = [envGet("VISUAL"), envGet("EDITOR"), "nano", "vi"].compactMap { $0 }
        for ed in candidates {
            let parts = Tok.posix(ed)
            guard let prog = parts.first, let path = hostWhich(prog) else { continue }
            spawn(path, Array(parts.dropFirst()) + (file.map { [$0] } ?? []), c.io)
            return
        }
        c.out.line("Bad command or file name")
    }

    func uStart(_ c: Ctx) {
        var words = Tok.posix(c.tail)
        var wait = false, background = false
        while let f = words.first, f.hasPrefix("/") {
            switch f.uppercased() {
            case "/W", "/WAIT": wait = true
            case "/M", "/MIN": background = true
            case "/MAX", "/R": break
            default:
                c.out.line("Invalid switch - \(f)")
                return
            }
            words.removeFirst()
        }
        guard let target = words.first else {
            c.out.line("Required parameter missing")
            return
        }
        guard let opener = Platform.opener(hostWhich) else {
            c.out.line("Cannot find the file '\(target)' (or one of its components).")
            errorLevel = 1
            return
        }
        #if os(Linux)
        // xdg-open takes exactly one thing and never waits; /W and /M have nothing to hold on to
        _ = (wait, background)
        func open(_ what: String, _ extra: [String]) { spawn(opener, [what], c.io) }
        #else
        var openArgs: [String] = []
        if wait { openArgs.append("-W") }
        if background { openArgs.append("-g") }
        func open(_ what: String, _ extra: [String]) {
            spawn(opener, openArgs + [what] + (extra.isEmpty ? [] : ["--args"] + extra), c.io)
        }
        #endif
        let rest = words.dropFirst().map(translateArg)
        if target.contains("://") || target.hasPrefix("mailto:") {
            open(target, [])
            return
        }
        if let r = try? drives.resolve(target), r.exists {
            open(drives.url(r).path, rest)
            return
        }
        switch findProgram(target) {
        case .host(let p):
            #if os(Linux)
            spawn(p, rest, c.io)
            #else
            open(p, rest)
            #endif
        case .batch, .utility:
            runLine(c.tail.replacingOccurrences(of: "/W ", with: ""), io: c.io)
        case .dosBinary:
            c.out.line("This program cannot be run in \(Platform.name) mode.")
        case nil:
            c.out.line("Cannot find the file '\(target)' (or one of its components).")
            errorLevel = 1
        }
    }

    // MARK: DOSKEY

    func uDoskey(_ c: Ctx) {
        var t = Substring(c.tail)
        var listMacros = false, listHistory = false
        if !Doskey.installed {
            Doskey.installed = true
            c.out.line("DOSKEY installed.")
        }
        while t.hasPrefix("/") {
            let (w, r) = Tok.firstWord(t)
            t = r.drop { $0 == " " || $0 == "\t" }
            switch w.uppercased().split(separator: "=")[0] {
            case "/REINSTALL":
                Doskey.history.removeAll()
                Doskey.macros.removeAll()
                c.out.line("DOSKEY installed.")
            case "/BUFSIZE", "/ECHO:ON", "/ECHO:OFF", "/FILE", "/KEYSIZE", "/LINE": break
            case "/M", "/MACROS": listMacros = true
            case "/H", "/HISTORY": listHistory = true
            case "/INSERT": Doskey.insertMode = true
            case "/OVERSTRIKE": Doskey.insertMode = false
            default:
                c.out.line("Invalid switch - \(w)")
                return
            }
        }
        if listMacros { for (n, v) in Doskey.macros { c.out.line("\(n)=\(v)") } }
        if listHistory { for h in Doskey.history { c.out.line(h) } }
        guard let eq = t.firstIndex(of: "=") else { return }
        let name = t[..<eq].trimmingCharacters(in: .whitespaces)
        let body = String(t[t.index(after: eq)...])
        guard !name.isEmpty, !name.contains(" ") else {
            c.out.line("Invalid macro definition")
            return
        }
        Doskey.macros.removeAll { $0.0.caseInsensitiveCompare(name) == .orderedSame }
        if !body.trimmingCharacters(in: .whitespaces).isEmpty { Doskey.macros.append((name.uppercased(), body)) }
    }

    // MARK: COMMAND (a new copy of the interpreter)

    func uCommand(_ c: Ctx) {
        let child = Shell(drives: drives)
        child.env = env
        child.hostPath = hostPath
        child.lfnFor = lfnFor
        child.nlsLoaded = nlsLoaded
        child.codePage = codePage
        child.substs = substs
        var words = Tok.posix(c.tail)
        var runC: String? = nil, runK: String? = nil
        var i = 0
        while i < words.count {
            let up = words[i].uppercased()
            if up == "/C" || up == "/K" {
                let cmd = words[(i + 1)...].joined(separator: " ")
                if up == "/C" { runC = cmd } else { runK = cmd }
                break
            }
            if up.hasPrefix("/C") || up.hasPrefix("/K"), up.count > 2 {
                words[i] = String(words[i].dropFirst(2))
                let cmd = words[i...].joined(separator: " ")
                if up.hasPrefix("/C") { runC = cmd } else { runK = cmd }
                break
            }
            if up == "/P" { child.permanent = true }
            if up == "/Y" { child.stepMode = true }
            i += 1
        }
        if let cmd = runC {
            child.runLine(cmd, io: c.io)
            errorLevel = child.errorLevel
            return
        }
        if Console.isTTY {
            Console.tty.write("\n\(Platform.product) \(Platform.arch) [Version \(Shell.version)]\n")
            Console.tty.write("   a from-scratch tribute to the Windows 98 SE command interpreter\n\n")
        }
        if let k = runK { child.runLine(k) }
        child.interactive()
        errorLevel = child.errorLevel
    }

    // MARK: SUBST, LABEL, CHKDSK

    func uSubst(_ c: Ctx) {
        let p = c.params
        if p.isEmpty && !c.has("/D") {
            for l in substs.keys.sorted() { c.out.line("\(l):\\ => \(substs[l]!)") }
            return
        }
        guard let d = p.first, d.count == 2, d.hasSuffix(":"), let l = d.uppercased().first, l.isLetter else {
            c.out.line("Incorrect number of parameters")
            errorLevel = 1
            return
        }
        if c.has("/D") {
            guard substs[l] != nil else {
                c.out.line("Invalid parameter")
                errorLevel = 1
                return
            }
            substs[l] = nil
            drives.table[l] = nil
            if drives.current == l { drives.current = "C" }
            return
        }
        guard p.count == 2 else {
            c.out.line("Incorrect number of parameters")
            errorLevel = 1
            return
        }
        if substs[l] != nil {
            c.out.line("Drive already SUBSTed")
            errorLevel = 1
            return
        }
        guard drives.table[l] == nil else {
            c.out.line("Invalid parameter")
            errorLevel = 1
            return
        }
        guard let r = try? drives.resolve(p[1]), r.exists, isDir(drives.url(r)) else {
            c.out.line("Path not found - \(p[1])")
            errorLevel = 1
            return
        }
        drives.mount(l, drives.url(r).path, sandbox: drives.table[r.letter]!.sandbox)
        substs[l] = drives.dosPath(r.letter, r.comps)
    }

    func uLabel(_ c: Ctx) {
        var t = c.tail.trimmingCharacters(in: .whitespaces)
        var l = drives.current
        let ch = Array(t)
        if ch.count >= 2, ch[1] == ":", ch[0].isLetter {
            l = Character(ch[0].uppercased())
            t = String(t.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            guard drives.table[l] != nil else {
                c.out.line("Invalid drive specification")
                errorLevel = 1
                return
            }
        }
        if substs[l] != nil {
            c.out.line("Cannot label a JOINed, SUBSTed or ASSIGNed drive")
            errorLevel = 1
            return
        }
        let root = drives.table[l]!.root.path
        func apply(_ new: String) {
            let bad = Set("*?/\\|.,;:+=[]<>\"")
            if new.count > 11 {
                c.out.line("Too many characters in volume label")
                errorLevel = 1
            } else if new.contains(where: { bad.contains($0) }) {
                c.out.line("Invalid characters in volume label")
                errorLevel = 1
            } else if !Attr.write(root, Attr.labelKey, new.uppercased()) {
                c.out.line("Cannot make directory entry")
                errorLevel = 1
            }
        }
        if !t.isEmpty {
            apply(t)
            return
        }
        c.out.line()
        volumeHeader(l, c.out)
        c.out.write("Volume label (11 characters, ENTER for none)? ")
        guard case .line(let input) = readInput(c) else { return }
        let v = input.trimmingCharacters(in: .whitespaces)
        if !v.isEmpty {
            apply(v)
        } else if !volumeLabel(l).isEmpty {
            c.out.line()
            if askYN("Delete current volume label (Y/N)? ") == true {
                if !Attr.write(root, Attr.labelKey, "") { c.out.line("Error deleting old volume label") }
            }
        }
    }

    func uChkdsk(_ c: Ctx) {
        guard let l = driveArg(c) else { return }
        if substs[l] != nil {
            c.out.line("Cannot CHKDSK a SUBSTed or ASSIGNed drive")
            return
        }
        let root = drives.table[l]!.root
        guard let ds = Platform.diskStats(root.path) else {
            c.out.line("CHKDSK not available on drive \(l)")
            return
        }
        let unit = ds.unit
        let total = ds.total * unit
        let avail = ds.avail * unit
        func n(_ v: Int64) -> String { Fmt.lpad(Fmt.num(v), 16) }
        let created = (try? root.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
        c.out.line()
        c.out.line("Volume \(Fmt.pad(volumeLabel(l), 11)) created \(Fmt.date(created, year4: true)) \(Fmt.time12(created))")
        c.out.line("Volume Serial Number is \(serial(l))")
        c.out.line()
        c.out.line(n(total) + " bytes total disk space")
        if root.path != "/" {
            var hidden = (0, Int64(0)), dirs = (0, Int64(0)), files = (0, Int64(0))
            let keys: [URLResourceKey] = [.isDirectoryKey, .isHiddenKey, .totalFileAllocatedSizeKey]
            if let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) {
                var seen = 0
                for case let u as URL in en {
                    seen += 1
                    if seen > 500_000 || gInterrupted != 0 { break }
                    guard let v = try? u.resourceValues(forKeys: Set(keys)) else { continue }
                    let size = Int64(v.totalFileAllocatedSize ?? 0)
                    if v.isDirectory == true {
                        dirs.0 += 1
                        dirs.1 += unit
                    } else if v.isHidden == true {
                        hidden.0 += 1
                        hidden.1 += size
                    } else {
                        files.0 += 1
                        files.1 += size
                    }
                }
            }
            c.out.line(n(hidden.1) + " bytes in \(hidden.0) hidden files")
            c.out.line(n(dirs.1) + " bytes in \(dirs.0) directories")
            c.out.line(n(files.1) + " bytes in \(files.0) user files")
        }
        c.out.line(n(avail) + " bytes available on disk")
        c.out.line()
        c.out.line(n(unit) + " bytes in each allocation unit")
        c.out.line(n(ds.total) + " total allocation units on disk")
        c.out.line(n(ds.avail) + " available allocation units on disk")
        c.out.line()
        c.out.line(n(655_360) + " total bytes memory")
        c.out.line(n(589_824) + " bytes free")
        c.out.line()
        c.out.line(Platform.fixer)
    }
}
