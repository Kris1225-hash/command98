import Foundation

/// What every platform can tell us about a file, already translated into DOS attribute terms.
struct FileInfo {
    let isDir: Bool
    let isLink: Bool
    let isRegular: Bool
    let size: Int64
    let mtime: Date
    let atime: Date
    let readOnly: Bool
    let hidden: Bool
    let system: Bool
    let archive: Bool
}
