import Foundation

/// The keys the full-screen tools care about. Everything is decoded here so QBASIC,
/// DEBUG, DEFRAG, ScanDisk and the blue screen all read the same arrow keys the same way.
enum Key: Equatable {
    case char(Character)
    case enter, tab, backspace, escape
    case up, down, left, right
    case home, end, pageUp, pageDown, insert, delete
    case f(Int)
    case ctrl(Character)
    case interrupt, eof, unknown
}

enum KeyReader {
    /// A lone byte, not the start of an escape sequence.
    static func decode(_ b: Int) -> Key? {
        switch b {
        case -1: return .eof
        case -2: return .interrupt
        case 13, 10: return .enter
        case 9: return .tab
        case 8, 127: return .backspace
        case 3: return .interrupt
        case 26: return .eof
        case 0..<32: return .ctrl(Character(UnicodeScalar(UInt8(b + 64))))
        default:
            guard b < 128 else { return .unknown }
            return .char(Character(UnicodeScalar(UInt8(b))))
        }
    }

    /// The part after ESC. Accepts "A", "[A", "OP", "[11~" and friends.
    static func decodeEscape(_ seq: String) -> Key {
        let s = seq.hasPrefix("[") ? String(seq.dropFirst()) : seq
        switch s {
        case "A": return .up
        case "B": return .down
        case "C": return .right
        case "D": return .left
        case "H", "1~", "OH": return .home
        case "F", "4~", "OF": return .end
        case "5~": return .pageUp
        case "6~": return .pageDown
        case "2~": return .insert
        case "3~": return .delete
        case "P", "OP", "11~": return .f(1)
        case "Q", "OQ", "12~": return .f(2)
        case "R", "OR", "13~": return .f(3)
        case "S", "OS", "14~": return .f(4)
        case "15~": return .f(5)
        case "17~": return .f(6)
        case "18~": return .f(7)
        case "19~": return .f(8)
        case "20~": return .f(9)
        case "21~": return .f(10)
        case "23~": return .f(11)
        case "24~": return .f(12)
        default: return .unknown
        }
    }

    /// Reads one key. Escape sequences are read to their final byte, with the same small
    /// pause the line editor uses so a bare Esc is not held hostage.
    static func read(fd: Int32 = 0) -> Key {
        let b = Console.readByte(fd)
        if b != 27 { return decode(b) ?? .unknown }
        if fd != 0 { return .escape }
        guard Console.pending(30) else { return .escape }
        var seq = ""
        while true {
            let c = Console.readByte(fd)
            if c < 0 { break }
            seq.append(Character(UnicodeScalar(UInt8(c))))
            if c >= 0x40 && c <= 0x7E { break }
            if seq.count > 8 { break }
        }
        return decodeEscape(seq)
    }

    /// Case-insensitive letter for menu shortcuts: Key.char("r") -> "R".
    static func letter(_ k: Key) -> Character? {
        guard case .char(let c) = k else { return nil }
        return Character(c.uppercased())
    }
}
