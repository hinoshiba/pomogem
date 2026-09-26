import SwiftUI

/// The music control in the focus and break timer headers (D4.4a,
/// Docs/FocusMusic.md). A tap plays or pauses the chosen source once Apple
/// Music is ready. Otherwise the tap, a long press, or the VoiceOver action
/// 「音楽を選ぶ」 opens `FocusMusicSheet`. Everything stays in PomoGem: the
/// Music app plays in the background and the timer screen never leaves.
struct FocusMusicButton: View {
    /// The focus on screen. With the opt-in 「集中を始めたら再生する」 on, a
    /// focus that has just started on this iPhone starts the chosen source
    /// once; `sessionID` is nil while paused.
    struct FocusStart: Equatable {
        var sessionID: UUID?
        var startedAt: Date?
        var isStartedOnThisIPhone: Bool

        /// FocusView's timer state as the autoplay gate reads it: a session
        /// only while the focus runs (not paused, not a break or an end),
        /// and 「started on this iPhone」 only for a local start, never for a
        /// focus continued from iCloud.
        static func make(
            phase: PomodoroPhase,
            currentSessionID: UUID?,
            phaseStartedAt: Date?,
            origin: FocusRecoveryOrigin
        ) -> FocusStart {
            FocusStart(
                sessionID: phase == .focusing ? currentSessionID : nil,
                startedAt: phaseStartedAt,
                isStartedOnThisIPhone: origin == .local
            )
        }
    }

    /// Set by FocusView: a focus is on screen, so the sheet never offers a
    /// way out of the app (D4.1), and autoplay may start.
    var focusStart: FocusStart?
    /// `FocusMusicSheetPolicy.keepsSheetClosed`: the phase is about to end or
    /// has ended. The sheet closes at once and cannot be opened, so the
    /// completion alarm's Stop control is never under it (#32).
    var keepsSheetClosed: Bool

    @Environment(TimerOrientationController.self) private var orientation: TimerOrientationController?
    @State private var music = FocusMusicController.shared
    @State private var isSheetPresented = false
    @State private var suppressesNextTap = false
    /// `keepsSheetClosed` kept as state: a tap's task that awaited the
    /// subscription past the end reads the current value here, not the view
    /// value it started from.
    @State private var isSheetLocked = false
    @AppStorage(FocusMusicPreferences.sourceKey) private var chosenSourceID = ""

    init(focusStart: FocusStart? = nil, keepsSheetClosed: Bool = false) {
        self.focusStart = focusStart
        self.keepsSheetClosed = keepsSheetClosed
    }

    var body: some View {
        Button(action: tap) {
            Image(systemName: music.isPlaying ? "speaker.wave.2.fill" : "music.note")
                .font(.system(size: 17, weight: .regular))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .foregroundStyle(music.isPlaying ? PomoGemTheme.amber : PomoGemTheme.muted)
        .buttonStyle(PomoGemBareButtonStyle())
        // Near and after the end, a tap that could only open the sheet does
        // nothing, so it is shown as unavailable instead.
        .disabled(keepsSheetClosed && music.headerAction == .presentSheet)
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.5).onEnded { _ in
                // The button's own tap still arrives when the finger lifts.
                suppressesNextTap = true
                presentSheet()
            }
        )
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilityValue)
        .accessibilityHint(accessibilityHint)
        .accessibilityAction(named: Text("音楽を選ぶ", tableName: "Focus", comment: "Focus music list: its heading, and the timer button's VoiceOver action that opens it")) {
            presentSheet()
        }
        .accessibilityIdentifier("timer.music")
        .sheet(isPresented: $isSheetPresented, onDismiss: { suppressesNextTap = false }) {
            FocusMusicSheet(controller: music, allowsLeavingApp: focusStart == nil)
                .modifier(FocusMusicSheetOrientation(isUpsideDown: isTimerUpsideDown))
        }
        .onChange(of: keepsSheetClosed, initial: true) { _, closes in
            isSheetLocked = closes
            guard closes, isSheetPresented else { return }
            // Without the dismissal animation, so nothing modal is left on
            // screen when the alarm starts and VoiceOver moves to its Stop.
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { isSheetPresented = false }
        }
        .task { await music.refresh() }
        .task(id: focusStart) {
            guard let focusStart else { return }
            await music.autoplayIfNeeded(
                sessionID: focusStart.sessionID,
                startedAt: focusStart.startedAt,
                isStartedOnThisIPhone: focusStart.isStartedOnThisIPhone
            )
        }
    }

    private func presentSheet() {
        guard !keepsSheetClosed, !isSheetLocked else { return }
        isSheetPresented = true
    }

    private func tap() {
        if suppressesNextTap {
            suppressesNextTap = false
            return
        }
        Task {
            let action = await music.handleHeaderTap()
            // Also after a play that did not start, so its hint, Apple's
            // offer or the permission card is seen (D4.3).
            if music.presentsSheet(after: action) {
                presentSheet()
            }
        }
    }

    /// On Face ID iPhones an upside-down timer is a 180° rotation of the
    /// contents inside a portrait scene (Docs/TimerOrientation.md), so a sheet
    /// would otherwise appear upside down to the person holding the phone.
    private var isTimerUpsideDown: Bool {
        guard let orientation else { return false }
        return orientation.state.direction.relative(to: orientation.interfaceOrientation) == .down
    }

    private var chosenTitle: String? {
        FocusMusicCatalog.source(id: chosenSourceID).map(music.title(for:))
    }

    /// The label follows what the tap will do (`FocusMusicHeaderPolicy`),
    /// never the playback state alone.
    private var accessibilityLabel: Text {
        switch music.headerAction {
        case .pause:
            return Text("集中用の音楽を一時停止", tableName: "Focus", comment: "VoiceOver label: pause the Music app from the timer")
        case .play, .resume, .ignore:
            return Text("集中用の音楽を再生", tableName: "Focus", comment: "VoiceOver label: play the chosen focus music from the timer")
        case .presentSheet:
            return Text("集中用の音楽を選ぶ", tableName: "Focus", comment: "VoiceOver label: open the focus music list from the timer")
        }
    }

    private var accessibilityValue: Text {
        if music.isPlaying, let title = music.nowPlaying.title {
            return Text(verbatim: title)
        }
        if let chosenTitle {
            return Text(verbatim: chosenTitle)
        }
        return Text(verbatim: "")
    }

    private var accessibilityHint: Text {
        if keepsSheetClosed {
            return Text(verbatim: "")
        }
        if music.headerAction == .presentSheet {
            return Text("ミュージックアプリで再生する音楽を選びます", tableName: "Focus", comment: "VoiceOver hint: the timer music button opens the music list")
        }
        return Text("長押しで音楽を選べます", tableName: "Focus", comment: "VoiceOver hint: long press the timer music button to choose music")
    }
}

/// Matches an upside-down timer, and keeps the full-height sheet there so its
/// rotated title and close button stay clear of the grabber edge.
struct FocusMusicSheetOrientation: ViewModifier {
    let isUpsideDown: Bool

    func body(content: Content) -> some View {
        if isUpsideDown {
            GeometryReader { proxy in
                // Turned over, the content's top edge (title and 閉じる) lands
                // on the home-indicator edge; keep it clear of that inset.
                content
                    .padding(.top, proxy.safeAreaInsets.bottom)
                    .rotationEffect(.degrees(180))
            }
            .presentationDetents([.large])
        } else {
            content
                .presentationDetents([.medium, .large])
        }
    }
}
