import XCTest
@testable import command98

final class SmokeTests: XCTestCase {
    func testWildcards() {
        XCTAssertTrue(Wild.matches("A.TXT", "*.TXT"))
        XCTAssertFalse(Wild.matches("A.TXT", "*.COM"))
    }
}
