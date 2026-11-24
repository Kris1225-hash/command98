#if canImport(Darwin)
import Darwin
#elseif canImport(Musl)
import Musl
#else
import Glibc
#endif
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

/// Where key bytes come from. Production wraps one descriptor; tests seed an array so
/// the escape state machine can be exercised without a terminal.
struct KeyByteStream {
    /// The next byte, blocking like a terminal. -1 is EOF and -2 is ^C.
    var read: () -> Int
    /// True when another byte arrives within `ms`. Polled before every continuation
    /// read, so a lone Esc never holds the program hostage.
    var ready: (Int32) -> Bool
    /// True while bytes remain. Used to replay a finite source in tests.
    var hasMore: () -> Bool

    static func console(fd: Int32) -> KeyByteStream {
        KeyByteStream(
            read: { Console.readByte(fd) },
            ready: { ms in Console.pending(fd, ms) },
            hasMore: { false })
    }

    /// An in-memory stream of bytes that are all available immediately.
    static func seeded(_ bytes: [Int]) -> KeyByteStream {
        var remaining = bytes
        return KeyByteStream(
            read: { remaining.isEmpty ? -1 : remaining.removeFirst() },
            ready: { _ in !remaining.isEmpty },
            hasMore: { !remaining.isEmpty })
    }
}

/// The escape-sequence state machine. It is a value so tests can drive it with a seeded
/// stream; `KeyReader.read` keeps one per descriptor.
struct KeyDecoder {
    private let stream: KeyByteStream
    private let timeoutMS: Int32
    /// A byte read from the stream that belongs to the next key, e.g. the space after
    /// a bare Esc.
    private var saved: Int?

    init(stream: KeyByteStream, timeoutMS: Int32 = 30) {
        self.stream = stream
        self.timeoutMS = timeoutMS
    }

    /// True while there is another key to read (a held-back byte counts).
    var hasMore: Bool { saved != nil || stream.hasMore() }

    /// True when a byte from a previous read is waiting to be decoded.
    var hasHeldByte: Bool { saved != nil }

    /// One keypress, including any byte a previous read held back.
    mutating func readKey() -> Key {
        let first: Int
        if let s = saved {
            saved = nil
            first = s
        } else {
            first = stream.read()
        }
        if first != 27 { return KeyReader.decode(first) ?? .unknown }
        return readEscape()
    }

    /// The part after Esc. `ESC [` is CSI and runs to a final byte; `ESC O` is SS3 and
    /// is exactly one more byte; anything else means the Esc was a key of its own and
    /// the byte that followed belongs to the next read.
    private mutating func readEscape() -> Key {
        guard let introducer = continuation() else { return .escape }

        switch introducer {
        case 0x5B: // '['
            var sequence: [UInt8] = [0x5B]
            while sequence.count < KeyReader.maxSequenceLength {
                guard let b = continuation() else { return hold(0x5B) }
                if b == -2 { return .interrupt }
                guard b >= 0 else { return hold(0x5B) }
                sequence.append(UInt8(truncatingIfNeeded: b))
                // Parameter and intermediate bytes (0x20...0x3F) come before the
                // final byte (0x40...0x7E); the introducer itself is not a final.
                if b >= 0x40 && b <= 0x7E { return KeyReader.decodeSequence(sequence) }
            }
            // No final byte inside the bound: junk, not a key. Whatever follows is
            // decoded normally by the next read.
            return .unknown
        case 0x4F: // 'O'
            guard let b = continuation() else { return hold(0x4F) }
            if b == -2 { return .interrupt }
            guard b >= 0 else { return hold(0x4F) }
            return KeyReader.decodeSequence([0x4F, UInt8(truncatingIfNeeded: b)])
        default:
            if introducer >= 0 { saved = introducer }
            return .escape
        }
    }

    /// One more byte of the sequence, or nil when none arrives inside the timeout.
    private mutating func continuation() -> Int? {
        guard stream.ready(timeoutMS) else { return nil }
        return stream.read()
    }

    /// Keeps `byte` for the next read and reports the Esc that preceded it.
    private mutating func hold(_ byte: Int) -> Key {
        saved = byte
        return .escape
    }
}

enum KeyReader {
    /// Longest CSI the decoder will believe, introducer included. Real sequences are
    /// a handful of bytes; this also keeps a pasted screenful from spinning here.
    static let maxSequenceLength = 32

    /// One decoder per descriptor, so a held-back byte survives between calls.
    private static var decoders: [Int32: KeyDecoder] = [:]

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

    /// The part after Esc, as text: "A", "OP", "[1;5A", "[11~" and friends.
    static func decodeEscape(_ seq: String) -> Key {
        decodeSequence(Array(seq.utf8))
    }

    /// Decodes a complete sequence byte for byte. `bytes` starts with the introducer:
    /// '[' for CSI, 'O' for SS3, or the single final byte of an ESC-letter key.
    /// CSI parameters are ignored; the final byte (or the number before '~') picks
    /// the key. This is pure so the terminal grammar is testable on its own.
    static func decodeSequence(_ bytes: [UInt8]) -> Key {
        guard let introducer = bytes.first else { return .escape }
        switch introducer {
        case UInt8(ascii: "["):
            return decodeCSI(Array(bytes.dropFirst()))
        case UInt8(ascii: "O"):
            // SS3: the introducer, then exactly one final byte.
            guard let final = bytes.dropFirst().first else { return .unknown }
            return decodeFinal(final)
        default:
            return decodeFinal(introducer)
        }
    }

    private static func decodeCSI(_ body: [UInt8]) -> Key {
        guard let final = body.first(where: { $0 >= 0x40 && $0 <= 0x7E }) else { return .unknown }
        if final == UInt8(ascii: "~") {
            // ESC [ 11 ~ is F1. Take the first parameter so `ESC [ 3 ; 5 ~` is still
            // Delete with a modifier rather than a different key.
            let digits = body.prefix { $0 >= 0x30 && $0 <= 0x39 }
            guard let number = Int(String(decoding: digits, as: UTF8.self)) else { return .unknown }
            return keyForTilde(number)
        }
        return decodeFinal(final)
    }

    /// The final byte of a CSI or SS3 sequence, or the letter of `ESC A`.
    private static func decodeFinal(_ b: UInt8) -> Key {
        switch b {
        case UInt8(ascii: "A"): return .up
        case UInt8(ascii: "B"): return .down
        case UInt8(ascii: "C"): return .right
        case UInt8(ascii: "D"): return .left
        case UInt8(ascii: "H"): return .home
        case UInt8(ascii: "F"): return .end
        case UInt8(ascii: "P"): return .f(1)
        case UInt8(ascii: "Q"): return .f(2)
        case UInt8(ascii: "R"): return .f(3)
        case UInt8(ascii: "S"): return .f(4)
        default: return .unknown
        }
    }

    private static func keyForTilde(_ n: Int) -> Key {
        switch n {
        case 1: return .home
        case 2: return .insert
        case 3: return .delete
        case 4: return .end
        case 5: return .pageUp
        case 6: return .pageDown
        case 11: return .f(1)
        case 12: return .f(2)
        case 13: return .f(3)
        case 14: return .f(4)
        case 15: return .f(5)
        case 17: return .f(6)
        case 18: return .f(7)
        case 19: return .f(8)
        case 20: return .f(9)
        case 21: return .f(10)
        case 23: return .f(11)
        case 24: return .f(12)
        default: return .unknown
        }
    }

    /// Reads one key. Escape sequences are read to their final byte, with a small
    /// pause before every continuation so a bare Esc is not held hostage.
    static func read(fd: Int32 = 0) -> Key {
        var decoder = decoders[fd] ?? KeyDecoder(stream: .console(fd: fd))
        let key = decoder.readKey()
        decoders[fd] = decoder
        return key
    }

    /// Forget every per-descriptor decoder. Tests use this between pipes.
    static func resetDecoders() { decoders.removeAll() }

    /// One key, if one is ready without waiting. A byte held back by a previous escape
    /// decode counts even though the kernel descriptor is empty; polling callers must use
    /// this instead of Console.pending, or an Esc+Space pair can strand the space.
    static func hasBufferedKey(fd: Int32 = 0) -> Bool {
        if decoders[fd]?.hasHeldByte == true { return true }
        return Console.pending(fd, 0)
    }

    /// Replays a seeded byte stream as if it came from the console. Tests use this;
    /// it is also handy for exercising redirected input without a terminal.
    static func decodeAll(_ bytes: [Int]) -> [Key] {
        var decoder = KeyDecoder(stream: .seeded(bytes))
        var keys: [Key] = []
        while decoder.hasMore {
            keys.append(decoder.readKey())
        }
        return keys
    }

    /// Case-insensitive letter for menu shortcuts: Key.char("r") -> "R".
    static func letter(_ k: Key) -> Character? {
        guard case .char(let c) = k else { return nil }
        return Character(c.uppercased())
    }
}
