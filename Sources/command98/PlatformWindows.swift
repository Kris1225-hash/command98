#if os(Windows)
import Foundation
import WinSDK
@_exported import ucrt

private func wide(_ s: String) -> [WCHAR] { Array(s.utf16) + [0] }

/// _wopen is variadic, which Swift can't call; _wsopen_s is the same thing with a fixed signature
private func wopen(_ path: String, _ flags: Int32, _ mode: Int32 = 0) -> Int32 {
    var fd: Int32 = -1
    let err = wide(path).withUnsafeBufferPointer { _wsopen_s(&fd, $0.baseAddress!, flags, _SH_DENYNO, mode) }
    return err == 0 ? fd : -1
}

private func fileTimeDate(_ ft: FILETIME) -> Date {
    let t = (UInt64(ft.dwHighDateTime) << 32) | UInt64(ft.dwLowDateTime)
    // FILETIME counts 100ns ticks since 1601
    return Date(timeIntervalSince1970: Double(t) / 10_000_000 - 11_644_473_600)
}

/// The result of opening a DEBUG write target without truncating it. The handle has
/// already been checked for reparse points and directories when `.opened` comes back.
enum PlatformWriteOpen {
    case opened(fd: Int32, finalPath: String, created: Bool)
    case readOnly
    case link
    case failed
}

/// Console handler: ^C and ^Break set the flag the long-running loops check, and we stay alive.
private func ctrlHandler(_ type: DWORD) -> WindowsBool {
    if type == DWORD(CTRL_C_EVENT) || type == DWORD(CTRL_BREAK_EVENT) {
        gInterrupted = 1
        return true
    }
    return false
}

/// The Windows side. A DOS shell on Windows is the one place where ATTRIB, short names and
/// drive letters are all real, so most of this is just asking Win32 nicely.
enum Platform {
    static let name = "Windows"
    static let hostUtility = "NT"
    static let clockOwner = "The clock belongs to Windows now. Use Settings > Time & language to change it."
    static let fixer = "CHKDSK only looks. Windows' own chkdsk (via NT chkdsk) does the fixing."
    #if arch(arm64)
    static let arch = "arm64"
    #else
    static let arch = "x86-64"
    #endif
    static let product = "Command98 for Windows"
    static let trashName = "the Recycle Bin"
    static let hostHelp = """
    Hands a command line to the real cmd.exe, built-ins and all.

    NT command [arguments]

    Handy when a DOS name means something else on NT: NT dir /s, NT ver, NT ipconfig
    """
    static let dotfilesHidden = false
    static let pathListSeparator: Character = ";"
    static let nullDevice = "NUL"

    static func setup() {
        SetConsoleCtrlHandler(ctrlHandler, true)
        SetConsoleOutputCP(UINT(CP_UTF8))
        SetConsoleCP(UINT(CP_UTF8))
        // text-mode stdin stops dead at ^Z; the shell wants to see it (COPY CON, end of input)
        if !isTTY(0) { _ = _setmode(0, _O_BINARY) }
        let out = GetStdHandle(STD_OUTPUT_HANDLE)
        var mode: DWORD = 0
        if GetConsoleMode(out, &mode) {
            SetConsoleMode(out, mode | DWORD(ENABLE_VIRTUAL_TERMINAL_PROCESSING))
        }
    }

    /// Foundation sometimes hands back "/C:/x"; Win32 wants "C:\x".
    static func native(_ path: String) -> String {
        var p = path.replacingOccurrences(of: "/", with: "\\")
        let c = Array(p)
        if c.count >= 3, c[0] == "\\", c[2] == ":", c[1].isLetter { p.removeFirst() }
        if p.count == 2, p.hasSuffix(":") { p += "\\" }
        return p
    }

    static var pid: Int { Int(GetCurrentProcessId()) }

    // MARK: output and descriptors

    static func writeAll(_ fd: Int32, _ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        // console: hand the UTF-8 straight to WriteFile, the CRT would mangle multibyte text
        let h = HANDLE(bitPattern: _get_osfhandle(fd))
        var mode: DWORD = 0
        if fd <= 2, let h, GetConsoleMode(h, &mode) {
            // LF -> CRLF so text lines up the DOS way
            var out: [UInt8] = []
            out.reserveCapacity(bytes.count + 16)
            for b in bytes {
                if b == 10 { out.append(13) }
                out.append(b)
            }
            out.withUnsafeBufferPointer { buf in
                var off = 0
                while off < buf.count {
                    var n: DWORD = 0
                    guard WriteFile(h, buf.baseAddress! + off, DWORD(buf.count - off), &n, nil), n > 0 else { return }
                    off += Int(n)
                }
            }
            return
        }
        bytes.withUnsafeBufferPointer { buf in
            var off = 0
            while off < buf.count {
                let n = _write(fd, buf.baseAddress! + off, UInt32(buf.count - off))
                if n <= 0 { return }
                off += Int(n)
            }
        }
    }

    static func openRead(_ path: String) -> Int32? {
        if path.uppercased() == "NUL" { return openNul(write: false) }
        let fd = wopen(native(path), _O_RDONLY | _O_BINARY)
        return fd >= 0 ? fd : nil
    }

    static func openWrite(_ path: String, append: Bool) -> Int32? {
        if path.uppercased() == "NUL" { return openNul(write: true) }
        // text mode: redirected output gets CRLF line endings, like it always did
        let flags = _O_WRONLY | _O_CREAT | (append ? _O_APPEND : _O_TRUNC) | _O_TEXT
        let fd = wopen(native(path), flags, _S_IREAD | _S_IWRITE)
        return fd >= 0 ? fd : nil
    }

    private static func openNul(write: Bool) -> Int32? {
        let fd = wopen("NUL", write ? _O_WRONLY : _O_RDONLY)
        return fd >= 0 ? fd : nil
    }

    static func closeFD(_ fd: Int32) { _ = _close(fd) }
    static func dupFD(_ fd: Int32) -> Int32 { _dup(fd) }

    /// DEBUG writes binary data and must know whether the whole buffer went out.
    static func writeAllChecked(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
        bytes.withUnsafeBufferPointer { buf in
            var off = 0
            while off < buf.count {
                let n = _write(fd, buf.baseAddress! + off, UInt32(buf.count - off))
                if n <= 0 { return false }
                off += Int(n)
            }
            return true
        }
    }

    static func truncateFD(_ fd: Int32) -> Bool { _chsize_s(fd, 0) == 0 }

    /// Marks the file behind `fd` for deletion when it is closed. The handle, not a path,
    /// is the identity, so a renamed or retargeted path cannot make this remove another
    /// file. The descriptor must have been opened with DELETE access.
    static func deleteOpenFile(_ fd: Int32) -> Bool {
        guard let h = HANDLE(bitPattern: _get_osfhandle(fd)) else { return false }
        var info = FILE_DISPOSITION_INFO()
        // DeleteFile is the first BOOLEAN field; writing the byte avoids depending on
        // whether this SDK imports BOOLEAN as UInt8 or a Swift Bool wrapper.
        withUnsafeMutableBytes(of: &info) { $0[0] = 1 }
        return SetFileInformationByHandle(h, FileDispositionInfo, &info,
                                          DWORD(MemoryLayout<FILE_DISPOSITION_INFO>.size))
    }

    // MARK: console input

    private static var stdinHandle: HANDLE? { GetStdHandle(STD_INPUT_HANDLE) }

    private static func isConsole(_ h: HANDLE?) -> Bool {
        var mode: DWORD = 0
        guard let h else { return false }
        return GetConsoleMode(h, &mode)
    }

    static func isTTY(_ fd: Int32) -> Bool {
        let h = HANDLE(bitPattern: _get_osfhandle(fd))
        if fd == 0 { return isConsole(h) }
        var mode: DWORD = 0
        guard let h else { return false }
        return GetConsoleMode(h, &mode)
    }

    static func withRaw<T>(_ body: () -> T) -> T {
        guard let h = stdinHandle, isConsole(h) else { return body() }
        var mode: DWORD = 0
        GetConsoleMode(h, &mode)
        let off = DWORD(ENABLE_LINE_INPUT) | DWORD(ENABLE_ECHO_INPUT) | DWORD(ENABLE_PROCESSED_INPUT)
        // VT input: arrows and F-keys arrive as the same escape sequences a Unix terminal sends
        SetConsoleMode(h, (mode & ~off) | DWORD(ENABLE_VIRTUAL_TERMINAL_INPUT))
        defer { SetConsoleMode(h, mode) }
        return body()
    }

    /// -1 = EOF, -2 = ^C
    static func readByte(_ fd: Int32) -> Int {
        if fd == 0, let h = stdinHandle, isConsole(h) {
            var b: UInt8 = 0
            var n: DWORD = 0
            guard ReadFile(h, &b, 1, &n, nil), n == 1 else { return -1 }
            if b == 3 {
                gInterrupted = 1
                return -2
            }
            return Int(b)
        }
        var b: UInt8 = 0
        let n = _read(fd, &b, 1)
        return n == 1 ? Int(b) : -1
    }

    /// Is a byte waiting on this descriptor? Only the console is pollable here; redirected
    /// input is read straight through, so the key decoder never needs to peek at it.
    static func pending(_ fd: Int32, _ ms: Int32) -> Bool {
        fd == 0 && pending(ms)
    }

    /// Modifier and lock keys change state but never produce a byte for ReadFile.
    /// Treating their key-down as "input ready" would make the full-screen tools block.
    private static func producesInput(_ vk: UInt16) -> Bool {
        switch vk {
        case 0x10, 0x11, 0x12, 0x14,          // Shift, Ctrl, Alt, Caps Lock
             0x5B, 0x5C, 0x5D,                // left/right Windows, Menu
             0x90, 0x91,                      // Num Lock, Scroll Lock
             0xA0, 0xA1, 0xA2, 0xA3, 0xA4, 0xA5, // left/right Shift, Ctrl, Alt
             0xE5:                            // IME process key
            return false
        default:
            return true // character, navigation, function and keypad keys
        }
    }

    /// Is a keypress waiting? Focus and mouse events wake the handle too, so skip those.
    /// Pure modifiers are consumed and skipped as well: they are key-down events with
    /// no corresponding byte, so returning true for them would strand the caller.
    static func pending(_ ms: Int32) -> Bool {
        guard let h = stdinHandle, isConsole(h) else { return false }
        let deadline = GetTickCount64() + UInt64(max(0, ms))
        while true {
            let now = GetTickCount64()
            let left = now >= deadline ? 0 : DWORD(deadline - now)
            guard WaitForSingleObject(h, left) == WAIT_OBJECT_0 else { return false }
            var rec = INPUT_RECORD()
            var n: DWORD = 0
            guard PeekConsoleInputW(h, &rec, 1, &n), n == 1 else { return false }
            if rec.EventType == WORD(KEY_EVENT) {
                let key = rec.Event.KeyEvent
                if key.bKeyDown.boolValue && producesInput(key.wVirtualKeyCode) { return true }
            }
            // Non-key, key-up, or a modifier/lock: consume it and keep looking.
            ReadConsoleInputW(h, &rec, 1, &n)
            if left == 0 { return false }
        }
    }

    static func termSize(_ fd: Int32 = 1) -> (rows: Int, cols: Int)? {
        var info = CONSOLE_SCREEN_BUFFER_INFO()
        guard GetConsoleScreenBufferInfo(GetStdHandle(STD_OUTPUT_HANDLE), &info) else { return nil }
        let r = Int(info.srWindow.Bottom - info.srWindow.Top) + 1
        let c = Int(info.srWindow.Right - info.srWindow.Left) + 1
        return r > 0 && c > 0 ? (r, c) : nil
    }

    // MARK: files

    static func renameFile(_ a: String, _ b: String) -> Bool {
        MoveFileW(wide(native(a)), wide(native(b)))
    }

    static func fileInfo(_ path: String) -> FileInfo? {
        var d = WIN32_FILE_ATTRIBUTE_DATA()
        guard GetFileAttributesExW(wide(native(path)), GetFileExInfoStandard, &d) else { return nil }
        let a = d.dwFileAttributes
        let isDir = a & DWORD(FILE_ATTRIBUTE_DIRECTORY) != 0
        let size = isDir ? 0 : Int64((UInt64(d.nFileSizeHigh) << 32) | UInt64(d.nFileSizeLow))
        return FileInfo(
            isDir: isDir, isLink: a & DWORD(FILE_ATTRIBUTE_REPARSE_POINT) != 0, isRegular: !isDir,
            size: size, mtime: fileTimeDate(d.ftLastWriteTime), atime: fileTimeDate(d.ftLastAccessTime),
            readOnly: a & DWORD(FILE_ATTRIBUTE_READONLY) != 0, hidden: a & DWORD(FILE_ATTRIBUTE_HIDDEN) != 0,
            system: a & DWORD(FILE_ATTRIBUTE_SYSTEM) != 0, archive: a & DWORD(FILE_ATTRIBUTE_ARCHIVE) != 0)
    }

    /// The real thing: these are the same four bits ATTRIB flipped in 1998.
    @discardableResult
    static func setAttributes(_ path: String, readOnly: Bool? = nil, hidden: Bool? = nil,
                              system: Bool? = nil, archive: Bool? = nil) -> Bool {
        let p = wide(native(path))
        var a = GetFileAttributesW(p)
        guard a != INVALID_FILE_ATTRIBUTES else { return false }
        func flip(_ bit: Int32, _ on: Bool?) {
            guard let on else { return }
            if on { a |= DWORD(bit) } else { a &= ~DWORD(bit) }
        }
        flip(FILE_ATTRIBUTE_READONLY, readOnly)
        flip(FILE_ATTRIBUTE_HIDDEN, hidden)
        flip(FILE_ATTRIBUTE_SYSTEM, system)
        flip(FILE_ATTRIBUTE_ARCHIVE, archive)
        a &= ~DWORD(FILE_ATTRIBUTE_DIRECTORY)
        return SetFileAttributesW(p, a == 0 ? DWORD(FILE_ATTRIBUTE_NORMAL) : a)
    }

    static func isExecutable(_ path: String) -> Bool {
        guard let i = fileInfo(path), !i.isDir else { return false }
        let ext = (path as NSString).pathExtension.uppercased()
        return ["EXE", "COM"].contains(ext)
    }

    static func isWritable(_ path: String) -> Bool {
        guard let i = fileInfo(path) else { return false }
        return !i.readOnly
    }

    /// MZ alone means DOS. MZ with a PE header behind it is a real Windows program.
    static func isNativeMZ(_ path: String) -> Bool {
        guard let h = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? h.close() }
        guard let head = try? h.read(upToCount: 64), head.count == 64 else { return false }
        let b = [UInt8](head)
        let off = UInt64(b[60]) | UInt64(b[61]) << 8 | UInt64(b[62]) << 16 | UInt64(b[63]) << 24
        guard off > 0, off < 1 << 20, (try? h.seek(toOffset: off)) != nil,
              let sig = try? h.read(upToCount: 4) else { return false }
        return [UInt8](sig) == [0x50, 0x45, 0, 0]
    }

    // MARK: final paths for DEBUG's write containment

    private static func finalPath(_ h: HANDLE) -> String? {
        var buf = [WCHAR](repeating: 0, count: 32_768)
        let n = GetFinalPathNameByHandleW(h, &buf, DWORD(buf.count), DWORD(FILE_NAME_NORMALIZED))
        guard n > 0, n < DWORD(buf.count) else { return nil }
        return String(decoding: buf.prefix(Int(n)), as: UTF16.self)
    }

    /// The kernel's final, link-resolved path for an existing file or directory.
    static func finalPath(of path: String) -> String? {
        let h = CreateFileW(wide(native(path)), DWORD(FILE_READ_ATTRIBUTES),
                            DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE), nil,
                            DWORD(OPEN_EXISTING), DWORD(FILE_FLAG_BACKUP_SEMANTICS), nil)
        guard h != INVALID_HANDLE_VALUE else { return nil }
        defer { CloseHandle(h) }
        return finalPath(h)
    }

    /// Case- and separator-insensitive containment for `\\?\` paths returned above.
    static func isPath(_ path: String, insideRoot root: String) -> Bool {
        func clean(_ p: String) -> String {
            var s = native(p)
            if s.hasPrefix("\\\\?\\UNC\\") {
                s = "\\\\" + String(s.dropFirst(8))
            } else if s.hasPrefix("\\\\?\\") {
                s = String(s.dropFirst(4))
            }
            while s.count > 3, s.hasSuffix("\\") { s.removeLast() }
            return s.lowercased()
        }
        let p = clean(path), r = clean(root)
        guard !r.isEmpty else { return false }
        if p == r { return true }
        return p.hasPrefix(r.hasSuffix("\\") ? r : r + "\\")
    }

    /// Opens a DEBUG write target without truncating it. Existing reparse points are
    /// refused; a missing file is created new. The returned fd owns the handle.
    static func openForWriteNoTruncate(_ path: String) -> PlatformWriteOpen {
        let p = wide(native(path))
        let share = DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE)
        let access = DWORD(GENERIC_WRITE) | DWORD(DELETE)
        // GetLastError returns DWORD; these are the documented system codes we map.
        let fileNotFound: DWORD = 2, pathNotFound: DWORD = 3, accessDenied: DWORD = 5
        // Refuse a final reparse point or a directory before asking for write access;
        // the opened handle is still checked below, so a retarget in between is caught.
        let existing = GetFileAttributesW(p)
        if existing != INVALID_FILE_ATTRIBUTES {
            if existing & DWORD(FILE_ATTRIBUTE_REPARSE_POINT) != 0 { return .link }
            if existing & DWORD(FILE_ATTRIBUTE_DIRECTORY) != 0 { return .failed }
        }
        var created = false
        var h = CreateFileW(p, access, share, nil, DWORD(OPEN_EXISTING),
                            DWORD(FILE_ATTRIBUTE_NORMAL) | DWORD(FILE_FLAG_OPEN_REPARSE_POINT), nil)
        if h == INVALID_HANDLE_VALUE {
            let err = GetLastError()
            if err == fileNotFound || err == pathNotFound {
                h = CreateFileW(p, access, share, nil, DWORD(CREATE_NEW),
                                DWORD(FILE_ATTRIBUTE_NORMAL), nil)
                if h != INVALID_HANDLE_VALUE { created = true }
            }
        }
        guard h != INVALID_HANDLE_VALUE else {
            let err = GetLastError()
            if err == accessDenied {
                let attrs = GetFileAttributesW(p)
                if attrs != INVALID_FILE_ATTRIBUTES && attrs & DWORD(FILE_ATTRIBUTE_REPARSE_POINT) != 0 {
                    return .link
                }
                return .readOnly
            }
            return .failed
        }

        var info = BY_HANDLE_FILE_INFORMATION()
        guard GetFileInformationByHandle(h, &info) else {
            CloseHandle(h)
            return .failed
        }
        if info.dwFileAttributes & DWORD(FILE_ATTRIBUTE_REPARSE_POINT) != 0 {
            CloseHandle(h)
            return .link
        }
        if info.dwFileAttributes & DWORD(FILE_ATTRIBUTE_DIRECTORY) != 0 {
            CloseHandle(h)
            return .failed
        }
        guard let final = finalPath(h) else {
            CloseHandle(h)
            return .failed
        }
        let fd = _open_osfhandle(Int(bitPattern: h), _O_WRONLY | _O_BINARY)
        guard fd >= 0 else {
            CloseHandle(h)
            return .failed
        }
        return .opened(fd: fd, finalPath: final, created: created)
    }

    // MARK: "extended attributes": NTFS alternate data streams

    static func xattrName(_ name: String) -> String { name }

    static func xattrGet(_ path: String, _ name: String) -> String? {
        let h = CreateFileW(wide(native(path) + ":" + name), DWORD(GENERIC_READ), DWORD(FILE_SHARE_READ), nil,
                            DWORD(OPEN_EXISTING), DWORD(FILE_FLAG_BACKUP_SEMANTICS), nil)
        guard h != INVALID_HANDLE_VALUE else { return nil }
        defer { CloseHandle(h) }
        var buf = [UInt8](repeating: 0, count: 4096)
        var n: DWORD = 0
        guard ReadFile(h, &buf, DWORD(buf.count), &n, nil) else { return nil }
        return String(decoding: buf.prefix(Int(n)), as: UTF8.self)
    }

    static func xattrSet(_ path: String, _ name: String, _ value: String?) -> Bool {
        let stream = native(path) + ":" + name
        guard let value else {
            _ = DeleteFileW(wide(stream))
            return true
        }
        let h = CreateFileW(wide(stream), DWORD(GENERIC_WRITE), 0, nil, DWORD(CREATE_ALWAYS),
                            DWORD(FILE_FLAG_BACKUP_SEMANTICS), nil)
        guard h != INVALID_HANDLE_VALUE else { return false }
        defer { CloseHandle(h) }
        let b = Array(value.utf8)
        var n: DWORD = 0
        return b.isEmpty || (WriteFile(h, b, DWORD(b.count), &n, nil) && Int(n) == b.count)
    }

    static func copyFile(_ src: String, _ dst: String) -> Bool {
        let d = wide(native(dst))
        let a = GetFileAttributesW(d)
        if a != INVALID_FILE_ATTRIBUTES && a & DWORD(FILE_ATTRIBUTE_READONLY) != 0 { return false }
        return CopyFileW(wide(native(src)), d, false)
    }

    /// Into the Recycle Bin, quietly, so it can be dragged back out.
    static func trash(_ u: URL) throws {
        var from = wide(native(u.path))
        from.append(0) // the list is double-NUL terminated
        let ok: Int32 = from.withUnsafeBufferPointer { buf in
            var op = SHFILEOPSTRUCTW()
            op.wFunc = UINT(FO_DELETE)
            op.pFrom = buf.baseAddress
            op.fFlags = FILEOP_FLAGS(FOF_ALLOWUNDO | FOF_NOCONFIRMATION | FOF_SILENT | FOF_NOERRORUI)
            return SHFileOperationW(&op)
        }
        if ok != 0 { throw CocoaError(.fileWriteNoPermission) }
    }

    private static func volumeRoot(_ path: String) -> String? {
        var buf = [WCHAR](repeating: 0, count: 300)
        guard GetVolumePathNameW(wide(native(path)), &buf, DWORD(buf.count)) else { return nil }
        return String(decoding: buf.prefix { $0 != 0 }, as: UTF16.self)
    }

    static func freeBytes(_ path: String) -> Int64 {
        var avail = ULARGE_INTEGER(), total = ULARGE_INTEGER(), free = ULARGE_INTEGER()
        guard GetDiskFreeSpaceExW(wide(native(path)), &avail, &total, &free) else { return 0 }
        return Int64(avail.QuadPart)
    }

    static func diskStats(_ path: String) -> (unit: Int64, total: Int64, avail: Int64)? {
        guard let root = volumeRoot(path) else { return nil }
        var spc: DWORD = 0, bps: DWORD = 0, freeC: DWORD = 0, totalC: DWORD = 0
        guard GetDiskFreeSpaceW(wide(root), &spc, &bps, &freeC, &totalC) else { return nil }
        let unit = Int64(spc) * Int64(bps)
        var avail = ULARGE_INTEGER(), total = ULARGE_INTEGER(), free = ULARGE_INTEGER()
        guard unit > 0, GetDiskFreeSpaceExW(wide(root), &avail, &total, &free) else { return nil }
        return (unit, Int64(total.QuadPart) / unit, Int64(avail.QuadPart) / unit)
    }

    /// Real drive roots have a real label and serial number. Folders mounted as drives don't.
    static func volumeInfo(_ path: String) -> (label: String, serial: UInt32)? {
        let p = native(path)
        guard p.count == 3, p.hasSuffix(":\\") else { return nil }
        var label = [WCHAR](repeating: 0, count: 64)
        var serial: DWORD = 0
        guard GetVolumeInformationW(wide(p), &label, DWORD(label.count), &serial, nil, nil, nil, 0) else { return nil }
        return (String(decoding: label.prefix { $0 != 0 }, as: UTF16.self), UInt32(serial))
    }

    static func memoryK() -> (total: Int64, free: Int64) {
        var m = MEMORYSTATUSEX()
        m.dwLength = DWORD(MemoryLayout<MEMORYSTATUSEX>.size)
        guard GlobalMemoryStatusEx(&m) else {
            let t = Int64(ProcessInfo.processInfo.physicalMemory) / 1024
            return (t, t / 2)
        }
        return (Int64(m.ullTotalPhys) / 1024, Int64(m.ullAvailPhys) / 1024)
    }

    /// what START hands things to: the real cmd.exe and its START
    static func opener(_ which: (String) -> String?) -> String? {
        var buf = [WCHAR](repeating: 0, count: 300)
        let n = GetSystemDirectoryW(&buf, UINT(buf.count))
        if n > 0 {
            let p = String(decoding: buf.prefix(Int(n)), as: UTF16.self) + "\\cmd.exe"
            if isExecutable(p) { return p }
        }
        return which("cmd")
    }

    /// Every drive letter Windows has right now.
    static func logicalDrives() -> [Character] {
        let mask = GetLogicalDrives()
        return (0..<26).compactMap { i in
            mask & (1 << DWORD(i)) != 0 ? Character(UnicodeScalar(UInt8(65 + i))) : nil
        }
    }

    // MARK: processes

    /// MSVCRT's argument quoting rules, so the child's argv comes out the way we meant it.
    static func quote(_ a: String) -> String {
        if !a.isEmpty && !a.contains(where: { $0 == " " || $0 == "\t" || $0 == "\"" }) { return a }
        var out = "\""
        var slashes = 0
        for ch in a {
            if ch == "\\" {
                slashes += 1
            } else if ch == "\"" {
                out += String(repeating: "\\", count: slashes * 2 + 1) + "\""
                slashes = 0
            } else {
                out += String(repeating: "\\", count: slashes) + String(ch)
                slashes = 0
            }
        }
        return out + String(repeating: "\\", count: slashes * 2) + "\""
    }

    static func spawn(_ path: String, _ args: [String], inFD: Int32, outFD: Int32, cwd: String, env: [String]) -> Int32? {
        var si = STARTUPINFOW()
        si.cb = DWORD(MemoryLayout<STARTUPINFOW>.size)
        si.dwFlags = DWORD(STARTF_USESTDHANDLES)
        let hin = HANDLE(bitPattern: _get_osfhandle(inFD))
        let hout = HANDLE(bitPattern: _get_osfhandle(outFD))
        let herr = GetStdHandle(STD_ERROR_HANDLE)
        for h in [hin, hout, herr] {
            if let h { SetHandleInformation(h, DWORD(HANDLE_FLAG_INHERIT), DWORD(HANDLE_FLAG_INHERIT)) }
        }
        si.hStdInput = hin
        si.hStdOutput = hout
        si.hStdError = herr

        var cmdline = wide(([native(path)] + args).map(quote).joined(separator: " "))
        var block: [WCHAR] = []
        for e in env { block += Array(e.utf16) + [0] }
        block += [0, 0]
        var pi = PROCESS_INFORMATION()
        let started = block.withUnsafeMutableBufferPointer { envBuf in
            CreateProcessW(wide(native(path)), &cmdline, nil, nil, true, DWORD(CREATE_UNICODE_ENVIRONMENT),
                           envBuf.baseAddress, wide(native(cwd)), &si, &pi)
        }
        guard started else { return nil }
        defer {
            CloseHandle(pi.hThread)
            CloseHandle(pi.hProcess)
        }
        WaitForSingleObject(pi.hProcess, INFINITE)
        var code: DWORD = 0
        GetExitCodeProcess(pi.hProcess, &code)
        return Int32(bitPattern: UInt32(code)) & 0xff
    }
}
#endif
