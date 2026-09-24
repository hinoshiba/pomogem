import SwiftData
import SwiftUI
import UIKit

/// launch-06. Which first-run screen a store that has not finished onboarding
/// shows. A returning user who reinstalls, or sets up another iPhone, and
/// chooses iCloud used to land in the new-user tutorial while the earlier jar
/// was still arriving — and finishing that tutorial wrote over state their
/// other devices had. Their data already exists, so the honest first screen
/// is the restore itself.
enum CloudRestoreWaitingPolicy {
    /// - Parameters:
    ///   - restoresFromCloud: this session mirrors the user's private iCloud.
    ///   - cloudHoldsUserRecords: the launch preflight saw rows only a device
    ///     that used PomoGem on this account writes (`CloudActivityHistoryObservation`).
    ///   - hasReceivedThemes: a theme already exists locally. A cloud cold
    ///     launch never seeds themes, and the ones this device creates are
    ///     written by finishing onboarding, in the same save as the row that
    ///     says onboarding finished and after `startsFresh` is set — so before
    ///     that, any theme here arrived from iCloud.
    ///   - isCloudOffline: an offline session cannot receive anything; it
    ///     keeps the tutorial and its own offline caption.
    ///   - startsFresh: the user chose 「新しく始める」, or has already answered
    ///     the tutorial. Their decision is final for this account on this
    ///     iPhone until onboarding completes, across relaunches.
    static func showsRestoreWaiting(
        restoresFromCloud: Bool,
        cloudHoldsUserRecords: Bool,
        hasReceivedThemes: Bool,
        isCloudOffline: Bool,
        startsFresh: Bool
    ) -> Bool {
        guard restoresFromCloud, !isCloudOffline, !startsFresh else { return false }
        return cloudHoldsUserRecords || hasReceivedThemes
    }

    /// How long nothing new may arrive before the screen says so. Imports
    /// arrive in batches with quiet gaps; this only adds a sentence, it never
    /// leaves the screen.
    static let quietInterval: TimeInterval = 60

    static func isQuiet(lastChangeAt: Date, now: Date) -> Bool {
        now.timeIntervalSince(lastChangeAt) >= quietInterval
    }
}

/// The first-run gate below RootView's auto-exit. RootView still decides when
/// the jar opens (onboarding evidence arriving); this only chooses what to
/// show until then.
struct FirstRunView: View {
    let persistenceMode: PersistenceLaunchMode
    let restoresFromCloud: Bool
    let cloudHoldsUserRecords: Bool
    @Binding var startsFresh: Bool
    let onComplete: (Set<String>, Bool, RareRewardMode) -> Void

    @Environment(\.isCloudOfflineSession) private var isCloudOffline
    /// Existence only, one row: this view lives only until onboarding ends.
    @Query private var receivedThemes: [Subject]

    init(
        persistenceMode: PersistenceLaunchMode,
        restoresFromCloud: Bool,
        cloudHoldsUserRecords: Bool,
        startsFresh: Binding<Bool>,
        onComplete: @escaping (Set<String>, Bool, RareRewardMode) -> Void
    ) {
        self.persistenceMode = persistenceMode
        self.restoresFromCloud = restoresFromCloud
        self.cloudHoldsUserRecords = cloudHoldsUserRecords
        _startsFresh = startsFresh
        self.onComplete = onComplete
        var descriptor = SubjectSyncPolicy.liveRowsDescriptor()
        descriptor.fetchLimit = 1
        _receivedThemes = Query(descriptor)
    }

    var body: some View {
        if CloudRestoreWaitingPolicy.showsRestoreWaiting(
            restoresFromCloud: restoresFromCloud,
            cloudHoldsUserRecords: cloudHoldsUserRecords,
            hasReceivedThemes: !receivedThemes.isEmpty,
            isCloudOffline: isCloudOffline,
            startsFresh: startsFresh
        ) {
            CloudRestoreWaitingView {
                startsFresh = true
            }
            .transition(.opacity)
        } else {
            OnboardingView(
                persistenceMode: persistenceMode,
                startedFreshOverRestore: startsFresh,
                onComplete: onComplete
            )
            .transition(.opacity)
        }
    }
}

/// 「iCloudから記録を復元しています」: what has arrived so far, how long it has
/// been, and an explicit way to start without waiting. The jar opens on its
/// own through RootView's existing auto-exit as soon as onboarding evidence
/// (a finished onboarding's settings, a focus record or an achievement) is
/// imported — the first of it, not the whole earlier jar, so the copy says
/// that the rest keeps arriving after the jar opens.
struct CloudRestoreWaitingView: View {
    let onStartFresh: () -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Query private var liveThemes: [Subject]
    /// Observed so a deletion delivered as a new physical row is not counted
    /// as a theme; see `SubjectSyncPolicy.presentationSubjects`.
    @Query private var themeTombstones: [Subject]
    @State private var startedAt = Date.now
    @State private var now = Date.now
    /// Raw focus-record rows, stale epochs included. Only a sign of progress
    /// for the quiet hint, never shown: the first current, supported focus
    /// record closes this screen, so a displayed focus count would read 0 for
    /// almost the whole wait.
    @State private var arrivedSessionRows = 0
    @State private var lastChangeAt = Date.now
    @State private var lastObservedTotal = -1
    @State private var confirmsFreshStart = false

    init(onStartFresh: @escaping () -> Void) {
        self.onStartFresh = onStartFresh
        _liveThemes = Query(SubjectSyncPolicy.liveRowsDescriptor())
        _themeTombstones = Query(SubjectSyncPolicy.tombstoneRowsDescriptor())
    }

    private var themeCount: Int {
        SubjectSyncPolicy.presentationSubjects(
            live: liveThemes, tombstones: themeTombstones, context: modelContext
        ).count
    }

    private var elapsedSeconds: Int {
        max(0, Int(now.timeIntervalSince(startedAt)))
    }

    private var isQuiet: Bool {
        CloudRestoreWaitingPolicy.isQuiet(lastChangeAt: lastChangeAt, now: now)
    }

    var body: some View {
        ZStack {
            NightBackground()
            ScrollView {
                VStack(spacing: 22) {
                    PomoGemLogo(compact: true)
                        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)

                    ProgressView()
                        .controlSize(.large)
                        .tint(PomoGemTheme.amber)
                        .accessibilityHidden(true)

                    VStack(spacing: 12) {
                        Text("iCloudから記録を復元しています", tableName: "Onboarding",
                             comment: "Restore waiting screen: title while an earlier jar arrives from iCloud")
                            .font(PomoGemTheme.brand(26))
                            .foregroundStyle(PomoGemTheme.text)
                            .multilineTextAlignment(.center)
                            // One line at ordinary sizes, so it never breaks
                            // mid-word (「…してい／ます」); AX sizes wrap.
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                            .minimumScaleFactor(dynamicTypeSize.isAccessibilitySize ? 1 : 0.7)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityAddTraits(.isHeader)
                            .accessibilityIdentifier("cloud-restore.title")
                        Text("このApple Accountの以前の瓶を、iCloudから受け取っています。記録が届きはじめると自動で瓶がひらき、残りの記録もそのあと順に届きます。",
                             tableName: "Onboarding",
                             comment: "Restore waiting screen: what is happening and what happens next")
                            .font(.body)
                            .foregroundStyle(PomoGemTheme.muted)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    receivedSummary

                    if isQuiet {
                        Text("しばらく新しい記録が届いていません。通信状態を確認するか、待たずに「新しく始める」を選べます。",
                             tableName: "Onboarding",
                             comment: "Restore waiting screen: shown when nothing new has arrived for a while")
                            .font(.callout)
                            .foregroundStyle(PomoGemTheme.text)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("cloud-restore.quiet")
                    }

                    VStack(spacing: 10) {
                        Button {
                            confirmsFreshStart = true
                        } label: {
                            Text("新しく始める", tableName: "Onboarding",
                                 comment: "Restore waiting screen: start onboarding without waiting for iCloud")
                        }
                        .buttonStyle(PomoGemSecondaryButtonStyle())
                        .accessibilityHint(Text("記録の到着を待たずに、最初のテーマ選びへ進みます", tableName: "Onboarding",
                                                comment: "VoiceOver hint for 新しく始める on the restore waiting screen"))
                        .accessibilityIdentifier("cloud-restore.start-fresh")
                        Text("この画面を開いたままお待ちください。", tableName: "Onboarding",
                             comment: "Restore waiting screen: keep the app open while records arrive")
                            .font(.caption)
                            .foregroundStyle(PomoGemTheme.muted)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
                .padding(.vertical, 32)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .accessibilityIdentifier("cloud-restore.waiting")
        // The screen asks the user to keep it open, so keep it on. Auto-Lock
        // would move the scene to the background, which retires the iCloud
        // session and stops this import; unlocking then starts the launch
        // (and this screen) over. Same reason as the transfer mirror wait
        // (transfer-04 in PomoGemApp.swift). Nothing else owns the idle timer
        // before onboarding ends: FocusView only exists after it.
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        .task {
            // One cheap COUNT per second from the store, never a fetch of the
            // history itself: a returning user can have decades of records.
            while !Task.isCancelled {
                refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .alert(
            String(localized: "新しく始めますか？", table: "Onboarding",
                   comment: "Restore waiting screen: confirmation title for starting without waiting"),
            isPresented: $confirmsFreshStart
        ) {
            Button(String(localized: "待つ", table: "Onboarding",
                          comment: "Restore waiting screen: keep waiting for iCloud (cancel)"),
                   role: .cancel) {}
            Button(String(localized: "新しく始める", table: "Onboarding",
                          comment: "Restore waiting screen: confirm starting without waiting")) {
                onStartFresh()
            }
        } message: {
            Text("記録の到着を待たずに、最初のテーマ選びへ進みます。iCloudの記録は、届きしだいこのiPhoneにも表示されます。",
                 tableName: "Onboarding",
                 comment: "Restore waiting screen: what starting without waiting means")
        }
    }

    private var receivedSummary: some View {
        VStack(spacing: 12) {
            Text("届いた記録", tableName: "Onboarding",
                 comment: "Restore waiting screen: heading above the received counts")
                .font(.caption.weight(.bold))
                .foregroundStyle(PomoGemTheme.muted)
            countTile(
                value: themeCount,
                title: Text("テーマ", tableName: "Onboarding", comment: "Restore waiting screen: count label for themes")
            )
            Text("経過 \(elapsedText)", tableName: "Onboarding",
                 comment: "Restore waiting screen: elapsed time, e.g. 経過 1:05")
                .font(.system(.footnote, design: .rounded, weight: .semibold).monospacedDigit())
                .foregroundStyle(PomoGemTheme.muted)
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(PomoGemTheme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("届いた記録：テーマ\(themeCount)件。経過時間\(elapsedSeconds / 60)分\(elapsedSeconds % 60)秒",
                                 tableName: "Onboarding",
                                 comment: "VoiceOver summary of the restore progress: theme count, elapsed minutes and seconds"))
        .accessibilityAddTraits(.updatesFrequently)
        .accessibilityIdentifier("cloud-restore.counts")
    }

    private func countTile(value: Int, title: Text) -> some View {
        VStack(spacing: 4) {
            Text("\(value)件", tableName: "Onboarding", comment: "Restore waiting screen: a received count")
                .font(.system(.title2, design: .rounded, weight: .bold).monospacedDigit())
                .foregroundStyle(PomoGemTheme.amber)
                .contentTransition(.numericText())
            title
                .font(.caption)
                .foregroundStyle(PomoGemTheme.muted)
        }
        .frame(maxWidth: .infinity, minHeight: 64)
        .padding(.vertical, 6)
        .background(PomoGemTheme.raised.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var elapsedText: String {
        String(format: "%d:%02d", elapsedSeconds / 60, elapsedSeconds % 60)
    }

    private func refresh() {
        now = .now
        arrivedSessionRows = (try? modelContext.fetchCount(FetchDescriptor<StudySession>())) ?? arrivedSessionRows
        let total = themeCount + arrivedSessionRows
        if total != lastObservedTotal {
            lastObservedTotal = total
            lastChangeAt = now
        }
    }
}
