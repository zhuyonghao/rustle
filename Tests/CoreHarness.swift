import Foundation

// The CLT runner compiles the existing XCTest test bodies against these small
// assertion adapters. Keep one source of truth for test cases, with no XCTest
// framework, downloaded dependencies, real provider calls, or ASR model required.
class XCTestCase {
    func setUp() {}
    func tearDown() {}
}

private struct CoreUnwrapFailure: Error, CustomStringConvertible {
    var description: String
}

func XCTUnwrap<T>(_ expression: @autoclosure () throws -> T?, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) throws -> T {
    guard let value = try expression() else {
        throw CoreUnwrapFailure(description: "\(file):\(line): Expected a non-nil value. \(message())")
    }
    return value
}

enum CoreTestRunner {
    private static let lock = NSLock()
    private static var failures: [String] = []
    private static var completed = 0

    static var failureCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return failures.count
    }

    static func fail(_ message: String, file: StaticString, line: UInt) {
        let diagnostic = "\(file):\(line): \(message)"
        lock.lock()
        failures.append(diagnostic)
        lock.unlock()
        FileHandle.standardError.write(Data("  FAIL: \(diagnostic)\n".utf8))
    }

    static func run(_ name: String, testCase: XCTestCase, operation: () async throws -> Void) async {
        let before = failureCount
        testCase.setUp()
        do { try await operation() }
        catch { fail("\(name) threw an unexpected error: \(error)", file: #filePath, line: #line) }
        testCase.tearDown()
        completed += 1
        print("\(failureCount == before ? "PASS" : "FAIL") \(name)")
    }

    static func finish() -> Int32 {
        let count = failureCount
        print("\n\(completed) checks completed; \(count) assertion failure(s).")
        return count == 0 ? 0 : 1
    }
}

private func verify(_ expression: () throws -> Bool, message: () -> String, fallback: String, file: StaticString, line: UInt) {
    do {
        if try !expression() {
            let detail = message()
            CoreTestRunner.fail(detail.isEmpty ? fallback : "\(fallback): \(detail)", file: file, line: line)
        }
    } catch {
        CoreTestRunner.fail("Assertion threw: \(error)", file: file, line: line)
    }
}

func XCTFail(_ message: String = "Unconditional failure", file: StaticString = #filePath, line: UInt = #line) {
    CoreTestRunner.fail(message, file: file, line: line)
}

func XCTAssertTrue(_ expression: @autoclosure () throws -> Bool, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    verify(expression, message: message, fallback: "Expected true", file: file, line: line)
}

func XCTAssertFalse(_ expression: @autoclosure () throws -> Bool, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    verify({ try !expression() }, message: message, fallback: "Expected false", file: file, line: line)
}

func XCTAssertEqual<T: Equatable>(_ actual: @autoclosure () throws -> T, _ expected: @autoclosure () throws -> T, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    verify({ try actual() == expected() }, message: message, fallback: "Values are not equal", file: file, line: line)
}

func XCTAssertEqual(_ actual: @autoclosure () throws -> Double, _ expected: @autoclosure () throws -> Double, accuracy: Double, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    verify({ try abs(actual() - expected()) <= accuracy }, message: message, fallback: "Values differ by more than \(accuracy)", file: file, line: line)
}

func XCTAssertNotEqual<T: Equatable>(_ actual: @autoclosure () throws -> T, _ expected: @autoclosure () throws -> T, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    verify({ try actual() != expected() }, message: message, fallback: "Values must not be equal", file: file, line: line)
}

func XCTAssertNotNil<T>(_ expression: @autoclosure () throws -> T?, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    verify({ try expression() != nil }, message: message, fallback: "Expected a non-nil value", file: file, line: line)
}

func XCTAssertNil<T>(_ expression: @autoclosure () throws -> T?, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    verify({ try expression() == nil }, message: message, fallback: "Expected nil", file: file, line: line)
}

func XCTAssertGreaterThan<T: Comparable>(_ actual: @autoclosure () throws -> T, _ expected: @autoclosure () throws -> T, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    verify({ try actual() > expected() }, message: message, fallback: "Expected greater than", file: file, line: line)
}

func XCTAssertGreaterThanOrEqual<T: Comparable>(_ actual: @autoclosure () throws -> T, _ expected: @autoclosure () throws -> T, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    verify({ try actual() >= expected() }, message: message, fallback: "Expected greater than or equal", file: file, line: line)
}

func XCTAssertLessThan<T: Comparable>(_ actual: @autoclosure () throws -> T, _ expected: @autoclosure () throws -> T, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    verify({ try actual() < expected() }, message: message, fallback: "Expected less than", file: file, line: line)
}

func XCTAssertLessThanOrEqual<T: Comparable>(_ actual: @autoclosure () throws -> T, _ expected: @autoclosure () throws -> T, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    verify({ try actual() <= expected() }, message: message, fallback: "Expected less than or equal", file: file, line: line)
}

func XCTAssertThrowsError<T>(_ expression: @autoclosure () throws -> T, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line, _ handler: (Error) -> Void = { _ in }) {
    do {
        _ = try expression()
        let detail = message()
        CoreTestRunner.fail(detail.isEmpty ? "Expected an error" : "Expected an error: \(detail)", file: file, line: line)
    } catch {
        handler(error)
    }
}

func XCTAssertNoThrow<T>(_ expression: @autoclosure () throws -> T, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    do { _ = try expression() }
    catch { CoreTestRunner.fail("Unexpected error: \(error). \(message())", file: file, line: line) }
}
