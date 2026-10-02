import XCTest
@testable import HealthSync

final class AppleIdentityTests: XCTestCase {
    func testNonceIsUniqueAndURLSafe() throws {
        let values = try (0..<100).map { _ in try AppleNonce.generate() }
        XCTAssertEqual(Set(values).count, 100)
        for value in values {
            XCTAssertEqual(value.count, 43)
            XCTAssertNotNil(value.range(of: "^[A-Za-z0-9_-]{43}$", options: .regularExpression))
        }
    }
    func testChallengeUsesSHA256Hex() {
        XCTAssertEqual(AppleNonce.hash("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
    func testAccountConflictExplainsDataIsPreserved() {
        XCTAssertTrue(AppleSignInError.accountConflict.localizedDescription.contains("have not changed"))
    }
}
