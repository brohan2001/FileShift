import XCTest
@testable import FileShiftCore

final class InstanceLockTests: XCTestCase {
    func testSecondInstanceIsRefusedUntilFirstReleases() {
        let sb = Sandbox()
        let path = (sb.root as NSString).appendingPathComponent("instance.lock")
        var first: InstanceLock? = InstanceLock(path: path)
        XCTAssertNotNil(first)
        // flock locks are per open file description, so a second open in the same process conflicts too.
        XCTAssertNil(InstanceLock(path: path))
        first = nil
        XCTAssertNotNil(InstanceLock(path: path))
    }
}
