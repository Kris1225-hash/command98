import Foundation

/// Feature 7 replaces this file. Called once on an interactive start, after CONFIG.SYS
/// and before AUTOEXEC.BAT, which is where the Win98 splash sits.
enum Boot {
    static func run(_ shell: Shell) {}
}
