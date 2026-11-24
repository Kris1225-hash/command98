import Foundation

/// The values IO.SYS would have handed to the system. Nothing here needs doing for real;
/// the numbers exist so MEM, DEVICE=ANSI.SYS and the diagnostics can notice them.
struct ConfigValues {
    var files = 30
    var buffers = 30
    var lastDrive: Character = "Z"
    var stacks = "9,256"
    var shellCommand: String? = nil
    var country: String? = nil
    var breakOn = false
    var devices: [String] = []
    var unknown: [String] = []
    var bootGui = false
}

/// Feature 6 replaces this file. Startup only needs the returned values.
enum ConfigSys {
    static func apply(_ shell: Shell) -> ConfigValues {
        ConfigValues()
    }
}
