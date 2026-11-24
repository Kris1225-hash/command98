import XCTest
@testable import command98

final class RecordingIO: QBasicIO {
    private(set) var output = ""
    private(set) var writes: [String] = []
    private(set) var clearCount = 0
    private(set) var locations: [(Int, Int)] = []
    private(set) var colors: [(Int, Int)] = []
    private(set) var prompts: [String] = []
    private(set) var sleeps: [Int] = []
    var inputQueue: [String]
    var keyQueue: [Key]
    var onWrite: ((String) -> Void)?
    var onSleep: ((Int) -> Void)?

    init(inputs: [String] = [], keys: [Key] = []) {
        inputQueue = inputs
        keyQueue = keys
    }

    func write(_ s: String) {
        writes.append(s)
        output += s
        onWrite?(s)
    }

    func cls() { clearCount += 1 }
    func locate(_ row: Int, _ col: Int) { locations.append((row, col)) }
    func color(_ fg: Int, _ bg: Int) { colors.append((fg, bg)) }

    func input(_ prompt: String) -> String? {
        prompts.append(prompt)
        guard !inputQueue.isEmpty else { return nil }
        return inputQueue.removeFirst()
    }

    func sleep(_ ms: Int) {
        sleeps.append(ms)
        onSleep?(ms)
    }
    func key() -> Key? { keyQueue.isEmpty ? nil : keyQueue.removeFirst() }
}

final class QBasicInterpreterTests: XCTestCase {
    @discardableResult
    func run(_ source: String, inputs: [String] = [], keys: [Key] = []) -> (Int32, RecordingIO) {
        let io = RecordingIO(inputs: inputs, keys: keys)
        let status = QBasic.run(source: source, io: io)
        return (status, io)
    }

    func testArithmeticPrecedenceIntegerDivisionAndLogic() {
        let (status, io) = run("""
        PRINT 2 + 3 * 4
        PRINT (2 + 3) * 4
        PRINT 7 \\ 2
        PRINT 7 MOD 2
        PRINT 2 ^ 3 ^ 2
        PRINT -2 ^ 2
        PRINT 5 AND 3
        PRINT 5 OR 2
        PRINT NOT 0
        """)
        XCTAssertEqual(status, 0)
        XCTAssertEqual(io.output, " 14 \n 20 \n 3 \n 1 \n 512 \n-4 \n 1 \n 7 \n-1 \n")
    }

    func testStringsConcatenationAndComparisons() {
        let (status, io) = run("""
        A$ = "basic"
        LET B$ = "QB"
        PRINT B$ + " " + A$
        PRINT "a" < "b"
        PRINT 3 >= 3
        PRINT 2 <> 2
        """)
        XCTAssertEqual(status, 0)
        XCTAssertEqual(io.output, "QB basic\n-1 \n-1 \n 0 \n")
    }

    func testPrintSeparatorsZonesAndTab() {
        let (status, io) = run("""
        PRINT "A"; "B";
        PRINT "C"
        PRINT "A", "B"
        PRINT TAB(5); "X"
        PRINT 1; 2
        PRINT "last";
        """)
        XCTAssertEqual(status, 0)
        XCTAssertEqual(io.output, "ABC\nA             B\n    X\n 1  2 \nlast")
    }

    func testForNextStepsAndNestedLoops() {
        let (status, io) = run("""
        FOR I = 1 TO 5 STEP 2: PRINT I;: NEXT I
        PRINT
        FOR I = 3 TO 1 STEP -1: PRINT I;: NEXT
        PRINT
        FOR I = 1 TO 2
        FOR J = 1 TO 2
        PRINT I; J;
        NEXT J
        NEXT I
        PRINT
        FOR I = 3 TO 1
        PRINT "not reached"
        NEXT I
        PRINT "done"
        """)
        XCTAssertEqual(status, 0)
        XCTAssertEqual(io.output, " 1  3  5 \n 3  2  1 \n 1  1  1  2  2  1  2  2 \ndone\n")
    }

    func testSingleLineAndBlockIfElse() {
        let (status, io) = run("""
        A = 2
        IF A = 2 THEN PRINT "yes" ELSE PRINT "no"
        IF A = 1 THEN PRINT "bad" ELSE PRINT "good"
        IF A = 2 THEN PRINT "two": PRINT "statements" ELSE PRINT "bad"
        IF A = 2 THEN
        PRINT "block"
        ELSE
        PRINT "bad block"
        END IF
        """)
        XCTAssertEqual(status, 0)
        XCTAssertEqual(io.output, "yes\ngood\ntwo\nstatements\nblock\n")
    }

    func testGotoGosubAndOnGoto() {
        let (status, io) = run("""
        10 GOTO 40
        20 PRINT "subroutine": RETURN
        30 PRINT "wrong"
        40 GOSUB 20
        50 X = 2
        60 ON X GOTO 70, 80, 30
        70 PRINT "wrong target"
        80 PRINT "done"
        90 END
        """)
        XCTAssertEqual(status, 0)
        XCTAssertEqual(io.output, "subroutine\ndone\n")
    }

    func testWhileAndAllDoLoopForms() {
        let (status, io) = run("""
        I = 0: WHILE I < 3: PRINT I;: I = I + 1: WEND
        PRINT
        J = 0: DO: J = J + 1: LOOP UNTIL J = 2: PRINT J
        K = 0: DO WHILE K < 2: K = K + 1: LOOP: PRINT K
        L = 0: DO UNTIL L = 2: L = L + 1: LOOP: PRINT L
        M = 0: DO: M = M + 1: LOOP WHILE M < 2: PRINT M
        """)
        XCTAssertEqual(status, 0)
        XCTAssertEqual(io.output, " 0  1  2 \n 2 \n 2 \n 2 \n 2 \n")
    }

    func testArraysDefaultBoundsAndSwap() {
        let (status, io) = run("""
        DIM A(2), B$(1, 2), S$(1)
        A(0) = 10: A(1) = 20: A(2) = A(0) + A(1)
        B$(0, 0) = "x": B$(1, 2) = "y"
        C(10) = 42
        S$(0) = "left": S$(1) = "right"
        SWAP A(0), A(1)
        SWAP S$(0), S$(1)
        PRINT A(0); A(1); A(2); C(10)
        PRINT B$(0, 0); B$(1, 2); S$(0); S$(1)
        """)
        XCTAssertEqual(status, 0)
        XCTAssertEqual(io.output, " 20  10  30  42 \nxyrightleft\n")
    }

    func testDataReadAndRestore() {
        let (status, io) = run("""
        10 DATA 1, "two", 3
        20 READ A, B$, C
        30 PRINT A; B$; C
        40 RESTORE
        50 READ D
        60 RESTORE 100
        70 READ E
        80 PRINT D; E
        90 END
        100 DATA 9
        """)
        XCTAssertEqual(status, 0)
        XCTAssertEqual(io.output, " 1 two 3 \n 1  9 \n")
    }

    func testInputAndLineInputUseScriptedQueue() {
        let (status, io) = run("""
        INPUT "Name"; N$
        INPUT "Values", A, B
        LINE INPUT "Whole"; L$
        PRINT N$; A + B
        PRINT L$
        """, inputs: ["Alice", "2,3", "one,two,three"])
        XCTAssertEqual(status, 0)
        XCTAssertEqual(io.prompts, ["Name", "Values? ", "Whole"])
        XCTAssertEqual(io.output, "Alice 5 \none,two,three\n")
    }

    func testStringAndNumericFunctions() {
        let (status, io) = run("""
        PRINT ABS(-3); SGN(-9); INT(-1.2)
        PRINT ASC("A"); CHR$(66)
        PRINT LEFT$("abcdef", 3); RIGHT$("abcdef", 2); MID$("abcdef", 2, 3)
        PRINT LEN("four"); "<"; LTRIM$("  x"); RTRIM$("y  "); ">"
        PRINT STR$(12); VAL("  -12.5tail")
        PRINT UCASE$("MiXeD"); LCASE$("MiXeD")
        PRINT "<"; SPACE$(2); STRING$(3, "ab"); STRING$(2, 65); ">"
        PRINT SQR(9); COS(0); SIN(0); TAN(0); LOG(EXP(1)); ATN(0)
        """)
        XCTAssertEqual(status, 0)
        XCTAssertEqual(io.output, " 3 -1 -2 \n 65 B\nabcefbcd\n 4 <xy>\n 12-12.5 \nMIXEDmixed\n<  aaaAA>\n 3  1  0  0  1  0 \n")
    }

    func testInkeyDoesNotRequireATerminal() {
        let (status, io) = run("""
        PRINT INKEY$;
        PRINT "<"; INKEY$; ">"
        """, keys: [.char("x")])
        XCTAssertEqual(status, 0)
        XCTAssertEqual(io.output, "x<>\n")
    }

    func testScreenAndSleepOperationsGoThroughIO() {
        let (status, io) = run("""
        CLS
        COLOR 14, 1
        LOCATE 4, 9
        PRINT "here"
        SLEEP 1.25
        """)
        XCTAssertEqual(status, 0)
        XCTAssertEqual(io.clearCount, 1)
        XCTAssertEqual(io.colors.map { [$0.0, $0.1] }, [[14, 1]])
        XCTAssertEqual(io.locations.map { [$0.0, $0.1] }, [[4, 9]])
        XCTAssertEqual(io.sleeps, Array(repeating: 40, count: 31) + [10])
        XCTAssertEqual(io.output, "here\n")
    }

    func testInterruptStopsLoopsAndClearsFlag() {
        let cases = [
            ("10 PRINT \"tick\": GOTO 10", 10),
            ("10 FOR I = 1 TO 2 STEP 0: PRINT \"tick\": NEXT I", 10),
            ("10 WHILE 1: PRINT \"tick\": WEND", 10),
            ("10 GOSUB 20\n20 PRINT \"tick\": GOTO 10", 20),
        ]
        for (source, line) in cases {
            let io = RecordingIO()
            gInterrupted = 0
            io.onWrite = { _ in
                gInterrupted = 1
                io.onWrite = nil
            }
            let status = QBasic.run(source: source, io: io)
            XCTAssertEqual(status, 2, source)
            XCTAssertEqual(gInterrupted, 0, source)
            XCTAssertEqual(io.output, "tick\nBreak in line \(line)\n", source)
        }
    }

    func testInterruptStopsLongSleepAfterFirstChunk() {
        let io = RecordingIO()
        gInterrupted = 0
        io.onSleep = { _ in gInterrupted = 1 }
        let status = QBasic.run(source: "10 SLEEP 60", io: io)
        XCTAssertEqual(status, 2)
        XCTAssertEqual(gInterrupted, 0)
        XCTAssertEqual(io.sleeps, [40])
        XCTAssertEqual(io.output, "Break in line 10\n")
    }

    func testExpressionAndStatementComplexityFailWithoutCrashing() {
        let nested = "10 PRINT " + String(repeating: "(", count: 5_000) + "1"
            + String(repeating: ")", count: 5_000)
        let additions = "10 PRINT 1" + String(repeating: " + 1", count: 49_999)
        let evaluatorDepth = "10 PRINT 1" + String(repeating: " + 1", count: 128)
        for source in [nested, additions, evaluatorDepth] {
            let (status, io) = run(source)
            XCTAssertEqual(status, 1)
            XCTAssertEqual(io.output, "Expression too complex in line 10\n")
        }

        let statements = String(repeating: "IF 1 THEN ", count: 1_000) + "PRINT \"unreachable\""
        let (status, io) = run(statements)
        XCTAssertEqual(status, 1)
        XCTAssertEqual(io.output, "Program too complex in line 1\n")
    }

    func testStackAndTotalArrayLimits() {
        var result = run("10 GOSUB 10")
        XCTAssertEqual(result.0, 1)
        XCTAssertEqual(result.1.output, "GOSUB stack overflow in line 10\n")

        result = run("10 FOR I = 1 TO 2\n20 GOTO 10\n30 NEXT I")
        XCTAssertEqual(result.0, 1)
        XCTAssertEqual(result.1.output, "FOR stack overflow in line 10\n")

        result = run("10 DIM A(65535, 65535)")
        XCTAssertEqual(result.0, 1)
        XCTAssertEqual(result.1.output, "Out of memory in line 10\n")

        result = run("10 DIM A(999, 499), B(999, 499), C(1)")
        XCTAssertEqual(result.0, 1)
        XCTAssertEqual(result.1.output, "Out of memory in line 10\n")
    }

    func testInlineGosubReturnsToFollowingStatement() {
        let (status, io) = run("""
        10 X = 1
        20 IF X = 1 THEN GOSUB 100: PRINT "after"
        30 PRINT "rest"
        40 END
        100 PRINT "sub": RETURN
        """)
        XCTAssertEqual(status, 0)
        XCTAssertEqual(io.output, "sub\nafter\nrest\n")
    }

    func testExponentLiteralsAndValAcceptLowercaseAndExplicitPlus() {
        let (status, io) = run("""
        PRINT 1e3; 1E+3; 1E3; 1e+3; 1E-3
        PRINT VAL("1e3"); VAL("1E+3"); VAL("1E3"); VAL("1e+3"); VAL("1E-3")
        """)
        XCTAssertEqual(status, 0)
        XCTAssertEqual(io.output, " 1000  1000  1000  1000  0.001 \n 1000  1000  1000  1000  0.001 \n")
    }

    func testRandomizeIsRepeatableAndRndZeroRepeats() {
        let source = "RANDOMIZE 42\nPRINT RND\nA = RND\nPRINT RND(0) = A"
        let first = run(source)
        let second = run(source)
        XCTAssertEqual(first.0, 0)
        XCTAssertEqual(second.0, 0)
        XCTAssertEqual(first.1.output, second.1.output)
        XCTAssertTrue(first.1.output.hasSuffix("-1 \n"))
    }

    func testSyntaxAndRuntimeErrorsIncludeSourceLines() {
        let cases: [(String, String)] = [
            ("10 PRINT 1\n20 PRINT 2 +", "Syntax error in line 20\n"),
            ("10 GOTO 99", "Undefined line number in line 10\n"),
            ("10 FOR I = 1 TO 2", "FOR without NEXT in line 10\n"),
            ("10 NEXT", "NEXT without FOR in line 10\n"),
            ("10 RETURN", "RETURN without GOSUB in line 10\n"),
            ("10 READ A", "Out of DATA in line 10\n"),
            ("10 DIM A(1)\n20 A(2) = 4", "Subscript out of range in line 20\n"),
            ("10 PRINT 1 / 0", "Division by zero in line 10\n"),
            ("10 A$ = \"x\"\n20 A = A$ + 1", "Type mismatch in line 20\n"),
            ("10 PRINT SQR(-1)", "Illegal function call in line 10\n"),
        ]
        for (source, expected) in cases {
            let (status, io) = run(source)
            XCTAssertEqual(status, 1, source)
            XCTAssertEqual(io.output, expected, source)
        }
    }

    func testEndAndStopReturnSuccess() {
        XCTAssertEqual(run("PRINT \"before\"\nEND\nPRINT \"after\"").0, 0)
        XCTAssertEqual(run("PRINT \"before\"\nEND\nPRINT \"after\"").1.output, "before\n")
        XCTAssertEqual(run("10 STOP\n20 PRINT \"after\"").0, 0)
        XCTAssertEqual(run("10 STOP\n20 PRINT \"after\"").1.output, "")
    }

    func testAllSamplesRunToCompletion() {
        for sample in QBasic.samples {
            let inputs = sample.name == "GUESS" ? (1...10).map(String.init) : []
            let (status, io) = run(sample.source, inputs: inputs)
            XCTAssertEqual(status, 0, sample.name)
            XCTAssertFalse(io.output.isEmpty, sample.name)
        }
        XCTAssertEqual(Set(QBasic.samples.map { $0.name }), Set(["HELLO", "GUESS", "PYRAMID"]))
    }

    func testFeatureRegistrationAndRunCommand() {
        XCTAssertEqual(QBasic.stubVersion, "1")
        XCTAssertEqual(QBasic.stubFiles.first?.0, "WINDOWS\\COMMAND")
        XCTAssertEqual(QBasic.stubFiles.first?.1, "QBASIC.EXE")
        XCTAssertTrue(QBasic.stubFiles.first?.2 ?? 0 > 1000)
        XCTAssertNotNil(QBasic.utilities["QBASIC"])
        XCTAssertTrue(QBasic.help["QBASIC"]?.contains("/RUN") == true)

        let test = TestShell()
        Shell.installStubs(root: test.root)
        test.shell.envSet("PATH", "C:\\WINDOWS\\COMMAND")
        test.write("TEST.BAS", "PRINT 2 + 2\nEND\n")
        let output = test.run("QBASIC /RUN TEST.BAS")
        XCTAssertEqual(output, " 4 \n")
        XCTAssertEqual(test.shell.errorLevel, 0)
    }

    func testRunWithRedirectedOutputLeavesScreenControlOut() {
        let test = TestShell()
        Shell.installStubs(root: test.root)
        test.shell.envSet("PATH", "C:\\WINDOWS\\COMMAND")
        test.write("RUNME.BAS", "CLS: COLOR 14,1: LOCATE 4,9: PRINT \"here\"\n")

        // TestShell's stdout is a file, so this is the redirected case: PRINT must still
        // land in the log, but no escape sequence may be written into it.
        let output = test.run("QBASIC /RUN C:\\RUNME.BAS")

        XCTAssertTrue(output.contains("here"), output)
        XCTAssertFalse(output.contains("\u{1B}"), output)
        XCTAssertFalse(output.contains("[2J"), output)
        XCTAssertFalse(output.contains("[93;44m"), output)
        XCTAssertEqual(test.shell.errorLevel, 0)
    }
}
