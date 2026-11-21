import Foundation
import Darwin

enum CopySource {
    case con
    case file(URL, String)

    var name: String {
        switch self {
        case .con: return "CON"
        case .file(_, let n): return n
        }
    }
    var url: URL? {
        if case .file(let u, _) = self { return u }
        return nil
    }
}

enum CopyDest {
    case con, nul
    case dir(URL)
    case file(URL)
    case pattern(URL, String)
}

extension Shell {
    /// COPY CON: type until ^Z (or ^D, for the mac people), like 1985.
    func readCon(_ c: Ctx) -> Data? {
        if c.io.inFD == 0 {  // piped too: share the shell's line buffer instead of racing it
            var text = ""
            while true {
                switch Console.readLine(template: "") {
                case .interrupt:
                    return nil
                case .eof:
                    return Data(text.utf8)
                case .line(let l):
                    if let z = l.firstIndex(of: "\u{1A}") {
                        text += l[..<z]
                        return Data(text.utf8)
                    }
                    text += l + "\n"
                }
            }
        }
        var d = FileHandle(fileDescriptor: c.io.inFD, closeOnDealloc: false).readDataToEndOfFile()
        if let z = d.firstIndex(of: 0x1A) { d = d[d.startIndex..<z] }
        return d
    }

    func readSource(_ s: CopySource, _ c: Ctx) -> Data? {
        switch s {
        case .con: return readCon(c)
        case .file(let u, _): return FileManager.default.contents(atPath: u.path)
        }
    }

    func expandCopySource(_ s: String, _ c: Ctx) -> (sources: [CopySource], wild: Bool)? {
        if Shell.deviceName(s) == "CON" { return ([.con], false) }
        guard let r = try? drives.resolve(s) else {
            c.out.line("Invalid drive specification")
            return nil
        }
        let visible: (DirEntry) -> Bool = { !$0.isDir && !$0.hidden && !$0.system }
        if r.exists && isDir(drives.url(r)) {
            let u = drives.url(r)
            return (readEntries(u, dots: false).filter(visible).map { .file(u.appendingPathComponent($0.name), $0.name) }, true)
        }
        if Wild.has(r.last) {
            guard r.parentExists else {
                c.out.line("Path not found")
                return nil
            }
            let u = drives.url(r.parent)
            let found = readEntries(u, dots: false).filter { visible($0) && matches($0, r.last) }
            return (found.map { .file(u.appendingPathComponent($0.name), $0.name) }, true)
        }
        guard r.exists else {
            c.out.line("File not found - \(s)")
            return nil
        }
        return ([.file(drives.url(r), r.last)], false)
    }

    func cmdCopy(_ c: Ctx) {
        // inside batch files COPY never asks before overwriting. that's the DOS 6.2+ rule.
        var confirm = batch.isEmpty
        var parts: [String] = []
        for a in Tok.args(envGet("COPYCMD") ?? "") + c.args {
            let up = a.uppercased()
            if up.hasPrefix("/") {
                switch up {
                case "/Y": confirm = false
                case "/-Y": confirm = true
                case "/A", "/B", "/V": break
                default:
                    c.out.line("Invalid switch - \(a)")
                    return
                }
            } else {
                parts.append(a)
            }
        }

        // group "a+b c", "a + b c", "a +b c" into [[a, b], [c]]
        var groups: [[String]] = []
        var join = false
        for p in parts {
            let names = p.split(separator: "+").map(String.init).filter { !$0.isEmpty }
            if (join || p.hasPrefix("+")) && !groups.isEmpty {
                groups[groups.count - 1] += names
            } else if !names.isEmpty {
                groups.append(names)
            }
            join = p.hasSuffix("+")
        }
        let copied = { (n: Int) in c.out.line(Fmt.lpad("\(n)", 9) + " file(s) copied") }

        guard let srcSpecs = groups.first else {
            c.out.line("Required parameter missing")
            return
        }
        if groups.count > 2 {
            c.out.line("Too many parameters - \(groups[2].joined(separator: "+"))")
            return
        }
        var sources: [CopySource] = []
        var wild = false
        for s in srcSpecs {
            guard let (found, w) = expandCopySource(s, c) else {
                copied(0)
                return
            }
            sources += found
            wild = wild || w
        }
        guard !sources.isEmpty else {
            c.out.line("File not found - \(srcSpecs.joined(separator: "+"))")
            copied(0)
            return
        }

        let dest: CopyDest
        if let d = groups.count == 2 ? groups[1].first : nil {
            if let dev = Shell.deviceName(d) {
                dest = dev == "CON" ? .con : .nul
            } else {
                guard let r = try? drives.resolve(d) else {
                    c.out.line("Invalid drive specification")
                    return
                }
                if d.hasSuffix("\\") || d.hasSuffix(":") || (r.exists && isDir(drives.url(r))) {
                    dest = .dir(drives.url(r))
                } else {
                    guard r.parentExists else {
                        c.out.line("Path not found")
                        copied(0)
                        return
                    }
                    dest = Wild.has(r.last) ? .pattern(drives.url(r.parent), r.last) : .file(drives.url(r))
                }
            }
        } else {
            dest = .dir(drives.cwdURL)
        }

        let showNames = wild || srcSpecs.count > 1
        var count = 0
        var all = !confirm

        func overwriteOK(_ target: URL) -> Bool? {
            guard FileManager.default.fileExists(atPath: target.path) else { return true }
            if !all {
                guard let a = Console.ask("Overwrite \(target.lastPathComponent) (Yes/No/All)?", "YNA") else { return nil }
                if a == "N" { return false }
                if a == "A" { all = true }
            }
            if access(target.path, W_OK) != 0 {
                c.out.line("Access denied")
                return false
            }
            return true
        }

        func samePath(_ a: URL?, _ b: URL) -> Bool {
            guard let a else { return false }
            return a.standardizedFileURL.path.caseInsensitiveCompare(b.standardizedFileURL.path) == .orderedSame
        }

        switch dest {
        case .con, .nul:
            for s in sources {
                if showNames { c.out.line(s.name) }
                guard let d = readSource(s, c) else { return }
                if case .con = dest { c.out.raw(Array(d)) }
                count += 1
            }
            copied(count)
            return
        default:
            break
        }

        // wildcard source into a single file, or explicit a+b: concatenate (yes, really)
        var single: URL? = nil
        if case .file(let u) = dest { single = u }
        let concat = srcSpecs.count > 1 || (wild && single != nil)

        if concat {
            let firstName = sources[0].name
            let target: URL
            switch dest {
            case .dir(let u): target = u.appendingPathComponent(firstName)
            case .file(let u): target = u
            case .pattern(let u, let p): target = u.appendingPathComponent(Wild.rename(firstName, p))
            default: return
            }
            var data = Data()
            for s in sources {
                if gInterrupted != 0 { return }
                if showNames { c.out.line(s.name) }
                guard let d = readSource(s, c) else { return }
                data.append(d)
            }
            let appendingToSelf = sources.contains { samePath($0.url, target) }
            if !appendingToSelf {
                guard let ok = overwriteOK(target) else { return }
                if !ok {
                    copied(0)
                    return
                }
            }
            if FileManager.default.createFile(atPath: target.path, contents: data) {
                count = 1
            } else {
                c.out.line("Access denied")
            }
            copied(count)
            return
        }

        for s in sources {
            if gInterrupted != 0 { break }
            let target: URL
            switch dest {
            case .dir(let u): target = u.appendingPathComponent(s.name)
            case .file(let u): target = u
            case .pattern(let u, let p): target = u.appendingPathComponent(Wild.rename(s.name, p))
            default: continue
            }
            if case .con = s, case .dir = dest {
                c.out.line("File cannot be copied onto itself")
                continue
            }
            if samePath(s.url, target) {
                c.out.line("File cannot be copied onto itself")
                continue
            }
            if showNames { c.out.line(s.name) }
            guard let ok = overwriteOK(target) else { break }
            if !ok { continue }
            if let src = s.url {
                if copyfile(src.path, target.path, nil, copyfile_flags_t(COPYFILE_ALL)) == 0 {
                    count += 1
                } else {
                    c.out.line("Access denied")
                }
            } else {
                guard let d = readCon(c) else { break }
                if FileManager.default.createFile(atPath: target.path, contents: d) { count += 1 }
            }
        }
        copied(count)
    }
}
