import Foundation
#if canImport(Darwin)
@_exported import Darwin
#elseif canImport(Musl)
@_exported import Musl
import CSupport
#else
@_exported import Glibc
import CSupport
#endif

// file-scope shims so Platform's own static members don't shadow the C functions
private func cWrite(_ fd: Int32, _ p: UnsafeRawPointer, _ n: Int) -> Int { write(fd, p, n) }
private func cRename(_ a: String, _ b: String) -> Int32 { rename(a, b) }

/// Everything that differs between macOS and Linux lives here, so the rest of the
/// interpreter doesn't have to care which kernel it's lying to.
enum Platform {
    #if os(Linux)
    static let name = "Linux"
    /// the escape hatch utility: LINUX ls -la / MAC ls -la
    static let hostUtility = "LINUX"
    static let clockOwner = "The clock belongs to Linux now. Use timedatectl (as root) to change it."
    static let fixer = "CHKDSK only looks. On Linux, fsck does the fixing (on an unmounted disk)."
    #else
    static let name = "macOS"
    static let hostUtility = "MAC"
    static let clockOwner = "The clock belongs to macOS now. Use System Settings to change it."
    static let fixer = "CHKDSK only looks. On a Mac, First Aid in Disk Utility does the fixing."
    #endif
    #if arch(arm64)
    static let arch = "arm64"
    #else
    static let arch = "x86-64"
    #endif
    static let product = "Command98 for \(name)"
    static let trashName = name == "Linux" ? "the trash can" : "the Trash"

    // MARK: signals and output

    static func installSIGINT(_ h: @escaping @convention(c) (Int32) -> Void) {
        var act = sigaction()
        #if canImport(Musl)
        act.__sa_handler.sa_handler = h
        #elseif os(Linux)
        act.__sigaction_handler.sa_handler = h
        #else
        act.__sigaction_u.__sa_handler = h
        #endif
        sigemptyset(&act.sa_mask)
        act.sa_flags = 0 // no SA_RESTART: blocking reads return EINTR so ^C is noticed
        sigaction(SIGINT, &act, nil)
    }

    static func sysWrite(_ fd: Int32, _ p: UnsafeRawPointer, _ n: Int) -> Int {
        cWrite(fd, p, n)
    }

    static func termSize(_ fd: Int32 = 1) -> (rows: Int, cols: Int)? {
        var w = winsize()
        #if os(Linux)
        let ok = ioctl(fd, UInt(TIOCGWINSZ), &w) == 0
        #else
        let ok = ioctl(fd, TIOCGWINSZ, &w) == 0
        #endif
        guard ok, w.ws_row > 0, w.ws_col > 0 else { return nil }
        return (Int(w.ws_row), Int(w.ws_col))
    }

    static func rename(_ a: String, _ b: String) -> Int32 {
        cRename(a, b)
    }

    // MARK: stat

    static func date(_ t: timespec) -> Date {
        Date(timeIntervalSince1970: Double(t.tv_sec) + Double(t.tv_nsec) / 1e9)
    }

    static func mtime(_ st: stat) -> Date {
        #if os(Linux)
        return date(st.st_mtim)
        #else
        return date(st.st_mtimespec)
        #endif
    }

    static func atime(_ st: stat) -> Date {
        #if os(Linux)
        return date(st.st_atim)
        #else
        return date(st.st_atimespec)
        #endif
    }

    /// macOS has a real "hidden" flag (the Finder's). Linux only has dotfiles.
    static func hiddenFlag(_ st: stat) -> Bool {
        #if os(Linux)
        return false
        #else
        return (st.st_flags & UInt32(UF_HIDDEN)) != 0
        #endif
    }

    /// false = no native flag here, keep it in our xattr instead
    static func setHiddenFlag(_ path: String, _ on: Bool) -> Bool {
        #if os(Linux)
        return false
        #else
        var st = stat()
        guard lstat(path, &st) == 0 else { return false }
        let f = on ? st.st_flags | UInt32(UF_HIDDEN) : st.st_flags & ~UInt32(UF_HIDDEN)
        return chflags(path, f) == 0
        #endif
    }

    // MARK: extended attributes

    static func xattrGet(_ path: String, _ name: String) -> String? {
        #if os(Linux)
        let n = getxattr(path, name, nil, 0)
        #else
        let n = getxattr(path, name, nil, 0, 0, 0)
        #endif
        guard n >= 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: n)
        #if os(Linux)
        let got = getxattr(path, name, &buf, n)
        #else
        let got = getxattr(path, name, &buf, n, 0, 0)
        #endif
        guard got == n else { return nil }
        return String(decoding: buf, as: UTF8.self)
    }

    static func xattrSet(_ path: String, _ name: String, _ value: String?) -> Bool {
        #if os(Linux)
        // unprivileged Linux processes may only touch the user. namespace
        let key = "user." + name
        guard let value else { return removexattr(path, key) == 0 || errno == ENODATA }
        let b = Array(value.utf8)
        return setxattr(path, key, b, b.count, 0) == 0
        #else
        guard let value else { return removexattr(path, name, 0) == 0 || errno == ENOATTR }
        let b = Array(value.utf8)
        return setxattr(path, name, b, b.count, 0, 0) == 0
        #endif
    }

    static func xattrName(_ name: String) -> String {
        #if os(Linux)
        return "user." + name
        #else
        return name
        #endif
    }

    // MARK: files

    /// Copy one file, contents, permissions, dates and xattrs. Overwrites the target.
    static func copyFile(_ src: String, _ dst: String) -> Bool {
        #if os(Linux)
        let fm = FileManager.default
        if fm.fileExists(atPath: dst) { unlink(dst) }
        do {
            try fm.copyItem(atPath: src, toPath: dst)
        } catch {
            return false
        }
        if let a = try? fm.attributesOfItem(atPath: src) {
            var keep: [FileAttributeKey: Any] = [:]
            keep[.modificationDate] = a[.modificationDate]
            keep[.posixPermissions] = a[.posixPermissions]
            try? fm.setAttributes(keep, ofItemAtPath: dst)
        }
        let n = listxattr(src, nil, 0)
        if n > 0 {
            var names = [CChar](repeating: 0, count: n)
            _ = listxattr(src, &names, n)
            for raw in names.split(separator: 0) {
                let key = String(decoding: raw.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                guard key.hasPrefix("user.") else { continue }
                let vn = getxattr(src, key, nil, 0)
                guard vn >= 0 else { continue }
                var v = [UInt8](repeating: 0, count: vn)
                _ = getxattr(src, key, &v, vn)
                _ = setxattr(dst, key, v, vn, 0)
            }
        }
        return true
        #else
        return copyfile(src, dst, nil, copyfile_flags_t(COPYFILE_ALL)) == 0
        #endif
    }

    /// The Trash (macOS) or the freedesktop.org trash can (Linux), so non-sandbox deletes can be undone.
    static func trash(_ u: URL) throws {
        #if os(Linux)
        let fm = FileManager.default
        let env = ProcessInfo.processInfo.environment
        let dataHome = env["XDG_DATA_HOME"] ?? ((env["HOME"] ?? NSHomeDirectory()) + "/.local/share")
        let files = URL(fileURLWithPath: dataHome + "/Trash/files")
        let info = URL(fileURLWithPath: dataHome + "/Trash/info")
        try fm.createDirectory(at: files, withIntermediateDirectories: true)
        try fm.createDirectory(at: info, withIntermediateDirectories: true)
        let base = u.lastPathComponent
        var name = base
        var i = 2
        while fm.fileExists(atPath: files.appendingPathComponent(name).path)
            || fm.fileExists(atPath: info.appendingPathComponent(name + ".trashinfo").path) {
            name = "\(base).\(i)"
            i += 1
        }
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        let path = u.standardizedFileURL.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? u.path
        let text = "[Trash Info]\nPath=\(path)\nDeletionDate=\(df.string(from: Date()))\n"
        try text.write(to: info.appendingPathComponent(name + ".trashinfo"), atomically: true, encoding: .utf8)
        do {
            try fm.moveItem(at: u, to: files.appendingPathComponent(name))
        } catch {
            try? fm.removeItem(at: info.appendingPathComponent(name + ".trashinfo"))
            throw error
        }
        #else
        try FileManager.default.trashItem(at: u, resultingItemURL: nil)
        #endif
    }

    static func freeBytes(_ path: String) -> Int64 {
        #if os(macOS)
        let u = URL(fileURLWithPath: path)
        if let v = try? u.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage { return v }
        #endif
        guard let d = diskStats(path) else { return 0 }
        return d.avail * d.unit
    }

    /// (allocation unit, total units, available units)
    static func diskStats(_ path: String) -> (unit: Int64, total: Int64, avail: Int64)? {
        var fs = statvfs()
        guard statvfs(path, &fs) == 0 else { return nil }
        let unit = Int64(fs.f_frsize > 0 ? fs.f_frsize : fs.f_bsize)
        return (unit, Int64(fs.f_blocks), Int64(fs.f_bavail))
    }

    // MARK: memory and launching

    /// (physical RAM, RAM that's free or easily reclaimed), in KB
    static func memoryK() -> (total: Int64, free: Int64) {
        let total = Int64(ProcessInfo.processInfo.physicalMemory) / 1024
        #if os(Linux)
        if let text = try? String(contentsOfFile: "/proc/meminfo", encoding: .utf8),
           let line = text.split(separator: "\n").first(where: { $0.hasPrefix("MemAvailable:") }),
           let kb = Int64(line.split(separator: " ").dropFirst().first ?? "") {
            return (total, kb)
        }
        return (total, total / 2)
        #else
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return (total, total / 2) }
        let page = Int64(vm_kernel_page_size) / 1024
        return (total, Int64(stats.free_count + stats.inactive_count) * page)
        #endif
    }

    /// What opens files, folders and URLs "the desktop way"
    static func opener(_ which: (String) -> String?) -> String? {
        #if os(Linux)
        return which("xdg-open")
        #else
        return "/usr/bin/open"
        #endif
    }
}
