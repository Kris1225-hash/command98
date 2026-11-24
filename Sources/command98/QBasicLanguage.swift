import Foundation

// MARK: - Source model

struct QBasicProblem: Error {
    let message: String
    let line: Int?

    init(_ message: String, line: Int? = nil) {
        self.message = message
        self.line = line
    }

    func atLine(_ n: Int) -> QBasicProblem {
        line == nil ? QBasicProblem(message, line: n) : self
    }

    var display: String {
        if let line { return "\(message) in line \(line)" }
        return message
    }
}

indirect enum QBasicExpression {
    case number(Double)
    case string(String)
    case variable(String)
    case array(String, [QBasicExpression])
    case function(String, [QBasicExpression])
    case unary(String, QBasicExpression)
    case binary(String, QBasicExpression, QBasicExpression)
}

struct QBasicLValue {
    let name: String
    let indices: [QBasicExpression]

    init(_ name: String, indices: [QBasicExpression] = []) {
        self.name = name
        self.indices = indices
    }
}

enum QBasicPrintItem {
    case expression(QBasicExpression)
    case tab(QBasicExpression)
    case semicolon
    case comma
}

struct QBasicArraySpec {
    let name: String
    let bounds: [QBasicExpression]
}

struct QBasicDataItem {
    let value: QBasicValue
    let line: Int
}

indirect enum QBasicStatementKind {
    case print([QBasicPrintItem])
    case assign(QBasicLValue, QBasicExpression)
    case input(prompt: String, line: Bool, variables: [QBasicLValue])
    case cls
    case color(QBasicExpression, QBasicExpression?)
    case locate(QBasicExpression, QBasicExpression)
    case sleep(QBasicExpression?)
    case end, stop
    case randomize(QBasicExpression?)
    case ifSingle(QBasicExpression, [QBasicStatement], [QBasicStatement])
    case ifBlock(QBasicExpression)
    case `else`, endIf
    case `for`(String, QBasicExpression, QBasicExpression, QBasicExpression?)
    case next(String?)
    case `while`(QBasicExpression)
    case wend
    case `do`(QBasicExpression?, Bool)
    case loop(QBasicExpression?, Bool)
    case goto(Int), gosub(Int), `return`
    case on(QBasicExpression, Bool, [Int])
    case dim([QBasicArraySpec])
    case swap(QBasicLValue, QBasicLValue)
    case data, read([QBasicLValue]), restore(Int?)
}

struct QBasicStatement {
    let line: Int
    let kind: QBasicStatementKind
    /// The matching NEXT, WEND, LOOP, or END IF. ELSE uses this for its END IF.
    var target = -1
    /// For a block IF, the matching ELSE, or -1.
    var alternate = -1
}

struct QBasicProgram {
    var statements: [QBasicStatement]
    let labels: [Int: Int]
    let data: [QBasicDataItem]
}

// MARK: - Tokens and expressions

enum QBasicToken: Equatable {
    case number(Double)
    case string(String)
    case identifier(String)
    case symbol(String)
    case end
}

enum QBasicLexer {
    static func tokens(_ source: String) throws -> [QBasicToken] {
        let chars = Array(source)
        var result: [QBasicToken] = []
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            if ch == " " || ch == "\t" || ch == "\r" || ch == "\n" {
                i += 1
                continue
            }
            if ch == "\"" {
                i += 1
                var value = ""
                var closed = false
                while i < chars.count {
                    if chars[i] == "\"" {
                        if i + 1 < chars.count, chars[i + 1] == "\"" {
                            value.append("\"")
                            i += 2
                        } else {
                            i += 1
                            closed = true
                            break
                        }
                    } else {
                        value.append(chars[i])
                        i += 1
                    }
                }
                guard closed else { throw QBasicProblem("Syntax error") }
                result.append(.string(value))
                continue
            }
            if ch.isNumber || (ch == "." && i + 1 < chars.count && chars[i + 1].isNumber) {
                let start = i
                var sawDot = false
                if ch == "." { sawDot = true }
                i += 1
                while i < chars.count, chars[i].isNumber { i += 1 }
                if !sawDot, i < chars.count, chars[i] == "." {
                    sawDot = true
                    i += 1
                    while i < chars.count, chars[i].isNumber { i += 1 }
                }
                if i < chars.count, chars[i] == "e" || i < chars.count, chars[i] == "E" {
                    var j = i + 1
                    if j < chars.count, chars[j] == "+" || j < chars.count, chars[j] == "-" { j += 1 }
                    let digits = j
                    while j < chars.count, chars[j].isNumber { j += 1 }
                    if j > digits { i = j }
                }
                let text = String(chars[start..<i])
                guard let n = Double(text), n.isFinite else { throw QBasicProblem("Syntax error") }
                result.append(.number(n))
                continue
            }
            if ch.isLetter || ch == "_" {
                let start = i
                i += 1
                while i < chars.count, chars[i].isLetter || chars[i].isNumber || chars[i] == "_" { i += 1 }
                if i < chars.count, "$%&!#".contains(chars[i]) { i += 1 }
                result.append(.identifier(String(chars[start..<i]).uppercased()))
                continue
            }
            if i + 1 < chars.count {
                let pair = String(chars[i...i + 1])
                if pair == "<=" || pair == ">=" || pair == "<>" {
                    result.append(.symbol(pair))
                    i += 2
                    continue
                }
            }
            result.append(.symbol(String(ch)))
            i += 1
        }
        result.append(.end)
        return result
    }
}

struct QBasicExpressionParser {
    private let tokens: [QBasicToken]
    private(set) var position = 0

    init(_ source: String) throws {
        tokens = try QBasicLexer.tokens(source)
    }

    static func expression(_ source: String) throws -> QBasicExpression {
        var parser = try QBasicExpressionParser(source)
        return try parser.parseComplete()
    }

    var isAtEnd: Bool { peek == .end }
    var peek: QBasicToken { tokens[position] }

    mutating func advance() {
        if position < tokens.count - 1 { position += 1 }
    }

    func check(_ symbol: String) -> Bool { peek == .symbol(symbol) }
    func checkIdentifier(_ name: String) -> Bool { peek == .identifier(name.uppercased()) }

    mutating func match(_ symbol: String) -> Bool {
        guard check(symbol) else { return false }
        advance()
        return true
    }

    mutating func matchIdentifier(_ name: String) -> Bool {
        guard checkIdentifier(name) else { return false }
        advance()
        return true
    }

    mutating func expect(_ symbol: String) throws {
        guard match(symbol) else { throw QBasicProblem("Syntax error") }
    }

    mutating func expectIdentifier(_ name: String) throws {
        guard matchIdentifier(name) else { throw QBasicProblem("Syntax error") }
    }

    mutating func identifier() throws -> String {
        guard case .identifier(let name) = peek else { throw QBasicProblem("Syntax error") }
        advance()
        return name
    }

    mutating func finish() throws {
        guard isAtEnd else { throw QBasicProblem("Syntax error") }
    }

    mutating func parseComplete() throws -> QBasicExpression {
        let value = try parseExpression()
        try finish()
        return value
    }

    mutating func parseLValue() throws -> QBasicLValue {
        let name = try identifier()
        var indices: [QBasicExpression] = []
        if match("(") {
            if !check(")") {
                repeat { indices.append(try parseExpression()) } while match(",")
            }
            try expect(")")
        }
        return QBasicLValue(name, indices: indices)
    }

    mutating func parseExpression() throws -> QBasicExpression { try parseOr() }

    private mutating func parseOr() throws -> QBasicExpression {
        var left = try parseAnd()
        while matchIdentifier("OR") {
            left = .binary("OR", left, try parseAnd())
        }
        return left
    }

    private mutating func parseAnd() throws -> QBasicExpression {
        var left = try parseNot()
        while matchIdentifier("AND") {
            left = .binary("AND", left, try parseNot())
        }
        return left
    }

    private mutating func parseNot() throws -> QBasicExpression {
        if matchIdentifier("NOT") { return .unary("NOT", try parseNot()) }
        return try parseComparison()
    }

    private mutating func parseComparison() throws -> QBasicExpression {
        var left = try parseAdditive()
        while let op = peekComparison() {
            advance()
            left = .binary(op, left, try parseAdditive())
        }
        return left
    }

    private func peekComparison() -> String? {
        guard case .symbol(let op) = peek else { return nil }
        return ["=", "<>", "<", ">", "<=", ">="].contains(op) ? op : nil
    }

    private mutating func parseAdditive() throws -> QBasicExpression {
        var left = try parseMultiplicative()
        while check("+") || check("-") {
            let op = check("+") ? "+" : "-"
            advance()
            left = .binary(op, left, try parseMultiplicative())
        }
        return left
    }

    private mutating func parseMultiplicative() throws -> QBasicExpression {
        var left = try parseUnary()
        while check("*") || check("/") || check("\\") || checkIdentifier("MOD") {
            let op: String
            if matchIdentifier("MOD") {
                op = "MOD"
            } else {
                guard case .symbol(let symbol) = peek else { throw QBasicProblem("Syntax error") }
                op = symbol
                advance()
            }
            left = .binary(op, left, try parseUnary())
        }
        return left
    }

    private mutating func parseUnary() throws -> QBasicExpression {
        if match("-") { return .unary("-", try parseUnary()) }
        if match("+") { return .unary("+", try parseUnary()) }
        return try parsePower()
    }

    private mutating func parsePower() throws -> QBasicExpression {
        let base = try parsePrimary()
        if match("^") { return .binary("^", base, try parseUnary()) }
        return base
    }

    private mutating func parsePrimary() throws -> QBasicExpression {
        switch peek {
        case .number(let n):
            advance()
            return .number(n)
        case .string(let s):
            advance()
            return .string(s)
        case .identifier(let name):
            advance()
            if match("(") {
                var args: [QBasicExpression] = []
                if !check(")") {
                    repeat { args.append(try parseExpression()) } while match(",")
                }
                try expect(")")
                if QBasicLanguage.functions.contains(name) {
                    return .function(name, args)
                }
                guard !args.isEmpty else { throw QBasicProblem("Syntax error") }
                return .array(name, args)
            }
            if name == "RND" || name == "INKEY$" { return .function(name, []) }
            return .variable(name)
        case .symbol("("):
            advance()
            let value = try parseExpression()
            try expect(")")
            return value
        default:
            throw QBasicProblem("Syntax error")
        }
    }
}

enum QBasicLanguage {
    static let functions: Set<String> = [
        "ABS", "ASC", "ATN", "CHR$", "COS", "EXP", "INT", "LEFT$", "LEN", "LOG",
        "LTRIM$", "MID$", "RIGHT$", "RND", "RTRIM$", "SGN", "SIN", "SQR", "STR$",
        "TAN", "VAL", "INKEY$", "SPACE$", "STRING$", "UCASE$", "LCASE$", "TAB",
    ]
}

// MARK: - Statement parser

struct QBasicSourceParser {
    private var statements: [QBasicStatement] = []
    private var labels: [Int: Int] = [:]
    private var data: [QBasicDataItem] = []

    static func parse(_ source: String) throws -> QBasicProgram {
        var parser = QBasicSourceParser()
        return try parser.parseSource(source)
    }

    private mutating func parseSource(_ source: String) throws -> QBasicProgram {
        let sourceLines = source.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        for (offset, raw) in sourceLines.enumerated() {
            let (label, text) = QBasicSourceParser.lineLabel(raw)
            do {
                let line = label ?? offset + 1
                if let label, labels[label] == nil { labels[label] = statements.count }
                try parsePhysicalLine(text, line: line)
            } catch let problem as QBasicProblem {
                throw problem.atLine(label ?? offset + 1)
            }
        }
        try resolveStructures()
        return QBasicProgram(statements: statements, labels: labels, data: data)
    }

    private static func lineLabel(_ raw: String) -> (Int?, String) {
        let text = raw.drop(while: { $0 == " " || $0 == "\t" })
        var end = text.startIndex
        while end < text.endIndex, text[end].isNumber { end = text.index(after: end) }
        guard end != text.startIndex, let n = Int(text[..<end]) else { return (nil, String(raw)) }
        return (n, String(text[end...]))
    }

    private mutating func parsePhysicalLine(_ raw: String, line: Int) throws {
        let text = QBasicSourceParser.stripComment(raw)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return }
        let head = QBasicSourceParser.head(text)
        if head == "IF", QBasicSourceParser.inlineIFTail(text) != nil {
            try appendStatement(text, line: line)
            return
        }
        let fragments = QBasicSourceParser.colonFragments(text)
        for fragment in fragments {
            let part = fragment.trimmingCharacters(in: .whitespacesAndNewlines)
            if part.isEmpty { continue }
            if QBasicSourceParser.isREM(part) { break }
            try appendStatement(part, line: line)
        }
    }

    private mutating func appendStatement(_ text: String, line: Int) throws {
        if QBasicSourceParser.isREM(text) { return }
        let upper = text.uppercased()
        let words = upper.split(whereSeparator: { $0 == " " || $0 == "\t" })
        if words.first == "DATA", let rest = QBasicSourceParser.remainder(text) {
            data.append(contentsOf: try QBasicSourceParser.parseData(rest, line: line))
            statements.append(QBasicStatement(line: line, kind: .data))
            return
        }
        let kind = try QBasicSourceParser.parseStatement(text)
        statements.append(QBasicStatement(line: line, kind: kind))
    }

    private mutating func resolveStructures() throws {
        var ifs: [Int] = []
        var fors: [(index: Int, variable: String)] = []
        var whiles: [Int] = []
        var dos: [Int] = []
        for i in statements.indices {
            let statement = statements[i]
            switch statement.kind {
            case .ifBlock:
                ifs.append(i)
            case .else:
                guard let open = ifs.last, statements[open].alternate < 0 else {
                    throw QBasicProblem("ELSE without IF", line: statement.line)
                }
                statements[open].alternate = i
            case .endIf:
                guard let open = ifs.popLast() else {
                    throw QBasicProblem("END IF without IF", line: statement.line)
                }
                statements[open].target = i
                if statements[open].alternate >= 0 {
                    statements[statements[open].alternate].target = i
                }
            case .for(let variable, _, _, _):
                fors.append((i, variable))
            case .next(let variable):
                guard let open = fors.last, variable == nil || variable == open.variable else {
                    throw QBasicProblem("NEXT without FOR", line: statement.line)
                }
                statements[open.index].target = i
                fors.removeLast()
            case .while:
                whiles.append(i)
            case .wend:
                guard let open = whiles.popLast() else {
                    throw QBasicProblem("WEND without WHILE", line: statement.line)
                }
                statements[open].target = i
                statements[i].target = open
            case .do:
                dos.append(i)
            case .loop:
                guard let open = dos.popLast() else {
                    throw QBasicProblem("LOOP without DO", line: statement.line)
                }
                statements[open].target = i
                statements[i].target = open
            default:
                break
            }
        }
        if let open = ifs.last { throw QBasicProblem("IF without END IF", line: statements[open].line) }
        if let open = fors.last { throw QBasicProblem("FOR without NEXT", line: statements[open.index].line) }
        if let open = whiles.last { throw QBasicProblem("WHILE without WEND", line: statements[open].line) }
        if let open = dos.last { throw QBasicProblem("DO without LOOP", line: statements[open].line) }
    }

    private static func parseStatement(_ original: String) throws -> QBasicStatementKind {
        let text = original.trimmingCharacters(in: .whitespacesAndNewlines)
        if text == "?" || text.hasPrefix("?") { return try parsePrint(String(text.dropFirst())) }
        let head = head(text)
        let rest = remainder(text) ?? ""
        let normalized = text.uppercased().split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
        switch head {
        case "PRINT": return try parsePrint(rest)
        case "LET":
            var parser = try QBasicExpressionParser(rest)
            let target = try parser.parseLValue()
            try parser.expect("=")
            let value = try parser.parseExpression()
            try parser.finish()
            return .assign(target, value)
        case "INPUT": return try parseInput(rest, line: false)
        case "LINE":
            var p = try QBasicExpressionParser(rest)
            try p.expectIdentifier("INPUT")
            // Reparse after the two words so prompts retain their original spelling.
            var r = rest.trimmingCharacters(in: .whitespaces)
            r = String(r.dropFirst(5))
            return try parseInput(r, line: true)
        case "CLS":
            try requireEmpty(rest)
            return .cls
        case "COLOR":
            var parser = try QBasicExpressionParser(rest)
            let fg = try parser.parseExpression()
            var bg: QBasicExpression? = nil
            if parser.match(",") { bg = try parser.parseExpression() }
            try parser.finish()
            return .color(fg, bg)
        case "LOCATE":
            var parser = try QBasicExpressionParser(rest)
            let row = try parser.parseExpression()
            try parser.expect(",")
            let col = try parser.parseExpression()
            try parser.finish()
            return .locate(row, col)
        case "SLEEP":
            if rest.trimmingCharacters(in: .whitespaces).isEmpty { return .sleep(nil) }
            return .sleep(try QBasicExpressionParser.expression(rest))
        case "END":
            if normalized == "END IF" { return .endIf }
            try requireEmpty(rest)
            return .end
        case "STOP":
            try requireEmpty(rest)
            return .stop
        case "RANDOMIZE":
            if rest.trimmingCharacters(in: .whitespaces).isEmpty { return .randomize(nil) }
            return .randomize(try QBasicExpressionParser.expression(rest))
        case "IF": return try parseIF(rest)
        case "ELSE":
            try requireEmpty(rest)
            return .else
        case "FOR": return try parseFOR(rest)
        case "NEXT":
            if rest.trimmingCharacters(in: .whitespaces).isEmpty { return .next(nil) }
            var parser = try QBasicExpressionParser(rest)
            let name = try parser.identifier()
            try parser.finish()
            return .next(name)
        case "WHILE": return .while(try QBasicExpressionParser.expression(rest))
        case "WEND":
            try requireEmpty(rest)
            return .wend
        case "DO": return try parseLoopCondition(rest, isDO: true)
        case "LOOP": return try parseLoopCondition(rest, isDO: false)
        case "GOTO": return .goto(try parseLineNumber(rest))
        case "GOSUB": return .gosub(try parseLineNumber(rest))
        case "RETURN":
            try requireEmpty(rest)
            return .return
        case "ON": return try parseON(rest)
        case "DIM": return try parseDIM(rest)
        case "SWAP":
            var parser = try QBasicExpressionParser(rest)
            let a = try parser.parseLValue()
            try parser.expect(",")
            let b = try parser.parseLValue()
            try parser.finish()
            return .swap(a, b)
        case "READ":
            var parser = try QBasicExpressionParser(rest)
            var variables: [QBasicLValue] = []
            repeat { variables.append(try parser.parseLValue()) } while parser.match(",")
            try parser.finish()
            return .read(variables)
        case "RESTORE":
            if rest.trimmingCharacters(in: .whitespaces).isEmpty { return .restore(nil) }
            return .restore(try parseLineNumber(rest))
        default:
            // LET is optional. Anything else that is not shaped like an assignment is an error.
            var parser = try QBasicExpressionParser(text)
            let target = try parser.parseLValue()
            try parser.expect("=")
            let value = try parser.parseExpression()
            try parser.finish()
            return .assign(target, value)
        }
    }

    private static func parsePrint(_ rest: String) throws -> QBasicStatementKind {
        var parser = try QBasicExpressionParser(rest)
        var items: [QBasicPrintItem] = []
        while !parser.isAtEnd {
            if parser.match(";") {
                items.append(.semicolon)
            } else if parser.match(",") {
                items.append(.comma)
            } else {
                let expression = try parser.parseExpression()
                if case .function("TAB", let args) = expression {
                    guard args.count == 1 else { throw QBasicProblem("Syntax error") }
                    items.append(.tab(args[0]))
                } else {
                    items.append(.expression(expression))
                }
                if !parser.isAtEnd, !parser.check(";"), !parser.check(",") {
                    throw QBasicProblem("Syntax error")
                }
            }
        }
        return .print(items)
    }

    private static func parseInput(_ rest: String, line: Bool) throws -> QBasicStatementKind {
        var parser = try QBasicExpressionParser(rest)
        var prompt = "? "
        if case .string(let text) = parser.peek {
            prompt = text
            parser.advance()
            if parser.match(",") { prompt += "? " }
            else if !parser.match(";") { throw QBasicProblem("Syntax error") }
        }
        var variables: [QBasicLValue] = []
        repeat { variables.append(try parser.parseLValue()) } while parser.match(",")
        try parser.finish()
        guard !variables.isEmpty, !line || variables.count == 1 else { throw QBasicProblem("Syntax error") }
        return .input(prompt: prompt, line: line, variables: variables)
    }

    private static func parseIF(_ rest: String) throws -> QBasicStatementKind {
        let chars = Array(rest)
        guard let thenRange = keywordRange("THEN", in: chars) else { throw QBasicProblem("Syntax error") }
        let conditionText = String(chars[..<thenRange.lowerBound])
        let tail = String(chars[thenRange.upperBound...]).trimmingCharacters(in: .whitespaces)
        let condition = try QBasicExpressionParser.expression(conditionText)
        if tail.isEmpty { return .ifBlock(condition) }
        if let line = Int(tail) { return .ifSingle(condition, [QBasicStatement(line: 0, kind: .goto(line))], []) }
        var thenText = tail
        var elseText = ""
        if let elseRange = keywordRange("ELSE", in: Array(tail)) {
            thenText = String(Array(tail)[..<elseRange.lowerBound])
            elseText = String(Array(tail)[elseRange.upperBound...])
        }
        let thenStatements = try parseInline(thenText)
        let elseStatements = elseText.isEmpty ? [] : try parseInline(elseText)
        return .ifSingle(condition, thenStatements, elseStatements)
    }

    private static func parseInline(_ text: String) throws -> [QBasicStatement] {
        var result: [QBasicStatement] = []
        for fragment in colonFragments(stripComment(text)) {
            let part = fragment.trimmingCharacters(in: .whitespaces)
            if part.isEmpty { continue }
            if isREM(part) { break }
            let kind = try parseStatement(part)
            switch kind {
            case .ifBlock, .else, .endIf, .for, .next, .while, .wend, .do, .loop:
                throw QBasicProblem("Syntax error")
            default:
                result.append(QBasicStatement(line: 0, kind: kind))
            }
        }
        guard !result.isEmpty else { throw QBasicProblem("Syntax error") }
        return result
    }

    private static func parseFOR(_ rest: String) throws -> QBasicStatementKind {
        var parser = try QBasicExpressionParser(rest)
        let variable = try parser.identifier()
        try parser.expect("=")
        let start = try parser.parseExpression()
        try parser.expectIdentifier("TO")
        let end = try parser.parseExpression()
        var step: QBasicExpression? = nil
        if parser.matchIdentifier("STEP") { step = try parser.parseExpression() }
        try parser.finish()
        return .for(variable, start, end, step)
    }

    private static func parseLoopCondition(_ rest: String, isDO: Bool) throws -> QBasicStatementKind {
        let trimmed = rest.trimmingCharacters(in: .whitespaces)
        var condition: QBasicExpression? = nil
        var until = false
        if !trimmed.isEmpty {
            let h = head(trimmed)
            guard h == "WHILE" || h == "UNTIL" else { throw QBasicProblem("Syntax error") }
            until = h == "UNTIL"
            condition = try QBasicExpressionParser.expression(remainder(trimmed) ?? "")
        }
        return isDO ? .do(condition, until) : .loop(condition, until)
    }

    private static func parseON(_ rest: String) throws -> QBasicStatementKind {
        var parser = try QBasicExpressionParser(rest)
        let expression = try parser.parseExpression()
        let gosub: Bool
        if parser.matchIdentifier("GOSUB") { gosub = true }
        else if parser.matchIdentifier("GOTO") { gosub = false }
        else { throw QBasicProblem("Syntax error") }
        var targets: [Int] = []
        repeat {
            guard case .number(let n) = parser.peek, n >= 0, n == n.rounded(), n < Double(Int.max) else {
                throw QBasicProblem("Syntax error")
            }
            targets.append(Int(n))
            parser.advance()
        } while parser.match(",")
        try parser.finish()
        return .on(expression, gosub, targets)
    }

    private static func parseDIM(_ rest: String) throws -> QBasicStatementKind {
        var parser = try QBasicExpressionParser(rest)
        var specs: [QBasicArraySpec] = []
        repeat {
            let value = try parser.parseLValue()
            guard !value.indices.isEmpty, value.indices.count <= 2 else { throw QBasicProblem("Syntax error") }
            specs.append(QBasicArraySpec(name: value.name, bounds: value.indices))
        } while parser.match(",")
        try parser.finish()
        return .dim(specs)
    }

    private static func parseLineNumber(_ text: String) throws -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let n = Int(trimmed), n >= 0 else { throw QBasicProblem("Syntax error") }
        return n
    }

    private static func parseData(_ rest: String, line: Int) throws -> [QBasicDataItem] {
        var result: [QBasicDataItem] = []
        for raw in commaFragments(rest) {
            let text = raw.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("\"") {
                var parser = try QBasicExpressionParser(text)
                let value = try parser.parseComplete()
                guard case .string(let s) = value else { throw QBasicProblem("Syntax error") }
                result.append(QBasicDataItem(value: .string(s), line: line))
            } else if let n = Double(text), n.isFinite {
                result.append(QBasicDataItem(value: .number(n), line: line))
            } else {
                result.append(QBasicDataItem(value: .string(text), line: line))
            }
        }
        return result
    }

    private static func requireEmpty(_ rest: String) throws {
        guard rest.trimmingCharacters(in: .whitespaces).isEmpty else { throw QBasicProblem("Syntax error") }
    }

    private static func head(_ text: String) -> String {
        let trimmed = text.drop(while: { $0 == " " || $0 == "\t" })
        var end = trimmed.startIndex
        while end < trimmed.endIndex, trimmed[end].isLetter { end = trimmed.index(after: end) }
        return String(trimmed[..<end]).uppercased()
    }

    private static func remainder(_ text: String) -> String? {
        let trimmed = text.drop(while: { $0 == " " || $0 == "\t" })
        var end = trimmed.startIndex
        while end < trimmed.endIndex, trimmed[end].isLetter { end = trimmed.index(after: end) }
        guard end > trimmed.startIndex else { return nil }
        return String(trimmed[end...]).trimmingCharacters(in: .whitespaces)
    }

    private static func isREM(_ text: String) -> Bool {
        head(text) == "REM" && {
            let trimmed = text.drop(while: { $0 == " " || $0 == "\t" })
            return trimmed.count == 3 || trimmed.dropFirst(3).first == " " || trimmed.dropFirst(3).first == "\t"
        }()
    }

    private static func inlineIFTail(_ text: String) -> String? {
        let rest = remainder(text) ?? ""
        let chars = Array(rest)
        guard let range = keywordRange("THEN", in: chars) else { return nil }
        let tail = String(chars[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        return tail.isEmpty ? nil : tail
    }

    private static func stripComment(_ text: String) -> String {
        let chars = Array(text)
        var quoted = false
        var i = 0
        while i < chars.count {
            if chars[i] == "\"" {
                if quoted, i + 1 < chars.count, chars[i + 1] == "\"" { i += 2; continue }
                quoted.toggle()
            } else if chars[i] == "'", !quoted {
                return String(chars[..<i])
            }
            i += 1
        }
        return text
    }

    private static func colonFragments(_ text: String) -> [String] {
        let chars = Array(text)
        var result: [String] = []
        var start = 0
        var quoted = false
        var i = 0
        while i < chars.count {
            if chars[i] == "\"" {
                if quoted, i + 1 < chars.count, chars[i + 1] == "\"" { i += 2; continue }
                quoted.toggle()
            } else if chars[i] == ":", !quoted {
                result.append(String(chars[start..<i]))
                start = i + 1
            }
            i += 1
        }
        result.append(String(chars[start...]))
        return result
    }

    private static func commaFragments(_ text: String) -> [String] {
        let chars = Array(text)
        var result: [String] = []
        var start = 0
        var quoted = false
        var depth = 0
        var i = 0
        while i < chars.count {
            if chars[i] == "\"" {
                if quoted, i + 1 < chars.count, chars[i + 1] == "\"" { i += 2; continue }
                quoted.toggle()
            } else if !quoted {
                if chars[i] == "(" { depth += 1 }
                if chars[i] == ")" { depth -= 1 }
                if chars[i] == ",", depth == 0 {
                    result.append(String(chars[start..<i]))
                    start = i + 1
                }
            }
            i += 1
        }
        result.append(String(chars[start...]))
        return result
    }

    private static func keywordRange(_ keyword: String, in chars: [Character]) -> Range<Int>? {
        let key = Array(keyword)
        var quoted = false
        var depth = 0
        var i = 0
        while i < chars.count {
            if chars[i] == "\"" {
                if quoted, i + 1 < chars.count, chars[i + 1] == "\"" { i += 2; continue }
                quoted.toggle()
                i += 1
                continue
            }
            if !quoted {
                if chars[i] == "(" { depth += 1 }
                if chars[i] == ")" { depth -= 1 }
                if depth == 0, i + key.count <= chars.count {
                    var matches = true
                    for j in key.indices {
                        if Character(chars[i + j].uppercased()) != key[j] { matches = false; break }
                    }
                    if matches {
                        let beforeOK = i == 0 || !(chars[i - 1].isLetter || chars[i - 1].isNumber || chars[i - 1] == "_" || chars[i - 1] == "$")
                        let after = i + key.count
                        let afterOK = after == chars.count || !(chars[after].isLetter || chars[after].isNumber || chars[after] == "_" || chars[after] == "$")
                        if beforeOK && afterOK { return i..<after }
                    }
                }
            }
            i += 1
        }
        return nil
    }
}
