import Foundation
import XCTest
@testable import PomoGem

/// Home recomputes its start button and celebration gate from the receipt
/// store, which lives in UserDefaults. Every write must announce itself.
final class PendingRewardReceiptChangeTests: XCTestCase {
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() { lock.lock(); value += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    func testEveryReceiptWriteIsAnnounced() throws {
        let suiteName = "PomoGemTests.reward-receipt-changes.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let announcements = Counter()
        let token = NotificationCenter.default.addObserver(
            forName: PendingRewardReceiptStore.didChangeNotification, object: defaults, queue: nil
        ) { _ in announcements.increment() }
        defer { NotificationCenter.default.removeObserver(token) }

        let receipt = PendingRewardReceipt(
            id: UUID(uuidString: "32000000-0000-4000-8000-000000000001")!,
            createdAt: Date(timeIntervalSince1970: 1_800_400_000),
            breakMinutes: 5,
            grams: 250,
            subjectName: "英語",
            colorHex: "#6CA8FF",
            weeklyCompletionCount: 1,
            kind: .normal,
            totalPebbleCount: 1,
            projectionIsLowerBound: false
        )
        PendingRewardReceiptStore.insert(receipt, defaults: defaults)
        XCTAssertEqual(announcements.count, 1)
        PendingRewardReceiptStore.remove(id: receipt.id, defaults: defaults)
        XCTAssertEqual(announcements.count, 2, "Removing the last receipt must be announced too")
        PendingRewardReceiptStore.removeAll(defaults: defaults)
        XCTAssertEqual(announcements.count, 3)
    }
}
