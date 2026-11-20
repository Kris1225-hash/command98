import Foundation


enum DosError: Error {
    case invalidDrive
}

func isDir(_ u: URL) -> Bool {
    var d: ObjCBool = false
    return FileManager.default.fileExists(atPath: u.path, isDirectory: &d) && d.boolValue
}

/// DOS wildcard matching, the 8.3-ish way: `*.*` is everything, `FOO.*` also matches `FOO`,
/// `*.` means "no extension", and trailing `?` may match nothing.
enum Wild {
    static func has(_ s: String) -> Bool { s.contains("*") || s.contains("?") }

    static func matches(_ name: String, _ pattern: String) -> Bool {
        let p = pattern.uppercased(), n = name.uppercased()
        if p == "*" || p == "*.*" { return true }
        if p.hasSuffix(".*"), glob(Array(n), Array(p.dropLast(2))) { return true }
        if p.hasSuffix("."), !p.hasSuffix("..") {
            return !n.contains(".") && glob(Array(n), Array(p.dropLast()))
        }
        return glob(Array(n), Array(p))
    }

    static func glob(_ s: [Character], _ p: [Character]) -> Bool {
        var si = 0, pi = 0, star = -1, mark = 0
        while si < s.count {
            if pi < p.count && (p[pi] == "?" || p[pi] == s[si]) {
                si += 1; pi += 1
            } else if pi < p.count && p[pi] == "*" {
                star = pi; mark = si; pi += 1
            } else if star != -1 {
                pi = star + 1; mark += 1; si = mark
            } else {
                return false
            }
        }
        while pi < p.count && (p[pi] == "*" || p[pi] == "?") { pi += 1 }
        return pi == p.count
    }

    /// REN/COPY wildcard targets: `?` keeps the source char, `*` keeps the rest.
    static func rename(_ src: String, _ pattern: String) -> String {
        func apply(_ s: [Character], _ p: [Character]) -> String {
            var out = ""
            var i = 0
            for c in p {
                if c == "*" {
                    if i < s.count { out += String(s[i...]) }
                    return out
                } else if c == "?" {
                    if i < s.count { out.append(s[i]) }
                } else {
                    out.append(c)
                }
                i += 1
            }
            return out
        }
        func split(_ s: String) -> (String, String?) {
            guard let d = s.lastIndex(of: "."), d != s.startIndex else { return (s, nil) }
            return (String(s[..<d]), String(s[s.index(after: d)...]))
        }
        let (pb, pe) = split(pattern)
        guard let pext = pe else { return apply(Array(src), Array(pattern)) }
        let (sb, se) = split(src)
        let base = apply(Array(sb), Array(pb))
        let ext = apply(Array(se ?? ""), Array(pext))
        return ext.isEmpty ? base : base + "." + ext
    }
}

/// Windows-95-style short name generation (PROGRA~1 and friends).
enum ShortName {
    static let invalid = Set("\"*+,/:;<=>?[\\]|")

    static func isValid83(_ n: String) -> Bool {
        if n.hasPrefix(".") { return false }
        let parts = n.split(separator: ".", omittingEmptySubsequences: false)
        if parts.count > 2 { return false }
        let base = parts[0]
        let ext = parts.count == 2 ? parts[1] : ""
        if base.isEmpty || base.count > 8 || ext.count > 3 { return false }
        if parts.count == 2 && ext.isEmpty { return false }
        for ch in n where ch != "." {
            if ch == " " || !ch.isASCII || invalid.contains(ch) { return false }
            if let a = ch.asciiValue, a < 33 { return false }
        }
        return true
    }

    static func clean(_ s: Substring) -> String {
        var r = ""
        for ch in s.uppercased() {
            if ch == " " || ch == "." { continue }
            if !ch.isASCII || invalid.contains(ch) || (ch.asciiValue ?? 0) < 33 {
                r.append("_")
            } else {
                r.append(ch)
            }
        }
        return r
    }

    /// long name -> short name for every entry of one directory
    static func map(_ names: [String]) -> [String: String] {
        var used = Set<String>()
        var res: [String: String] = [:]
        for n in names where isValid83(n) {
            let s = n.uppercased()
            if !used.contains(s) {
                used.insert(s)
                res[n] = s
            }
        }
        for n in names.sorted() where res[n] == nil {
            var stripped = Substring(n)
            while stripped.hasPrefix(".") { stripped = stripped.dropFirst() }
            var base = stripped
            var ext: Substring = ""
            if let dot = stripped.lastIndex(of: ".") {
                base = stripped[..<dot]
                ext = stripped[stripped.index(after: dot)...]
            }
            var b = clean(base)
            let e = String(clean(ext).prefix(3))
            if b.isEmpty { b = "_" }
            var i = 1
            while true {
                let suffix = "~\(i)"
                let cand = String(b.prefix(8 - suffix.count)) + suffix + (e.isEmpty ? "" : "." + e)
                if !used.contains(cand) {
                    used.insert(cand)
                    res[n] = cand
                    break
                }
                i += 1
            }
        }
        return res
    }
}

struct Drive {
    let letter: Character
    let root: URL
    /// sandbox drives delete for real; everything else goes to the Trash
    let sandbox: Bool
    var cwd: [String] = []
}

struct Resolved {
    let letter: Character
    var comps: [String]
    var exists: Bool
    var parentExists: Bool

    var last: String { comps.last ?? "" }
    var parent: Resolved {
        Resolved(letter: letter, comps: Array(comps.dropLast()), exists: parentExists, parentExists: true)
    }
}

/// Maps DOS drive letters onto macOS directories and resolves DOS paths
/// (case-insensitive, long or short names, `..` and Win9x `...`).
final class Drives {
    var table: [Character: Drive] = [:]
    var current: Character = "C"

    func mount(_ letter: Character, _ path: String, sandbox: Bool) {
        let u = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
        table[letter] = Drive(letter: letter, root: u, sandbox: sandbox)
    }

    var cwd: [String] {
        get { table[current]!.cwd }
        set { table[current]!.cwd = newValue }
    }

    func url(_ l: Character, _ comps: [String]) -> URL {
        comps.reduce(table[l]!.root) { $0.appendingPathComponent($1) }
    }
    func url(_ r: Resolved) -> URL { url(r.letter, r.comps) }
    var cwdURL: URL { url(current, cwd) }

    func entries(_ dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    func lookup(_ part: String, in dir: URL) -> String? {
        if Wild.has(part) { return nil }
        let names = entries(dir)
        if let n = names.first(where: { $0 == part }) { return n }
        if let n = names.first(where: { $0.caseInsensitiveCompare(part) == .orderedSame }) { return n }
        let up = part.uppercased()
        return ShortName.map(names).first(where: { $0.value == up })?.key
    }

    func split(_ path: String) -> (Character?, Bool, [String]) {
        var p = Substring(path)
        var letter: Character? = nil
        if p.count >= 2, p[p.index(after: p.startIndex)] == ":", let f = p.first, f.isLetter, f.isASCII {
            letter = Character(f.uppercased())
            p = p.dropFirst(2)
        }
        let unified = p.replacingOccurrences(of: "/", with: "\\")
        let abs = unified.hasPrefix("\\")
        let parts = unified.split(separator: "\\").map(String.init)
        return (letter, abs, parts)
    }

    func resolve(_ path: String) throws -> Resolved {
        let (dl, abs, parts) = split(path)
        let l = dl ?? current
        guard let d = table[l] else { throw DosError.invalidDrive }
        var comps = abs ? [] : d.cwd
        var exists = true
        var parentExists = true
        for part in parts {
            if part == "." { continue }
            if part.allSatisfy({ $0 == "." }) {
                // "..": up one. Win9x also understood "..." (up two), "...." (up three)
                for _ in 0..<(part.count - 1) where !comps.isEmpty { comps.removeLast() }
                continue
            }
            parentExists = exists
            if exists, let actual = lookup(part, in: url(l, comps)) {
                comps.append(actual)
            } else {
                comps.append(part)
                exists = false
            }
        }
        return Resolved(letter: l, comps: comps, exists: exists, parentExists: parentExists)
    }

    func shortComps(_ l: Character, _ comps: [String]) -> [String] {
        var res: [String] = []
        var u = table[l]!.root
        for c in comps {
            res.append(ShortName.map(entries(u))[c] ?? c.uppercased())
            u.appendPathComponent(c)
        }
        return res
    }

    func dosPath(_ l: Character, _ comps: [String], long: Bool = false) -> String {
        "\(l):\\" + (long ? comps : shortComps(l, comps)).joined(separator: "\\")
    }

    func hostToDos(_ path: String) -> (Character, [String])? {
        var best: (Character, [String], Int)? = nil
        for (l, d) in table {
            let root = d.root.path
            var rest: String? = nil
            if root == "/" {
                rest = String(path.dropFirst())
            } else if path == root {
                rest = ""
            } else if path.hasPrefix(root + "/") {
                rest = String(path.dropFirst(root.count + 1))
            }
            if let r = rest, root.count > (best?.2 ?? -1) {
                best = (l, r.split(separator: "/").map(String.init), root.count)
            }
        }
        return best.map { ($0.0, $0.1) }
    }
}
