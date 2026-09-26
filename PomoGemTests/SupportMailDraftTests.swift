import Foundation
import XCTest
@testable import PomoGem

/// settings-07 / product-08. The support draft carries only what support
/// needs, survives the trip through a mailto: URL intact, and the review
/// row opens this app's review sheet.
final class SupportMailDraftTests: XCTestCase {
    private let diagnostics = SupportMailDiagnostics(
        appVersion: "1.1.0 (10)",
        systemVersion: "26.5",
        deviceModel: "iPhone13,1",
        storage: .iCloud,
        pro: .notOwned
    )

    func testTheBodyListsOnlyTheDiagnosticsSupportNeeds() {
        let body = SupportMailDraft.body(for: diagnostics)
        let lines = body.components(separatedBy: "\n")
        XCTAssertEqual(Array(lines.suffix(5)), [
            "アプリ：ポモジェム 1.1.0 (10)",
            "iOS：26.5",
            "機種：iPhone13,1",
            "保存先：iCloud",
            "Pro：未購入"
        ])
        XCTAssertTrue(body.hasPrefix("（お問い合わせの内容をお書きください。"), body)
        XCTAssertTrue(body.contains("記録の内容やテーマ名は含まれていません"), body)
    }

    func testStorageAndProReadAsTheSettingsScreenSaysThem() {
        let local = SupportMailDiagnostics(
            appVersion: "1.1.0 (10)", systemVersion: "26.5", deviceModel: "iPhone17,1",
            storage: .thisiPhone, pro: .owned
        )
        let body = SupportMailDraft.body(for: local)
        XCTAssertTrue(body.contains("保存先：このiPhoneのみ"), body)
        XCTAssertTrue(body.contains("Pro：利用中"), body)

        let offline = SupportMailDiagnostics(
            appVersion: "1.1.0 (10)", systemVersion: "26.5", deviceModel: "iPhone17,1",
            storage: .iCloudOffline, pro: .awaitingApproval
        )
        let offlineBody = SupportMailDraft.body(for: offline)
        XCTAssertTrue(offlineBody.contains("保存先：iCloud（オフラインで利用中）"), offlineBody)
        XCTAssertTrue(offlineBody.contains("Pro：承認待ち"), offlineBody)
    }

    func testTheMailtoURLCarriesJapaneseAndPunctuationIntact() throws {
        let subject = "件名 & テスト"
        let body = "一行目\n二行目 a+b=c & 100%"
        let url = try XCTUnwrap(AppLinks.supportMail(subject: subject, body: body))

        XCTAssertEqual(url.scheme, "mailto")
        XCTAssertTrue(url.absoluteString.hasPrefix("mailto:support@hinoshiba.com?subject="), url.absoluteString)
        let query = try XCTUnwrap(url.absoluteString.split(separator: "?", maxSplits: 1).last)
        XCTAssertTrue(query.allSatisfy(\.isASCII), "Everything outside ASCII must be percent-encoded")
        XCTAssertFalse(query.contains("+"), "A literal + reads as a space in some mail apps")

        let fields = Dictionary(uniqueKeysWithValues: query.split(separator: "&").map { pair -> (String, String) in
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            return (parts[0], parts.count > 1 ? parts[1] : "")
        })
        XCTAssertEqual(fields.count, 2, "An & inside a value must not start a new field")
        XCTAssertEqual(fields["subject"]?.removingPercentEncoding, subject)
        XCTAssertEqual(fields["body"]?.removingPercentEncoding, body)
    }

    func testTheRealDraftBuildsAURL() throws {
        let url = try XCTUnwrap(SupportMailDraft.url(for: diagnostics))
        XCTAssertEqual(url.scheme, "mailto")
    }

    func testTheReviewRowOpensThisAppsWriteReviewSheet() {
        XCTAssertEqual(
            AppLinks.appStoreWriteReview.absoluteString,
            "https://apps.apple.com/app/id6809139517?action=write-review"
        )
    }

    /// product-08: the owner kept the automatic prompt's gate; only the
    /// user-initiated row was added.
    func testTheAutomaticReviewGateIsUnchanged() {
        XCTAssertEqual(ReviewRequestPolicy.minimumCompletionCount, 10)
        XCTAssertEqual(ReviewRequestPolicy.minimumElapsedTime, 7 * 24 * 60 * 60)
    }
}
