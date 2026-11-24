import Foundation

/// The values IO.SYS would have handed to the system. Nothing here needs doing for real;
/// the numbers exist so MEM, DEVICE=ANSI.SYS and the diagnostics can notice them.
struct ConfigValues {
    var files = 30
    var buffers = 30
    /// BUFFERSHIGH=n keeps its own number; plain BUFFERS is still the low-memory figure.
    var buffersHigh: Int? = nil
    var fcbs = "4,0"
    var lastDrive: Character = "Z"
    var stacks = "9,256"
    var shellCommand: String? = nil
    var country: String? = nil
    var breakOn = false
    var dosHigh = false
    var dosUMB = false
    /// DEVICE= paths in file order, exactly as written
    var devices: [String] = []
    /// DEVICEHIGH= paths; acknowledged, not actually placed in upper memory
    var devicesHigh: [String] = []
    var installs: [String] = []
    /// SET name=value pairs with the name upper-cased, the way the DOS environment knows them
    var sets: [String: String] = [:]
    /// directives this shell has never heard of, verbatim
    var unknown: [String] = []
    /// known directives whose values made no sense, verbatim
    var errors: [String] = []
    var bootGui = false
}

/// CONFIG.SYS, as much as a macOS tribute needs. Every line is acknowledged somewhere:
/// the ones with numbers land in `ConfigValues`, the ones that only mattered on real
/// hardware are recorded and left alone, and the rest are kept for the curious.
enum ConfigSys {
    /// Called once at startup, before PATH is built and before AUTOEXEC.BAT. Failure to
    /// read the file is silent, exactly like a machine with no CONFIG.SYS.
    static func apply(_ shell: Shell) -> ConfigValues {
        guard shell.drives.table["C"] != nil,
              let text = read(root: shell.drives.url("C", [])) else { return ConfigValues() }
        return parse(text)
    }

    /// CONFIG.SYS from the root of a drive. The file name is matched without regard to
    /// case so a sandbox created on a case-sensitive filesystem still boots.
    static func read(root: URL) -> String? {
        let direct = root.appendingPathComponent("CONFIG.SYS")
        if let data = try? Data(contentsOf: direct) { return decode(data) }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root.path),
              let name = names.first(where: { $0.caseInsensitiveCompare("CONFIG.SYS") == .orderedSame }),
              let data = try? Data(contentsOf: root.appendingPathComponent(name)) else { return nil }
        return decode(data)
    }

    private static func decode(_ data: Data) -> String? {
        String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }

    /// Parses the text of CONFIG.SYS. A ^Z ends the file; CR, LF and CRLF all end a line.
    static func parse(_ text: String) -> ConfigValues {
        var values = ConfigValues()
        var body = text
        if body.hasPrefix("\u{FEFF}") { body.removeFirst() }
        if let end = body.firstIndex(of: "\u{001A}") { body = String(body[..<end]) }
        // Swift sees CRLF as one Character, so normalise before splitting.
        body = body.replacingOccurrences(of: "\r\n", with: "\n")
        body = body.replacingOccurrences(of: "\r", with: "\n")
        for raw in body.split(separator: "\n") {
            parseLine(String(raw), into: &values)
        }
        return values
    }

    // MARK: lines

    private struct Head {
        let key: String
        /// an `=` followed the keyword (spaces allowed on either side of it)
        let hasEquals: Bool
        /// everything after that `=` (or after the keyword, when there was none)
        let value: String
    }

    private static func head(_ line: String) -> Head? {
        var i = line.startIndex
        while i < line.endIndex, !line[i].isWhitespace, line[i] != "=" {
            i = line.index(after: i)
        }
        guard i > line.startIndex else { return nil }
        let key = String(line[..<i]).uppercased()
        var j = i
        while j < line.endIndex, line[j].isWhitespace { j = line.index(after: j) }
        var hasEquals = false
        if j < line.endIndex, line[j] == "=" {
            hasEquals = true
            j = line.index(after: j)
            while j < line.endIndex, line[j].isWhitespace { j = line.index(after: j) }
        }
        return Head(key: key, hasEquals: hasEquals, value: String(line[j...]))
    }

    private static func parseLine(_ raw: String, into v: inout ConfigValues) {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.isEmpty || line.hasPrefix(";") { return }
        guard let h = head(line) else { v.unknown.append(line); return }

        if h.key == "REM" { return }

        if h.key == "SET" {
            guard let eq = h.value.firstIndex(of: "=") else { v.errors.append(line); return }
            let name = String(h.value[..<eq]).trimmingCharacters(in: .whitespaces).uppercased()
            let value = String(h.value[h.value.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !name.contains(where: { $0.isWhitespace }) else {
                v.errors.append(line)
                return
            }
            v.sets[name] = value
            return
        }

        // Every other directive needs an equals sign; `FILES 40` was never legal.
        guard h.hasEquals else { v.unknown.append(line); return }

        switch h.key {
        case "FILES":
            guard let n = number(h.value) else { v.errors.append(line); return }
            v.files = n

        case "BUFFERS":
            guard let n = number(h.value) else { v.errors.append(line); return }
            v.buffers = n

        case "BUFFERSHIGH":
            guard let n = number(h.value) else { v.errors.append(line); return }
            v.buffersHigh = n

        case "FCBS":
            guard let (a, b) = pair(h.value) else { v.errors.append(line); return }
            v.fcbs = "\(a),\(b)"

        case "STACKS":
            guard let (a, b) = pair(h.value) else { v.errors.append(line); return }
            v.stacks = "\(a),\(b)"

        case "LASTDRIVE":
            let t = h.value.trimmingCharacters(in: .whitespaces)
            guard t.count == 1, let c = t.uppercased().first, c.isASCII, c.isLetter else {
                v.errors.append(line)
                return
            }
            v.lastDrive = c

        case "SHELL":
            guard !h.value.isEmpty else { v.errors.append(line); return }
            v.shellCommand = h.value

        case "COUNTRY":
            let parts = h.value.split(separator: ",", omittingEmptySubsequences: false).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard (1...3).contains(parts.count),
                  number(parts[0]) != nil,
                  parts.count < 2 || number(parts[1]) != nil,
                  parts.count < 3 || !parts[2].isEmpty else {
                v.errors.append(line)
                return
            }
            v.country = parts.joined(separator: ",")

        case "DOS":
            let tokens = h.value.split(separator: ",", omittingEmptySubsequences: false).map {
                $0.trimmingCharacters(in: .whitespaces).uppercased()
            }
            guard !tokens.isEmpty, tokens.allSatisfy({ $0 == "HIGH" || $0 == "UMB" }) else {
                v.errors.append(line)
                return
            }
            v.dosHigh = tokens.contains("HIGH")
            v.dosUMB = tokens.contains("UMB")

        case "BREAK":
            switch h.value.uppercased() {
            case "ON": v.breakOn = true
            case "OFF": v.breakOn = false
            default: v.errors.append(line)
            }

        case "DEVICE":
            guard !h.value.isEmpty else { v.errors.append(line); return }
            if isAnsiDriver(h.value) {
                AnsiSys.load()
            } else {
                v.devices.append(h.value)
            }

        case "DEVICEHIGH":
            guard !h.value.isEmpty else { v.errors.append(line); return }
            if isAnsiDriver(h.value) {
                AnsiSys.load()
            } else {
                v.devicesHigh.append(h.value)
            }

        case "INSTALL":
            guard !h.value.isEmpty else { v.errors.append(line); return }
            v.installs.append(h.value)

        default:
            v.unknown.append(line)
        }
    }

    // MARK: values

    private static func number(_ s: String) -> Int? {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, t.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(t)
    }

    /// `m,n`: the pair that FCBS and STACKS take, with either number allowed to have spaces.
    private static func pair(_ s: String) -> (Int, Int)? {
        let parts = s.split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let a = number(String(parts[0])),
              let b = number(String(parts[1])) else { return nil }
        return (a, b)
    }

    /// True for `ANSI.SYS` under either separator convention, since the sandbox is a Mac
    /// folder and users copy their real CONFIG.SYS in unchanged.
    private static func isAnsiDriver(_ value: String) -> Bool {
        let firstWord = value.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? value
        let leaf = firstWord.split(whereSeparator: { $0 == "\\" || $0 == "/" }).last
        return leaf?.uppercased() == "ANSI.SYS"
    }
}
