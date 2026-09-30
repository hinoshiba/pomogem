import XCTest

/// Proves the complete real-file share lease on a Debug iPhone simulator:
/// an 8-frame GIF is generated, mounted in `UIActivityViewController`, then
/// removed after the user cancels that system sheet.
@MainActor
final class GIFShareLifecycleUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        executionTimeAllowance = 180
        app = XCUIApplication()
        app.launchEnvironment["POMOGEM_LOCAL_PREVIEW"] = "1"
        app.launchEnvironment["POMOGEM_UI_TEST_MODE"] = "1"
        PomoGemUITestLanguage.configureJapanese(app)
        app.launch()
        XCTAssertTrue(app.buttons["メニュー"].waitForExistence(timeout: 8))
    }

    func testRealGIFSystemShareCancelRemovesTemporaryFile() {
        addShareableSession()
        openMenuAction(containing: "動く瓶をシェア")
        XCTAssertTrue(app.navigationBars["カードにする"].waitForExistence(timeout: 8))
        includeSelfReportedDirectlyIfOffered()
        configureSingleCustomHashtag("DeepFocus_2026")

        let share = app.descendants(matching: .any)["share.primary-action"]
        XCTAssertTrue(share.waitForExistence(timeout: 8))
        enableSelfReportedSessionIfNeeded(for: share)
        XCTAssertTrue(waitUntilEnabled(share, timeout: 12))
        share.tap()

        // Once UIKit hands the controller to the system share service, iOS
        // exposes the real remote hierarchy as ActivityListView.
        let systemSheet = app.otherElements["ActivityListView"]
        XCTAssertTrue(
            systemSheet.waitForExistence(timeout: 60),
            "The generated GIF must reach a real UIActivityViewController"
        )
        let presentedAttachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        presentedAttachment.name = "Real GIF in system share sheet"
        presentedAttachment.lifetime = .keepAlways
        add(presentedAttachment)

        cancelSystemShareSheet(systemSheet)

        // The status element already shows the preparation message behind
        // the sheet, so wait for the cancellation text rather than for the
        // element to exist.
        let status = app.staticTexts["share.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 12))
        XCTAssertTrue(
            waitForLabel(
                status,
                equalTo: "共有はキャンセルされました。カードはこの画面に残っています。",
                timeout: 12
            ),
            status.label
        )

        let probe = app.staticTexts["share.debug.gif-lifecycle"]
        XCTAssertTrue(probe.waitForExistence(timeout: 8))
        XCTAssertTrue(
            waitForProbeCleanup(probe, timeout: 12),
            "Expected valid generated GIF and deletion after cancellation; value=\(String(describing: probe.value))"
        )

        let fields = parseProbe(probe.value as? String ?? "")
        XCTAssertEqual(fields["prepared"], "1")
        XCTAssertEqual(fields["valid"], "1")
        XCTAssertEqual(fields["owned"], "1")
        XCTAssertEqual(fields["gif"], "1")
        XCTAssertEqual(fields["frames"], "8")
        XCTAssertGreaterThan(Int(fields["bytes"] ?? "0") ?? 0, 0)
        XCTAssertEqual(fields["controller"], "1")
        XCTAssertEqual(fields["cleanup"], "1")
        XCTAssertEqual(fields["existsAfter"], "0")
        XCTAssertEqual(fields["hashtags"], "#DeepFocus_2026")
        XCTAssertEqual(
            fields["captionTagsExact"],
            "1",
            "The preview/export snapshot and shared caption must use the exact current tag selection"
        )
        XCTAssertEqual(
            fields["captionURLExact"],
            "1",
            "The shared caption must carry exactly one canonical product URL"
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["share.primary-action"].exists,
            "Cancelling must keep the share composer reversible"
        )
    }

    func testCopyCTAAndSuccessfulShareCompletionRemainIndependentControls() {
        addShareableSession()
        openMenuAction(containing: "動く瓶をシェア")
        XCTAssertTrue(app.navigationBars["カードにする"].waitForExistence(timeout: 8))
        includeSelfReportedDirectlyIfOffered()
        expandAdjustmentsIfNeeded()

        let stillImage = app.buttons["静止画"]
        XCTAssertTrue(stillImage.waitForExistence(timeout: 5))
        let primaryShare = app.descendants(matching: .any)["share.primary-action"]
        XCTAssertTrue(primaryShare.waitForExistence(timeout: 5))
        // Tap the segment where it is whole, above the pinned action bar.
        app.swipeUp()
        XCTAssertTrue(
            scrollUntilHittable(stillImage, avoiding: shareActionBar),
            "The still-image segment must be visible above the persistent share CTA"
        )
        XCTAssertFalse(
            stillImage.frame.intersects(primaryShare.frame),
            "The persistent share CTA must not intercept the still-image selection"
        )
        stillImage.tap()
        XCTAssertTrue(
            waitUntilSelected(stillImage, timeout: 5),
            "The still-image selection must settle before exercising the copy CTA"
        )

        let copyCaption = app.buttons["share.copy-caption"]
        XCTAssertTrue(
            scrollUntilHittable(copyCaption, avoiding: shareActionBar),
            "The copy CTA must remain independently discoverable and hittable"
        )
        XCTAssertTrue(copyCaption.isHittable)
        XCTAssertEqual(copyCaption.label, "本文とハッシュタグをコピー")
        copyCaption.tap()

        let copiedStatus = app.staticTexts["share.status"]
        XCTAssertTrue(copiedStatus.waitForExistence(timeout: 5))
        XCTAssertEqual(copiedStatus.label, "本文とハッシュタグをコピーしました。")

        let share = app.descendants(matching: .any)["share.primary-action"]
        XCTAssertTrue(scrollUntilHittable(share))
        enableSelfReportedSessionIfNeeded(for: share)
        XCTAssertTrue(waitUntilEnabled(share, timeout: 12))
        share.tap()

        let systemSheet = app.otherElements["ActivityListView"]
        XCTAssertTrue(
            systemSheet.waitForExistence(timeout: 30),
            "The still image must reach a real UIActivityViewController"
        )
        // Scope the localized action query to the remote share hierarchy. The
        // composer underneath also owns a copy icon, so an app-wide query can
        // accidentally tap that obscured element instead of UIActivityViewController.
        let systemCopy = systemSheet.cells.matching(
            NSPredicate(
                format: "identifier == %@ AND label == %@",
                "actionGroupCell",
                "コピー"
            )
        ).firstMatch
        XCTAssertTrue(
            systemCopy.waitForExistence(timeout: 8),
            "The system Copy activity must be available to complete sharing"
        )
        XCTAssertTrue(systemCopy.isHittable)
        systemCopy.tap()

        let successMessage = app.descendants(matching: .any)["share.success.message"]
        XCTAssertTrue(successMessage.waitForExistence(timeout: 12))
        XCTAssertEqual(successMessage.label, "共有できました。次の集中も、また一粒ずつ。")

        let done = app.buttons["share.success.done"]
        XCTAssertTrue(
            scrollUntilHittable(done),
            "The success banner completion CTA must be independently hittable"
        )
        XCTAssertTrue(done.isHittable)
        XCTAssertEqual(done.label, "共有を完了して閉じる")
        done.tap()

        XCTAssertTrue(app.buttons["メニュー"].waitForExistence(timeout: 8))
        XCTAssertTrue(
            waitForNonExistence(app.navigationBars["カードにする"], timeout: 5),
            "Completing the share must dismiss the composer"
        )
    }

    func testBrandAndWebsiteRemainPermanentShareAttribution() {
        addShareableSession()
        openMenuAction(containing: "動く瓶をシェア")
        XCTAssertTrue(app.navigationBars["カードにする"].waitForExistence(timeout: 8))
        includeSelfReportedDirectlyIfOffered()

        let card = app.descendants(matching: .any)["share.card"]
        XCTAssertTrue(card.waitForExistence(timeout: 8))
        XCTAssertTrue(card.label.contains("ポモジェムシェアカード"), card.label)
        XCTAssertTrue(card.label.contains("pomogem.hinoshiba.com"), card.label)

        expandAdjustmentsIfNeeded()
        let branding = app.descendants(matching: .any)["share.branding"]
        XCTAssertTrue(
            scrollUntilHittable(branding),
            "Permanent share attribution must be disclosed in the composer"
        )
        XCTAssertTrue(branding.label.contains("ポモジェムロゴと公式サイト"), branding.label)
        XCTAssertTrue(branding.label.contains("常に表示"), branding.label)
        XCTAssertFalse(app.buttons["share.watermark-pro"].exists)
    }

    func testManualOnlyShareExplainsTheExcludedParticleAndOffersDirectInclusion() {
        addShareableSession()
        openMenuAction(containing: "動く瓶をシェア")
        XCTAssertTrue(app.navigationBars["カードにする"].waitForExistence(timeout: 8))

        let summary = app.descendants(matching: .any)["share.settings-summary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 8))
        XCTAssertEqual(
            summary.label,
            "現在の共有設定、GIF・4:5・実測のみ（自己申告は除外）・タグ2個"
        )

        XCTAssertFalse(
            app.buttons["静止画"].exists,
            "Advanced media decisions must stay collapsed until the user asks to adjust them"
        )
        XCTAssertFalse(app.segmentedControls["share.format"].exists)
        XCTAssertFalse(app.textFields["share.custom-hashtag"].exists)
        XCTAssertFalse(app.buttons["share.watermark-pro"].exists)
        XCTAssertFalse(app.buttons["写真に2サイズ保存"].exists)
        XCTAssertTrue(app.buttons["調整"].exists)
        XCTAssertTrue(app.staticTexts["自己申告の粒があります"].waitForExistence(timeout: 5))
        XCTAssertFalse(
            app.buttons["最初の一粒へ"].exists,
            "A manual-only bottle must not be misrepresented as having no particle"
        )
        let collapsedAttachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        collapsedAttachment.name = "Manual-only share — collapsed decisions and direct inclusion"
        collapsedAttachment.lifetime = .keepAlways
        add(collapsedAttachment)

        let includeDirectly = app.buttons["share.include-self-reported-direct"]
        XCTAssertTrue(includeDirectly.waitForExistence(timeout: 5))
        XCTAssertTrue(scrollUntilHittable(includeDirectly))
        includeDirectly.tap()

        let share = app.descendants(matching: .any)["share.primary-action"]
        XCTAssertTrue(waitUntilEnabled(share, timeout: 12))
        XCTAssertTrue(
            waitForLabel(
                summary,
                equalTo: "現在の共有設定、GIF・4:5・自己申告あり・タグ2個",
                timeout: 8
            )
        )
        let includedAttachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        includedAttachment.name = "Manual-only share — included preview and truthful summary"
        includedAttachment.lifetime = .keepAlways
        add(includedAttachment)

        share.tap()
        let systemSheet = app.otherElements["ActivityListView"]
        XCTAssertTrue(
            systemSheet.waitForExistence(timeout: 60),
            "Direct self-reported inclusion must continue to the real system share sheet"
        )
        cancelSystemShareSheet(systemSheet)
        let status = app.staticTexts["share.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 8))
        XCTAssertTrue(
            waitForLabel(
                status,
                equalTo: "共有はキャンセルされました。カードはこの画面に残っています。",
                timeout: 12
            ),
            status.label
        )
    }

    /// device-verify-2 P5. The pinned シェア button used to be a safe-area
    /// inset over the scroll view: the scroll view ran on under the bar, so
    /// on first appearance 「調整」 lay under the button, readable through
    /// its material, and a tap there started the share. The bar now sits
    /// below the scroll view, which ends at the bar's top edge: a row is cut
    /// off there, never drawn under the button, and a tap on what shows of
    /// it opens it.
    func testAdjustmentsTappedWhereTheyFirstAppearOpenWithoutStartingTheShare() {
        addShareableSession()
        openMenuAction(containing: "動く瓶をシェア")
        XCTAssertTrue(app.navigationBars["カードにする"].waitForExistence(timeout: 8))
        includeSelfReportedDirectlyIfOffered()
        for _ in 0..<3 { app.swipeDown(velocity: .slow) }

        let share = app.descendants(matching: .any)["share.primary-action"]
        XCTAssertTrue(waitUntilEnabled(share, timeout: 12), "A mis-tap on the bar would start the share")
        let adjustments = app.buttons["調整"]
        XCTAssertTrue(adjustments.waitForExistence(timeout: 8))
        XCTAssertTrue(shareActionBar.exists)
        let content = app.scrollViews.containing(NSPredicate(format: "label == %@", "調整")).firstMatch
        XCTAssertTrue(content.exists)
        XCTAssertLessThanOrEqual(
            content.frame.maxY, shareActionBar.frame.minY + 1,
            "The composer's content must end at the pinned bar, not run on under it"
        )
        saveScreenshot("share-first-appearance")

        // Tap what a person sees of the row: its part above the bar. XCTest
        // aims at an element's centre even when the scroll view cuts it off,
        // and a row wholly below the fold is scrolled into view first.
        let barTop = shareActionBar.frame.minY
        var row = adjustments.frame
        if row.maxY > barTop, row.minY >= barTop - 12 {
            // Only a sliver shows: bring the row up the way a person would.
            app.swipeUp(velocity: .slow)
            row = adjustments.frame
        }
        if row.maxY > barTop, row.minY < barTop - 12 {
            let visibleMidY = (row.minY + barTop) / 2
            app.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: row.midX, dy: visibleMidY))
                .tap()
        } else {
            adjustments.tap()
        }
        XCTAssertTrue(
            app.buttons["静止画"].waitForExistence(timeout: 5),
            "Tapping 「調整」 must open the adjustments"
        )
        XCTAssertFalse(
            app.otherElements["ActivityListView"].waitForExistence(timeout: 3),
            "Tapping 「調整」 must not start the share"
        )
    }

    /// device-verify-2 P3. After 「写真に2サイズ保存」 the result line sat at
    /// the end of the scrolled content: under the pinned シェア button, or
    /// above the screen once scrolled back up, so the save seemed to do
    /// nothing. It is now in the pinned bar, on screen wherever the content
    /// is scrolled.
    func testPhotoSaveOutcomeStaysOnScreenAboveTheShareButton() {
        addShareableSession()
        openMenuAction(containing: "動く瓶をシェア")
        XCTAssertTrue(app.navigationBars["カードにする"].waitForExistence(timeout: 8))
        includeSelfReportedDirectlyIfOffered()
        expandAdjustmentsIfNeeded()

        // Two stills render faster than two GIFs; the outcome line is shared.
        let stillImage = app.buttons["静止画"]
        XCTAssertTrue(scrollUntilHittable(stillImage, avoiding: shareActionBar))
        stillImage.tap()
        let save = app.buttons["写真に2サイズ保存"]
        XCTAssertTrue(scrollUntilHittable(save, avoiding: shareActionBar))
        save.tap()

        // Photos asks once per install; answer it when it comes.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let status = app.staticTexts["share.status"]
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            let alert = springboard.alerts.firstMatch
            if alert.exists {
                let allow = alert.buttons.matching(NSPredicate(
                    format: "(label BEGINSWITH %@ AND NOT (label CONTAINS %@)) OR label ==[c] %@",
                    "許可", "しない", "allow"
                )).firstMatch
                XCTAssertTrue(allow.exists, "The Photos prompt must offer 許可: \(alert.buttons.allElementsBoundByIndex.map(\.label))")
                allow.tap()
                break
            }
            if status.exists, status.label.contains("写真に保存") { break }
            pause(0.5)
        }
        XCTAssertTrue(
            waitForLabel(status, containing: "フィード用とストーリー用を写真に保存しました", timeout: 60),
            "status=\(status.exists ? status.label : "<absent>")"
        )
        assertOnScreenInTheActionBar(status)
        saveScreenshot("share-photo-save-outcome")

        // Scrolled back to the top, the outcome is still on screen.
        for _ in 0..<4 { app.swipeDown() }
        assertOnScreenInTheActionBar(status)
        saveScreenshot("share-photo-save-outcome-scrolled-top")
    }

    /// Review of #58. The outcome stays above the シェア button until the
    /// next action, so it used to shorten the preview for good. An edit
    /// starts a new card: it clears the line and gives the room back.
    func testAnEditClearsTheLastOutcomeFromTheBar() {
        addShareableSession()
        openMenuAction(containing: "動く瓶をシェア")
        XCTAssertTrue(app.navigationBars["カードにする"].waitForExistence(timeout: 8))
        includeSelfReportedDirectlyIfOffered()
        expandAdjustmentsIfNeeded()

        let status = copyCaptionAndWaitForTheOutcome()
        assertOnScreenInTheActionBar(status)
        let barWithOutcome = shareActionBar.frame.height
        let statusHeight = status.frame.height

        tapHashtagChip("#ポモドーロ")
        XCTAssertTrue(waitForNonExistence(status, timeout: 5), "An edit clears the last outcome")
        let barWithout = shareActionBar.frame.height
        XCTAssertLessThan(barWithout, barWithOutcome, "The preview gets its room back")
        // The one-line outcome took its own height (and the 8 pt above the
        // button), not a fixed box around it.
        XCTAssertLessThanOrEqual(barWithOutcome - barWithout, statusHeight + 12,
                                 "outcome \(statusHeight) pt grew the bar by \(barWithOutcome - barWithout) pt")
    }

    /// Review of #58. At accessibility sizes only the シェア button stays
    /// capped (AX2); the outcome above it is read at the person's own size,
    /// scrolling inside a bounded height when it is long, so the bar still
    /// leaves the preview most of the screen.
    func testAtAccessibility5TheOutcomeKeepsItsSizeAndTheBarStaysBounded() {
        app.terminate()
        app.launchEnvironment["POMOGEM_UI_TEST_AX5"] = "1"
        app.launch()
        XCTAssertTrue(app.buttons["メニュー"].waitForExistence(timeout: 8))
        addShareableSession()
        openMenuAction(containing: "動く瓶をシェア")
        XCTAssertTrue(app.navigationBars["カードにする"].waitForExistence(timeout: 8))
        includeSelfReportedDirectlyIfOffered()
        expandAdjustmentsIfNeeded()

        let status = copyCaptionAndWaitForTheOutcome()
        assertOnScreenInTheActionBar(status)
        let window = app.windows.firstMatch.frame
        XCTAssertLessThanOrEqual(shareActionBar.frame.height, window.height / 2,
                                 "bar=\(shareActionBar.frame) window=\(window)")
        saveScreenshot("share-outcome-ax5")

        tapHashtagChip("#ポモドーロ")
        XCTAssertTrue(waitForNonExistence(status, timeout: 5), "An edit clears the last outcome")
        saveScreenshot("share-outcome-cleared-ax5")
    }

    private func copyCaptionAndWaitForTheOutcome() -> XCUIElement {
        let copyCaption = app.buttons["share.copy-caption"]
        XCTAssertTrue(scrollUntilHittable(copyCaption, avoiding: shareActionBar))
        copyCaption.tap()
        let status = app.staticTexts["share.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertTrue(status.label.contains("コピーしました"), status.label)
        return status
    }

    private func tapHashtagChip(_ label: String) {
        let chip = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", label)).firstMatch
        XCTAssertTrue(scrollUntilHittable(chip, avoiding: shareActionBar), "Missing hashtag chip: \(label)")
        let wasSelected = chip.isSelected
        chip.tap()
        let toggled = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "selected == %@", NSNumber(value: !wasSelected)),
            object: chip
        )
        XCTAssertEqual(XCTWaiter.wait(for: [toggled], timeout: 3), .completed, "The chip must toggle: \(label)")
    }

    private func assertOnScreenInTheActionBar(
        _ element: XCUIElement,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let window = app.windows.firstMatch.frame
        XCTAssertTrue(element.exists, file: file, line: line)
        XCTAssertTrue(element.isHittable, "The outcome line must be visible", file: file, line: line)
        XCTAssertGreaterThanOrEqual(element.frame.minY, shareActionBar.frame.minY, file: file, line: line)
        XCTAssertLessThanOrEqual(element.frame.maxY, min(shareActionBar.frame.maxY, window.maxY), file: file, line: line)
        let share = app.descendants(matching: .any)["share.primary-action"]
        XCTAssertLessThanOrEqual(element.frame.maxY, share.frame.minY,
                                 "The outcome line sits above the button", file: file, line: line)
    }

    private func pause(_ seconds: TimeInterval) {
        let idle = XCTestExpectation(description: "pause")
        idle.isInverted = true
        _ = XCTWaiter.wait(for: [idle], timeout: seconds)
    }

    /// Keeps a screenshot with the result bundle and, when the runner is
    /// given POMOGEM_SHOTS_DIR, also as a PNG for review.
    private func saveScreenshot(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let directory = ProcessInfo.processInfo.environment["POMOGEM_SHOTS_DIR"] else { return }
        let url = URL(fileURLWithPath: directory).appendingPathComponent("\(name).png")
        try? screenshot.pngRepresentation.write(to: url)
    }

    /// walk-std-04 / walk-edge-08: a month holding only self-reported focus
    /// and a 記念石, opened from its Wrapped screen, must explain the excluded
    /// time in 分 and offer to include it next to the card, not read as an
    /// unexplained 0g.
    func testWrappedMonthWithSelfReportedFocusAndAStoneExplainsAndIncludesTheTime() {
        addShareableSession()
        addExamPassStone()

        openMenuAction(containing: "記録を見る")
        XCTAssertTrue(app.navigationBars["記録"].waitForExistence(timeout: 6))
        let monthRow = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", currentMonthTitle())
        ).firstMatch
        XCTAssertTrue(scrollUntilHittable(monthRow), "The month must be listed under 月の振り返り")
        XCTAssertTrue(monthRow.label.contains("30分・1粒"), monthRow.label)
        XCTAssertFalse(monthRow.label.contains("30m"), monthRow.label)
        attachScreenshot(named: "Log — month row in 分")
        monthRow.tap()

        let note = app.descendants(matching: .any)["wrapped.self-reported-note"]
        XCTAssertTrue(note.waitForExistence(timeout: 8))
        XCTAssertEqual(note.label, "時間と粒には、自己申告の記録も含みます。")
        attachScreenshot(named: "Wrapped — totals say they include self-reported time")
        let makeCard = app.buttons["この月の瓶をカードにする"]
        XCTAssertTrue(scrollUntilHittable(makeCard))
        makeCard.tap()

        XCTAssertTrue(app.navigationBars["カードにする"].waitForExistence(timeout: 8))
        let summary = app.descendants(matching: .any)["share.settings-summary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 8))
        XCTAssertEqual(
            summary.label,
            "現在の共有設定、GIF・4:5・実測のみ（自己申告は除外）・記念石は自己申告・タグ2個"
        )
        let card = app.descendants(matching: .any)["share.card"]
        XCTAssertTrue(card.waitForExistence(timeout: 8))
        XCTAssertTrue(card.label.contains("瓶に積んだ集中、0グラム。"), card.label)
        let notice = app.descendants(matching: .any)["share.excluded-self-reported"]
        XCTAssertTrue(notice.waitForExistence(timeout: 5))
        XCTAssertEqual(notice.label, "自己申告の30分は、カードに含めていません。")
        attachScreenshot(named: "Share — stone-only month explains the excluded 30分")

        let include = app.buttons["share.include-self-reported-inline"]
        XCTAssertTrue(scrollUntilHittable(include))
        include.tap()
        XCTAssertTrue(
            waitForLabel(
                summary,
                equalTo: "現在の共有設定、GIF・4:5・自己申告あり・記念石は自己申告・タグ2個",
                timeout: 8
            )
        )
        XCTAssertTrue(
            waitForLabel(card, containing: "瓶に積んだ集中、300グラム、30分。", timeout: 8),
            card.label
        )
        XCTAssertTrue(waitForNonExistence(notice, timeout: 5))
        attachScreenshot(named: "Share — included card states 300g and 30分")
    }

    /// history-10: typing a tag must reuse the resolved card instead of
    /// re-reading every record; study tags are offered but stay opt-in.
    func testTypingATagReusesTheResolvedCardAndStudyTagsStayOptional() {
        addShareableSession()
        openMenuAction(containing: "動く瓶をシェア")
        XCTAssertTrue(app.navigationBars["カードにする"].waitForExistence(timeout: 8))
        includeSelfReportedDirectlyIfOffered()
        expandAdjustmentsIfNeeded()
        app.swipeUp()

        for tag in ["#勉強記録", "#勉強垢"] {
            let chip = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", tag)).firstMatch
            XCTAssertTrue(chip.waitForExistence(timeout: 5), "Missing suggested tag \(tag)")
            XCTAssertFalse(chip.isSelected, "\(tag) must be offered unselected")
        }

        let probe = app.staticTexts["share.debug.selection"]
        XCTAssertTrue(probe.waitForExistence(timeout: 5))
        let before = parseProbe(probe.value as? String ?? "")

        let custom = app.textFields["share.custom-hashtag"]
        XCTAssertTrue(scrollUntilHittable(custom))
        app.swipeUp()
        XCTAssertTrue(scrollUntilHittable(custom))
        custom.tap()
        custom.typeText("FocusLog")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)).tap()
        XCTAssertTrue(
            app.staticTexts["選択中：#ポモジェム #ポモドーロ #FocusLog"].waitForExistence(timeout: 5)
        )

        let after = parseProbe(probe.value as? String ?? "")
        XCTAssertEqual(
            after["builds"],
            before["builds"],
            "Typing must not re-resolve the card's records; before=\(before) after=\(after)"
        )
        XCTAssertGreaterThan(
            Int(after["lookups"] ?? "0") ?? 0,
            Int(before["lookups"] ?? "0") ?? 0,
            "The composer must have redrawn while typing"
        )

        let studyTag = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "#勉強記録")).firstMatch
        XCTAssertTrue(scrollUntilHittable(studyTag))
        studyTag.tap()
        XCTAssertTrue(
            app.staticTexts["選択中：#ポモジェム #ポモドーロ #勉強記録 #FocusLog"]
                .waitForExistence(timeout: 5)
        )
        attachScreenshot(named: "Share — suggested study tags and a custom tag")
    }

    /// The excluded-time notice, the two-part scope summary and the Log's
    /// time tile must stay whole and reachable at the largest text size.
    func testExcludedTimeNoticeAndLogTimeStayReadableAtAccessibilitySizes() {
        app.terminate()
        app.launchEnvironment["POMOGEM_UI_TEST_AX5"] = "1"
        app.launch()
        XCTAssertTrue(app.buttons["メニュー"].waitForExistence(timeout: 8))
        addShareableSession()
        addExamPassStone()

        openMenuAction(containing: "動く瓶をシェア")
        XCTAssertTrue(app.navigationBars["カードにする"].waitForExistence(timeout: 8))
        let notice = app.descendants(matching: .any)["share.excluded-self-reported"]
        XCTAssertTrue(notice.waitForExistence(timeout: 8))
        XCTAssertTrue(scrollUntilHittable(notice))
        attachScreenshot(named: "AX5 Share — excluded-time notice")
        let include = app.buttons["share.include-self-reported-inline"]
        XCTAssertTrue(scrollUntilHittable(include), "The inline include button must be reachable at AX5")
        let summary = app.descendants(matching: .any)["share.settings-summary"]
        XCTAssertTrue(scrollUntilHittable(summary))
        XCTAssertTrue(summary.label.hasSuffix("・記念石は自己申告・タグ2個"), summary.label)
        attachScreenshot(named: "AX5 Share — two-part scope summary")
        // The summary check scrolled on. At AX5 on a 4.7-inch iPhone the
        // inline button had scrolled off the top by then and the tap missed
        // it. Bring it back, clear of the navigation bar and the pinned
        // share bar, first.
        XCTAssertTrue(scrollUntilHittable(include, avoiding: shareActionBar, searchingTowardTop: true))
        tapUntilGone(include, "Including self-reported time must retire the inline button")
        XCTAssertTrue(waitForNonExistence(notice, timeout: 8))
        app.navigationBars["カードにする"].buttons["閉じる"].tap()
        XCTAssertTrue(app.buttons["メニュー"].waitForExistence(timeout: 8))

        openMenuAction(containing: "記録を見る")
        XCTAssertTrue(app.navigationBars["記録"].waitForExistence(timeout: 6))
        let timeTile = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "30分", "積んだ時間")
        ).firstMatch
        XCTAssertTrue(scrollUntilHittable(timeTile), "The Log time tile must read 30分")
        attachScreenshot(named: "AX5 Log — time tile in 分")
    }

    private func addExamPassStone() {
        openMenuAction(containing: "成果を積む")
        XCTAssertTrue(app.navigationBars["成果を選ぶ"].waitForExistence(timeout: 5))
        let examPass = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "試験合格")
        ).firstMatch
        XCTAssertTrue(examPass.waitForExistence(timeout: 5))
        examPass.tap()
        XCTAssertTrue(app.navigationBars["記念石にする"].waitForExistence(timeout: 5))
        let save = app.buttons["この成果を積む"]
        XCTAssertTrue(scrollUntilHittable(save))
        save.tap()
        XCTAssertTrue(app.buttons["メニュー"].waitForExistence(timeout: 5))
    }

    private func currentMonthTitle() -> String {
        let parts = Calendar(identifier: .gregorian).dateComponents([.year, .month], from: .now)
        return "\(parts.year ?? 0)年\(parts.month ?? 0)月"
    }

    private func attachScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func waitForLabel(
        _ element: XCUIElement,
        containing expected: String,
        timeout: TimeInterval
    ) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", expected),
            object: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private func addShareableSession() {
        openMenuAction(containing: "時間を手動で積む")
        let thirtyMinutes = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "30分")
        ).firstMatch
        XCTAssertTrue(thirtyMinutes.waitForExistence(timeout: 5))
        thirtyMinutes.tap()
        let confirm = app.buttons["manual.confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        XCTAssertTrue(scrollUntilHittable(confirm))
        confirm.tap()
        XCTAssertTrue(app.buttons["メニュー"].waitForExistence(timeout: 5))
    }

    private func openMenuAction(containing title: String) {
        XCTAssertTrue(app.buttons["メニュー"].waitForExistence(timeout: 5))
        app.buttons["メニュー"].tap()
        let action = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", title)
        ).firstMatch
        XCTAssertTrue(bringFullyIntoView(action), "Missing menu action: \(title)")
        action.tap()
    }

    /// The Home menu is a half-height sheet whose last rows start below its
    /// edge. XCTest reports a row cut by that edge as hittable, but the tap
    /// lands in the home-indicator strip and opens nothing. Short drags (a
    /// fling can carry a row straight past) until the whole row is inside the
    /// window and below the sheet's top.
    private func bringFullyIntoView(_ element: XCUIElement, attempts: Int = 16) -> Bool {
        let window = app.windows.firstMatch.frame
        let topInset: CGFloat = 100
        for _ in 0..<attempts {
            if element.exists, element.isHittable,
               element.frame.minY >= window.minY + topInset,
               element.frame.maxY <= window.maxY { return true }
            let isAbove = element.exists && element.frame.minY < window.minY + topInset
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: isAbove ? 0.45 : 0.8))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: isAbove ? 0.75 : 0.5))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        return element.exists && element.isHittable
    }

    private func enableSelfReportedSessionIfNeeded(for shareButton: XCUIElement) {
        guard !shareButton.isEnabled else { return }
        expandAdjustmentsIfNeeded()
        // The switch follows the hashtag editor and can otherwise sit beneath
        // the fixed share CTA. Move it into the unobscured scroll region first.
        app.swipeUp()
        let includeManual = app.switches["share.include-self-reported"]
        XCTAssertTrue(
            scrollUntilHittable(includeManual),
            "The user must be able to opt a self-reported session into sharing"
        )
        if String(describing: includeManual.value ?? "") != "1" {
            includeManual.tap()
            let enabled = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "value == %@", "1"),
                object: includeManual
            )
            XCTAssertEqual(
                XCTWaiter.wait(for: [enabled], timeout: 3),
                .completed,
                "The self-reported focus switch must visibly turn on before sharing"
            )
        }
    }

    private func configureSingleCustomHashtag(_ body: String) {
        expandAdjustmentsIfNeeded()
        // The hashtag row initially overlaps the fixed share CTA. Move the
        // chips into the scroll view's unobscured region before tapping them.
        app.swipeUp()
        for label in ["#ポモジェム", "#ポモドーロ"] {
            let chip = app.buttons.matching(
                NSPredicate(format: "label CONTAINS %@", label)
            ).firstMatch
            XCTAssertTrue(scrollUntilHittable(chip), "Missing hashtag chip: \(label)")
            if chip.isSelected {
                chip.coordinate(
                    withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
                ).tap()
                let deselected = XCTNSPredicateExpectation(
                    predicate: NSPredicate(format: "selected == false"),
                    object: chip
                )
                XCTAssertEqual(
                    XCTWaiter.wait(for: [deselected], timeout: 3),
                    .completed,
                    "Hashtag chip must become deselected before composing a custom-only snapshot: \(label)"
                )
            }
        }

        let custom = app.textFields["share.custom-hashtag"]
        XCTAssertTrue(scrollUntilHittable(custom))
        // A partially clipped text field can report `isHittable` even though
        // XCTest cannot place keyboard focus at its off-screen center.
        // Move it once into the scroll view's safe visible region, then reuse
        // the bounded reachability check before typing the exact snapshot tag.
        app.swipeUp()
        XCTAssertTrue(scrollUntilHittable(custom))
        custom.tap()
        custom.typeText(body)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)).tap()
        XCTAssertTrue(
            app.staticTexts["選択中：#\(body)"].waitForExistence(timeout: 5),
            "The composer must reflect the exact custom hashtag before export"
        )
    }

    private func scrollUntilHittable(
        _ element: XCUIElement,
        attempts: Int = 8
    ) -> Bool {
        for _ in 0..<attempts {
            if element.exists, element.isHittable { return true }
            app.swipeUp()
        }
        return element.exists && element.isHittable
    }

    private func scrollUntilHittable(
        _ element: XCUIElement,
        avoiding obstruction: XCUIElement,
        searchingTowardTop: Bool = false,
        attempts: Int = 8
    ) -> Bool {
        // A fast fling can carry the element past the top, where XCTest still
        // reports it hittable under the translucent navigation bar and a tap
        // lands on the bar instead. Require it below the bar, and come back
        // down slowly when it has gone past. The obstruction is the action
        // bar pinned under the scroll view (`share.action-bar`): the scroll
        // view ends at its top edge, so an element there is cut off.
        let navigationBar = app.navigationBars.firstMatch
        func isClear() -> Bool {
            element.exists
                && obstruction.exists
                && element.isHittable
                && element.frame.maxY <= obstruction.frame.minY
                && (!navigationBar.exists || element.frame.minY >= navigationBar.frame.maxY)
        }
        for _ in 0..<attempts {
            if element.exists { _ = waitUntilFrameSettles(element, timeout: 3) }
            if isClear() { return true }
            guard element.exists, obstruction.exists else {
                // Not laid out yet: search in the given direction.
                if searchingTowardTop {
                    app.swipeDown(velocity: .slow)
                } else {
                    app.swipeUp(velocity: .slow)
                }
                continue
            }
            // Laid out but not clear: drag by the distance that is missing.
            // At AX5 on a 4.7-inch iPhone the band between the navigation
            // bar and the share bar is shorter than a slow swipe, and whole
            // swipes kept carrying the element from one side to the other.
            let top = navigationBar.exists ? navigationBar.frame.maxY : app.windows.firstMatch.frame.minY
            let bottom = obstruction.frame.minY
            let frame = element.frame
            let correction = frame.minY < top
                ? top - frame.minY + 8
                : bottom - frame.maxY - 8
            let distance = min(300, max(40, abs(correction))) * (correction < 0 ? -1 : 1)
            // Hold at the end so the list does not coast past the band.
            let start = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            start.press(
                forDuration: 0.05,
                thenDragTo: start.withOffset(CGVector(dx: 0, dy: distance)),
                withVelocity: .slow,
                thenHoldForDuration: 0.2
            )
        }
        return isClear()
    }

    /// The pinned bar under the composer's scroll view: the outcome line
    /// and the シェア button.
    private var shareActionBar: XCUIElement {
        app.descendants(matching: .any)["share.action-bar"]
    }

    private func expandAdjustmentsIfNeeded() {
        if app.buttons["静止画"].exists { return }
        let adjustments = app.buttons["調整"]
        XCTAssertTrue(adjustments.waitForExistence(timeout: 8))
        XCTAssertTrue(scrollUntilHittable(adjustments))
        adjustments.tap()
        XCTAssertTrue(
            app.buttons["静止画"].waitForExistence(timeout: 5),
            "The single adjustment disclosure must reveal all optional share decisions"
        )
    }

    private func includeSelfReportedDirectlyIfOffered() {
        let direct = app.buttons["share.include-self-reported-direct"]
        guard direct.waitForExistence(timeout: 5) else { return }
        XCTAssertTrue(scrollUntilHittable(direct))
        direct.tap()
        let share = app.descendants(matching: .any)["share.primary-action"]
        XCTAssertTrue(waitUntilEnabled(share, timeout: 12))
    }

    private func waitForLabel(
        _ element: XCUIElement,
        equalTo expected: String,
        timeout: TimeInterval
    ) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", expected),
            object: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private func waitUntilSelected(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "selected == true"),
            object: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private func waitForNonExistence(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private func cancelSystemShareSheet(_ sheet: XCUIElement) {
        XCTAssertTrue(sheet.exists)
        // This identifier belongs to the remote system share service, avoiding
        // any ambiguity with the composer's own Japanese "閉じる" button.
        let dismissButton = app.buttons["header.closeButton"]
        XCTAssertTrue(
            dismissButton.waitForExistence(timeout: 12),
            "The real system share sheet must expose its cancel control"
        )
        dismissButton.tap()
    }

    private func waitUntilEnabled(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true"),
            object: element
        )
        let result = XCTWaiter.wait(for: [expectation], timeout: timeout)
        if result != .completed {
            attachShareStateDiagnostics(primaryAction: element)
        }
        return result == .completed
    }

    private func attachShareStateDiagnostics(primaryAction: XCUIElement) {
        let includeManual = app.switches.matching(
            NSPredicate(format: "label CONTAINS %@", "自己申告を含める")
        ).firstMatch
        let firstChip = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "#ポモジェム")
        ).firstMatch
        let secondChip = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "#ポモドーロ")
        ).firstMatch
        let selectionSummary = app.staticTexts.matching(
            NSPredicate(
                format: "label BEGINSWITH %@ OR label == %@",
                "選択中：",
                "ハッシュタグなしで共有します"
            )
        ).firstMatch
        let status = app.staticTexts["share.status"]
        let custom = app.textFields["share.custom-hashtag"]

        let state = """
        switch exists=\(includeManual.exists) hittable=\(includeManual.isHittable) enabled=\(includeManual.isEnabled) value=\(String(describing: includeManual.value)) frame=\(includeManual.frame)
        primary exists=\(primaryAction.exists) hittable=\(primaryAction.isHittable) enabled=\(primaryAction.isEnabled) label=\(primaryAction.label) value=\(String(describing: primaryAction.value)) frame=\(primaryAction.frame)
        #ポモジェム selected=\(firstChip.isSelected) enabled=\(firstChip.isEnabled) hittable=\(firstChip.isHittable) frame=\(firstChip.frame)
        #ポモドーロ selected=\(secondChip.isSelected) enabled=\(secondChip.isEnabled) hittable=\(secondChip.isHittable) frame=\(secondChip.frame)
        custom value=\(String(describing: custom.value)) frame=\(custom.frame)
        summary exists=\(selectionSummary.exists) label=\(selectionSummary.label) frame=\(selectionSummary.frame)
        status exists=\(status.exists) label=\(status.label) value=\(String(describing: status.value)) frame=\(status.frame)

        AX hierarchy:
        \(app.debugDescription)
        """
        let stateAttachment = XCTAttachment(string: state)
        stateAttachment.name = "Share state and accessibility hierarchy"
        stateAttachment.lifetime = .keepAlways
        add(stateAttachment)

        let screenshotAttachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshotAttachment.name = "Share state when primary action stayed disabled"
        screenshotAttachment.lifetime = .keepAlways
        add(screenshotAttachment)
    }

    private func waitForProbeCleanup(_ probe: XCUIElement, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(
                format: "value CONTAINS %@ AND value CONTAINS %@ AND value CONTAINS %@",
                "valid=1",
                "controller=1",
                "cleanup=1;existsAfter=0"
            ),
            object: probe
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private func parseProbe(_ value: String) -> [String: String] {
        Dictionary(uniqueKeysWithValues: value.split(separator: ";").compactMap { field in
            let parts = field.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return nil }
            return (parts[0], parts[1])
        })
    }
}
