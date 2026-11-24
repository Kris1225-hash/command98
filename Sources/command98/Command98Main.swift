import Foundation

/// Program entry point, kept in the library target so the test target can link the module.
/// The thin executable target in Sources/command98CLI calls this.
public func command98Main() {
installSignalHandlers()

let fm = FileManager.default
let home = ProcessInfo.processInfo.environment["HOME"] ?? fm.homeDirectoryForCurrentUser.path
func expandTilde(_ p: String) -> String { p.hasPrefix("~") ? home + p.dropFirst() : p }

func usage() {
    Console.tty.write("""
    command98 - a native re-creation of the Windows 98 SE command interpreter

    command98 [/C command | /K command] [/P] [/Y] [--real | --sandbox] [--mount X=path ...]

      /C command   Run the command, then exit (errorlevel becomes the exit code).
      /K command   Run the command, then stay.
      /P           Permanent: EXIT does nothing.
      /Y           Step through batch files line by line.
      --real       every real drive letter is itself. The sandbox moves to the first free letter.
      --sandbox    C:\\ is the sandbox folder (the default).
      --mount X=p  Mount a folder as drive X:.

    Config lives in %USERPROFILE%\\.command98.ini.

    """)
}

// MARK: config

let cfgPath = home + "/.command98.ini"
if !fm.fileExists(atPath: cfgPath) {
    let defaultConfig = """
    ; command98 drive map. one drive per line: LETTER=path
    ; C: is a sandbox folder unless REAL=yes, which mounts every real drive letter
    ; and moves the sandbox to the first free letter.
    ; DEL on the sandbox deletes for real. on every other drive it goes to the Recycle Bin.
    C=~/DOSROOT
    ; D=~/Downloads
    REAL=no

    """
    try? defaultConfig.write(toFile: cfgPath, atomically: true, encoding: .utf8)
}

var cfgDrives: [Character: String] = [:]
var real = false
if let text = try? String(contentsOfFile: cfgPath, encoding: .utf8) {
    for raw in text.split(whereSeparator: \.isNewline) {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.isEmpty || line.hasPrefix(";") || line.hasPrefix("#") || line.hasPrefix("[") { continue }
        guard let eq = line.firstIndex(of: "=") else { continue }
        let key = line[..<eq].trimmingCharacters(in: .whitespaces).uppercased()
        let val = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        if key.count == 1, let ch = key.first, ch.isLetter {
            cfgDrives[ch] = val
        } else if key == "REAL" {
            real = ["YES", "TRUE", "ON", "1"].contains(val.uppercased())
        }
    }
}

// MARK: arguments

let argv = Array(CommandLine.arguments.dropFirst())
var runC: String? = nil
var runK: String? = nil
var permanent = false
var step = false
var extraMounts: [(Character, String)] = []
var i = 0
while i < argv.count {
    let a = argv[i]
    let up = a.uppercased()
    if up == "/C" || up == "/K" {
        let cmd = argv[(i + 1)...].joined(separator: " ")
        if up == "/C" { runC = cmd } else { runK = cmd }
        break
    } else if (up.hasPrefix("/C") || up.hasPrefix("/K")) && up.count > 2 && !up.hasPrefix("/K:") {
        let cmd = ([String(a.dropFirst(2))] + argv[(i + 1)...]).joined(separator: " ")
        if up.hasPrefix("/C") { runC = cmd } else { runK = cmd }
        break
    } else if up == "/P" {
        permanent = true
    } else if up == "/Y" {
        step = true
    } else if a == "--real" {
        real = true
    } else if a == "--sandbox" {
        real = false
    } else if a == "--mount", i + 1 < argv.count {
        let spec = argv[i + 1]
        if let eq = spec.firstIndex(of: "="), let ch = spec.first, ch.isLetter {
            extraMounts.append((Character(ch.uppercased()), String(spec[spec.index(after: eq)...])))
        }
        i += 1
    } else if a == "--help" || a == "-h" || up == "/?" {
        usage()
        exit(0)
    }
    // /E:nnnn, /L:nnnn, /U:nnn, /LOW, /MSG: nothing to do on a machine with gigabytes of RAM
    i += 1
}

// MARK: drives

let drives = Drives()
let sandboxRoot = expandTilde(cfgDrives["C"] ?? "~/DOSROOT")
let freshSandbox = !fm.fileExists(atPath: sandboxRoot)
try? fm.createDirectory(atPath: sandboxRoot, withIntermediateDirectories: true)
if freshSandbox {
    let autoexec = "@ECHO OFF\r\nREM command98 runs this at startup. edit away.\r\nPROMPT $P$G\r\n"
    try? autoexec.write(toFile: sandboxRoot + "/AUTOEXEC.BAT", atomically: true, encoding: .utf8)
}

if real {
    #if os(Windows)
    // on Windows the real drive letters are already DOS drive letters. how convenient.
    for l in Platform.logicalDrives() { drives.mount(l, "\(l):\\", sandbox: false) }
    let sandboxLetter = Array("STUVWXYZRQPONMLKJIHGFED").first { drives.table[$0] == nil && cfgDrives[$0] == nil } ?? "S"
    drives.mount(sandboxLetter, sandboxRoot, sandbox: true)
    #else
    drives.mount("C", "/", sandbox: false)
    if cfgDrives["S"] == nil { drives.mount("S", sandboxRoot, sandbox: true) }
    #endif
} else {
    drives.mount("C", sandboxRoot, sandbox: true)
}
for (l, p) in cfgDrives where l != "C" {
    let path = expandTilde(p)
    if fm.fileExists(atPath: path) { drives.mount(l, path, sandbox: false) }
}
for (l, p) in extraMounts {
    let path = expandTilde(p)
    if fm.fileExists(atPath: path) { drives.mount(l, path, sandbox: false) }
}

// in real mode, start where the host shell was
if real, let (l, comps) = drives.hostToDos(URL(fileURLWithPath: fm.currentDirectoryPath).resolvingSymlinksInPath().path) {
    drives.current = l
    drives.table[l]!.cwd = comps
}

// MARK: go

Shell.installStubs(root: URL(fileURLWithPath: sandboxRoot))

let shell = Shell(drives: drives)
shell.permanent = permanent
shell.stepMode = step
shell.config = ConfigSys.apply(shell)

// the Win98 defaults: C:\WINDOWS and C:\WINDOWS\COMMAND first in PATH, COMSPEC at the root
if let (sl, _) = drives.hostToDos(URL(fileURLWithPath: sandboxRoot).resolvingSymlinksInPath().path) {
    let hostDirs = shell.envGet("PATH") ?? ""
    shell.envSet("PATH", "\(sl):\\WINDOWS;\(sl):\\WINDOWS\\COMMAND" + (hostDirs.isEmpty ? "" : ";" + hostDirs))
    shell.envSet("COMSPEC", "\(sl):\\COMMAND.COM")
    shell.envSet("WINDIR", "\(sl):\\WINDOWS")
}

// the boot splash belongs to an interactive start, not to /C
if runC == nil {
    Boot.run(shell)
}

if let c = runC {
    shell.runLine(c)
    exit(shell.errorLevel)
}

if Console.isTTY {
    Console.tty.write("\n\(Platform.product) \(Platform.arch) [Version \(Shell.version)]\n")
    Console.tty.write("   a from-scratch tribute to the Windows 98 SE command interpreter\n\n")
}

let autoexecPath = drives.url("C", []).appendingPathComponent("AUTOEXEC.BAT").path
if runK == nil, fm.fileExists(atPath: autoexecPath) {
    shell.runLine("C:\\AUTOEXEC.BAT")
}
if let k = runK { shell.runLine(k) }

shell.interactive()
exit(shell.errorLevel)

}
