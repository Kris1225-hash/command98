import Foundation


extension Shell {
    // MARK: ATTRIB

    func uAttrib(_ c: Ctx) {
        var changes: [Character: Bool] = [:]
        var sub = false
        var specs: [String] = []
        for w in Tok.words(c.rest, seps: [" ", "\t"]) {
            let t = w.text
            let up = t.uppercased()
            if !w.quoted, t.count == 2, t.first == "+" || t.first == "-", "RASH".contains(up.last!) {
                changes[up.last!] = t.first == "+"
            } else if !w.quoted, up == "/S" {
                sub = true
            } else if !w.quoted, t.hasPrefix("/") {
                c.out.line("Invalid switch - \(t)")
                errorLevel = 1
                return
            } else {
                specs.append(t)
            }
        }
        if specs.isEmpty { specs = ["*.*"] }

        var found = false
        func handle(_ dir: Resolved, _ e: DirEntry) {
            found = true
            let r = Resolved(letter: dir.letter, comps: dir.comps + [e.name], exists: true, parentExists: true)
            let path = drives.url(r).path
            let shown = dosShow(r)
            if changes.isEmpty {
                let flags = (e.archive ? "  A  " : "     ") + (e.system ? "S" : " ") + (e.hidden ? "H" : " ") + (e.readOnly ? "R" : " ")
                c.out.line(flags + "     " + shown)
                return
            }
            // the real thing refuses to touch a system or hidden file unless you mention S or H
            if e.system && changes["S"] == nil {
                c.out.line("Not resetting system file \(shown)")
                return
            }
            if e.hidden && changes["H"] == nil {
                c.out.line("Not resetting hidden file \(shown)")
                return
            }
            Platform.setAttributes(path, readOnly: changes["R"], hidden: changes["H"],
                                   system: changes["S"], archive: changes["A"])
        }
        func walk(_ dir: Resolved, _ pattern: String) {
            let entries = readEntries(drives.url(dir), dots: false)
            for e in entries where !e.isDir && matches(e, pattern) {
                if gInterrupted != 0 { return }
                handle(dir, e)
            }
            guard sub else { return }
            for e in entries where e.isDir && !e.isLink {
                walk(Resolved(letter: dir.letter, comps: dir.comps + [e.name], exists: true, parentExists: true), pattern)
            }
        }
        for spec in specs {
            guard let r = try? drives.resolve(spec) else {
                c.out.line("Invalid drive specification")
                continue
            }
            if r.exists && isDir(drives.url(r)) && !Wild.has(r.last) {
                if sub {
                    walk(r, "*.*")
                } else if let e = readEntries(drives.url(r.parent), dots: false).first(where: { $0.name == r.last }) {
                    handle(r.parent, e) // a directory named on its own shows its own attributes
                }
                continue
            }
            guard r.parentExists else {
                c.out.line("Path not found - \(spec)")
                continue
            }
            walk(r.parent, r.last)
        }
        if !found {
            c.out.line("File not found - \(specs.joined(separator: " "))")
            errorLevel = 1
        }
    }

    // MARK: DELTREE

    func uDeltree(_ c: Ctx) {
        var confirm = true
        var specs: [String] = []
        for a in c.args {
            if a.uppercased() == "/Y" {
                confirm = false
            } else if a.hasPrefix("/") {
                c.out.line("Invalid switch - \(a)")
                return
            } else {
                specs.append(a)
            }
        }
        guard !specs.isEmpty else {
            c.out.line("Required parameter missing")
            return
        }
        for spec in specs {
            guard let r = try? drives.resolve(spec) else {
                c.out.line("Invalid drive specification")
                continue
            }
            var victims: [Resolved] = []
            if Wild.has(r.last) {
                guard r.parentExists else { continue }
                victims = readEntries(drives.url(r.parent), dots: false).filter { matches($0, r.last) }.map {
                    Resolved(letter: r.letter, comps: r.comps.dropLast() + [$0.name], exists: true, parentExists: true)
                }
            } else if r.exists && !r.comps.isEmpty {
                victims = [r]
            }
            for v in victims {
                if gInterrupted != 0 { return }
                let u = drives.url(v)
                let dir = isDir(u)
                let shown = dosShow(v)
                if confirm {
                    let q = dir ? "Delete directory \"\(shown)\" and all its subdirectories? [yn] " : "Delete file \"\(shown)\"? [yn] "
                    guard let yes = askYN(q) else { return }
                    if !yes { continue }
                }
                c.out.line("Deleting \(shown)...")
                do {
                    try removeFile(u, letter: v.letter)
                } catch {
                    c.out.line("Access denied")
                    continue
                }
                // don't leave a drive's current directory pointing into thin air
                for (l, d) in drives.table where l == v.letter && d.cwd.starts(with: v.comps) {
                    drives.table[l]!.cwd = Array(v.comps.dropLast())
                }
            }
        }
    }

    // MARK: MOVE

    func uMove(_ c: Ctx) {
        var confirm = batch.isEmpty
        var parts: [String] = []
        for a in Tok.args(envGet("COPYCMD") ?? "") + c.args {
            switch a.uppercased() {
            case "/Y": confirm = false
            case "/-Y": confirm = true
            case let s where s.hasPrefix("/"):
                c.out.line("Invalid switch - \(a)")
                return
            default: parts.append(a)
            }
        }
        guard parts.count >= 2 else {
            c.out.line("Required parameter missing")
            return
        }
        let destSpec = parts.removeLast()
        var sources: [Resolved] = []
        for s in parts {
            guard let r = try? drives.resolve(s) else {
                c.out.line("Invalid drive specification")
                return
            }
            if Wild.has(r.last) {
                guard r.parentExists else { continue }
                sources += readEntries(drives.url(r.parent), dots: false)
                    .filter { !$0.isDir && !$0.hidden && !$0.system && matches($0, r.last) }
                    .map { Resolved(letter: r.letter, comps: r.comps.dropLast() + [$0.name], exists: true, parentExists: true) }
            } else if r.exists {
                sources.append(r)
            } else {
                c.out.line("Cannot move \(s) - No such file or directory")
            }
        }
        guard !sources.isEmpty else { return }
        guard let d = try? drives.resolve(destSpec) else {
            c.out.line("Invalid drive specification")
            return
        }
        let destIsDir = (d.exists && isDir(drives.url(d))) || destSpec.hasSuffix("\\") || destSpec.hasSuffix(":")
        if sources.count > 1 && !destIsDir {
            c.out.line("Cannot move multiple files to a single file")
            return
        }
        if !destIsDir && !d.parentExists {
            if destSpec.contains("\\"), confirm {
                guard askYN("Make directory \"\(dosShow(d.parent))\"? [yn] ") == true else { return }
            }
            try? FileManager.default.createDirectory(at: drives.url(d.parent), withIntermediateDirectories: true)
        }
        var all = !confirm
        let fm = FileManager.default
        for s in sources {
            if gInterrupted != 0 { return }
            let src = drives.url(s)
            let target = destIsDir
                ? Resolved(letter: d.letter, comps: d.comps + [s.last], exists: false, parentExists: true)
                : d
            let dst = drives.url(target)
            let line = "\(dosShow(s)) => \(dosShow(target)) "
            if src.standardizedFileURL.path.lowercased() == dst.standardizedFileURL.path.lowercased() {
                c.out.line("Source and destination are the same, \(dosShow(s))")
                continue
            }
            if fm.fileExists(atPath: dst.path) {
                if isDir(src) || isDir(dst) {
                    c.out.line(line + "[File exists]")
                    continue
                }
                if !all {
                    guard let a = Console.ask("Overwrite \(dosShow(target)) (Yes/No/All)?", "YNA") else { return }
                    if a == "N" { continue }
                    if a == "A" { all = true }
                }
                do {
                    try removeFile(dst, letter: target.letter)
                } catch {
                    c.out.line(line + "[Unable to delete destination]")
                    continue
                }
            }
            do {
                try fm.moveItem(at: src, to: dst)
                c.out.line(line + "[ok]")
            } catch {
                c.out.line(line + "[Permission denied]")
            }
        }
    }

    // MARK: XCOPY

    struct XcopyOpts {
        var sub = false, empty = false, prompt = false, wait = false, cont = false, assumeDir = false
        var quiet = false, full = false, list = false, hidden = false, overRO = false, tree = false
        var update = false, keep = false, short = false, archiveOnly = false, archiveClear = false
        var since: Date? = nil, newer = false
    }

    func uXcopy(_ c: Ctx) {
        var o = XcopyOpts()
        var confirm = batch.isEmpty
        var params: [String] = []
        for a in Tok.args(envGet("COPYCMD") ?? "") + c.args {
            let up = a.uppercased()
            guard up.hasPrefix("/") else {
                params.append(a)
                continue
            }
            switch up {
            case "/S": o.sub = true
            case "/E": o.sub = true; o.empty = true
            case "/P": o.prompt = true
            case "/W": o.wait = true
            case "/C": o.cont = true
            case "/I": o.assumeDir = true
            case "/Q": o.quiet = true
            case "/F": o.full = true
            case "/L": o.list = true
            case "/H": o.hidden = true
            case "/R": o.overRO = true
            case "/T": o.tree = true
            case "/U": o.update = true
            case "/K": o.keep = true
            case "/N": o.short = true
            case "/A": o.archiveOnly = true
            case "/M": o.archiveClear = true
            case "/Y": confirm = false
            case "/-Y": confirm = true
            case "/V", "/Z": break
            case let s where s.hasPrefix("/D"):
                var v = s.dropFirst(2)
                if v.hasPrefix(":") { v = v.dropFirst() }
                if v.isEmpty {
                    o.newer = true
                } else {
                    let p = v.split(whereSeparator: { $0 == "-" || $0 == "/" || $0 == "." }).compactMap { Int($0) }
                    var dc = DateComponents()
                    guard p.count == 3, (1...12).contains(p[0]), (1...31).contains(p[1]) else {
                        c.out.line("Invalid date")
                        errorLevel = 4
                        return
                    }
                    (dc.month, dc.day, dc.year) = (p[0], p[1], p[2] < 80 ? 2000 + p[2] : p[2] < 100 ? 1900 + p[2] : p[2])
                    o.since = Calendar.current.date(from: dc)
                }
            default:
                c.out.line("Invalid switch - \(a)")
                errorLevel = 4
                return
            }
        }
        guard (1...2).contains(params.count) else {
            c.out.line("Invalid number of parameters")
            errorLevel = 4
            return
        }
        if Shell.deviceName(params[0]) != nil {
            c.out.line("Cannot XCOPY from a reserved device")
            errorLevel = 4
            return
        }
        guard let sr = try? drives.resolve(params[0]) else {
            c.out.line("Invalid drive specification")
            errorLevel = 4
            return
        }
        var srcDir: Resolved, pattern: String
        let srcIsDir = sr.exists && isDir(drives.url(sr)) && !Wild.has(sr.last)
        if srcIsDir {
            srcDir = sr
            pattern = "*.*"
        } else {
            guard sr.parentExists else {
                c.out.line("Path not found")
                errorLevel = 4
                return
            }
            srcDir = sr.parent
            pattern = sr.last
        }
        let wild = srcIsDir || Wild.has(pattern)

        // where to: a directory, or a single file?
        var dstRoot: Resolved
        var dstFile: String? = nil
        if params.count == 2 {
            if Shell.deviceName(params[1]) != nil {
                c.out.line("Cannot XCOPY to a reserved device")
                errorLevel = 4
                return
            }
            guard let dr = try? drives.resolve(params[1]) else {
                c.out.line("Invalid drive specification")
                errorLevel = 4
                return
            }
            if (dr.exists && isDir(drives.url(dr))) || params[1].hasSuffix("\\") || params[1].hasSuffix(":") {
                dstRoot = dr
            } else if dr.exists {
                dstRoot = dr.parent
                dstFile = dr.last
            } else if o.assumeDir && (wild || o.sub) {
                dstRoot = dr
            } else {
                c.out.write("Does \(params[1]) specify a file name\nor directory name on the target\n(F = file, D = directory)?")
                guard let a = Console.ask("", "FD") else { return }
                if a == "D" {
                    dstRoot = dr
                } else {
                    dstRoot = dr.parent
                    dstFile = dr.last
                }
            }
        } else {
            dstRoot = Resolved(letter: drives.current, comps: drives.cwd, exists: true, parentExists: true)
        }
        let srcURL = drives.url(srcDir).standardizedFileURL
        let dstURL = drives.url(dstRoot).standardizedFileURL
        if o.sub && (dstURL.path == srcURL.path || dstURL.path.hasPrefix(srcURL.path + "/")) {
            c.out.line("Cannot perform a cyclic copy")
            errorLevel = 4
            return
        }
        if srcURL.path == dstURL.path && dstFile == nil {
            c.out.line("File cannot be copied onto itself")
            c.out.line("0 File(s) copied")
            errorLevel = 4
            return
        }
        if o.wait {
            c.out.write("Press any key to begin copying file(s)")
            if Console.readKey() == -2 { c.out.line(); return }
            c.out.line()
        }

        let fm = FileManager.default
        var count = 0, matched = 0
        var all = !confirm
        var stop = false

        func mkdir(_ u: URL) -> Bool {
            if o.list || isDir(u) { return true }
            do {
                try fm.createDirectory(at: u, withIntermediateDirectories: true)
                return true
            } catch {
                c.out.line("Unable to create directory")
                return false
            }
        }

        func walk(_ from: URL, _ to: URL) {
            let entries = readEntries(from, dots: false)
            var made = false
            if o.empty || (o.tree && o.sub) { made = mkdir(to) }
            for e in entries where !e.isDir && !o.tree {
                if stop || gInterrupted != 0 { stop = true; return }
                guard matches(e, pattern), o.hidden || (!e.hidden && !e.system) else { continue }
                guard !o.archiveOnly && !o.archiveClear || e.archive else { continue }
                if let s = o.since, e.mtime < s { continue }
                let name = dstFile ?? (o.short ? e.short : e.name)
                let target = to.appendingPathComponent(name)
                let exists = fm.fileExists(atPath: target.path)
                if o.update && !exists { continue }
                if o.newer, exists, let m = (try? fm.attributesOfItem(atPath: target.path))?[.modificationDate] as? Date,
                   m >= e.mtime { continue }
                matched += 1
                let src = from.appendingPathComponent(e.name)
                if o.prompt {
                    guard let yes = askYN("\(dosShow(src)) (Y/N)?") else { stop = true; return }
                    if !yes { continue }
                }
                if !made { made = mkdir(to) }
                if !made { stop = !o.cont; if stop { return } else { continue } }
                if exists && !all && !o.list {
                    guard let a = Console.ask("Overwrite \(dosShow(target)) (Yes/No/All)?", "YNA") else { stop = true; return }
                    if a == "N" { continue }
                    if a == "A" { all = true }
                }
                if o.full {
                    c.out.line("\(dosShow(src)) -> \(dosShow(target))")
                } else if !o.quiet {
                    c.out.line(dosShow(src))
                }
                if o.list {
                    count += 1
                    continue
                }
                if exists && !Platform.isWritable(target.path) {
                    if o.overRO {
                        Platform.setAttributes(target.path, readOnly: false)
                    } else {
                        c.out.line("Access denied")
                        if !o.cont { stop = true; return }
                        continue
                    }
                }
                if exists { try? fm.removeItem(at: target) }
                guard Platform.copyFile(src.path, target.path) else {
                    c.out.line("Access denied")
                    if !o.cont { stop = true; return }
                    continue
                }
                count += 1
                // fresh copies get the archive bit back and lose read-only, unless /K
                if !o.keep { Platform.setAttributes(target.path, readOnly: false, system: false, archive: true) }
                if o.archiveClear { Platform.setAttributes(src.path, archive: false) }
            }
            guard o.sub else { return }
            for e in entries where e.isDir && !e.isLink && (o.hidden || !e.hidden) {
                if stop { return }
                walk(from.appendingPathComponent(e.name), to.appendingPathComponent(o.short ? e.short : e.name))
            }
        }
        walk(srcURL, dstURL)
        if gInterrupted != 0 {
            errorLevel = 2
            return
        }
        if matched == 0 && !o.tree && count == 0 {
            c.out.line("File not found - \(sr.last.isEmpty ? params[0] : sr.last)")
            errorLevel = 1
        }
        c.out.line("\(count) File(s) \(o.list ? "" : "copied")".trimmingCharacters(in: .whitespaces))
        if stop && errorLevel == 0 { errorLevel = 5 }
    }
}
