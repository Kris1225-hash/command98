import Foundation
import Darwin

struct DirEntry {
    let name: String
    let short: String
    let isDir: Bool
    let size: Int64
    let mtime: Date
    let atime: Date
    let hidden: Bool
    let readOnly: Bool
    let system: Bool
    let isLink: Bool
    let archive: Bool
    var ext: String {
        guard let d = name.lastIndex(of: "."), d != name.startIndex else { return "" }
        return String(name[name.index(after: d)...])
    }
}

/// DIR switches. Letter sets come straight out of the binary: /A uses "RHSvDA", /O uses "NEDSGAC".
struct DirOpts {
    var wide = false, bare = false, sub = false, pause = false, lower = false, year4 = false, commas = true
    var attrSpecified = false
    var attrReq: [(Character, Bool)] = []
    var order: [(Character, Bool)]? = nil

    mutating func apply(_ raw: String) -> String? {
        var body = Substring(raw.uppercased().dropFirst())
        var neg = false
        if body.hasPrefix("-") {
            neg = true
            body = body.dropFirst()
        }
        guard let key = body.first else { return "Invalid switch - \(raw)" }
        var val = body.dropFirst()
        if val.hasPrefix(":") { val = val.dropFirst() }
        switch key {
        case "W": wide = !neg
        case "B": bare = !neg
        case "S": sub = !neg
        case "P": pause = !neg
        case "L": lower = !neg
        case "4": year4 = !neg
        case "C": commas = !neg
        case "V", "Z": break
        case "A":
            attrReq = []
            attrSpecified = !neg
            if neg { return nil }
            var want = true
            for ch in val {
                if ch == "-" { want = false; continue }
                guard "RHSVDA".contains(ch) else { return "Parameter format not correct - \(raw)" }
                attrReq.append((ch, want))
                want = true
            }
        case "O":
            if neg { order = nil; return nil }
            var o: [(Character, Bool)] = []
            var rev = false
            for ch in val {
                if ch == "-" { rev = true; continue }
                guard "NEDSGAC".contains(ch) else { return "Parameter format not correct - \(raw)" }
                o.append((ch, rev))
                rev = false
            }
            order = o.isEmpty ? [("G", false), ("N", false)] : o
        default:
            return "Invalid switch - \(raw)"
        }
        return nil
    }

    func attrOK(_ e: DirEntry) -> Bool {
        if !attrSpecified { return !e.hidden && !e.system }
        for (l, must) in attrReq {
            let has: Bool
            switch l {
            case "R": has = e.readOnly
            case "H": has = e.hidden
            case "S": has = e.system
            case "D": has = e.isDir
            case "A": has = e.archive
            default: has = false // V: volume labels don't live in directories here
            }
            if has != must { return false }
        }
        return true
    }

    func less(_ a: DirEntry, _ b: DirEntry) -> Bool {
        for (k, rev) in order ?? [] {
            let c: Int
            switch k {
            case "N": c = cmp(a.name.lowercased(), b.name.lowercased())
            case "E": c = cmp(a.ext.lowercased(), b.ext.lowercased())
            case "D": c = cmp(a.mtime, b.mtime)
            case "S": c = cmp(a.size, b.size)
            case "A": c = cmp(a.atime, b.atime)
            case "G": c = a.isDir == b.isDir ? 0 : (a.isDir ? -1 : 1)
            default: c = 0 // C: compression ratio. DriveSpace died, and so did this key
            }
            if c != 0 { return rev ? c > 0 : c < 0 }
        }
        return a.name.lowercased() < b.name.lowercased()
    }

    private func cmp<T: Comparable>(_ a: T, _ b: T) -> Int { a < b ? -1 : (a > b ? 1 : 0) }
}

/// "Press any key to continue . . ." then "(continuing C:\FOO)", like /P always did.
final class Pager {
    let out: Out
    let enabled: Bool
    let rows: Int
    var count = 0
    var label = ""
    var aborted = false

    init(out: Out, enabled: Bool) {
        self.out = out
        self.enabled = enabled
        rows = Console.rows()
    }

    func line(_ s: String = "") {
        if aborted { return }
        if gInterrupted != 0 {
            aborted = true
            return
        }
        out.line(s)
        guard enabled else { return }
        count += 1
        if count >= rows - 1 {
            out.write("Press any key to continue . . .")
            let k = Console.readKey()
            out.line()
            if k == -2 {
                aborted = true
                return
            }
            out.line("(continuing \(label))")
            count = 1
        }
    }
}

extension Shell {
    func statEntry(_ url: URL, name: String, short: String) -> DirEntry? {
        let path = url.path
        var ls = stat()
        var st = stat()
        let isLink = lstat(path, &ls) == 0 && (ls.st_mode & S_IFMT) == S_IFLNK
        if stat(path, &st) != 0 {
            guard isLink else { return nil }
            st = ls
        }
        func date(_ t: timespec) -> Date {
            Date(timeIntervalSince1970: Double(t.tv_sec) + Double(t.tv_nsec) / 1e9)
        }
        let dots = name == "." || name == ".."
        let hidden = !dots && (name.hasPrefix(".") || (st.st_flags & UInt32(UF_HIDDEN)) != 0)
        let extra = Attr.get(path)
        let system = name == ".DS_Store" || name == ".localized" || name.hasPrefix("._") || extra.contains("S")
        let isDirectory = (st.st_mode & S_IFMT) == S_IFDIR
        return DirEntry(
            name: name, short: short, isDir: (st.st_mode & S_IFMT) == S_IFDIR, size: (st.st_mode & S_IFMT) == S_IFDIR ? 0 : Int64(st.st_size),
            mtime: date(st.st_mtimespec), atime: date(st.st_atimespec), hidden: hidden,
            readOnly: access(path, W_OK) != 0, system: system, isLink: isLink,
            archive: !isDirectory && !extra.contains("-A"))
    }

    func readEntries(_ dir: URL, dots: Bool) -> [DirEntry] {
        let names = drives.entries(dir)
        let sm = ShortName.map(names)
        var res: [DirEntry] = []
        if dots {
            if let e = statEntry(dir, name: ".", short: ".") { res.append(e) }
            if let e = statEntry(dir.deletingLastPathComponent(), name: "..", short: "..") { res.append(e) }
        }
        for n in names {
            if let e = statEntry(dir.appendingPathComponent(n), name: n, short: sm[n] ?? n.uppercased()) {
                res.append(e)
            }
        }
        return res
    }

    func matches(_ e: DirEntry, _ pattern: String) -> Bool {
        Wild.matches(e.name, pattern) || Wild.matches(e.short, pattern)
    }

    func volumeLabel(_ l: Character) -> String {
        let d = drives.table[l]!
        if let set = Attr.label(d.root.path) { return set }
        let name = d.root.path == "/"
            ? ((try? d.root.resourceValues(forKeys: [.volumeNameKey]).volumeName) ?? "")
            : d.root.lastPathComponent
        return String(name.uppercased().prefix(11))
    }

    func serial(_ l: Character) -> String {
        var h: UInt32 = 2_166_136_261
        for b in drives.table[l]!.root.path.utf8 {
            h ^= UInt32(b)
            h = h &* 16_777_619
        }
        let hex = String(h, radix: 16, uppercase: true)
        let s = String(repeating: "0", count: 8 - hex.count) + hex
        return s.prefix(4) + "-" + s.suffix(4)
    }

    func volumeHeader(_ l: Character, _ out: Out) {
        let label = volumeLabel(l)
        out.line(label.isEmpty ? " Volume in drive \(l) has no label" : " Volume in drive \(l) is \(label)")
        out.line(" Volume Serial Number is \(serial(l))")
    }

    func freeBytes(_ u: URL) -> Int64 {
        if let v = try? u.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage { return v }
        if let v = try? u.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity {
            return Int64(v)
        }
        return 0
    }

    /// One row, column-for-column what Win98 printed: 8.3 name, size or <DIR>, date, time, long name.
    func dirLine(_ e: DirEntry, _ o: DirOpts) -> String {
        var b = e.short
        var x = ""
        if e.name != "." && e.name != "..", let d = e.short.lastIndex(of: ".") {
            b = String(e.short[..<d])
            x = String(e.short[e.short.index(after: d)...])
        }
        if o.lower {
            b = b.lowercased()
            x = x.lowercased()
        }
        let size = e.isDir ? "   <DIR>      " : Fmt.lpad(Fmt.num(e.size, commas: o.commas), 14)
        let name = Fmt.pad(b, 8) + " " + Fmt.pad(x, 3)
        return "\(name)\(size)  \(Fmt.date(e.mtime, year4: o.year4)) \(Fmt.time12(e.mtime)) \(e.name)"
    }

    func filesLine(_ n: Int, _ bytes: Int64, _ o: DirOpts) -> String {
        Fmt.lpad("\(n)", 10) + " file(s) " + Fmt.lpad(Fmt.num(bytes, commas: o.commas), 14) + " bytes"
    }

    func dirsLine(_ n: Int, _ free: Int64, _ o: DirOpts) -> String {
        Fmt.lpad("\(n)", 10) + " dir(s) " + Fmt.lpad(Fmt.num(free, commas: o.commas), 15) + " bytes free"
    }

    func cmdDir(_ c: Ctx) {
        var o = DirOpts()
        var targets: [String] = []
        for a in Tok.args(envGet("DIRCMD") ?? "") + c.args {
            if a.hasPrefix("/") {
                if let err = o.apply(a) {
                    c.out.line(err)
                    return
                }
            } else {
                targets.append(a)
            }
        }
        if targets.isEmpty { targets = [""] }

        let pager = Pager(out: c.out, enabled: o.pause && isatty(c.out.fd) == 1)
        var total = (files: 0, bytes: Int64(0), dirs: 0)
        var headerDone = false
        var lastLetter = drives.current

        for t in targets {
            let r: Resolved
            do {
                r = try drives.resolve(t.isEmpty ? "." : t)
            } catch {
                c.out.line("Invalid drive specification")
                continue
            }
            lastLetter = r.letter
            if !o.bare && !headerDone {
                c.out.line()
                volumeHeader(r.letter, c.out)
                headerDone = true
            }
            var comps = r.comps
            var pattern = "*"
            let endsSep = t.isEmpty || t.hasSuffix("\\") || t.hasSuffix(":")
            if !(endsSep || (r.exists && isDir(drives.url(r)))) {
                guard r.parentExists else {
                    pager.line("File not found")
                    continue
                }
                comps = Array(r.comps.dropLast())
                pattern = r.last
            }
            listDirectory(r.letter, comps, pattern, o, pager, &total)
            if pager.aborted { break }
        }

        if o.sub && !o.bare && !pager.aborted {
            if total.files + total.dirs == 0 {
                pager.line("File not found")
            } else {
                pager.line("     Total files listed:")
                pager.line(filesLine(total.files, total.bytes, o))
                pager.line(dirsLine(total.dirs, freeBytes(drives.url(lastLetter, [])), o))
            }
        }
        if pager.aborted { gInterrupted = 0 }
    }

    func listDirectory(_ l: Character, _ comps: [String], _ pattern: String, _ o: DirOpts, _ pager: Pager,
                       _ total: inout (files: Int, bytes: Int64, dirs: Int)) {
        let url = drives.url(l, comps)
        var entries = readEntries(url, dots: !comps.isEmpty).filter { matches($0, pattern) && o.attrOK($0) }
        if o.order != nil { entries.sort { o.less($0, $1) } }
        let label = drives.dosPath(l, comps)
        pager.label = label

        if !entries.isEmpty || !o.sub {
            if !o.bare {
                pager.line(" Directory of \(label)")
                pager.line()
            }
            if entries.isEmpty {
                pager.line("File not found")
                return
            }
            if o.bare {
                for e in entries where e.name != "." && e.name != ".." {
                    var n = o.sub ? drives.dosPath(l, comps + [e.name], long: true) : e.name
                    if o.lower { n = n.lowercased() }
                    pager.line(n)
                }
            } else if o.wide {
                let cells = entries.map { e -> String in
                    let n = o.lower ? e.short.lowercased() : e.short
                    return e.isDir ? "[\(n)]" : n
                }
                stride(from: 0, to: cells.count, by: 5).forEach { i in
                    let row = cells[i..<min(i + 5, cells.count)].map { Fmt.pad($0, 16) }.joined()
                    pager.line(String(row.reversed().drop(while: { $0 == " " }).reversed()))
                }
            } else {
                for e in entries { pager.line(dirLine(e, o)) }
            }
            let files = entries.filter { !$0.isDir }
            let bytes = files.reduce(Int64(0)) { $0 + $1.size }
            let dirs = entries.count - files.count
            total.files += files.count
            total.bytes += bytes
            total.dirs += dirs
            if !o.bare {
                pager.line(filesLine(files.count, bytes, o))
                if o.sub {
                    pager.line()
                } else {
                    pager.line(dirsLine(dirs, freeBytes(url), o))
                }
            }
        }
        guard o.sub else { return }
        for e in readEntries(url, dots: false) where e.isDir && !e.isLink {
            if pager.aborted { return }
            listDirectory(l, comps + [e.name], pattern, o, pager, &total)
        }
    }
}
