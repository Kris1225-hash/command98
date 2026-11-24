import Foundation
import Darwin

extension Shell {
    /// Same 40 names, same order as the table at transient offset 0x8876 in the real COMMAND.COM.
    static let commandNames = [
        "DIR", "CALL", "CHCP", "RENAME", "REN", "ERASE", "DEL", "TYPE", "REM", "COPY", "PAUSE", "DATE", "TIME",
        "VER", "VOL", "CD", "CHDIR", "MD", "MKDIR", "RD", "RMDIR", "BREAK", "VERIFY", "SET", "PROMPT", "PATH",
        "EXIT", "CTTY", "ECHO", "LOCK", "UNLOCK", "GOTO", "SHIFT", "IF", "FOR", "CLS", "TRUENAME", "LOADHIGH",
        "LH", "LFNFOR",
    ]
    static let namesByLength = commandNames.sorted { $0.count > $1.count }

    static let table: [String: (Shell) -> (Ctx) -> Void] = [
        "DIR": Shell.cmdDir, "CALL": Shell.cmdCall, "CHCP": Shell.cmdChcp,
        "RENAME": Shell.cmdRen, "REN": Shell.cmdRen, "ERASE": Shell.cmdDel, "DEL": Shell.cmdDel,
        "TYPE": Shell.cmdType, "REM": Shell.cmdRem, "COPY": Shell.cmdCopy, "PAUSE": Shell.cmdPause,
        "DATE": Shell.cmdDate, "TIME": Shell.cmdTime, "VER": Shell.cmdVer, "VOL": Shell.cmdVol,
        "CD": Shell.cmdCd, "CHDIR": Shell.cmdCd, "MD": Shell.cmdMd, "MKDIR": Shell.cmdMd,
        "RD": Shell.cmdRd, "RMDIR": Shell.cmdRd, "BREAK": Shell.cmdBreak, "VERIFY": Shell.cmdVerify,
        "SET": Shell.cmdSet, "PROMPT": Shell.cmdPrompt, "PATH": Shell.cmdPath, "EXIT": Shell.cmdExit,
        "CTTY": Shell.cmdCtty, "ECHO": Shell.cmdEcho, "LOCK": Shell.cmdLock, "UNLOCK": Shell.cmdUnlock,
        "GOTO": Shell.cmdGoto, "SHIFT": Shell.cmdShift, "IF": Shell.cmdIf, "FOR": Shell.cmdFor,
        "CLS": Shell.cmdCls, "TRUENAME": Shell.cmdTruename, "LOADHIGH": Shell.cmdLh, "LH": Shell.cmdLh,
        "LFNFOR": Shell.cmdLfnfor,
    ]

    // MARK: helpers

    func driveArg(_ c: Ctx) -> Character? {
        guard let p = c.params.first else { return drives.current }
        let ch = Array(p)
        guard ch.count == 2, ch[1] == ":", ch[0].isLetter, let _ = drives.table[Character(ch[0].uppercased())] else {
            c.out.line("Invalid drive specification")
            return nil
        }
        return Character(ch[0].uppercased())
    }

    func onOff(_ c: Ctx, _ name: String, _ value: Bool, _ set: (Bool) -> Void) {
        guard let p = c.params.first else {
            c.out.line("\(name) is \(value ? "on" : "off")")
            return
        }
        switch p.uppercased() {
        case "ON": set(true)
        case "OFF": set(false)
        default: c.out.line("Must specify ON or OFF")
        }
    }

    func readInput(_ c: Ctx) -> LineResult {
        c.io.inFD == 0 ? Console.readLine(template: "") : Console.readLine(fd: c.io.inFD)
    }

    func removeFile(_ u: URL, letter: Character) throws {
        if drives.table[letter]!.sandbox {
            try FileManager.default.removeItem(at: u)
        } else {
            try FileManager.default.trashItem(at: u, resultingItemURL: nil)
        }
    }

    func stripQuotes(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\"", with: "")
    }

    // MARK: the simple ones

    /// The real REM handler is the "back to the prompt" routine at transient 0x0104. Same energy.
    func cmdRem(_ c: Ctx) {}

    func cmdCls(_ c: Ctx) { c.out.control("\u{1B}[2J\u{1B}[H") }

    func cmdVer(_ c: Ctx) {
        c.out.line()
        c.out.line("Command98 for macOS [Version \(Shell.version)]")
        c.out.line()
    }

    func cmdEcho(_ c: Ctx) {
        guard let first = c.rest.first else {
            c.out.line("ECHO is \(echoOn ? "on" : "off")")
            return
        }
        let r = String(c.rest.dropFirst())
        if first == " " || first == "\t" {
            let t = r.trimmingCharacters(in: .whitespaces)
            switch t.uppercased() {
            case "": c.out.line("ECHO is \(echoOn ? "on" : "off")")
            case "ON": echoOn = true
            case "OFF": echoOn = false
            default: c.out.line(r)
            }
        } else {
            // ECHO. ECHO: ECHO/ etc. print whatever follows, even nothing
            c.out.line(r)
        }
    }

    func cmdPause(_ c: Ctx) {
        c.out.write("Press any key to continue . . .")
        _ = Console.readKey(fd: c.io.inFD)
        c.out.line()
    }

    func cmdBreak(_ c: Ctx) { onOff(c, "BREAK", breakOn) { self.breakOn = $0 } }
    func cmdVerify(_ c: Ctx) { onOff(c, "VERIFY", verifyOn) { self.verifyOn = $0 } }
    func cmdLfnfor(_ c: Ctx) { onOff(c, "LFNFOR", lfnFor) { self.lfnFor = $0 } }

    func cmdChcp(_ c: Ctx) {
        guard let p = c.params.first else {
            c.out.line("Active code page: \(codePage)")
            return
        }
        guard let n = Int(p), [437, 850, 852, 860, 863, 865, 866].contains(n) else {
            c.out.line("Invalid code page")
            return
        }
        // without NLSFUNC loaded, this is exactly what Win98 tells you. so. (run NLSFUNC first)
        if n != codePage && !nlsLoaded {
            c.out.line("NLSFUNC not installed")
            return
        }
        codePage = n
    }

    func cmdCtty(_ c: Ctx) {
        guard let p = c.params.first else {
            c.out.line("Required parameter missing")
            return
        }
        if Shell.deviceName(p) != "CON" { c.out.line("Invalid device") }
    }

    func cmdExit(_ c: Ctx) {
        guard !permanent else { return }
        exitRequested = true
        batch.removeAll()
    }

    func cmdLock(_ c: Ctx) {
        guard let l = driveArg(c) else { return }
        c.out.line("WARNING: LOCK lets programs write straight to the disk, going around")
        c.out.line("the operating system. Programs that aren't expecting it can lose data.")
        c.out.line()
        guard Console.ask("Proceed with lock of drive \(l): (Y/N)?", "YN") == "Y" else { return }
        locked.insert(l)
    }

    func cmdUnlock(_ c: Ctx) {
        guard let l = driveArg(c) else { return }
        locked.remove(l)
    }

    func cmdVol(_ c: Ctx) {
        guard let l = driveArg(c) else { return }
        c.out.line()
        volumeHeader(l, c.out)
    }

    func cmdLh(_ c: Ctx) {
        // there is no "higher" than a 64-bit address space. just run it.
        var rest = Substring(c.rest)
        while true {
            let (w, after) = Tok.firstWord(rest)
            if w.hasPrefix("/") { rest = after } else { break }
        }
        runSimple(String(rest), c.io)
    }

    // MARK: dates

    func validDate(_ s: String) -> Bool {
        let p = s.split(whereSeparator: { "-/.".contains($0) }).compactMap { Int($0) }
        guard p.count == 3 else { return false }
        return (1...12).contains(p[0]) && (1...31).contains(p[1]) && (p[2] < 100 || (1980...2099).contains(p[2]))
    }

    func validTime(_ s: String) -> Bool {
        var t = s.trimmingCharacters(in: .whitespaces).lowercased()
        if t.hasSuffix("a") || t.hasSuffix("p") { t.removeLast() }
        let p = t.split(whereSeparator: { ":.".contains($0) }).map(String.init)
        guard (1...4).contains(p.count), p.allSatisfy({ Int($0) != nil }) else { return false }
        let n = p.map { Int($0)! }
        return n[0] < 24 && (n.count < 2 || n[1] < 60) && (n.count < 3 || n[2] < 60)
    }

    func dateTime(_ c: Ctx, current: String, ask: String, valid: (String) -> Bool, bad: String) {
        let refuse = "The clock belongs to macOS now. Use System Settings to change it."
        if let p = c.params.first {
            c.out.line(valid(p) ? refuse : bad)
            return
        }
        c.out.line(current)
        while true {
            c.out.write(ask)
            guard case .line(let l) = readInput(c) else {
                c.out.line()
                return
            }
            if l.trimmingCharacters(in: .whitespaces).isEmpty { return }
            if valid(l) {
                c.out.line(refuse)
                return
            }
            c.out.line(bad)
        }
    }

    func cmdDate(_ c: Ctx) {
        dateTime(c, current: "Current date is \(Fmt.longDate(Date()))", ask: "Enter new date (mm-dd-yy): ",
                 valid: validDate, bad: "Invalid date")
    }

    func cmdTime(_ c: Ctx) {
        dateTime(c, current: "Current time is \(Fmt.timeDOS(Date()))", ask: "Enter new time: ",
                 valid: validTime, bad: "Invalid time")
    }

    // MARK: environment

    func cmdSet(_ c: Ctx) {
        let r = c.tail
        if r.isEmpty {
            for (k, v) in env { c.out.line("\(k)=\(v)") }
            return
        }
        guard let eq = r.firstIndex(of: "=") else {
            c.out.line("Syntax error")
            return
        }
        let name = String(r[..<eq])
        guard !name.isEmpty else {
            c.out.line("Syntax error")
            return
        }
        envSet(name, String(r[r.index(after: eq)...]))
    }

    func cmdPrompt(_ c: Ctx) {
        let r = c.tail
        envSet("PROMPT", r.isEmpty ? nil : r)
    }

    func cmdPath(_ c: Ctx) {
        let r = c.tail.trimmingCharacters(in: .whitespaces)
        if r.isEmpty {
            if let p = envGet("PATH") { c.out.line("PATH=\(p)") } else { c.out.line("No Path") }
            return
        }
        envSet("PATH", r == ";" ? nil : r.uppercased())
    }

    // MARK: directories

    func cmdCd(_ c: Ctx) {
        let a = stripQuotes(c.rest)
        if a.isEmpty {
            c.out.line(currentPath())
            return
        }
        let ch = Array(a)
        if ch.count == 2, ch[1] == ":", ch[0].isLetter {
            let l = Character(ch[0].uppercased())
            guard let d = drives.table[l] else {
                c.out.line("Invalid drive specification")
                return
            }
            c.out.line(drives.dosPath(l, d.cwd))
            return
        }
        guard let r = try? drives.resolve(a) else {
            c.out.line("Invalid drive specification")
            return
        }
        guard r.exists, isDir(drives.url(r)) else {
            c.out.line("Invalid directory")
            return
        }
        // like the original: CD D:\FOO changes D's directory, not the current drive
        drives.table[r.letter]!.cwd = r.comps
    }

    func cmdMd(_ c: Ctx) {
        let a = stripQuotes(c.rest)
        guard !a.isEmpty else {
            c.out.line("Required parameter missing")
            return
        }
        guard let r = try? drives.resolve(a) else {
            c.out.line("Invalid drive specification")
            return
        }
        guard !r.exists, r.parentExists else {
            c.out.line("Unable to create directory")
            return
        }
        do {
            try FileManager.default.createDirectory(at: drives.url(r), withIntermediateDirectories: false)
        } catch {
            c.out.line("Unable to create directory")
        }
    }

    func cmdRd(_ c: Ctx) {
        let a = stripQuotes(c.rest)
        let bad = "Invalid path, not directory,\nor directory not empty"
        guard !a.isEmpty else {
            c.out.line("Required parameter missing")
            return
        }
        guard let r = try? drives.resolve(a) else {
            c.out.line("Invalid drive specification")
            return
        }
        let u = drives.url(r)
        guard r.exists, isDir(u) else {
            c.out.line(bad)
            return
        }
        let cur = drives.table[r.letter]!.cwd
        if cur.count >= r.comps.count && Array(cur.prefix(r.comps.count)) == r.comps {
            c.out.line("Attempt to remove current directory - \(a)")
            return
        }
        // Finder litters .DS_Store everywhere; a directory holding only that counts as empty
        let contents = drives.entries(u)
        guard contents.allSatisfy({ $0 == ".DS_Store" }) else {
            c.out.line(bad)
            return
        }
        for f in contents { unlink(u.appendingPathComponent(f).path) }
        if rmdir(u.path) != 0 { c.out.line(bad) }
    }

    func cmdTruename(_ c: Ctx) {
        let a = c.params.first ?? "."
        guard let r = try? drives.resolve(a) else {
            c.out.line("Invalid drive specification")
            return
        }
        guard r.parentExists else {
            c.out.line("Path not found")
            return
        }
        // the SUBST/JOIN-piercing command, so here it pierces symlinks
        let host = drives.url(r).resolvingSymlinksInPath().path
        if let (l, comps) = drives.hostToDos(host) {
            c.out.line(drives.dosPath(l, comps))
        } else {
            c.out.line(host)
        }
    }

    // MARK: files

    func cmdType(_ c: Ctx) {
        guard let a = c.params.first else {
            c.out.line("Required parameter missing")
            return
        }
        if let dev = Shell.deviceName(a) {
            if dev == "CON" {
                let fh = FileHandle(fileDescriptor: c.io.inFD, closeOnDealloc: false)
                c.out.raw(Array(fh.readDataToEndOfFile()))
            }
            return
        }
        if Wild.has(a) {
            c.out.line("Invalid filename or file not found")
            return
        }
        guard let r = try? drives.resolve(a) else {
            c.out.line("Invalid drive specification")
            return
        }
        guard r.exists else {
            c.out.line("File not found - \(a)")
            return
        }
        let u = drives.url(r)
        guard !isDir(u), let data = FileManager.default.contents(atPath: u.path) else {
            c.out.line("Access denied")
            return
        }
        c.out.raw(Array(data))
    }

    func cmdDel(_ c: Ctx) {
        let confirmEach = c.has("/P")
        let targets = c.params
        guard !targets.isEmpty else {
            c.out.line("Required parameter missing")
            return
        }
        for t in targets {
            guard let r = try? drives.resolve(t) else {
                c.out.line("Invalid drive specification")
                continue
            }
            var dir = r
            var pat = "*"
            if !(r.exists && isDir(drives.url(r))) {
                guard r.parentExists else {
                    c.out.line("Path not found")
                    continue
                }
                dir = r.parent
                pat = r.last
            }
            let dirURL = drives.url(dir)
            if ["*", "*.*", "????????.???"].contains(pat) && !confirmEach {
                c.out.line("All files in directory will be deleted!")
                guard Console.ask("Are you sure (Y/N)?", "YN") == "Y" else { continue }
            }
            let victims = readEntries(dirURL, dots: false).filter {
                !$0.isDir && !$0.hidden && !$0.system && matches($0, pat)
            }
            if victims.isEmpty {
                c.out.line("File not found")
                continue
            }
            for v in victims {
                if gInterrupted != 0 { return }
                if confirmEach {
                    let shown = drives.dosPath(dir.letter, dir.comps + [v.name])
                    guard let a = Console.ask("\(shown),    Delete (Y/N)?", "YN") else { return }
                    if a != "Y" { continue }
                }
                if v.readOnly {
                    c.out.line("Access denied")
                    continue
                }
                do {
                    try removeFile(dirURL.appendingPathComponent(v.name), letter: dir.letter)
                } catch {
                    c.out.line("Access denied")
                }
            }
        }
    }

    func cmdRen(_ c: Ctx) {
        let p = c.params
        guard p.count >= 2 else {
            c.out.line("Required parameter missing")
            return
        }
        guard p.count == 2 else {
            c.out.line("Too many parameters - \(p[2])")
            return
        }
        let newPat = p[1]
        if newPat.contains("\\") || newPat.contains(":") {
            c.out.line("Invalid parameter - \(newPat)")
            return
        }
        guard let r = try? drives.resolve(p[0]) else {
            c.out.line("Invalid drive specification")
            return
        }
        guard r.parentExists else {
            c.out.line("Path not found")
            return
        }
        let dirURL = drives.url(r.parent)
        let srcs = readEntries(dirURL, dots: false).filter { !$0.hidden && matches($0, r.last) }
        guard !srcs.isEmpty else {
            c.out.line("Duplicate file name or file not found")
            return
        }
        for s in srcs {
            let target = Wild.has(newPat) ? Wild.rename(s.name, newPat) : newPat
            let clash = drives.entries(dirURL).contains {
                $0.caseInsensitiveCompare(target) == .orderedSame && $0.caseInsensitiveCompare(s.name) != .orderedSame
            }
            if clash || target.isEmpty {
                c.out.line("Duplicate file name or file not found")
                continue
            }
            let from = dirURL.appendingPathComponent(s.name).path
            let to = dirURL.appendingPathComponent(target).path
            if Darwin.rename(from, to) != 0 { c.out.line("Duplicate file name or file not found") }
        }
    }

    // MARK: batch plumbing

    func cmdCall(_ c: Ctx) {
        let t = c.rest.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        let (name, rest, builtin) = splitCommand(t)
        if builtin == nil, case .batch(let u, let dn)? = findProgram(name) {
            let params = [name] + Tok.words(rest, keepQuotes: true).map(\.text)
            startBatch(u, dn, params: params, call: true, io: c.io)
            return
        }
        runSimple(t, c.io)
    }

    func cmdShift(_ c: Ctx) { batch.last?.shift += 1 }

    func cmdGoto(_ c: Ctx) {
        guard let b = batch.last else { return }
        var label = c.rest.trimmingCharacters(in: .whitespaces)
        while label.hasPrefix(":") { label.removeFirst() }
        // only the first 8 characters of a label ever counted
        let want = String(Tok.firstWord(Substring(label)).0.uppercased().prefix(8))
        for (i, l) in b.lines.enumerated() {
            let t = l.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix(":") else { continue }
            let name = String(Tok.firstWord(t.dropFirst()).0.uppercased().prefix(8))
            if name == want {
                b.pc = i + 1
                return
            }
        }
        c.out.line("Label not found")
        batch.removeLast()
    }

    func pathExists(_ p: String) -> Bool {
        guard let r = try? drives.resolve(p) else { return false }
        // the classic trick: IF EXIST C:\SOMEDIR\NUL tests for a directory
        if r.last.uppercased() == "NUL" { return r.parentExists && isDir(drives.url(r.parent)) }
        if Wild.has(r.last) {
            guard r.parentExists else { return false }
            return readEntries(drives.url(r.parent), dots: false).contains { !$0.isDir && matches($0, r.last) }
        }
        return r.exists && !isDir(drives.url(r))
    }

    func cmdIf(_ c: Ctx) {
        var s = Substring(c.rest)
        var (w, after) = Tok.firstWord(s)
        var negate = false
        if w.uppercased() == "NOT" {
            negate = true
            s = after
            (w, after) = Tok.firstWord(s)
        }
        let cond: Bool
        let cmd: Substring
        switch w.uppercased() {
        case "ERRORLEVEL":
            let (n, a2) = Tok.firstWord(after)
            guard let v = Int(n) else {
                c.out.line("Syntax error")
                return
            }
            cond = errorLevel >= v
            cmd = a2
        case "EXIST":
            let (p, a2) = Tok.firstWord(after)
            guard !p.isEmpty else {
                c.out.line("Syntax error")
                return
            }
            cond = pathExists(p.replacingOccurrences(of: "\"", with: ""))
            cmd = a2
        default:
            guard let eq = s.range(of: "==") else {
                c.out.line("Syntax error")
                return
            }
            let left = s[..<eq.lowerBound].trimmingCharacters(in: .whitespaces)
            let (right, a2) = Tok.firstWord(s[eq.upperBound...])
            cond = left == right
            cmd = a2
        }
        let command = cmd.trimmingCharacters(in: .whitespaces)
        guard !command.isEmpty else {
            c.out.line("Syntax error")
            return
        }
        if cond != negate { runSimple(command, c.io) }
    }

    func expandForItem(_ item: String) -> [String] {
        guard Wild.has(item) else { return [item] }
        let cut = item.lastIndex(where: { $0 == "\\" || $0 == ":" }).map { item.index(after: $0) } ?? item.startIndex
        let prefix = String(item[..<cut])
        let pat = String(item[cut...])
        guard let r = try? drives.resolve(prefix.isEmpty ? "." : prefix), r.exists else { return [] }
        // LFNFOR OFF (the default) hands out 8.3 names, just like Win98
        return readEntries(drives.url(r), dots: false)
            .filter { !$0.isDir && !$0.hidden && matches($0, pat) }
            .map { prefix + (lfnFor ? $0.name : $0.short) }
    }

    static let forRegex = try! NSRegularExpression(
        pattern: #"^\s*%([^\s%])\s+IN\s*\((.*)\)\s*DO\s+(.+)$"#, options: [.caseInsensitive])

    func cmdFor(_ c: Ctx) {
        guard !inFor else {
            c.out.line("FOR cannot be nested.")
            return
        }
        let ns = c.rest as NSString
        guard let m = Shell.forRegex.firstMatch(in: c.rest, range: NSRange(location: 0, length: ns.length)) else {
            c.out.line("Syntax error")
            return
        }
        let v = ns.substring(with: m.range(at: 1))
        let set = ns.substring(with: m.range(at: 2))
        let body = ns.substring(with: m.range(at: 3))
        inFor = true
        defer { inFor = false }
        for item in Tok.words(set, keepQuotes: true).map(\.text) {
            for value in expandForItem(item) {
                if gInterrupted != 0 || exitRequested { return }
                runSimple(body.replacingOccurrences(of: "%" + v, with: value), c.io)
            }
        }
    }
}
