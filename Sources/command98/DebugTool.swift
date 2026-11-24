import Foundation

/// DEBUG.EXE, in-process. The classic dash prompt, a 64 KiB scratch segment, and just
/// enough of an assembler to poke at bytes. Files are real files, but nothing is written
/// without the caller saying yes first.

enum DebugFileError: Error {
    case invalidDrive
}

/// A name resolved through the DOS drive table, plus the few facts DEBUG cares about.
struct DebugPath {
    let dosPath: String
    let url: URL
    let exists: Bool
    let readOnly: Bool
    /// false when the real path (after links) leaves every mounted drive
    let inside: Bool
}

/// Everything the session needs from the outside world, kept behind closures so tests can
/// hand it a drive table or nothing at all.
struct DebugFiles {
    var resolve: (String) throws -> DebugPath
    var read: (DebugPath) -> Data?
    var write: (DebugPath, Data) throws -> Void

    static let unavailable = DebugFiles(
        resolve: { _ in throw DebugFileError.invalidDrive },
        read: { _ in nil },
        write: { _, _ in throw DebugFileError.invalidDrive }
    )
}

struct DebugRegisters {
    var ax: UInt16 = 0
    var bx: UInt16 = 0
    var cx: UInt16 = 0
    var dx: UInt16 = 0
    var sp: UInt16 = 0xFFEE
    var bp: UInt16 = 0
    var si: UInt16 = 0
    var di: UInt16 = 0
    var ds: UInt16 = 0x0000
    var es: UInt16 = 0x0000
    var ss: UInt16 = 0x0000
    var cs: UInt16 = 0x0000
    var ip: UInt16 = 0x0100
    var flags: UInt16 = 0x0202
}

/// A segment:offset pair. Addressing wraps modulo 64 KiB, the way a real mode segment does.
struct DebugAddress {
    var seg: UInt16
    var off: UInt16

    var flat: Int { ((Int(seg) << 4) + Int(off)) & 0xFFFF }

    func advanced(by n: Int) -> DebugAddress {
        let total = Int(off) + n
        return DebugAddress(seg: UInt16((Int(seg) + total / 0x10000) & 0xFFFF),
                            off: UInt16(total & 0xFFFF))
    }
}

final class DebugSession {
    private(set) var memory = [UInt8](repeating: 0, count: 65536)
    var regs = DebugRegisters()
    private(set) var loadedStart = 0x100
    private(set) var loadedLength = 0
    private(set) var hasImage = false
    private(set) var fileName: String?

    let files: DebugFiles
    var input: () -> String?
    var output: (String) -> Void
    var confirmWrite: (String) -> Bool
    var interactive: Bool
    private(set) var running = true

    static let helpText = """
    DEBUG is a small assembler and hex editor that works in memory.

    Commands:
      N name        Name the file DEBUG will use.
      L [address]   Load that file (default 0100).
      D [range]     Dump memory as hexadecimal and text.
      E address ... Change bytes; with no bytes, change one byte at a time.
      A [address]   Assemble NOP, RET, INT, MOV, JMP, CALL, DB and DW.
      U [range]     Disassemble those same instructions.
      R [register]  Show the registers, or give one a new value.
      W [address]   Write the loaded bytes back to the named file.
      Q             Leave DEBUG.
      ?             Show this list.

    Addresses are hexadecimal. A range is `addr`, `addr addr`, or
    `addr L length`. Segment:offset is written `SSSS:OOOO`.
    """

    init(files: DebugFiles = .unavailable,
         input: @escaping () -> String? = { nil },
         output: @escaping (String) -> Void = { _ in },
         confirmWrite: @escaping (String) -> Bool = { _ in false },
         interactive: Bool = false) {
        self.files = files
        self.input = input
        self.output = output
        self.confirmWrite = confirmWrite
        self.interactive = interactive
    }

    // MARK: the prompt

    func run() {
        while running {
            output("-")
            guard let line = input() else {
                output("\n")
                return
            }
            _ = execute(line)
        }
    }

    /// Runs one command. Returns false once Q has ended the session.
    @discardableResult
    func execute(_ raw: String) -> Bool {
        guard running else { return false }
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.isEmpty { return true }

        let command = String(line.first!).uppercased()
        let rest = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)

        switch command {
        case "N": commandName(rest)
        case "L": commandLoad(rest)
        case "D": commandDump(rest)
        case "E": commandEnter(rest)
        case "A": commandAssemble(rest)
        case "U": commandUnassemble(rest)
        case "R": commandRegisters(rest)
        case "W": commandWrite(rest)
        case "Q":
            running = false
            return false
        case "?":
            output(Self.helpText)
            output("\n")
        default:
            output("^ Error\n")
        }
        return true
    }

    // MARK: N and L

    private func commandName(_ rest: String) {
        let name = unquoted(rest)
        if name.isEmpty {
            output(fileName ?? "No file name")
            output("\n")
            return
        }
        do {
            _ = try files.resolve(name)
            fileName = name
        } catch {
            output("Invalid drive specification\n")
        }
    }

    private func commandLoad(_ rest: String) {
        let words = tokens(rest)
        guard words.count <= 1 else { output("^ Error\n"); return }
        var start = DebugAddress(seg: regs.cs, off: 0x0100)
        if let w = words.first {
            guard let a = parseAddress(w, defaultSeg: regs.cs) else {
                output("^ Error\n")
                return
            }
            start = a
        }
        guard let name = fileName else {
            output("No file name\n")
            return
        }
        let path: DebugPath
        do {
            path = try files.resolve(name)
        } catch {
            output("Invalid drive specification\n")
            return
        }
        guard path.inside else {
            output("Access denied - \(path.dosPath)\n")
            return
        }
        guard path.exists else {
            output("File not found - \(path.dosPath)\n")
            return
        }
        guard let data = files.read(path) else {
            output("Error reading file - \(path.dosPath)\n")
            return
        }
        guard data.count + start.flat <= 0x10000 else {
            output("File too large for memory\n")
            return
        }
        for (i, byte) in data.enumerated() {
            memory[(start.flat + i) & 0xFFFF] = byte
        }
        loadedStart = start.flat
        loadedLength = data.count
        hasImage = true
        regs.bx = UInt16((data.count >> 16) & 0xFFFF)
        regs.cx = UInt16(data.count & 0xFFFF)
    }

    // MARK: D

    private func commandDump(_ rest: String) {
        guard let (start, count) = parseRange(rest,
                                             defaultStart: DebugAddress(seg: regs.cs, off: 0x0100),
                                             defaultCount: 128) else {
            output("^ Error\n")
            return
        }
        var offset = 0
        while offset < count {
            let address = start.advanced(by: offset)
            let rowCount = min(16, count - offset)
            var row: [UInt8] = []
            for i in 0..<rowCount {
                row.append(memory[(start.flat + offset + i) & 0xFFFF])
            }
            output(hexRow(address: address, bytes: row) + "\n")
            offset += rowCount
        }
    }

    private func hexRow(address: DebugAddress, bytes: [UInt8]) -> String {
        var hex = ""
        for i in 0..<16 {
            if i == 8 { hex.append("-") }
            if i < bytes.count {
                hex += String(format: "%02X", bytes[i])
            } else {
                hex += "  "
            }
            if i < 15 && i != 7 { hex.append(" ") }
        }
        let ascii = bytes.map { b -> Character in
            (b >= 0x20 && b <= 0x7E) ? Character(UnicodeScalar(b)) : "."
        }
        return String(format: "%04X:%04X", address.seg, address.off) + "  " + hex + "  "
            + String(ascii)
    }

    // MARK: E

    private func commandEnter(_ rest: String) {
        let (addrWord, remainder) = splitFirst(rest)
        guard !addrWord.isEmpty, let address = parseAddress(addrWord, defaultSeg: regs.cs) else {
            output("^ Error\n")
            return
        }
        if !remainder.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let bytes = byteList(remainder), !bytes.isEmpty else {
                output("^ Error\n")
                return
            }
            for (i, byte) in bytes.enumerated() {
                memory[(address.flat + i) & 0xFFFF] = byte
            }
            return
        }
        guard interactive else {
            output("^ Error\n")
            return
        }
        var current = address
        while true {
            output(String(format: "%04X:%04X  %02X.", current.seg, current.off,
                          memory[current.flat]))
            guard let line = input() else {
                output("\n")
                break
            }
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.isEmpty { break }
            if let byte = UInt8(text, radix: 16) {
                memory[current.flat] = byte
                current = current.advanced(by: 1)
            } else {
                output("^ Error\n")
            }
        }
    }

    // MARK: A

    private func commandAssemble(_ rest: String) {
        let words = tokens(rest)
        guard words.count <= 1 else { output("^ Error\n"); return }
        var address = DebugAddress(seg: regs.cs, off: regs.ip)
        if let w = words.first {
            guard let a = parseAddress(w, defaultSeg: regs.cs) else {
                output("^ Error\n")
                return
            }
            address = a
        }
        var used = 0
        var current = address
        while true {
            if interactive { output(String(format: "%04X:%04X", current.seg, current.off)) }
            guard let line = input() else {
                if interactive { output("\n") }
                break
            }
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.isEmpty {
                if interactive { output("\n") }
                break
            }
            guard let bytes = assemble(text, at: current.off) else {
                output("^ Error\n")
                continue
            }
            let shown = current
            for (i, byte) in bytes.enumerated() {
                memory[(address.flat + used + i) & 0xFFFF] = byte
            }
            used += bytes.count
            current = current.advanced(by: bytes.count)
            output(String(format: "%04X:%04X", shown.seg, shown.off) + "  "
                   + bytes.map { String(format: "%02X", $0) }.joined(separator: " ") + "\n")
        }
    }

    private func assemble(_ line: String, at ip: UInt16) -> [UInt8]? {
        var index = line.startIndex
        while index < line.endIndex, line[index] != " ", line[index] != "\t" {
            index = line.index(after: index)
        }
        let mnemonic = String(line[..<index]).uppercased()
        let operand = String(line[index...]).trimmingCharacters(in: .whitespaces)
        guard !mnemonic.isEmpty else { return nil }

        switch mnemonic {
        case "NOP":
            return operand.isEmpty ? [0x90] : nil
        case "RET":
            return operand.isEmpty ? [0xC3] : nil
        case "INT":
            guard let vector = hexByte(operand) else { return nil }
            return vector == 0x03 ? [0xCC] : [0xCD, vector]
        case "MOV":
            return assembleMov(operand)
        case "JMP":
            guard let target = jumpTarget(operand) else { return nil }
            let rel = UInt16(truncatingIfNeeded: Int(target) - Int(ip) - 3)
            return [0xE9, UInt8(rel & 0xFF), UInt8(rel >> 8)]
        case "CALL":
            guard let target = jumpTarget(operand) else { return nil }
            let rel = UInt16(truncatingIfNeeded: Int(target) - Int(ip) - 3)
            return [0xE8, UInt8(rel & 0xFF), UInt8(rel >> 8)]
        case "DB":
            return byteList(operand)
        case "DW":
            return wordList(operand)
        default:
            return nil
        }
    }

    private func assembleMov(_ operand: String) -> [UInt8]? {
        let halves = operand.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
        guard halves.count == 2 else { return nil }
        let dst = halves[0].trimmingCharacters(in: .whitespaces).uppercased()
        let src = halves[1].trimmingCharacters(in: .whitespaces)
        let r8 = ["AL": 0, "CL": 1, "DL": 2, "BL": 3,
                  "AH": 4, "CH": 5, "DH": 6, "BH": 7]
        let r16 = ["AX": 0, "CX": 1, "DX": 2, "BX": 3,
                   "SP": 4, "BP": 5, "SI": 6, "DI": 7]
        if let n = r8[dst] {
            guard let value = hexByte(src) else { return nil }
            return [UInt8(0xB0 + n), value]
        }
        if let n = r16[dst] {
            guard let value = hexWord(src) else { return nil }
            return [UInt8(0xB8 + n), UInt8(value & 0xFF), UInt8(value >> 8)]
        }
        return nil
    }

    private func jumpTarget(_ operand: String) -> UInt16? {
        guard let address = parseAddress(operand, defaultSeg: regs.cs) else { return nil }
        return address.off
    }

    // MARK: U

    private func commandUnassemble(_ rest: String) {
        guard let (start, count) = parseRange(rest,
                                             defaultStart: DebugAddress(seg: regs.cs, off: regs.ip),
                                             defaultCount: 32) else {
            output("^ Error\n")
            return
        }
        var offset = 0
        while offset < count {
            let address = start.advanced(by: offset)
            let remaining = count - offset
            let opcode = memory[(start.flat + offset) & 0xFFFF]
            let needed = instructionLength(opcode)
            if needed > remaining {
                output(formatInstruction(address: address, bytes: [opcode], text: "DB "
                    + String(format: "%02X", opcode)) + "\n")
                offset += 1
                continue
            }
            var raw: [UInt8] = []
            for i in 0..<needed {
                raw.append(memory[(start.flat + offset + i) & 0xFFFF])
            }
            let text = disassemble(raw, at: address.off)
            output(formatInstruction(address: address, bytes: raw, text: text) + "\n")
            offset += needed
        }
    }

    private func formatInstruction(address: DebugAddress, bytes: [UInt8], text: String) -> String {
        let byteText = bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
        let pad = max(0, 12 - byteText.count)
        return String(format: "%04X:%04X", address.seg, address.off) + "  " + byteText
            + String(repeating: " ", count: pad) + " " + text
    }

    private func instructionLength(_ opcode: UInt8) -> Int {
        switch opcode {
        case 0xB0...0xB7, 0xCD, 0xEB: return 2
        case 0xB8...0xBF, 0xE8, 0xE9: return 3
        default: return 1
        }
    }

    private func disassemble(_ bytes: [UInt8], at ip: UInt16) -> String {
        let op = bytes[0]
        switch op {
        case 0x90: return "NOP"
        case 0xC3: return "RET"
        case 0xCC: return "INT 3"
        case 0xCD:
            return String(format: "INT %02X", bytes[1])
        case 0xB0...0xB7:
            let names = ["AL", "CL", "DL", "BL", "AH", "CH", "DH", "BH"]
            return "MOV " + names[Int(op - 0xB0)] + String(format: ",%02X", bytes[1])
        case 0xB8...0xBF:
            let names = ["AX", "CX", "DX", "BX", "SP", "BP", "SI", "DI"]
            let word = UInt16(bytes[1]) | (UInt16(bytes[2]) << 8)
            return "MOV " + names[Int(op - 0xB8)] + String(format: ",%04X", word)
        case 0xE9:
            let rel = UInt16(bytes[1]) | (UInt16(bytes[2]) << 8)
            let target = UInt16(truncatingIfNeeded: Int(ip) + 3 + Int(rel))
            return String(format: "JMP %04X", target)
        case 0xEB:
            let target = UInt16(truncatingIfNeeded: Int(ip) + 2 + Int(Int8(bitPattern: bytes[1])))
            return String(format: "JMP %04X", target)
        case 0xE8:
            let rel = UInt16(bytes[1]) | (UInt16(bytes[2]) << 8)
            let target = UInt16(truncatingIfNeeded: Int(ip) + 3 + Int(rel))
            return String(format: "CALL %04X", target)
        default:
            return String(format: "DB %02X", op)
        }
    }

    // MARK: R

    private func commandRegisters(_ rest: String) {
        let words = tokens(rest)
        guard words.count <= 1 else { output("^ Error\n"); return }
        if words.isEmpty {
            showRegisters()
            return
        }
        let name = words[0].uppercased()
        let value: UInt16?
        switch name {
        case "AX": value = regs.ax
        case "BX": value = regs.bx
        case "CX": value = regs.cx
        case "DX": value = regs.dx
        case "SP": value = regs.sp
        case "BP": value = regs.bp
        case "SI": value = regs.si
        case "DI": value = regs.di
        case "DS": value = regs.ds
        case "ES": value = regs.es
        case "SS": value = regs.ss
        case "CS": value = regs.cs
        case "IP": value = regs.ip
        case "F", "FLAGS": value = regs.flags
        default: output("^ Error\n"); return
        }
        output((name == "FLAGS" ? "F" : name) + String(format: " %04X", value ?? 0) + "\n")
        output(": ")
        guard let line = input() else { return }
        let text = line.trimmingCharacters(in: .whitespaces)
        if text.isEmpty { return }
        guard let newValue = hexWord(text) else {
            output("^ Error\n")
            return
        }
        switch name {
        case "AX": regs.ax = newValue
        case "BX": regs.bx = newValue
        case "CX": regs.cx = newValue
        case "DX": regs.dx = newValue
        case "SP": regs.sp = newValue
        case "BP": regs.bp = newValue
        case "SI": regs.si = newValue
        case "DI": regs.di = newValue
        case "DS": regs.ds = newValue
        case "ES": regs.es = newValue
        case "SS": regs.ss = newValue
        case "CS": regs.cs = newValue
        case "IP": regs.ip = newValue
        default: regs.flags = newValue
        }
    }

    private func showRegisters() {
        output(String(format: "AX=%04X  BX=%04X  CX=%04X  DX=%04X  SP=%04X  BP=%04X  SI=%04X  DI=%04X",
                      regs.ax, regs.bx, regs.cx, regs.dx, regs.sp, regs.bp, regs.si, regs.di) + "\n")
        output(String(format: "DS=%04X  ES=%04X  SS=%04X  CS=%04X  IP=%04X   ",
                      regs.ds, regs.es, regs.ss, regs.cs, regs.ip) + flagString + "\n")
    }

    private var flagString: String {
        let f = regs.flags
        func pick(_ bit: UInt16, _ set: String, _ clear: String) -> String {
            (f & bit) != 0 ? set : clear
        }
        return [
            pick(0x0800, "OV", "NV"),
            pick(0x0400, "DN", "UP"),
            pick(0x0200, "EI", "DI"),
            pick(0x0080, "NG", "PL"),
            pick(0x0040, "ZR", "NZ"),
            pick(0x0010, "AC", "NA"),
            pick(0x0004, "PE", "PO"),
            pick(0x0001, "CY", "NC"),
        ].joined(separator: " ")
    }

    // MARK: W

    private func commandWrite(_ rest: String) {
        guard hasImage, let name = fileName else {
            output("No file to write\n")
            return
        }
        let words = tokens(rest)
        var sourceStart = loadedStart
        if words.count == 1 {
            guard let address = parseAddress(words[0], defaultSeg: regs.cs) else {
                output("^ Error\n")
                return
            }
            sourceStart = address.flat
        } else if words.count >= 2 {
            output("Direct sector writes are not available here.\n")
            return
        }

        let target: DebugPath
        do {
            target = try files.resolve(name)
        } catch {
            output("Invalid drive specification\n")
            return
        }
        guard target.inside else {
            output("Access denied - \(target.dosPath)\n")
            return
        }
        guard !target.readOnly else {
            output("File is read-only - \(target.dosPath)\n")
            return
        }

        let count = loadedLength
        var data = Data()
        data.reserveCapacity(count)
        for i in 0..<count {
            data.append(memory[(sourceStart + i) & 0xFFFF])
        }
        let warning = "About to write \(count) bytes to \(target.dosPath)."
        guard confirmWrite(warning) else {
            output("Write cancelled.\n")
            return
        }
        do {
            try files.write(target, data)
        } catch {
            output("Write failed - \(target.dosPath)\n")
            return
        }
        output("\(count) bytes written to \(target.dosPath)\n")
    }

    // MARK: ranges and addresses

    private func parseRange(_ rest: String, defaultStart: DebugAddress,
                            defaultCount: Int) -> (DebugAddress, Int)? {
        let words = tokens(rest)
        switch words.count {
        case 0:
            return (defaultStart, defaultCount)
        case 1:
            guard let start = parseAddress(words[0], defaultSeg: defaultStart.seg) else { return nil }
            return (start, defaultCount)
        case 2:
            guard let start = parseAddress(words[0], defaultSeg: defaultStart.seg) else { return nil }
            if words[1].uppercased() == "L" { return nil }
            guard let end = parseAddress(words[1], defaultSeg: start.seg) else { return nil }
            guard end.flat >= start.flat else { return nil }
            return (start, end.flat - start.flat + 1)
        case 3:
            guard words[1].uppercased() == "L" else { return nil }
            guard let start = parseAddress(words[0], defaultSeg: defaultStart.seg) else { return nil }
            guard let length = Int(words[2], radix: 16), length > 0, length <= 0x10000 else { return nil }
            return (start, length)
        default:
            return nil
        }
    }

    private func parseAddress(_ text: String, defaultSeg: UInt16) -> DebugAddress? {
        var s = text.uppercased()
        guard !s.isEmpty else { return nil }
        if s.hasSuffix("H") { s.removeLast() }
        guard !s.isEmpty else { return nil }
        if let colon = s.firstIndex(of: ":") {
            let left = String(s[..<colon])
            let right = String(s[s.index(after: colon)...])
            guard !left.isEmpty, !right.isEmpty,
                  let seg = UInt16(left, radix: 16),
                  let off = UInt16(right, radix: 16) else { return nil }
            return DebugAddress(seg: seg, off: off)
        }
        guard let off = UInt16(s, radix: 16) else { return nil }
        return DebugAddress(seg: defaultSeg, off: off)
    }

    // MARK: little parsers

    private func tokens(_ s: String) -> [String] {
        s.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
    }

    private func splitFirst(_ s: String) -> (String, String) {
        var i = s.startIndex
        while i < s.endIndex, s[i] == " " || s[i] == "\t" { i = s.index(after: i) }
        let start = i
        while i < s.endIndex, s[i] != " " && s[i] != "\t" { i = s.index(after: i) }
        return (String(s[start..<i]), String(s[i...]))
    }

    private func unquoted(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespaces)
        if t.count >= 2, t.hasPrefix("\""), t.hasSuffix("\"") {
            t = String(t.dropFirst().dropLast())
        }
        return t
    }

    private func hexByte(_ s: String) -> UInt8? {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, t.count <= 2 else { return nil }
        return UInt8(t, radix: 16)
    }

    private func hexWord(_ s: String) -> UInt16? {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, t.count <= 4 else { return nil }
        return UInt16(t, radix: 16)
    }

    /// Hex bytes and quoted text, separated by spaces or commas. `DB 41 "BC"` is three bytes.
    private func byteList(_ s: String) -> [UInt8]? {
        var result: [UInt8] = []
        let chars = Array(s)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == " " || c == "\t" || c == "," { i += 1; continue }
            if c == "\"" || c == "'" {
                let quote = c
                i += 1
                var closed = false
                while i < chars.count {
                    if chars[i] == quote { i += 1; closed = true; break }
                    guard let value = chars[i].asciiValue else { return nil }
                    result.append(value)
                    i += 1
                }
                if !closed { return nil }
                continue
            }
            var digits = ""
            while i < chars.count, !" \t,".contains(chars[i]) {
                digits.append(chars[i])
                i += 1
            }
            guard digits.count >= 1, digits.count <= 2, let value = UInt8(digits, radix: 16) else {
                return nil
            }
            result.append(value)
        }
        return result.isEmpty ? nil : result
    }

    private func wordList(_ s: String) -> [UInt8]? {
        var result: [UInt8] = []
        let chars = Array(s)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == " " || c == "\t" || c == "," { i += 1; continue }
            var digits = ""
            while i < chars.count, !" \t,".contains(chars[i]) {
                digits.append(chars[i])
                i += 1
            }
            guard digits.count >= 1, digits.count <= 4, let value = UInt16(digits, radix: 16) else {
                return nil
            }
            result.append(UInt8(value & 0xFF))
            result.append(UInt8(value >> 8))
        }
        return result.isEmpty ? nil : result
    }
}

// MARK: - Shell hookup

extension Shell {
    func uDebug(_ c: Ctx) {
        let session = DebugSession(files: DebugTool.files(for: self))
        session.output = { c.out.write($0) }
        session.interactive = c.io.inFD == 0 && Console.isTTY
        session.input = {
            switch self.readInput(c) {
            case .line(let text): return text
            case .eof, .interrupt: return nil
            }
        }
        session.confirmWrite = { warning in
            if c.io.inFD == 0 && Console.isTTY {
                return Console.ask(warning + " Write it (Y/N)? ", "YN") == "Y"
            }
            c.out.write(warning + " Write it (Y/N)? ")
            guard case .line(let answer) = self.readInput(c) else { return false }
            c.out.write("\n")
            return answer.trimmingCharacters(in: .whitespaces).uppercased().hasPrefix("Y")
        }
        session.run()
    }
}

enum DebugTool {
    static let utilities: [String: CommandHandler] = ["DEBUG": Shell.uDebug]

    static let stubFiles: [(String, String, Int)] = [
        ("WINDOWS\\COMMAND", "DEBUG.EXE", 20_702),
    ]

    static let help: [String: String] = [
        "DEBUG": DebugSession.helpText,
    ]

    static let stubVersion = "1"

    /// The real drive table, with link checks, for a running shell.
    static func files(for shell: Shell) -> DebugFiles {
        DebugFiles(
            resolve: { name in
                let resolved: Resolved
                do {
                    resolved = try shell.drives.resolve(name)
                } catch {
                    throw DebugFileError.invalidDrive
                }
                let url = shell.drives.url(resolved)
                // follow links and ask the drive table whether the destination is still
                // inside a mounted drive; that works the same with NTFS junctions and
                // with POSIX symlinks, and needs no path spelling assumptions.
                let real = url.standardizedFileURL.resolvingSymlinksInPath().path
                let inside = shell.drives.hostToDos(real) != nil
                var isDirectory: ObjCBool = false
                let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
                    && !isDirectory.boolValue
                let readOnly = exists && !Platform.isWritable(url.path)
                return DebugPath(
                    dosPath: shell.drives.dosPath(resolved.letter, resolved.comps, long: true),
                    url: url,
                    exists: exists,
                    readOnly: readOnly,
                    inside: inside
                )
            },
            read: { path in FileManager.default.contents(atPath: path.url.path) },
            write: { path, data in try data.write(to: path.url) }
        )
    }
}
