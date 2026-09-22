import Foundation
import ImageIO
import SwiftUI
import Testing
import UniformTypeIdentifiers
import XCTest
@testable import PomoGem

struct AnimatedShareExporterTests {
    @Test func shareCardPreviewFitsTheSameCanonicalCanvasAsExport() {
        let feedCanvas = ShareCardLayoutPolicy.canvasSize(for: .feed)
        let storyCanvas = ShareCardLayoutPolicy.canvasSize(for: .story)
        #expect(feedCanvas == CGSize(width: 360, height: 450))
        #expect(storyCanvas == CGSize(width: 360, height: 640))

        let compactFeedPreview = CGSize(width: 310, height: 387.5)
        let fittedFeed = ShareCardLayoutPolicy.fittedSize(
            for: .feed,
            in: compactFeedPreview
        )
        #expect(abs(fittedFeed.width - compactFeedPreview.width) < 0.001)
        #expect(abs(fittedFeed.height - compactFeedPreview.height) < 0.001)

        let compactStoryPreview = CGSize(width: 248, height: 440)
        let fittedStory = ShareCardLayoutPolicy.fittedSize(
            for: .story,
            in: compactStoryPreview
        )
        #expect(fittedStory.width <= compactStoryPreview.width)
        #expect(fittedStory.height <= compactStoryPreview.height)
        #expect(abs((fittedStory.width / fittedStory.height) - (9.0 / 16.0)) < 0.001)

        #expect(
            ShareCardLayoutPolicy.scaleToFit(
                canvas: feedCanvas,
                in: .zero
            ) == 0
        )

        let feedInsets = ShareCardLayoutPolicy.contentInsets(for: .feed)
        let storyInsets = ShareCardLayoutPolicy.contentInsets(for: .story)
        #expect(feedInsets.top >= 20 && feedInsets.bottom >= 20)
        #expect(storyInsets.top >= 64 && storyInsets.bottom >= 72)
    }

    @Test func writesLoopedGIFWithExpectedFrameCount() throws {
        let frames = try [
            makeFrame(red: 0.95, green: 0.35, blue: 0.18),
            makeFrame(red: 0.34, green: 0.68, blue: 0.96),
            makeFrame(red: 0.72, green: 0.34, blue: 0.88)
        ]
        let url = AnimatedShareExporter.makeTemporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }

        try AnimatedShareExporter.write(frames: frames, to: url, frameDelay: 0.125)

        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        #expect(CGImageSourceGetCount(source) == frames.count)
        #expect(CGImageSourceGetType(source) as String? == UTType.gif.identifier)
        #expect(AnimatedShareExporter.fileSize(at: url) > 0)
        #expect(AnimatedShareExporter.fileSize(at: url) < AnimatedShareExporter.maximumShareBytes)
        let containerProperties = try #require(CGImageSourceCopyProperties(source, nil) as? [CFString: Any])
        let containerGIF = try #require(containerProperties[kCGImagePropertyGIFDictionary] as? [CFString: Any])
        #expect((containerGIF[kCGImagePropertyGIFLoopCount] as? Int) == 0)
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        let gif = try #require(properties[kCGImagePropertyGIFDictionary] as? [CFString: Any])
        let delay = try #require(gif[kCGImagePropertyGIFDelayTime] as? Double)
        #expect(delay >= 0.1)
    }

    @Test func clampsTooFastFrameDelayForInteroperability() throws {
        let url = AnimatedShareExporter.makeTemporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try AnimatedShareExporter.write(
            frames: [try makeFrame(red: 1, green: 0.8, blue: 0.2)],
            to: url,
            frameDelay: 0.01
        )

        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        let gif = try #require(properties[kCGImagePropertyGIFDictionary] as? [CFString: Any])
        let delay = try #require(gif[kCGImagePropertyGIFDelayTime] as? Double)
        #expect(delay >= 0.1)
    }

    @Test func captionUsesSafePublicHashtagDefaultsWithoutPrivateLabels() {
        let caption = ShareCopy.caption(
            subject: "今月の集中",
            grams: "1,250g",
            includesSelfReportedFocus: false,
            achievementCount: 0
        )

        #expect(caption.contains("1,250g"))
        #expect(ShareCopy.hashtags == ["#ポモジェム", "#ポモドーロ"])
        #expect(
            ShareCopy.websiteURL.absoluteString
                == "https://pomogem.hinoshiba.com/"
        )
        #expect(
            caption.components(
                separatedBy: ShareCopy.websiteURL.absoluteString
            ).count - 1 == 1
        )
        for hashtag in ShareCopy.hashtags {
            #expect(caption.contains(hashtag))
        }
        #expect(!caption.contains("テーマ"))
        #expect(!caption.contains("顧客"))
        #expect(!caption.contains("成果メモ"))
    }

    @Test func editableHashtagsAreValidatedDeduplicatedAndOptional() {
        #expect(ShareHashtagPolicy.normalized(" 学習記録 ") == "#学習記録")
        #expect(ShareHashtagPolicy.normalized("#Study_2026") == "#Study_2026")
        #expect(ShareHashtagPolicy.normalized("#two words") == nil)
        #expect(ShareHashtagPolicy.normalized("@mention") == nil)
        #expect(ShareHashtagPolicy.normalized("https://example.com") == nil)
        #expect(ShareHashtagPolicy.normalized(String(repeating: "学", count: 31)) == nil)

        let custom = ShareCopy.caption(
            subject: "今日の集中",
            grams: "250g",
            includesSelfReportedFocus: false,
            achievementCount: 0,
            hashtags: ["#学習記録", "学習記録", "#Study_2026", "bad tag"]
        )
        #expect(custom.components(separatedBy: "#学習記録").count - 1 == 1)
        #expect(custom.contains("#Study_2026"))
        #expect(!custom.contains("bad tag"))

        let none = ShareCopy.caption(
            subject: "今日の集中",
            grams: "250g",
            includesSelfReportedFocus: false,
            achievementCount: 0,
            hashtags: []
        )
        #expect(!none.contains("#"))
        #expect(!none.hasSuffix("\n"))
        #expect(
            none.components(
                separatedBy: ShareCopy.websiteURL.absoluteString
            ).count - 1 == 1
        )
    }

    @Test func achievementDisclosureNeverClaimsMeasuredOnly() {
        let policy = ShareDisclosurePolicy(
            includesSelfReportedFocus: false,
            achievementCount: 1
        )
        let caption = ShareCopy.caption(
            subject: "これまでの集中",
            grams: "250g",
            includesSelfReportedFocus: false,
            achievementCount: 1
        )

        #expect(policy.hasSelfReportedContent)
        #expect(policy.cardBadge == "記念石は自己申告")
        #expect(policy.accessibilityDisclosure == "記念石は自己申告")
        #expect(caption.contains("記念石は自己申告"))
        #expect(!caption.contains("実測のみ"))
    }

    @Test func combinedDisclosureNamesBothSelfReportedSources() {
        let policy = ShareDisclosurePolicy(
            includesSelfReportedFocus: true,
            achievementCount: 2
        )

        #expect(policy.cardBadge == "自己申告込み・記念石は自己申告")
        #expect(policy.captionDisclosure == "自己申告の集中を含む・記念石は自己申告")
    }

    @Test func measuredOnlyDisclosureRequiresNoAchievements() {
        let policy = ShareDisclosurePolicy(
            includesSelfReportedFocus: false,
            achievementCount: 0
        )
        let caption = ShareCopy.caption(
            subject: "今月の集中",
            grams: "25g",
            includesSelfReportedFocus: false,
            achievementCount: 0
        )

        #expect(!policy.hasSelfReportedContent)
        #expect(policy.cardBadge == nil)
        #expect(policy.accessibilityDisclosure == "実測のみ")
        #expect(!caption.contains("自己申告"))
    }

    @Test func shareColorPolicyPreservesValidRGBAndFallsBackForMalformedValues() {
        #expect(ShareColorPolicy.resolvedHex("#e85d4a") == "E85D4A")
        #expect(ShareColorPolicy.resolvedHex(" 70FFD8 ") == "70FFD8")

        for malformed in ["", "#12", "GGHHII", "12345678", "#12-34-56"] {
            #expect(ShareColorPolicy.resolvedHex(malformed) == "8B93AC")
        }
        #expect(ShareColorPolicy.fallbackHex == "8B93AC")
    }

    @Test func denseShareProjectionCapsAndDisclosesEveryHiddenLayer() {
        let feed = ShareJarVisibilityPolicy.hiddenContent(
            loosePebbleCount: 80,
            aggregateCount: 25,
            achievementCount: 15,
            format: .feed
        )
        let story = ShareJarVisibilityPolicy.hiddenContent(
            loosePebbleCount: 80,
            aggregateCount: 25,
            achievementCount: 15,
            format: .story
        )

        #expect(feed == ShareHiddenContent(
            loosePebbleCount: 48,
            aggregateCount: 17,
            achievementCount: 9
        ))
        #expect(feed.compactLabel == "代表表示 +74")
        #expect(feed.captionDisclosure == "瓶は代表表示（ほか集中粒48粒・まとまり17個・記念石9個）")
        #expect(story == ShareHiddenContent(
            loosePebbleCount: 16,
            aggregateCount: 13,
            achievementCount: 7
        ))
    }

    @Test func aggregateMembersAreNotReportedAsHiddenLooseGems() {
        let sessionIDs = (0..<90).map { _ in UUID() }
        let withDuplicate = sessionIDs + [sessionIDs[0]]

        #expect(ShareJarVisibilityPolicy.unrepresentedLoosePebbleCount(
            sessionIDs: withDuplicate,
            representedSessionIDs: Array(sessionIDs.prefix(20))
        ) == 70)
    }

    @Test func compactLifetimeShareOnlyAddsLooseRowsNewerThanItsSummaries() {
        let summaryEnd = Date(timeIntervalSince1970: 10_000)

        #expect(!CompactShareProjectionPolicy.includesLooseSession(
            endingAt: summaryEnd.addingTimeInterval(-1),
            summaryEnds: [summaryEnd]
        ))
        #expect(!CompactShareProjectionPolicy.includesLooseSession(
            endingAt: summaryEnd,
            summaryEnds: [summaryEnd]
        ))
        #expect(CompactShareProjectionPolicy.includesLooseSession(
            endingAt: summaryEnd.addingTimeInterval(1),
            summaryEnds: [summaryEnd]
        ))
        #expect(CompactShareProjectionPolicy.includesLooseSession(
            endingAt: summaryEnd.addingTimeInterval(-1),
            summaryEnds: []
        ))
    }

    @Test func compactLifetimeShareCanProveMeasuredOnlyHistoryWithoutExpandingIt() {
        let measured = CompactShareProjectionPolicy.SummaryComposition(
            pebbleCount: 100_000,
            measuredPebbleCount: 100_000,
            manualPebbleCount: 0
        )

        #expect(CompactShareProjectionPolicy.canUseLifetimeRoots(
            includesSelfReportedFocus: false,
            modernSummaryComposition: [measured],
            hasLegacySummaries: false,
            looseSources: [.timer, .timer]
        ))
        #expect(CompactShareProjectionPolicy.canUseLifetimeRoots(
            includesSelfReportedFocus: true,
            modernSummaryComposition: [],
            hasLegacySummaries: true,
            looseSources: [.manual]
        ))
    }

    @Test func compactMeasuredOnlyShareIncludesScreenTimeWithoutDroppingOlderRoots() {
        let measured = CompactShareProjectionPolicy.SummaryComposition(
            pebbleCount: 100_000,
            measuredPebbleCount: 100_000,
            manualPebbleCount: 0
        )
        for sources: [SessionSource] in [[.screenTime], [.timer, .screenTime]] {
            #expect(CompactShareProjectionPolicy.canUseLifetimeRoots(
                includesSelfReportedFocus: false,
                modernSummaryComposition: [measured],
                hasLegacySummaries: false,
                looseSources: sources
            ))
        }
        for selfReported in [SessionSource.manual, .timerDemoted] {
            #expect(!CompactShareProjectionPolicy.canUseLifetimeRoots(
                includesSelfReportedFocus: false,
                modernSummaryComposition: [measured],
                hasLegacySummaries: false,
                looseSources: [.screenTime, selfReported]
            ))
        }
    }

    @Test func compactMeasuredOnlyShareRejectsUnknownOrSelfReportedComposition() {
        let mixed = CompactShareProjectionPolicy.SummaryComposition(
            pebbleCount: 100,
            measuredPebbleCount: 99,
            manualPebbleCount: 1
        )
        let unknown = CompactShareProjectionPolicy.SummaryComposition(
            pebbleCount: 100,
            measuredPebbleCount: 0,
            manualPebbleCount: 0
        )

        #expect(!CompactShareProjectionPolicy.canUseLifetimeRoots(
            includesSelfReportedFocus: false,
            modernSummaryComposition: [mixed],
            hasLegacySummaries: false,
            looseSources: [.timer]
        ))
        #expect(!CompactShareProjectionPolicy.canUseLifetimeRoots(
            includesSelfReportedFocus: false,
            modernSummaryComposition: [unknown],
            hasLegacySummaries: false,
            looseSources: [.timer]
        ))
        #expect(!CompactShareProjectionPolicy.canUseLifetimeRoots(
            includesSelfReportedFocus: false,
            modernSummaryComposition: [],
            hasLegacySummaries: true,
            looseSources: [.timer]
        ))
        #expect(!CompactShareProjectionPolicy.canUseLifetimeRoots(
            includesSelfReportedFocus: false,
            modernSummaryComposition: [],
            hasLegacySummaries: false,
            looseSources: [.manual]
        ))
        #expect(!CompactShareProjectionPolicy.canUseLifetimeRoots(
            includesSelfReportedFocus: false,
            modernSummaryComposition: [],
            hasLegacySummaries: false,
            looseSources: [.timerDemoted]
        ))
    }

    @Test func shareRarePebbleIdentityDistinguishesGoldAndPrism() {
        let normal = SharePebbleRewardIdentity(kind: .normal)
        let gold = SharePebbleRewardIdentity(
            kind: .gold,
            presentsRareRewards: true
        )
        let prism = SharePebbleRewardIdentity(
            kind: .prism,
            presentsRareRewards: true
        )

        #expect(normal.mark == nil)
        #expect(gold.mark == "✦")
        #expect(gold.accessibilityName == "金のレア粒")
        #expect(prism.mark == "◇")
        #expect(prism.accessibilityName == "虹のレア粒")
        #expect(gold != prism)
    }

    @Test func shareAchievementIdentityIsKindDriven() {
        let perfect = ShareAchievementIdentity(kind: .perfectScore)
        let pass = ShareAchievementIdentity(kind: .examPass)
        let work = ShareAchievementIdentity(kind: .workMilestone)

        #expect(perfect.title == "100点")
        #expect(perfect.mark == "100")
        #expect(pass.title == "試験合格")
        #expect(pass.mark == "✓")
        #expect(work.title == "仕事の節目")
        #expect(work.mark == "W")
        #expect(Set([perfect.baseHex, pass.baseHex, work.baseHex]).count == 3)
        #expect(Set([perfect.edgeHex, pass.edgeHex, work.edgeHex]).count == 3)
        #expect(Set([perfect.glowHex, pass.glowHex, work.glowHex]).count == 3)
    }

    @Test func shareAggregateRewardIdentityCarriesGoldAndPrismSeparately() {
        let combined = ShareAggregateRewardIdentity(
            goldCount: 2,
            prismCount: 1,
            presentsRareRewards: true
        )
        let none = ShareAggregateRewardIdentity(
            goldCount: 0,
            prismCount: 0,
            presentsRareRewards: true
        )

        #expect(combined.compactLabel == "金2 虹1")
        #expect(combined.accessibilityDetail == "金のレア粒2粒、虹のレア粒1粒")
        #expect(none.compactLabel == nil)
        #expect(none.accessibilityDetail == nil)
    }

    @Test func shareCardSemanticsNamesRewardKindsAndHiddenContentInCaption() {
        let semantics = ShareRewardSemantics(
            goldCount: 2,
            prismCount: 1,
            achievementKinds: [.perfectScore, .examPass, .examPass, .workMilestone],
            presentsRareRewards: true
        )
        let hidden = ShareHiddenContent(
            loosePebbleCount: 4,
            aggregateCount: 2,
            achievementCount: 1
        )
        let caption = ShareCopy.caption(
            subject: "これまでの集中",
            grams: "12,500g",
            includesSelfReportedFocus: false,
            achievementCount: 4,
            rewardDetail: semantics.captionDetail,
            visualDisclosure: hidden.captionDisclosure
        )

        #expect(semantics.captionDetail?.contains("金のレア粒2粒") == true)
        #expect(semantics.captionDetail?.contains("虹のレア粒1粒") == true)
        #expect(semantics.captionDetail?.contains("100点1個") == true)
        #expect(semantics.captionDetail?.contains("試験合格2個") == true)
        #expect(semantics.captionDetail?.contains("仕事の節目1個") == true)
        #expect(semantics.accessibilityDetail.contains("記念石の内訳"))
        #expect(caption.contains("報酬内訳"))
        #expect(caption.contains("瓶は代表表示"))
        #expect(caption.contains("記念石は自己申告"))
    }

    @Test func shippingShareSurfacesHideRetainedRareRewardData() {
        let pebble = SharePebbleRewardIdentity(
            kind: .prism,
            rewardCounts: RareRewardCounts(
                drawCount: Int.max,
                goldCount: Int.max,
                prismCount: Int.max
            )
        )
        let aggregate = ShareAggregateRewardIdentity(
            goldCount: Int.max,
            prismCount: Int.max
        )
        let semantics = ShareRewardSemantics(
            goldCount: Int.max,
            prismCount: Int.max,
            achievementKinds: []
        )

        #expect(pebble.mark == nil)
        #expect(pebble.accessibilityName == "通常の集中粒")
        #expect(aggregate.compactLabel == nil)
        #expect(aggregate.accessibilityDetail == nil)
        #expect(semantics.captionDetail == nil)
        #expect(!semantics.accessibilityDetail.contains("レア"))
        #expect(!semantics.accessibilityDetail.contains("金"))
        #expect(!semantics.accessibilityDetail.contains("虹"))
    }

    @Test func staleCleanupOnlyRemovesOwnedExpiredGIFs() throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("pomogem-cleanup-tests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let stale = directory.appendingPathComponent("pomogem-share-\(UUID().uuidString).gif")
        let fresh = directory.appendingPathComponent("pomogem-share-\(UUID().uuidString).gif")
        let malformed = directory.appendingPathComponent("pomogem-share-not-a-uuid.gif")
        let wrongExtension = directory.appendingPathComponent("pomogem-share-\(UUID().uuidString).png")
        for url in [stale, fresh, malformed, wrongExtension] {
            try Data([0x47, 0x49, 0x46]).write(to: url)
        }
        try fileManager.setAttributes(
            [.modificationDate: now.addingTimeInterval(-(25 * 60 * 60))],
            ofItemAtPath: stale.path
        )
        try fileManager.setAttributes(
            [.modificationDate: now.addingTimeInterval(-(23 * 60 * 60))],
            ofItemAtPath: fresh.path
        )
        try fileManager.setAttributes(
            [.modificationDate: now.addingTimeInterval(-(48 * 60 * 60))],
            ofItemAtPath: malformed.path
        )
        try fileManager.setAttributes(
            [.modificationDate: now.addingTimeInterval(-(48 * 60 * 60))],
            ofItemAtPath: wrongExtension.path
        )

        let removed = AnimatedShareExporter.removeStaleTemporaryFiles(
            in: directory,
            now: now,
            olderThan: 24 * 60 * 60,
            fileManager: fileManager
        )

        #expect(removed.count == 1)
        #expect(removed.first?.lastPathComponent == stale.lastPathComponent)
        #expect(!fileManager.fileExists(atPath: stale.path))
        #expect(fileManager.fileExists(atPath: fresh.path))
        #expect(fileManager.fileExists(atPath: malformed.path))
        #expect(fileManager.fileExists(atPath: wrongExtension.path))
    }

    @Test func temporaryOwnershipRequiresPrefixUUIDAndGIFExtension() {
        let directory = FileManager.default.temporaryDirectory
        let owned = directory.appendingPathComponent("pomogem-share-\(UUID().uuidString).gif")
        let malformed = directory.appendingPathComponent("pomogem-share-anything.gif")
        let wrongPrefix = directory.appendingPathComponent("other-\(UUID().uuidString).gif")
        let wrongExtension = directory.appendingPathComponent("pomogem-share-\(UUID().uuidString).png")

        #expect(AnimatedShareExporter.isOwnedTemporaryGIF(owned))
        #expect(!AnimatedShareExporter.isOwnedTemporaryGIF(malformed))
        #expect(!AnimatedShareExporter.isOwnedTemporaryGIF(wrongPrefix))
        #expect(!AnimatedShareExporter.isOwnedTemporaryGIF(wrongExtension))
    }

    private func makeFrame(red: CGFloat, green: CGFloat, blue: CGFloat) throws -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try #require(
            CGContext(
                data: nil,
                width: 8,
                height: 8,
                bitsPerComponent: 8,
                bytesPerRow: 8 * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        context.setFillColor(red: red, green: green, blue: blue, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        return try #require(context.makeImage())
    }
}

/// Produces inspectable, real share media from the production SwiftUI card.
/// Attachments can be exported from the xcresult without adding sample media
/// to the shipping bundle or teaching the app a QA-only persistence path.
@MainActor
final class ShareVisualQAArtifactTests: XCTestCase {
    func testExportsFeedStoryAndAnimatedGIFArtifacts() throws {
        let startedAt = ContinuousClock.now
        let feed = try render(
            format: .feed,
            phase: 0.25,
            scale: 1.5,
            usesAnimatedArtwork: false
        )
        print("SHARE_QA feed_elapsed=\(startedAt.duration(to: .now))")
        let story = try render(
            format: .story,
            phase: 0.25,
            scale: 1.5,
            usesAnimatedArtwork: false
        )
        print("SHARE_QA story_elapsed=\(startedAt.duration(to: .now))")

        XCTAssertEqual(feed.cgImage?.width, 540)
        XCTAssertEqual(feed.cgImage?.height, 675)
        XCTAssertEqual(story.cgImage?.width, 540)
        XCTAssertEqual(story.cgImage?.height, 960)
        attach(feed, named: "PomoGem Share 4x5 Aurora.png")
        attach(story, named: "PomoGem Share 9x16 Aurora.png")
        print("SHARE_QA png_attachments_elapsed=\(startedAt.duration(to: .now))")

        let gifURL = AnimatedShareExporter.makeTemporaryURL()
        defer { try? FileManager.default.removeItem(at: gifURL) }
        let writer = try AnimatedShareExporter.Writer(
            url: gifURL,
            frameCount: AnimatedShareExporter.frameCount
        )
        let gifStartedAt = ContinuousClock.now
        let poses = try (0..<AnimatedShareExporter.renderedPoseCount).map { index in
            let phase = Double(index) / Double(AnimatedShareExporter.renderedPoseCount)
            let image = try XCTUnwrap(render(
                format: .story,
                phase: phase,
                scale: 1.25,
                usesAnimatedArtwork: true
            ).cgImage)
            print("SHARE_QA pose=\(index) elapsed=\(startedAt.duration(to: .now))")
            return image
        }
        XCTAssertEqual(Set(poses.map(imageDigest)).count, AnimatedShareExporter.renderedPoseCount)
        var frames: [CGImage] = []
        for poseIndex in 0..<AnimatedShareExporter.renderedPoseCount {
            let pose = poses[poseIndex]
            let nextPose = poses[(poseIndex + 1) % AnimatedShareExporter.renderedPoseCount]
            frames.append(pose)
            frames.append(try XCTUnwrap(AnimatedShareExporter.intermediateFrame(
                from: pose,
                to: nextPose
            )))
        }
        XCTAssertEqual(frames.count, AnimatedShareExporter.frameCount)
        XCTAssertEqual(Set(frames.map(imageDigest)).count, AnimatedShareExporter.frameCount)
        for frame in frames {
            try writer.add(frame)
        }
        try writer.finalize()

        let inspection = AnimatedShareExporter.debugInspection(at: gifURL)
        XCTAssertTrue(inspection.isValidExport)
        XCTAssertLessThanOrEqual(inspection.byteCount, AnimatedShareExporter.maximumShareBytes)
        let gifElapsed = gifStartedAt.duration(to: .now)
        let totalElapsed = startedAt.duration(to: .now)
        print("SHARE_QA gif_elapsed=\(gifElapsed) total_elapsed=\(totalElapsed) bytes=\(inspection.byteCount)")
        XCTAssertLessThan(gifElapsed, .seconds(30))
        let gifAttachment = XCTAttachment(contentsOfFile: gifURL)
        gifAttachment.name = "PomoGem Share 9x16 Aurora.gif"
        gifAttachment.lifetime = .keepAlways
        add(gifAttachment)
    }

    private func imageDigest(_ image: CGImage) -> Int {
        guard let data = image.dataProvider?.data as Data? else { return 0 }
        return data.enumerated().reduce(2_166_136_261) { hash, item in
            // Sample every 997th byte: enough to prove poses differ without
            // hashing each full-size QA frame on the simulator main actor.
            item.offset.isMultiple(of: 997)
                ? (hash ^ Int(item.element)) &* 16_777_619
                : hash
        }
    }

    private func attach(_ image: UIImage, named name: String) {
        guard let data = image.pngData() else {
            XCTFail("Could not encode PNG attachment \(name)")
            return
        }
        let attachment = XCTAttachment(
            data: data,
            uniformTypeIdentifier: UTType.png.identifier
        )
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func render(
        format: ShareComposerView.Format,
        phase: Double,
        scale: CGFloat,
        usesAnimatedArtwork: Bool
    ) throws -> UIImage {
        let size = ShareCardLayoutPolicy.canvasSize(for: format)
        let card = ShareCardView(
            sessions: sessions,
            aggregates: [],
            achievements: achievements,
            includesSelfReportedFocus: false,
            format: format,
            jarSnapshot: nil,
            periodLabel: "これまで",
            hashtags: ShareCopy.hashtags,
            usesAnimatedArtwork: usesAnimatedArtwork,
            animationPhase: phase
        )
        .frame(width: size.width, height: size.height)
        let renderer = ImageRenderer(content: card)
        renderer.proposedSize = ProposedViewSize(size)
        renderer.scale = scale
        return try XCTUnwrap(renderer.uiImage)
    }

    private var sessions: [ShareSessionVisual] {
        let colors = [
            Constants.Color.english,
            Constants.Color.mathematics,
            Constants.Color.japanese,
            Constants.Color.science,
            Constants.Color.socialStudies
        ]
        return (0..<18).map { index in
            let kind: PebbleKind = switch index {
            case 16: .gold
            case 17: .prism
            default: .normal
            }
            let rewards: RareRewardCounts = switch index {
            case 16: RareRewardCounts(drawCount: 2, goldCount: 1, prismCount: 0)
            case 17: RareRewardCounts(drawCount: 3, goldCount: 1, prismCount: 1)
            default: RareRewardCounts(drawCount: 1, goldCount: 0, prismCount: 0)
            }
            return ShareSessionVisual(
                id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index + 1))!,
                grams: index.isMultiple(of: 7) ? 600 : 250,
                source: .timer,
                kind: kind,
                rewardCounts: rewards,
                colorHex: colors[index % colors.count],
                endAt: Date(timeIntervalSinceReferenceDate: Double(index * 1_500))
            )
        }
    }

    private var achievements: [ShareAchievementVisual] {
        [
            ShareAchievementVisual(
                id: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
                kind: .perfectScore,
                colorHex: Constants.Color.mathematics
            ),
            ShareAchievementVisual(
                id: UUID(uuidString: "10000000-0000-0000-0000-000000000002")!,
                kind: .examPass,
                colorHex: Constants.Color.science
            )
        ]
    }
}
