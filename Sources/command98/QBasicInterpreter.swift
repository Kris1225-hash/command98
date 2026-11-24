import Foundation

enum QBasicValue {
    case number(Double)
    case string(String)

    var isString: Bool {
        if case .string = self { return true }
        return false
    }
}

final class QBasicArray {
    let bounds: [Int]
    var values: [QBasicValue]

    init(name: String, bounds: [Int]) throws {
        guard bounds.count == 1 || bounds.count == 2 else { throw QBasicProblem("Subscript out of range") }
        var count = 1
        for bound in bounds {
            guard bound >= 0, bound <= 65_535 else { throw QBasicProblem("Subscript out of range") }
            let dimension = bound + 1
            guard count <= 1_000_000 / dimension else { throw QBasicProblem("Out of memory") }
            count *= dimension
        }
        self.bounds = bounds
        values = Array(repeating: name.hasSuffix("$") ? .string("") : .number(0), count: count)
    }

    func offset(_ indices: [Int]) throws -> Int {
        guard indices.count == bounds.count else { throw QBasicProblem("Subscript out of range") }
        for (index, bound) in zip(indices, bounds) where index < 0 || index > bound {
            throw QBasicProblem("Subscript out of range")
        }
        if bounds.count == 1 { return indices[0] }
        return indices[0] * (bounds[1] + 1) + indices[1]
    }
}

private enum QBasicFlow {
    case next
    case jump(Int)
    case stop
}

private struct QBasicForFrame {
    let variable: String
    let end: Double
    let step: Double
    let body: Int
}

final class QBasicInterpreter {
    private let program: QBasicProgram
    private let io: QBasicIO
    private var variables: [String: QBasicValue] = [:]
    private var arrays: [String: QBasicArray] = [:]
    private var gosubs: [Int] = []
    private var forFrames: [QBasicForFrame] = []
    private var dataPosition = 0
    private var randomState: UInt32 = 1
    private var lastRandom = 0.0
    private var outputColumn = 0

    init(program: QBasicProgram, io: QBasicIO) {
        self.program = program
        self.io = io
    }

    func execute() throws {
        var pc = 0
        while pc >= 0 && pc < program.statements.count {
            let statement = program.statements[pc]
            do {
                switch try execute(statement, pc: pc, next: pc + 1) {
                case .next: pc += 1
                case .jump(let destination): pc = destination
                case .stop: return
                }
            } catch let problem as QBasicProblem {
                throw problem.atLine(statement.line)
            }
        }
    }

    private func execute(_ statement: QBasicStatement, pc: Int, next: Int) throws -> QBasicFlow {
        switch statement.kind {
        case .print(let items):
            try printItems(items)
        case .assign(let target, let expression):
            try set(target, try evaluate(expression))
        case .input(let prompt, let line, let targets):
            try readInput(prompt: prompt, wholeLine: line, targets: targets)
        case .cls:
            io.cls()
            outputColumn = 0
        case .color(let foreground, let background):
            let fg = try integer(try number(try evaluate(foreground)))
            let bg = background == nil ? 0 : try integer(try number(try evaluate(background!)))
            guard (0...15).contains(fg), (0...15).contains(bg) else { throw QBasicProblem("Illegal function call") }
            io.color(fg, bg)
        case .locate(let rowExpression, let columnExpression):
            let row = try integer(try number(try evaluate(rowExpression)))
            let column = try integer(try number(try evaluate(columnExpression)))
            guard (1...25).contains(row), (1...80).contains(column) else { throw QBasicProblem("Illegal function call") }
            io.locate(row, column)
            outputColumn = column - 1
        case .sleep(let expression):
            var milliseconds = 0
            if let expression {
                let seconds = try number(try evaluate(expression))
                guard seconds.isFinite, seconds >= 0, seconds <= 86_400 else { throw QBasicProblem("Illegal function call") }
                milliseconds = Int((seconds * 1000).rounded())
            }
            io.sleep(milliseconds)
        case .end, .stop:
            return .stop
        case .randomize(let expression):
            if let expression {
                let seed = try number(try evaluate(expression))
                guard seed.isFinite, abs(seed) <= Double(UInt32.max) else { throw QBasicProblem("Illegal function call") }
                randomState = UInt32(truncatingIfNeeded: Int64(seed))
            } else {
                randomState = UInt32(truncatingIfNeeded: Int64(Date().timeIntervalSince1970 * 1000))
            }
            _ = nextRandom()
        case .ifSingle(let condition, let yes, let no):
            if try truth(try evaluate(condition)) {
                if let flow = try executeInline(yes, pc: pc, next: next) { return flow }
            } else {
                if let flow = try executeInline(no, pc: pc, next: next) { return flow }
            }
        case .ifBlock(let condition):
            if try !truth(try evaluate(condition)) {
                return .jump(statement.alternate >= 0 ? statement.alternate + 1 : statement.target + 1)
            }
        case .else:
            return .jump(statement.target + 1)
        case .endIf:
            break
        case .for(let variable, let startExpression, let endExpression, let stepExpression):
            let start = try number(try evaluate(startExpression))
            let end = try number(try evaluate(endExpression))
            let step = stepExpression == nil ? 1 : try number(try evaluate(stepExpression!))
            guard start.isFinite, end.isFinite, step.isFinite else { throw QBasicProblem("Illegal function call") }
            try set(QBasicLValue(variable), .number(start))
            if !forContinues(start, end: end, step: step) {
                return .jump(statement.target + 1)
            }
            forFrames.append(QBasicForFrame(variable: variable, end: end, step: step, body: pc + 1))
        case .next(let variable):
            guard let frame = forFrames.last, variable == nil || variable == frame.variable else {
                throw QBasicProblem("NEXT without FOR")
            }
            let old = try number(try get(QBasicLValue(frame.variable)))
            let value = old + frame.step
            try set(QBasicLValue(frame.variable), .number(value))
            if forContinues(value, end: frame.end, step: frame.step) {
                return .jump(frame.body)
            }
            forFrames.removeLast()
        case .while(let condition):
            if try !truth(try evaluate(condition)) { return .jump(statement.target + 1) }
        case .wend:
            return .jump(statement.target)
        case .do(let condition, let until):
            if let condition {
                let value = try truth(try evaluate(condition))
                if until ? value : !value { return .jump(statement.target + 1) }
            }
        case .loop(let condition, let until):
            var again = true
            if let condition {
                let value = try truth(try evaluate(condition))
                again = until ? !value : value
            }
            if again { return .jump(statement.target) }
        case .goto(let line):
            return .jump(try destination(line))
        case .gosub(let line):
            gosubs.append(next)
            return .jump(try destination(line))
        case .return:
            guard let returning = gosubs.popLast() else { throw QBasicProblem("RETURN without GOSUB") }
            return .jump(returning)
        case .on(let expression, let isGosub, let targets):
            let selected = try integer(try number(try evaluate(expression)))
            guard selected > 0, selected <= targets.count else { break }
            if isGosub { gosubs.append(next) }
            return .jump(try destination(targets[selected - 1]))
        case .dim(let specs):
            for spec in specs {
                var bounds: [Int] = []
                for expression in spec.bounds { bounds.append(try integer(try number(try evaluate(expression)))) }
                guard arrays[spec.name] == nil else { throw QBasicProblem("Duplicate definition") }
                arrays[spec.name] = try QBasicArray(name: spec.name, bounds: bounds)
            }
        case .swap(let a, let b):
            let left = try resolve(a)
            let right = try resolve(b)
            let av = try read(left)
            let bv = try read(right)
            guard av.isString == bv.isString else { throw QBasicProblem("Type mismatch") }
            try write(left, bv)
            try write(right, av)
        case .data:
            break
        case .read(let targets):
            for target in targets {
                guard dataPosition < program.data.count else { throw QBasicProblem("Out of DATA") }
                let value = program.data[dataPosition].value
                dataPosition += 1
                try set(target, value)
            }
        case .restore(let line):
            if let line {
                guard program.labels[line] != nil else { throw QBasicProblem("Undefined line number") }
                dataPosition = program.data.firstIndex(where: { $0.line >= line }) ?? program.data.count
            } else {
                dataPosition = 0
            }
        }
        return .next
    }

    private func executeInline(_ statements: [QBasicStatement], pc: Int, next: Int) throws -> QBasicFlow? {
        for statement in statements {
            let flow = try execute(statement, pc: pc, next: next)
            switch flow {
            case .next: continue
            default: return flow
            }
        }
        return nil
    }

    private func destination(_ line: Int) throws -> Int {
        guard let destination = program.labels[line] else { throw QBasicProblem("Undefined line number") }
        return destination
    }

    private func forContinues(_ value: Double, end: Double, step: Double) -> Bool {
        step >= 0 ? value <= end : value >= end
    }

    // MARK: Variables and arrays

    private enum Reference {
        case variable(String)
        case element(String, Int)
    }

    private func resolve(_ target: QBasicLValue) throws -> Reference {
        guard !target.name.isEmpty else { throw QBasicProblem("Syntax error") }
        if target.indices.isEmpty { return .variable(target.name) }
        guard target.indices.count <= 2 else { throw QBasicProblem("Subscript out of range") }
        var indices: [Int] = []
        for expression in target.indices { indices.append(try integer(try number(try evaluate(expression)))) }
        if arrays[target.name] == nil {
            arrays[target.name] = try QBasicArray(name: target.name, bounds: Array(repeating: 10, count: indices.count))
        }
        guard let array = arrays[target.name] else { throw QBasicProblem("Subscript out of range") }
        return .element(target.name, try array.offset(indices))
    }

    private func read(_ reference: Reference) throws -> QBasicValue {
        switch reference {
        case .variable(let name):
            return variables[name] ?? (name.hasSuffix("$") ? .string("") : .number(0))
        case .element(let name, let offset):
            guard let array = arrays[name], array.values.indices.contains(offset) else {
                throw QBasicProblem("Subscript out of range")
            }
            return array.values[offset]
        }
    }

    private func write(_ reference: Reference, _ value: QBasicValue) throws {
        switch reference {
        case .variable(let name):
            guard name.hasSuffix("$") == value.isString else { throw QBasicProblem("Type mismatch") }
            variables[name] = value
        case .element(let name, let offset):
            guard name.hasSuffix("$") == value.isString, let array = arrays[name], array.values.indices.contains(offset) else {
                if let array = arrays[name], !array.values.indices.contains(offset) { throw QBasicProblem("Subscript out of range") }
                throw QBasicProblem("Type mismatch")
            }
            array.values[offset] = value
        }
    }

    private func get(_ target: QBasicLValue) throws -> QBasicValue { try read(resolve(target)) }
    private func set(_ target: QBasicLValue, _ value: QBasicValue) throws { try write(resolve(target), value) }

    // MARK: Expressions

    private func evaluate(_ expression: QBasicExpression) throws -> QBasicValue {
        switch expression {
        case .number(let n): return .number(n)
        case .string(let s): return .string(s)
        case .variable(let name): return try get(QBasicLValue(name))
        case .array(let name, let indices): return try get(QBasicLValue(name, indices: indices))
        case .unary(let op, let operand):
            let value = try number(try evaluate(operand))
            switch op {
            case "-": return .number(-value)
            case "+": return .number(value)
            case "NOT": return .number(Double(try ~integer(value)))
            default: throw QBasicProblem("Syntax error")
            }
        case .binary(let op, let leftExpression, let rightExpression):
            if op == "+" {
                let left = try evaluate(leftExpression)
                let right = try evaluate(rightExpression)
                switch (left, right) {
                case (.number(let a), .number(let b)): return .number(a + b)
                case (.string(let a), .string(let b)): return .string(a + b)
                default: throw QBasicProblem("Type mismatch")
                }
            }
            if ["=", "<>", "<", ">", "<=", ">="].contains(op) {
                let left = try evaluate(leftExpression)
                let right = try evaluate(rightExpression)
                let result: Bool
                switch (left, right) {
                case (.number(let a), .number(let b)):
                    switch op {
                    case "=": result = a == b
                    case "<>": result = a != b
                    case "<": result = a < b
                    case ">": result = a > b
                    case "<=": result = a <= b
                    default: result = a >= b
                    }
                case (.string(let a), .string(let b)):
                    switch op {
                    case "=": result = a == b
                    case "<>": result = a != b
                    case "<": result = a < b
                    case ">": result = a > b
                    case "<=": result = a <= b
                    default: result = a >= b
                    }
                default: throw QBasicProblem("Type mismatch")
                }
                return .number(result ? -1 : 0)
            }
            let a = try number(try evaluate(leftExpression))
            let b = try number(try evaluate(rightExpression))
            switch op {
            case "-": return .number(a - b)
            case "*": return .number(a * b)
            case "/":
                guard b != 0 else { throw QBasicProblem("Division by zero") }
                return .number(a / b)
            case "\\":
                let divisor = try integer(b)
                guard divisor != 0 else { throw QBasicProblem("Division by zero") }
                let dividend = try integer(a)
                guard dividend != Int.min || divisor != -1 else { throw QBasicProblem("Illegal function call") }
                return .number(Double(dividend / divisor))
            case "MOD":
                let divisor = try integer(b)
                guard divisor != 0 else { throw QBasicProblem("Division by zero") }
                let dividend = try integer(a)
                guard dividend != Int.min || divisor != -1 else { throw QBasicProblem("Illegal function call") }
                return .number(Double(dividend % divisor))
            case "^":
                let result = Foundation.pow(a, b)
                guard result.isFinite else { throw QBasicProblem("Illegal function call") }
                return .number(result)
            case "AND": return .number(Double(try integer(a) & integer(b)))
            case "OR": return .number(Double(try integer(a) | integer(b)))
            default: throw QBasicProblem("Syntax error")
            }
        case .function(let name, let arguments):
            return try call(name, arguments)
        }
    }

    private func number(_ value: QBasicValue) throws -> Double {
        guard case .number(let n) = value else { throw QBasicProblem("Type mismatch") }
        return n
    }

    private func string(_ value: QBasicValue) throws -> String {
        guard case .string(let s) = value else { throw QBasicProblem("Type mismatch") }
        return s
    }

    private func truth(_ value: QBasicValue) throws -> Bool { try number(value) != 0 }

    private func integer(_ value: Double) throws -> Int {
        guard value.isFinite, value.rounded() >= Double(Int.min), value.rounded() < Double(Int.max) else {
            throw QBasicProblem("Illegal function call")
        }
        return Int(value.rounded())
    }

    private func call(_ name: String, _ expressions: [QBasicExpression]) throws -> QBasicValue {
        if name == "INKEY$" {
            guard expressions.isEmpty else { throw QBasicProblem("Illegal function call") }
            return .string(readKey())
        }
        if name == "RND" {
            guard expressions.count <= 1 else { throw QBasicProblem("Illegal function call") }
            if let expression = expressions.first {
                let selector = try number(try evaluate(expression))
                if selector == 0 { return .number(lastRandom) }
                if selector < 0 {
                    guard selector.isFinite, selector >= Double(Int32.min), selector <= Double(UInt32.max) else { throw QBasicProblem("Illegal function call") }
                    randomState = UInt32(truncatingIfNeeded: Int64(selector))
                }
            }
            return .number(nextRandom())
        }
        let args = try expressions.map { try evaluate($0) }
        switch name {
        case "ABS":
            try arity(args, 1)
            return .number(abs(try number(args[0])))
        case "ASC":
            try arity(args, 1)
            let s = try string(args[0])
            guard let scalar = s.unicodeScalars.first else { throw QBasicProblem("Illegal function call") }
            return .number(Double(scalar.value))
        case "ATN":
            try arity(args, 1)
            return .number(Foundation.atan(try number(args[0])))
        case "CHR$":
            try arity(args, 1)
            let n = try integer(try number(args[0]))
            guard (0...255).contains(n), let scalar = UnicodeScalar(n) else { throw QBasicProblem("Illegal function call") }
            return .string(String(Character(scalar)))
        case "COS":
            try arity(args, 1)
            return .number(Foundation.cos(try number(args[0])))
        case "EXP":
            try arity(args, 1)
            let result = Foundation.exp(try number(args[0]))
            guard result.isFinite else { throw QBasicProblem("Illegal function call") }
            return .number(result)
        case "INT":
            try arity(args, 1)
            return .number((try number(args[0])).rounded(.down))
        case "LEFT$":
            try arity(args, 2)
            let count = try integer(try number(args[1]))
            guard count >= 0 else { throw QBasicProblem("Illegal function call") }
            return .string(String(Array(try string(args[0])).prefix(count)))
        case "LEN":
            try arity(args, 1)
            return .number(Double(try string(args[0]).count))
        case "LOG":
            try arity(args, 1)
            let n = try number(args[0])
            guard n > 0 else { throw QBasicProblem("Illegal function call") }
            return .number(Foundation.log(n))
        case "LTRIM$":
            try arity(args, 1)
            return .string(String((try string(args[0])).drop(while: { $0 == " " || $0 == "\t" })))
        case "RTRIM$":
            try arity(args, 1)
            var s = try string(args[0])
            while s.last == " " || s.last == "\t" { s.removeLast() }
            return .string(s)
        case "MID$":
            guard args.count == 2 || args.count == 3 else { throw QBasicProblem("Illegal function call") }
            let chars = Array(try string(args[0]))
            let start = try integer(try number(args[1]))
            guard start >= 1 else { throw QBasicProblem("Illegal function call") }
            let length = args.count == 3 ? try integer(try number(args[2])) : Int.max
            guard length >= 0 else { throw QBasicProblem("Illegal function call") }
            guard start <= chars.count else { return .string("") }
            let available = chars.count - (start - 1)
            return .string(String(chars[(start - 1)..<(start - 1 + min(length, available))]))
        case "RIGHT$":
            try arity(args, 2)
            let count = try integer(try number(args[1]))
            guard count >= 0 else { throw QBasicProblem("Illegal function call") }
            return .string(String(Array(try string(args[0])).suffix(count)))
        case "SGN":
            try arity(args, 1)
            let n = try number(args[0])
            return .number(n == 0 ? 0 : (n < 0 ? -1 : 1))
        case "SIN":
            try arity(args, 1)
            return .number(Foundation.sin(try number(args[0])))
        case "SQR":
            try arity(args, 1)
            let n = try number(args[0])
            guard n >= 0 else { throw QBasicProblem("Illegal function call") }
            return .number(Foundation.sqrt(n))
        case "STR$":
            try arity(args, 1)
            return .string(QBasicFormat.string(try number(args[0])))
        case "TAN":
            try arity(args, 1)
            return .number(Foundation.tan(try number(args[0])))
        case "VAL":
            try arity(args, 1)
            return .number(QBasicFormat.value(try string(args[0])))
        case "SPACE$":
            try arity(args, 1)
            let count = try integer(try number(args[0]))
            guard (0...1_000_000).contains(count) else { throw QBasicProblem("Illegal function call") }
            return .string(String(repeating: " ", count: count))
        case "STRING$":
            try arity(args, 2)
            let count = try integer(try number(args[0]))
            guard (0...1_000_000).contains(count) else { throw QBasicProblem("Illegal function call") }
            let piece: String
            switch args[1] {
            case .number(let n):
                let code = try integer(n)
                guard (0...255).contains(code), let scalar = UnicodeScalar(code) else { throw QBasicProblem("Illegal function call") }
                piece = String(Character(scalar))
            case .string(let s):
                guard let first = s.first else { throw QBasicProblem("Illegal function call") }
                piece = String(first)
            }
            return .string(String(repeating: piece, count: count))
        case "UCASE$":
            try arity(args, 1)
            return .string((try string(args[0])).uppercased())
        case "LCASE$":
            try arity(args, 1)
            return .string((try string(args[0])).lowercased())
        case "TAB":
            throw QBasicProblem("Illegal function call")
        default:
            throw QBasicProblem("Syntax error")
        }
    }

    private func arity(_ args: [QBasicValue], _ count: Int) throws {
        guard args.count == count else { throw QBasicProblem("Illegal function call") }
    }

    private func nextRandom() -> Double {
        randomState = UInt32((UInt64(randomState) * 1_103_515_245 + 12_345) & 0x7fff_ffff)
        lastRandom = Double(randomState) / 2_147_483_648.0
        return lastRandom
    }

    private func readKey() -> String {
        guard let key = io.key() else { return "" }
        switch key {
        case .char(let c): return String(c)
        case .enter: return "\r"
        case .tab: return "\t"
        case .backspace: return "\u{8}"
        case .escape: return "\u{1B}"
        case .ctrl(let c):
            guard let ascii = c.uppercased().first?.asciiValue, ascii >= 64 else { return "" }
            return String(Character(UnicodeScalar(ascii - 64)))
        default: return ""
        }
    }

    // MARK: Console statements

    private func printItems(_ items: [QBasicPrintItem]) throws {
        for item in items {
            switch item {
            case .expression(let expression):
                switch try evaluate(expression) {
                case .string(let s): emit(s)
                case .number(let n): emit(QBasicFormat.string(n) + " ")
                }
            case .tab(let expression):
                let position = try integer(try number(try evaluate(expression)))
                guard position > 0 else { throw QBasicProblem("Illegal function call") }
                let column = (position - 1) % 80
                if column < outputColumn { emit("\n") }
                if column > outputColumn { emit(String(repeating: " ", count: column - outputColumn)) }
            case .semicolon:
                break
            case .comma:
                let zone = (outputColumn / 14 + 1) * 14
                if zone >= 80 { emit("\n") }
                else { emit(String(repeating: " ", count: zone - outputColumn)) }
            }
        }
        if let last = items.last {
            switch last {
            case .semicolon, .comma: break
            default: emit("\n")
            }
        } else {
            emit("\n")
        }
    }

    private func emit(_ text: String) {
        io.write(text)
        for ch in text {
            switch ch {
            case "\n", "\r": outputColumn = 0
            case "\t": outputColumn = (outputColumn / 8 + 1) * 8
            default:
                outputColumn += 1
                if outputColumn >= 80 { outputColumn = 0 }
            }
        }
    }

    private func readInput(prompt: String, wholeLine: Bool, targets: [QBasicLValue]) throws {
        if wholeLine {
            guard targets.count == 1, targets[0].name.hasSuffix("$") else { throw QBasicProblem("Type mismatch") }
            guard let text = io.input(prompt) else { throw QBasicProblem("Input past end") }
            outputColumn = 0
            try set(targets[0], .string(text))
            return
        }
        var pieces: [String] = []
        var first = true
        while pieces.count < targets.count {
            guard let text = io.input(first ? prompt : "?? ") else { throw QBasicProblem("Input past end") }
            outputColumn = 0
            pieces.append(contentsOf: QBasicInputFields.split(text))
            first = false
        }
        for (target, piece) in zip(targets, pieces) {
            if target.name.hasSuffix("$") {
                try set(target, .string(QBasicInputFields.unquote(piece)))
            } else {
                let text = piece.trimmingCharacters(in: .whitespaces)
                guard let n = Double(text), n.isFinite else { throw QBasicProblem("Type mismatch") }
                try set(target, .number(n))
            }
        }
    }
}

// MARK: - BASIC's text representations

enum QBasicFormat {
    static func plain(_ n: Double) -> String {
        if n == 0 { return "0" }
        if n.rounded() == n, abs(n) < 1e15 { return String(Int64(n)) }
        var text = String(format: "%.15g", n)
        text = text.replacingOccurrences(of: "e+", with: "E+")
            .replacingOccurrences(of: "e-", with: "E-")
            .replacingOccurrences(of: "e", with: "E")
        return text
    }

    /// STR$ reserves a sign column for nonnegative numbers. PRINT uses the same text and
    /// adds the traditional trailing blank after every numeric value.
    static func string(_ n: Double) -> String {
        (n >= 0 ? " " : "") + plain(n)
    }

    static func value(_ text: String) -> Double {
        let chars = Array(text.drop(while: { $0 == " " || $0 == "\t" }))
        guard !chars.isEmpty else { return 0 }
        var end = 0
        if chars[end] == "+" || chars[end] == "-" {
            end += 1
            if end == chars.count { return 0 }
        }
        let wholeStart = end
        while end < chars.count, chars[end].isNumber { end += 1 }
        var digits = end - wholeStart
        if end < chars.count, chars[end] == "." {
            end += 1
            let fractionStart = end
            while end < chars.count, chars[end].isNumber { end += 1 }
            digits += end - fractionStart
        }
        guard digits > 0 else { return 0 }
        let exponent = end
        if end < chars.count, chars[end] == "e" || end < chars.count, chars[end] == "E" {
            end += 1
            if end < chars.count, chars[end] == "+" || end < chars.count, chars[end] == "-" { end += 1 }
            let exponentDigits = end
            while end < chars.count, chars[end].isNumber { end += 1 }
            if end == exponentDigits { end = exponent }
        }
        return Double(String(chars[..<end])) ?? 0
    }
}

private enum QBasicInputFields {
    static func split(_ text: String) -> [String] {
        let chars = Array(text)
        var result: [String] = []
        var current = ""
        var quoted = false
        var i = 0
        while i < chars.count {
            if chars[i] == "\"" {
                if quoted, i + 1 < chars.count, chars[i + 1] == "\"" {
                    current.append("\"")
                    i += 2
                    continue
                }
                quoted.toggle()
                current.append(chars[i])
            } else if chars[i] == ",", !quoted {
                result.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(chars[i])
            }
            i += 1
        }
        result.append(current.trimmingCharacters(in: .whitespaces))
        return result
    }

    static func unquote(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.first == "\"", trimmed.last == "\"", trimmed.count >= 2 else { return trimmed }
        return String(trimmed.dropFirst().dropLast()).replacingOccurrences(of: "\"\"", with: "\"")
    }
}
