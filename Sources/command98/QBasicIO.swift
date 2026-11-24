import Foundation

/// What a BASIC program can do to the outside world. The IDE paints cells; the plain
/// `/RUN` path writes lines. Keeping this a protocol is what lets the interpreter be
/// tested without a terminal.
protocol QBasicIO: AnyObject {
    /// Text output. "\n" starts a new line; the destination decides how to scroll.
    func write(_ s: String)
    func cls()
    /// 1-based row and column, like LOCATE.
    func locate(_ row: Int, _ col: Int)
    /// DOS colour numbers, 0...15.
    func color(_ fg: Int, _ bg: Int)
    /// Prints the prompt, then reads one line. nil = end of input / user pressed Esc.
    func input(_ prompt: String) -> String?
    func sleep(_ ms: Int)
    /// One key if one is waiting, without blocking. Used by INKEY$ and the IDE.
    func key() -> Key?
}
