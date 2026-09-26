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
    }

    var focusStart: FocusStart?

    @Environment(TimerOrientationController.self) private var orientation: TimerOrientationController?
    @State private var music = FocusMusicController.shared
    @State private var isSheetPresented = false
    @State private var suppressesNextTap = false
    @AppStorage(FocusMusicPreferences.sourceKey) private var chosenSourceID = ""

    init(focusStart: FocusStart? = nil) {
        self.focusStart = focusStart
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
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.5).onEnded { _ in
                // The button's own tap still arrives when the finger lifts.
                suppressesNextTap = true
                isSheetPresented = true
            }
        )
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilityValue)
        .accessibilityHint(accessibilityHint)
        .accessibilityAction(named: Text("音楽を選ぶ", tableName: "Focus", comment: "Focus music list: its heading, and the timer button's VoiceOver action that opens it")) {
            isSheetPresented = true
        }
        .accessibilityIdentifier("timer.music")
        .sheet(isPresented: $isSheetPresented, onDismiss: { suppressesNextTap = false }) {
            FocusMusicSheet(controller: music)
                .modifier(FocusMusicSheetOrientation(isUpsideDown: isTimerUpsideDown))
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

    private func tap() {
        if suppressesNextTap {
            suppressesNextTap = false
            return
        }
        Task {
            if await music.handleHeaderTap() == .presentSheet {
                isSheetPresented = true
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

    private var isReadyToPlay: Bool {
        music.availability == .ready && chosenTitle != nil
    }

    private var accessibilityLabel: Text {
        if music.isPlaying {
            return Text("集中用の音楽を一時停止", tableName: "Focus", comment: "VoiceOver label: pause the Music app from the timer")
        }
        if isReadyToPlay {
            return Text("集中用の音楽を再生", tableName: "Focus", comment: "VoiceOver label: play the chosen focus music from the timer")
        }
        return Text("集中用の音楽を選ぶ", tableName: "Focus", comment: "VoiceOver label: open the focus music list from the timer")
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
        if music.isPlaying || isReadyToPlay {
            return Text("長押しで音楽を選べます", tableName: "Focus", comment: "VoiceOver hint: long press the timer music button to choose music")
        }
        return Text("ミュージックアプリで再生する音楽を選びます", tableName: "Focus", comment: "VoiceOver hint: the timer music button opens the music list")
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
