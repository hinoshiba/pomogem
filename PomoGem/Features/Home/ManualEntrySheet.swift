import SwiftUI

/// 「時間を手動で積む」: a self-reported block of focus, saved only after an
/// explicit confirmation and counted against the per-device daily allowance.
///
/// The sheet owns its theme choice (Home's selection is only the starting
/// point) and keeps 「確認して積む」 pinned above the home indicator once a
/// duration is chosen, so the commit button is reachable without scrolling at
/// every text size and on the smallest phones.
struct ManualEntrySheet: View {
    let subjects: [Subject]
    let counterState: ManualCounterState
    /// Returns nil once saved (Home then closes the sheet), otherwise the
    /// reason, shown beside the button.
    let onAdd: (Subject, ManualDuration) -> String?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.pomogemReduceMotionOverride) private var reduceMotionOverride
    @State private var selectedSubjectID: UUID?
    @State private var selectedDuration: ManualDuration?
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @AccessibilityFocusState private var confirmationHeadingIsFocused: Bool

    private static let confirmationCardID = "manual.confirmation-card"

    init(
        initialSubject: Subject?,
        subjects: [Subject],
        counterState: ManualCounterState,
        onAdd: @escaping (Subject, ManualDuration) -> String?
    ) {
        self.subjects = subjects
        self.counterState = counterState
        self.onAdd = onAdd
        _selectedSubjectID = State(
            initialValue: ThemeSelectionMenu.initialID(for: initialSubject, in: subjects)
        )
    }

    private var reduceMotion: Bool {
        reduceMotionOverride ?? systemReduceMotion
    }

    private var selectedSubject: Subject? {
        subjects.first { $0.id == selectedSubjectID }
    }

    var body: some View {
        TimelineView(.everyMinute) { context in
            content(at: context.date)
        }
    }

    private func content(at date: Date) -> some View {
        let availability = FairnessPolicy.manualEntryAvailability(
            state: counterState,
            at: date
        )

        return NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        header
                        ThemeSelectionMenu(
                            subjects: subjects,
                            selectedID: $selectedSubjectID,
                            accessibilityHint: String(
                                localized: "積むテーマを変更できます。ホームで選んでいるテーマは変わりません",
                                table: "Home",
                                comment: "VoiceOver hint of the manual-entry sheet's theme menu"
                            ),
                            accessibilityIdentifier: "manual.subject-picker"
                        )
                        remainingCount(availability)
                        durationButtons(isEnabled: availability.isAllowed && selectedSubject != nil)
                        if let selectedDuration, availability.isAllowed {
                            confirmationCard(
                                duration: selectedDuration,
                                availability: availability
                            )
                            .id(Self.confirmationCardID)
                        }
                        fairnessCopy
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
                }
                .scrollBounceBehavior(.basedOnSize)
                .onChange(of: selectedDuration) { _, duration in
                    errorMessage = nil
                    guard duration != nil else { return }
                    revealConfirmation(using: proxy)
                }
                .onChange(of: selectedSubjectID) { _, _ in
                    errorMessage = nil
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let selectedDuration, availability.isAllowed {
                    confirmBar(duration: selectedDuration, availability: availability)
                }
            }
            .background(NightBackground())
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    PomoGemSheetCloseButton { dismiss() }
                }
            }
        }
        .onChange(of: availability.isAllowed) { _, isAllowed in
            if !isAllowed {
                selectedDuration = nil
                isSubmitting = false
            }
        }
    }

    /// Choosing a duration only previews it. Bring the summary into view and
    /// move VoiceOver there so the second step is never silently off-screen.
    private func revealConfirmation(using proxy: ScrollViewProxy) {
        Task { @MainActor in
            // Let the card join the layout before scrolling to it.
            await Task.yield()
            withAnimation(reduceMotion ? nil : .snappy) {
                proxy.scrollTo(Self.confirmationCardID, anchor: .bottom)
            }
            confirmationHeadingIsFocused = true
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionEyebrow(text: "SELF-REPORTED")
            Text("手動で積む", tableName: "Home", comment: "Manual-entry sheet title")
                .font(PomoGemTheme.brand(26))
                .accessibilityAddTraits(.isHeader)
            Text("タイマーを使わずに集中した時間を、あとから瓶に積めます。", tableName: "Home", comment: "Manual-entry sheet introduction")
                .font(.subheadline)
                .foregroundStyle(PomoGemTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func remainingCount(_ availability: ManualEntryAvailability) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: availability.isAllowed ? "checkmark.circle.fill" : "clock.badge.xmark")
                .font(.title3)
                .foregroundStyle(availability.isAllowed ? PomoGemTheme.amber : PomoGemTheme.muted)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(
                    "この端末で本日あと\(availability.remainingEntries)回",
                    tableName: "Home",
                    comment: "Manual entry: how many self-reported entries this device can still add today"
                )
                    .font(.headline)
                    .accessibilityIdentifier("manual.remaining-count")
                Text(
                    availability.isAllowed
                        ? String(
                            localized: "時間を選ぶと、下に内容の確認が出ます。「確認して積む」を押すまで保存されません。",
                            table: "Home",
                            comment: "Manual entry: choosing a length only previews it; nothing is saved before 確認して積む"
                        )
                        : String(
                            localized: "この端末での本日の上限です。朝\(Self.dayBoundaryTimeLabel())に3回へ切り替わります。",
                            table: "Home",
                            comment: "Manual entry: today's allowance is used up; the argument is the time of day it resets (4:00; en 4:00 AM)"
                        )
                )
                .font(.caption)
                .foregroundStyle(PomoGemTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PomoGemTheme.raised, in: RoundedRectangle(cornerRadius: 13))
    }

    private var fairnessCopy: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(Constants.UIStrings.fairnessNote, systemImage: "circle.dashed")
                .font(.caption)
                .foregroundStyle(PomoGemTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
            Text(
                "この端末で1日3回まで・朝\(Self.dayBoundaryTimeLabel())に回数が切り替わります",
                tableName: "Home",
                comment: "Manual entry footnote: three entries a day on this device; the argument is the time of day the count resets (4:00; en 4:00 AM)"
            )
                .font(.caption2)
                .foregroundStyle(PomoGemTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func confirmationCard(
        duration: ManualDuration,
        availability: ManualEntryAvailability
    ) -> some View {
        PomoGemCard {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    SectionEyebrow(text: "CONFIRM")
                    Text("この内容で積みますか？", tableName: "Home", comment: "Manual entry: heading of the confirmation card")
                        .font(PomoGemTheme.brand(21))
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityFocused($confirmationHeadingIsFocused)
                }

                VStack(spacing: 10) {
                    confirmationRow(
                        title: String(localized: "テーマ", table: "Home", comment: "The word theme, alone: the caption above the sheets' theme menu, the manual-entry confirmation row, and the stand-in for a missing theme name"),
                        value: selectedSubject?.safeDisplayName ?? String(
                            localized: "未選択",
                            table: "Home",
                            comment: "No theme chosen yet: read after テーマ、 by VoiceOver and shown in the manual-entry confirmation row"
                        )
                    )
                    confirmationRow(
                        title: String(localized: "時間", table: "Home", comment: "Manual entry confirmation row: the self-reported time"),
                        value: durationTitle(duration)
                    )
                    confirmationRow(
                        title: String(localized: "加算", table: "Home", comment: "Manual entry confirmation row: the mass it adds"),
                        // Ungrouped, as this row has always printed it (「+3000g」).
                        value: "+\(MassText.grams(String(duration.grams)))"
                    )
                    confirmationRow(
                        title: String(localized: "保存後", table: "Home", comment: "Manual entry confirmation row: the allowance left once saved"),
                        value: String(
                            localized: "この端末で本日あと\(availability.remainingEntriesAfterSaving)回",
                            table: "Home",
                            comment: "Manual entry: how many self-reported entries this device can still add today"
                        )
                    )
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func confirmBar(
        duration: ManualDuration,
        availability: ManualEntryAvailability
    ) -> some View {
        VStack(spacing: 8) {
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(Color.red.opacity(0.9))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("manual.error")
            }
            Button {
                guard !isSubmitting, let selectedSubject else { return }
                isSubmitting = true
                errorMessage = onAdd(selectedSubject, duration)
                if errorMessage != nil {
                    isSubmitting = false
                    announce(errorMessage)
                }
            } label: {
                if isSubmitting {
                    ProgressView().tint(PomoGemTheme.background)
                } else {
                    Label(
                        String(localized: "確認して積む", table: "Home", comment: "Manual entry: the button that saves the entry"),
                        systemImage: "plus.circle.fill"
                    )
                }
            }
            .buttonStyle(PomoGemPrimaryButtonStyle())
            .disabled(selectedSubject == nil || !availability.isAllowed || isSubmitting)
            .accessibilityHint(confirmAccessibilityHint(duration))
            .accessibilityIdentifier("manual.confirm")
            Text("積んだ直後は、ホームで数秒のあいだ取り消せます。", tableName: "Home", comment: "Manual entry: under the confirm button; the entry can be undone briefly on Home")
                .font(.caption2)
                .foregroundStyle(PomoGemTheme.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Divider().overlay(PomoGemTheme.glassEdge.opacity(0.16))
        }
        .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
    }

    private func announce(_ message: String?) {
        guard let message, UIAccessibility.isVoiceOverRunning else { return }
        UIAccessibility.post(notification: .announcement, argument: message)
    }

    private func confirmationRow(title: String, value: String) -> some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                // Side by side, a long value wraps a few characters per line.
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(PomoGemTheme.muted)
                    Text(value)
                        .font(.subheadline.weight(.bold))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(PomoGemTheme.muted)
                    Spacer(minLength: 12)
                    Text(value)
                        .font(.subheadline.weight(.bold))
                        .multilineTextAlignment(.trailing)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func confirmAccessibilityHint(_ duration: ManualDuration) -> String {
        let theme = selectedSubject?.safeDisplayName ?? String(
            localized: "テーマ",
            table: "Home",
            comment: "The word theme, alone: the caption above the sheets' theme menu, the manual-entry confirmation row, and the stand-in for a missing theme name"
        )
        return String(
            localized: "\(theme)に\(DurationText.spoken(minutes: duration.minutes))、\(MassText.spoken(grams: duration.grams))を積みます",
            table: "Home",
            comment: "VoiceOver hint of the manual-entry confirm button: theme, spoken duration, spoken mass"
        )
    }

    /// 「30分」「1時間」「2時間」.
    private func durationTitle(_ duration: ManualDuration) -> String {
        DurationText.short(minutes: duration.minutes)
    }

    /// The study-day boundary (`Constants.Fairness.dayBoundaryHour`) as a time
    /// of day. Japanese keeps the bare 「4:00」 that 「朝」 already qualifies,
    /// whether the iPhone uses a 12- or 24-hour clock; other languages get
    /// their own clock ("4:00 AM", "04:00").
    static func dayBoundaryTimeLabel(locale: Locale = PomoGemLocale.current, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        // A fixed winter date, so a daylight-saving change can never move the hour.
        let boundary = calendar.date(from: DateComponents(
            year: 2026,
            month: 1,
            day: 15,
            hour: Constants.Fairness.dayBoundaryHour,
            minute: 0
        )) ?? .now
        let style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: timeZone)
        if PomoGemLocale.composesJapanese(locale) {
            return boundary.formatted(style.hour(.defaultDigits(amPM: .omitted)).minute(.twoDigits))
        }
        return boundary.formatted(style.hour().minute())
    }

    @ViewBuilder
    private func durationButtons(isEnabled: Bool) -> some View {
        if dynamicTypeSize.isAccessibilitySize || verticalSizeClass == .compact {
            VStack(spacing: 10) {
                manualButtons(isEnabled: isEnabled)
            }
        } else {
            HStack(spacing: 10) {
                manualButtons(isEnabled: isEnabled)
            }
        }
    }

    @ViewBuilder
    private func manualButtons(isEnabled: Bool) -> some View {
        ForEach(ManualDuration.allCases, id: \.self) { duration in
            ManualButton(
                title: durationTitle(duration),
                spokenTitle: DurationText.spoken(minutes: duration.minutes),
                grams: duration.grams,
                selected: selectedDuration == duration,
                isEnabled: isEnabled
            ) { selectedDuration = duration }
        }
    }
}

/// A self-reported entry confirmed with 「確認して積む」 but not written yet
/// (history-02). Nothing is saved for a short window while Home offers
/// 「元に戻す」, so undoing never deletes a row. A synced `StudySession` is
/// append-only: a physically deleted row invalidates the models that other
/// screens and devices (including 1.0.2) still hold. Until it is committed
/// the entry exists only in Home's memory: no total, jar body, export, share
/// card or iCloud record sees it.
struct PendingManualEntry: Identifiable, Equatable {
    let id = UUID()
    let subjectID: UUID
    let subjectName: String
    let colorHex: String
    let duration: ManualDuration
    /// When 「確認して積む」 was pressed: the saved session ends here and the
    /// daily allowance is counted for this moment's day.
    let confirmedAt: Date
    /// The reset epoch the entry was confirmed in; a reset in between drops it.
    let dataEpochID: UUID?
    /// The account the entry was confirmed under; a change in between drops
    /// it (`ManualEntryUndoPolicy.mayCommit`).
    let accountScope: ManualEntryAccountScope
}

/// Which account's store local writes currently belong to, as
/// `AccountScopedLocalState` records it.
///
/// Home also commits a pending entry from `onDisappear`. That teardown runs
/// when `PomoGemApp.quiesceForPossibleAccountChange` (CKAccountChanged)
/// closes the account boundary and retires the container, after which every
/// late write from the old view hierarchy must be refused
/// (Docs/OfflineCloudMode.md). Comparing this value at confirm and at commit
/// time catches that closed boundary, as well as a different account or
/// local namespace in between.
struct ManualEntryAccountScope: Equatable {
    let binding: ActiveAccountLocalBinding?
    let namespace: AccountDataNamespace?
    let boundaryIsClosed: Bool

    static func current(defaults: UserDefaults = .standard) -> Self {
        Self(
            binding: AccountScopedLocalState.activeBinding(defaults: defaults),
            namespace: AccountScopedLocalState.activeNamespace(defaults: defaults),
            boundaryIsClosed: AccountScopedLocalState.isBoundaryClosed(defaults: defaults)
        )
    }
}

/// When a pending self-reported entry is written (history-02). The window is
/// the only thing that waits: leaving the foreground, starting a timer,
/// opening another screen or adding again all commit it at once.
enum ManualEntryUndoPolicy {
    static let window: Duration = .seconds(5)
    /// VoiceOver and Switch Control users need time to reach the button after
    /// the announcement.
    static let assistiveWindow: Duration = .seconds(15)

    static func window(assistiveTechnologyIsRunning: Bool) -> Duration {
        assistiveTechnologyIsRunning ? assistiveWindow : window
    }

    /// Only into the account it was confirmed for, and never once that
    /// account's boundary has closed. A dropped entry spent nothing: the
    /// allowance is counted in the same write.
    static func mayCommit(
        confirmedUnder confirmed: ManualEntryAccountScope,
        now current: ManualEntryAccountScope
    ) -> Bool {
        !current.boundaryIsClosed && current == confirmed
    }
}

private struct ManualButton: View {
    let title: String
    let spokenTitle: String
    let grams: Int
    let selected: Bool
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Text(title).font(.system(.headline, design: .rounded, weight: .bold))
                // Grouped, as this button has always printed it (「+3,000g」).
                Text(verbatim: "+\(MassText.grams(grams.formatted()))")
                    .font(.caption)
                    .foregroundStyle(
                        selected
                            ? PomoGemTheme.background.opacity(0.72)
                            : PomoGemTheme.muted
                    )
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: 78)
            .foregroundStyle(selected ? PomoGemTheme.background : PomoGemTheme.text)
            .background(
                selected ? PomoGemTheme.amber : PomoGemTheme.raised,
                in: RoundedRectangle(cornerRadius: 13)
            )
        }
        .buttonStyle(PomoGemBareButtonStyle())
        .disabled(!isEnabled)
        .accessibilityLabel(String(
            localized: "\(spokenTitle)、\(MassText.spoken(grams: grams))加算",
            table: "Home",
            comment: "VoiceOver label of a manual-entry length button: spoken duration, spoken mass it adds"
        ))
        .accessibilityHint(
            isEnabled
                ? String(localized: "内容の確認へ進みます", table: "Home", comment: "VoiceOver hint of a manual-entry length button")
                : String(
                    localized: "本日の手動追加上限です",
                    table: "Home",
                    comment: "VoiceOver hint of a manual-entry length button once today's allowance is used up"
                )
        )
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
