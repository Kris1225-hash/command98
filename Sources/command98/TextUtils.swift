import Foundation


extension Shell {
    func fileText(_ u: URL) -> String? {
        guard let d = FileManager.default.contents(atPath: u.path) else { return nil }
        return String(decoding: Shell.cutZ(d), as: UTF8.self)
    }

    // MARK: FIND

    func uFind(_ c: Ctx) {
        var invert = false, countOnly = false, numbers = false, ignoreCase = false
        var needle: String? = nil
        var files: [String] = []
        for w in Tok.words(c.rest, seps: [" ", "\t"]) {
            if w.quoted && needle == nil {
                needle = w.text
                continue
            }
            if w.text.hasPrefix("/") && !w.quoted {
                for sw in w.text.uppercased().split(separator: "/") {
                    switch sw {
                    case "V": invert = true
                    case "C": countOnly = true
                    case "N": numbers = true
                    case "I": ignoreCase = true
                    default:
                        c.out.line("FIND: Invalid switch")
                        errorLevel = 2
                        return
                    }
                }
                continue
            }
            if needle == nil {
                c.out.line("FIND: Parameter format not correct")
                errorLevel = 2
                return
            }
            files.append(w.text)
        }
        guard let n = needle else {
            c.out.line("FIND: Parameter format not correct")
            errorLevel = 2
            return
        }
        var any = false
        func scan(_ text: String, header: String?) {
            var hits = 0
            var lines: [String] = []
            for (i, l) in Shell.textLines(text).enumerated() {
                let has = ignoreCase ? l.range(of: n, options: .caseInsensitive) != nil : l.contains(n)
                guard has != invert else { continue }
                hits += 1
                if !countOnly { lines.append(numbers ? "[\(i + 1)]\(l)" : l) }
            }
            if hits > 0 { any = true }
            if let h = header {
                if countOnly {
                    c.out.line()
                    c.out.line("---------- \(h): \(hits)")
                } else {
                    c.out.line()
                    c.out.line("---------- \(h)")
                }
            } else if countOnly {
                c.out.line("\(hits)")
            }
            lines.forEach { c.out.line($0) }
        }
        if files.isEmpty {
            guard let t = readAllText(c) else { return }
            scan(t, header: nil)
        } else {
            for f in files {
                guard let (dir, es) = matchFiles(f), !es.isEmpty else {
                    c.out.line("File not found - \(f.uppercased())")
                    errorLevel = 2
                    continue
                }
                let prefix = f.contains("\\") || f.contains(":")
                    ? String(f[...(f.lastIndex(where: { $0 == "\\" || $0 == ":" })!)]).uppercased()
                    : ""
                for e in es {
                    if gInterrupted != 0 { return }
                    guard let t = fileText(drives.url(dir).appendingPathComponent(e.name)) else {
                        c.out.line("Access denied - \(e.name.uppercased())")
                        continue
                    }
                    scan(t, header: prefix + e.name.uppercased())
                }
            }
        }
        if errorLevel == 0 { errorLevel = any ? 0 : 1 }
    }

    // MARK: SORT

    func uSort(_ c: Ctx) {
        var reverse = false
        var column = 1
        var file: String? = nil
        for a in c.args {
            let up = a.uppercased()
            if up == "/R" {
                reverse = true
            } else if up.hasPrefix("/+"), let n = Int(up.dropFirst(2)), n >= 1 {
                column = n
            } else if up.hasPrefix("/") {
                c.out.line("SORT: Invalid switch")
                errorLevel = 1
                return
            } else if file == nil {
                file = a
            } else {
                c.out.line("SORT: Too many parameters")
                errorLevel = 1
                return
            }
        }
        var text: String
        if let f = file {
            guard let r = try? drives.resolve(f), r.exists, let t = fileText(drives.url(r)) else {
                c.out.line("SORT: File <\(f)> not found")
                errorLevel = 1
                return
            }
            text = t
        } else {
            guard let t = readAllText(c) else { return }
            text = t
        }
        let lines = Shell.textLines(text).enumerated().map { ($0.offset, $0.element) }
        func key(_ s: String) -> String { String(s.dropFirst(column - 1)) }
        // DOS SORT ignores case; ties keep their original order
        let sorted = lines.sorted { a, b in
            let r = key(a.1).caseInsensitiveCompare(key(b.1))
            if r == .orderedSame { return a.0 < b.0 }
            return reverse ? r == .orderedDescending : r == .orderedAscending
        }
        for (_, l) in sorted { c.out.line(l) }
    }

    // MARK: MORE

    func uMore(_ c: Ctx) {
        var texts: [String] = []
        let files = c.args.filter { !$0.hasPrefix("/") }
        if files.isEmpty {
            guard let t = readAllText(c) else { return }
            texts = [t]
        } else {
            for f in files {
                guard let (dir, es) = matchFiles(f), !es.isEmpty else {
                    c.out.line("Invalid file name in command line")
                    errorLevel = 1
                    return
                }
                for e in es {
                    if let t = fileText(drives.url(dir).appendingPathComponent(e.name)) { texts.append(t) }
                }
            }
        }
        let paging = Platform.isTTY(c.out.fd) && Platform.isTTY(0)
        let cols = Platform.termSize()?.cols ?? 80
        let rows = Console.rows()
        var used = 0
        for t in texts {
            for raw in Shell.textLines(t) {
                if gInterrupted != 0 { return }
                // tabs to 8 columns, like the real one
                var l = ""
                for ch in raw {
                    if ch == "\t" {
                        l += String(repeating: " ", count: 8 - l.count % 8)
                    } else {
                        l.append(ch)
                    }
                }
                let height = max(1, (l.count + cols - 1) / cols)
                if paging && used + height > rows - 1 {
                    c.out.write("-- More --")
                    let k = Console.readKey()
                    c.out.write("\r          \r")
                    if k == -2 { gInterrupted = 0; return }
                    used = 0
                }
                c.out.line(l)
                used += height
            }
        }
    }

    // MARK: FC

    func uFc(_ c: Ctx) {
        var binary = false, text = false, ignoreCase = false, numbers = false, abbrev = false, squeeze = false
        var resync = 2
        var maxMismatch = 100
        var names: [String] = []
        for a in c.args {
            let up = a.uppercased()
            switch up {
            case "/B": binary = true
            case "/L": text = true
            case "/C": ignoreCase = true
            case "/N": numbers = true
            case "/A": abbrev = true
            case "/W": squeeze = true
            case "/T", "/U": break
            case let s where s.hasPrefix("/LB"):
                guard let n = Int(s.dropFirst(3)) else {
                    c.out.line("FC: Invalid switch")
                    return
                }
                maxMismatch = n
            case let s where s.hasPrefix("/"):
                guard let n = Int(s.dropFirst()) else {
                    c.out.line("FC: Invalid switch")
                    return
                }
                resync = max(1, n)
            default:
                names.append(a)
            }
        }
        if binary && text {
            c.out.line("FC: Incompatible switches")
            return
        }
        guard names.count >= 2 else {
            c.out.line("FC: Insufficient number of filespecs")
            return
        }
        guard names.count == 2 else {
            c.out.line("FC: Too many filenames")
            return
        }
        guard let (adir, aes) = matchFiles(names[0], hidden: true), !aes.isEmpty else {
            c.out.line("FC: cannot open \(names[0].uppercased()) - No such file or directory")
            return
        }
        for ae in aes {
            let au = drives.url(adir).appendingPathComponent(ae.name)
            let aName = Wild.has(names[0]) ? dosShow(au).uppercased() : names[0].uppercased()
            var bSpec = names[1]
            if let br = try? drives.resolve(bSpec), br.exists, isDir(drives.url(br)) {
                bSpec = (bSpec.hasSuffix("\\") || bSpec.hasSuffix(":") ? bSpec : bSpec + "\\") + ae.name
            } else if Wild.has(bSpec) {
                let base = bSpec.lastIndex(where: { $0 == "\\" || $0 == ":" }).map { String(bSpec[...$0]) } ?? ""
                bSpec = base + Wild.rename(ae.name, String(bSpec.dropFirst(base.count)))
            }
            guard let br = try? drives.resolve(bSpec), br.exists, !isDir(drives.url(br)),
                  let bData = FileManager.default.contents(atPath: drives.url(br).path),
                  let aData = FileManager.default.contents(atPath: au.path) else {
                c.out.line("FC: cannot open \(bSpec.uppercased()) - No such file or directory")
                continue
            }
            let bName = bSpec.uppercased()
            c.out.line("Comparing files \(aName) and \(bName)")
            let ext = (ae.name as NSString).pathExtension.uppercased()
            let asBinary = binary || (!text && ["EXE", "COM", "SYS", "OBJ", "LIB", "BIN"].contains(ext))
            let differ = asBinary
                ? fcBinary(c, [UInt8](aData), [UInt8](bData), aName, bName)
                : fcText(c, String(decoding: Shell.cutZ(aData), as: UTF8.self), String(decoding: Shell.cutZ(bData), as: UTF8.self),
                         aName, bName, ignoreCase: ignoreCase, squeeze: squeeze, numbers: numbers, abbrev: abbrev,
                         resync: resync, maxMismatch: maxMismatch)
            if !differ {
                c.out.line("FC: no differences encountered")
                c.out.line()
            }
            if differ { errorLevel = 1 }
        }
    }

    private func fcBinary(_ c: Ctx, _ a: [UInt8], _ b: [UInt8], _ an: String, _ bn: String) -> Bool {
        var differ = false
        func hex(_ v: Int, _ w: Int) -> String {
            let s = String(v, radix: 16, uppercase: true)
            return String(repeating: "0", count: max(0, w - s.count)) + s
        }
        for i in 0..<min(a.count, b.count) where a[i] != b[i] {
            if gInterrupted != 0 { return true }
            differ = true
            c.out.line("\(hex(i, 8)): \(hex(Int(a[i]), 2)) \(hex(Int(b[i]), 2))")
        }
        if a.count != b.count {
            differ = true
            c.out.line(a.count > b.count ? "FC: \(an) longer than \(bn)" : "FC: \(bn) longer than \(an)")
            c.out.line()
        }
        return differ
    }

    /// Line diff, printed the FC way: each differing block with the matching line on either
    /// side, framed in ***** markers.
    private func fcText(_ c: Ctx, _ at: String, _ bt: String, _ an: String, _ bn: String, ignoreCase: Bool,
                        squeeze: Bool, numbers: Bool, abbrev: Bool, resync: Int, maxMismatch: Int) -> Bool {
        let a = Shell.textLines(at), b = Shell.textLines(bt)
        func norm(_ s: String) -> String {
            var t = s
            if squeeze {
                t = t.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
            }
            return ignoreCase ? t.lowercased() : t
        }
        let na = a.map(norm), nb = b.map(norm)

        // trim the common head and tail, then LCS the middle
        var lo = 0
        while lo < na.count && lo < nb.count && na[lo] == nb[lo] { lo += 1 }
        var hiA = na.count, hiB = nb.count
        while hiA > lo && hiB > lo && na[hiA - 1] == nb[hiB - 1] { hiA -= 1; hiB -= 1 }
        let n = hiA - lo, m = hiB - lo
        if n == 0 && m == 0 { return false }
        guard n * m <= 8_000_000 else {
            c.out.line("Resync failed.  Files are too different")
            return true
        }
        var dp = [Int32](repeating: 0, count: (n + 1) * (m + 1))
        let w = m + 1
        if n > 0 && m > 0 {
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    dp[i * w + j] = na[lo + i] == nb[lo + j] ? dp[(i + 1) * w + j + 1] + 1 : max(dp[(i + 1) * w + j], dp[i * w + j + 1])
                }
            }
        }
        // walk the table into (a-range, b-range) hunks
        var hunks: [(Range<Int>, Range<Int>)] = []
        var i = 0, j = 0
        var startI = -1, startJ = -1
        while i < n || j < m {
            if i < n && j < m && na[lo + i] == nb[lo + j] {
                if startI >= 0 { hunks.append(((lo + startI)..<(lo + i), (lo + startJ)..<(lo + j))); startI = -1 }
                i += 1; j += 1
            } else {
                if startI < 0 { startI = i; startJ = j }
                if j >= m || (i < n && dp[(i + 1) * w + j] >= dp[i * w + j + 1]) { i += 1 } else { j += 1 }
            }
        }
        if startI >= 0 { hunks.append(((lo + startI)..<(lo + n), (lo + startJ)..<(lo + m))) }

        // merge hunks separated by fewer than `resync` matching lines, like FC's resync rule
        var merged: [(Range<Int>, Range<Int>)] = []
        for h in hunks {
            if let last = merged.last, h.0.lowerBound - last.0.upperBound < resync {
                merged[merged.count - 1] = (last.0.lowerBound..<h.0.upperBound, last.1.lowerBound..<h.1.upperBound)
            } else {
                merged.append(h)
            }
        }
        if merged.contains(where: { $0.0.count > maxMismatch || $0.1.count > maxMismatch }) {
            c.out.line("Resync failed.  Files are too different")
            return true
        }
        func show(_ lines: [String], _ r: Range<Int>, _ name: String) {
            c.out.line("***** \(name)")
            let from = max(0, r.lowerBound - 1)
            let to = min(lines.count, r.upperBound + 1)
            var block = Array(from..<to)
            if abbrev && block.count > 2 { block = [block.first!, -1, block.last!] }
            for k in block {
                if k < 0 {
                    c.out.line("...")
                    continue
                }
                c.out.line(numbers ? Fmt.lpad("\(k + 1)", 5) + ":  " + lines[k] : lines[k])
            }
        }
        for (ra, rb) in merged {
            show(a, ra, an)
            show(b, rb, bn)
            c.out.line("*****")
            c.out.line()
        }
        return true
    }
}
