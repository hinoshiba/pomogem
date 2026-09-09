import SwiftUI
import UIKit

/// Directions describe where the top of the timer points on an upright phone.
/// Rotating the contents also supports upside down on Face ID iPhones, whose
/// system interface does not support portraitUpsideDown.
enum TimerOrientation: Int, CaseIterable {
    case up, right, down, left

    var degrees: Double { Double(rawValue * 90) }
    var isLandscape: Bool { self == .right || self == .left }
    var next: Self { Self(rawValue: (rawValue + 1) % 4)! }
    var label: String {
        switch self {
        case .up: "上"
        case .right: "右"
        case .down: "下"
        case .left: "左"
        }
    }

    init?(deviceOrientation: UIDeviceOrientation) {
        switch deviceOrientation {
        case .portrait: self = .up
        case .landscapeLeft: self = .right
        case .portraitUpsideDown: self = .down
        case .landscapeRight: self = .left
        default: return nil
        }
    }

    func contentSize(in available: CGSize) -> CGSize {
        isLandscape
            ? CGSize(width: available.height, height: available.width)
            : available
    }
}

struct TimerOrientationState {
    private(set) var direction: TimerOrientation = .up
    private(set) var rotationDegrees: Double = 0
    private(set) var isManual = false

    mutating func rotate() {
        isManual = true
        turn(to: direction.next)
    }

    mutating func receive(_ device: UIDeviceOrientation, isLocked: Bool) {
        guard !isManual, !isLocked,
              let orientation = TimerOrientation(deviceOrientation: device) else { return }
        turn(to: orientation)
    }

    mutating func followDevice(_ device: UIDeviceOrientation, isLocked: Bool) {
        isManual = false
        receive(device, isLocked: isLocked)
    }

    private mutating func turn(to newDirection: TimerOrientation) {
        let steps = (newDirection.rawValue - direction.rawValue + 4) % 4
        rotationDegrees += Double((steps > 2 ? steps - 4 : steps) * 90)
        direction = newDirection
    }
}

/// Cloud account revalidation can replace the entire view hierarchy on resume.
/// Keep only this display choice in memory across that replacement and between
/// focus and break. Never persist it to the timer, preferences, or CloudKit.
@MainActor
final class TimerOrientationSelection {
    static let shared = TimerOrientationSelection()
    var state = TimerOrientationState()
}

@MainActor @Observable
final class TimerOrientationController {
    private(set) var state: TimerOrientationState {
        didSet { selection.state = state }
    }
    @ObservationIgnored private let selection: TimerOrientationSelection
    @ObservationIgnored private weak var windowScene: UIWindowScene?
    @ObservationIgnored private var isObserving = false

    init(selection: TimerOrientationSelection? = nil) {
        let selection = selection ?? .shared
        self.selection = selection
        state = selection.state
    }

    func attach(to scene: UIWindowScene?) {
        windowScene = scene
        refresh()
    }

    func setActive(_ active: Bool) {
        if active, !isObserving {
            state = selection.state
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
            isObserving = true
        } else if !active, isObserving {
            UIDevice.current.endGeneratingDeviceOrientationNotifications()
            isObserving = false
        }
        if active { refresh() }
    }

    private var isLocked: Bool {
#if DEBUG
        let environment = ProcessInfo.processInfo.environment
        if LocalPreviewLaunchPolicy.isUITestMode(environment: environment, isDebugBuild: true),
           environment["POMOGEM_UI_TEST_ORIENTATION_LOCKED"] == "1" {
            return true
        }
#endif
        if #available(iOS 26.0, *), let windowScene {
            return windowScene.effectiveGeometry.isInterfaceOrientationLocked
        }
        // Earlier iOS versions expose no scene-lock query. Follow the cardinal
        // notifications UIKit delivers; manual mode remains available on all OSes.
        return false
    }

    func refresh() {
        guard isObserving, windowScene?.activationState == .foregroundActive else { return }
        state.receive(UIDevice.current.orientation, isLocked: isLocked)
    }

    func rotate() { state.rotate() }

    func followDevice() {
        state.followDevice(UIDevice.current.orientation, isLocked: isLocked)
    }
}

struct TimerLayoutContext {
    let size: CGSize
    let isLandscape: Bool
}

/// The outer scene stays upright. Use its safe rectangle before swapping axes,
/// so the camera cutout and home indicator remain clear in every direction.
/// The timer engine lives above this container and is never re-created on turn.
struct TimerOrientationContainer<Content: View>: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.pomogemReduceMotionOverride) private var reduceMotionOverride
    private var reduceMotion: Bool { reduceMotionOverride ?? systemReduceMotion }
    @State private var orientation = TimerOrientationController()
    @ViewBuilder let content: (TimerLayoutContext) -> Content

    var body: some View {
        GeometryReader { proxy in
            let direction = orientation.state.direction
            let size = direction.contentSize(in: proxy.size)
            content(TimerLayoutContext(size: size, isLandscape: direction.isLandscape))
                .environment(orientation)
                .frame(width: size.width, height: size.height)
                .rotationEffect(.degrees(orientation.state.rotationDegrees))
                .frame(width: proxy.size.width, height: proxy.size.height)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: direction)
        }
        .background {
            TimerWindowSceneReader { orientation.attach(to: $0) }
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        .onAppear { orientation.setActive(scenePhase == .active) }
        .onDisappear { orientation.setActive(false) }
        .onChange(of: scenePhase) { _, phase in
            orientation.setActive(phase == .active)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            orientation.refresh()
        }
    }
}

struct TimerRotationControls: View {
    @Environment(TimerOrientationController.self) private var orientation

    var body: some View {
        HStack(spacing: 0) {
            if orientation.state.isManual {
                Button(action: orientation.followDevice) {
                    Text("自動")
                        .font(.caption)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("端末の向きに合わせる")
                .accessibilityIdentifier("timer.rotation.automatic")
            }
            Button(action: orientation.rotate) {
                Image(systemName: "rotate.right")
                    .font(.system(size: 17, weight: .regular))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("タイマーの向きを変える")
            .accessibilityValue(orientation.state.direction.label)
            .accessibilityHint("上、右、下、左の順に回転し、選んだ向きを保ちます")
            .accessibilityIdentifier("timer.rotate")
        }
        .foregroundStyle(PomoGemTheme.muted)
        .buttonStyle(PomoGemBareButtonStyle())
    }
}

private struct TimerWindowSceneReader: UIViewRepresentable {
    let onChange: (UIWindowScene?) -> Void

    func makeUIView(context: Context) -> SceneView {
        let view = SceneView()
        view.onChange = onChange
        return view
    }

    func updateUIView(_ uiView: SceneView, context: Context) {
        uiView.onChange = onChange
    }

    final class SceneView: UIView {
        var onChange: ((UIWindowScene?) -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            // Avoid publishing Observable state during SwiftUI's view update.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                onChange?(window?.windowScene)
            }
        }
    }
}
