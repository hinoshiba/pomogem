import SwiftUI
import UIKit

enum TimerDefaultOrientation: String, CaseIterable, Identifiable {
    case automatic, up, right, down, left

    var id: String { rawValue }
    var direction: TimerOrientation? {
        switch self {
        case .automatic: nil
        case .up: .up
        case .right: .right
        case .down: .down
        case .left: .left
        }
    }
    var title: String {
        switch self {
        case .automatic: "自動"
        case .up: "上（縦）"
        case .right: "右（横）"
        case .down: "下（縦・上下逆）"
        case .left: "左（横）"
        }
    }
    var symbol: String {
        switch self {
        case .automatic: "iphone.gen3.radiowaves.left.and.right"
        case .up: "arrow.up"
        case .right: "arrow.right"
        case .down: "arrow.down"
        case .left: "arrow.left"
        }
    }
}

enum TimerOrientationPreference {
    // A device display choice, like the local Live Activity setting. The
    // physical direction and per-timer override are never written here.
    static let defaultsKey = "timer.default-orientation"

    static func load(defaults: UserDefaults = .standard) -> TimerDefaultOrientation {
        TimerDefaultOrientation(rawValue: defaults.string(forKey: defaultsKey) ?? "") ?? .automatic
    }
}

/// Directions describe where the top of the timer points on an upright phone.
/// The scene rotates with the timer wherever UIKit supports the direction.
/// Content rotation supplies only the difference from the actual scene geometry.
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

    var interfaceOrientation: UIInterfaceOrientation {
        switch self {
        case .up: .portrait
        case .right: .landscapeRight
        case .down: .portraitUpsideDown
        case .left: .landscapeLeft
        }
    }

    var interfaceMask: UIInterfaceOrientationMask {
        UIInterfaceOrientationMask(rawValue: 1 << interfaceOrientation.rawValue)
    }

    init?(interfaceOrientation: UIInterfaceOrientation) {
        switch interfaceOrientation {
        case .portrait: self = .up
        case .landscapeRight: self = .right
        case .portraitUpsideDown: self = .down
        case .landscapeLeft: self = .left
        default: return nil
        }
    }

    func relative(to interfaceOrientation: UIInterfaceOrientation) -> Self {
        let sceneDirection = Self(interfaceOrientation: interfaceOrientation) ?? .up
        return Self(rawValue: (rawValue - sceneDirection.rawValue + 4) % 4)!
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

    init(defaultOrientation: TimerDefaultOrientation = .automatic) {
        if let direction = defaultOrientation.direction {
            self.direction = direction
            rotationDegrees = direction.degrees
            isManual = true
        }
    }

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
/// Keep a running timer's override across that replacement. A new session
/// starts from the saved default, independent of previous timers' overrides.
@MainActor
final class TimerOrientationSelection {
    static let shared = TimerOrientationSelection()
    private var states: [AnyHashable: TimerOrientationState] = [:]
    private var sessionOrder: [AnyHashable] = []

    func state(for sessionID: AnyHashable, defaultOrientation: TimerDefaultOrientation) -> TimerOrientationState {
        // SwiftUI eagerly constructs disposable @State initial values whenever
        // a parent recomputes. Reading one must not evict a live timer's choice.
        states[sessionID] ?? TimerOrientationState(defaultOrientation: defaultOrientation)
    }

    func update(_ state: TimerOrientationState, for sessionID: AnyHashable) {
        if states[sessionID] == nil { sessionOrder.append(sessionID) }
        states[sessionID] = state
        // Retain recent recovery choices without growing with timer history.
        if sessionOrder.count > 8 { states.removeValue(forKey: sessionOrder.removeFirst()) }
    }
}

@MainActor @Observable
final class TimerOrientationController {
    private(set) var state: TimerOrientationState {
        didSet { selection.update(state, for: sessionID) }
    }
    @ObservationIgnored private let sessionID: AnyHashable
    @ObservationIgnored private let selection: TimerOrientationSelection
    @ObservationIgnored private weak var windowScene: UIWindowScene?
    private(set) var interfaceOrientation: UIInterfaceOrientation = .portrait
    @ObservationIgnored private var isObserving = false
    @ObservationIgnored private var isPresented = false
    @ObservationIgnored private var requestedDirection: TimerOrientation?
    @ObservationIgnored private var requestGeneration = 0

    init(sessionID: AnyHashable, selection: TimerOrientationSelection? = nil, defaults: UserDefaults = .standard) {
        let selection = selection ?? .shared
        self.sessionID = sessionID
        self.selection = selection
        state = selection.state(for: sessionID, defaultOrientation: TimerOrientationPreference.load(defaults: defaults))
    }

    func attach(to scene: UIWindowScene?) {
        if windowScene !== scene {
            releaseScene()
            windowScene = scene
        }
        updateGeometry()
        refresh()
    }

    func updateGeometry() {
        guard let windowScene else { return }
        interfaceOrientation = windowScene.effectiveGeometry.interfaceOrientation
    }

    func disappear() {
        isPresented = false
        setActive(false)
        releaseScene()
    }

    private func releaseScene() {
        requestGeneration += 1
        requestedDirection = nil
        if let windowScene {
            TimerSceneOrientation.shared.release(windowScene, owner: self)
        }
    }

    func setActive(_ active: Bool) {
        if active, !isObserving {
            isPresented = true
            requestedDirection = nil
            // The live controller owns its selection even if the bounded
            // recovery cache has expired. Inactivity must not reset it.
            selection.update(state, for: sessionID)
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
        requestSceneOrientation()
    }

    func rotate() {
        state.rotate()
        requestSceneOrientation()
    }

    func followDevice() {
        state.followDevice(UIDevice.current.orientation, isLocked: isLocked)
        requestSceneOrientation()
    }

    private func requestSceneOrientation() {
        guard isPresented, isObserving, let windowScene,
              windowScene.activationState == .foregroundActive,
              requestedDirection != state.direction else { return }
        let direction = state.direction
        requestedDirection = direction
        requestGeneration += 1
        let generation = requestGeneration
        // Keep portrait available when UIKit rejects upside down on an iPhone
        // without a Home button. All other directions use native scene rotation.
        let mask: UIInterfaceOrientationMask = direction == .down
            ? [.portrait, .portraitUpsideDown] : direction.interfaceMask
        TimerSceneOrientation.shared.claim(windowScene, owner: self, mask: mask)
        windowScene.requestGeometryUpdate(.iOS(interfaceOrientations: direction.interfaceMask)) { [weak self, weak windowScene] _ in
            guard let self, let windowScene, self.isPresented,
                  self.requestGeneration == generation,
                  TimerSceneOrientation.shared.isOwner(self, of: windowScene) else { return }
            if direction == .down {
                // The platform cannot move its system UI to an unsupported
                // edge. Restore portrait and retain the readable 180° fallback.
                windowScene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait))
            }
            self.updateGeometry()
        }
    }
}

struct TimerLayoutContext {
    let size: CGSize
    let isLandscape: Bool
}

/// Lay out in the scene's safe rectangle. Native rotation moves the system UI;
/// only any unsupported remainder (notably upside down) rotates the contents.
/// The timer engine lives above this container and is never re-created on turn.
struct TimerOrientationContainer<Content: View>: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var orientation: TimerOrientationController
    let content: (TimerLayoutContext) -> Content

    init(sessionID: AnyHashable, @ViewBuilder content: @escaping (TimerLayoutContext) -> Content) {
        _orientation = State(initialValue: TimerOrientationController(sessionID: sessionID))
        self.content = content
    }

    var body: some View {
        GeometryReader { proxy in
            let direction = orientation.state.direction
            let residual = direction.relative(to: orientation.interfaceOrientation)
            let size = residual.contentSize(in: proxy.size)
            content(TimerLayoutContext(size: size, isLandscape: direction.isLandscape))
                .environment(orientation)
                .frame(width: size.width, height: size.height)
                .rotationEffect(.degrees(residual.degrees))
                .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .background {
            TimerWindowSceneReader(onChange: { orientation.attach(to: $0) },
                                   onGeometryChange: { orientation.updateGeometry() })
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        .overlay(alignment: .topLeading) {
#if DEBUG
            if LocalPreviewLaunchPolicy.isUITestMode(environment: ProcessInfo.processInfo.environment, isDebugBuild: true) {
                Text(verbatim: "\(orientation.interfaceOrientation.rawValue)")
                    .font(.system(size: 1))
                    .accessibilityIdentifier("timer.interface-orientation")
                    .allowsHitTesting(false)
            }
#endif
        }
        .onAppear { orientation.setActive(scenePhase == .active) }
        .onDisappear { orientation.disappear() }
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

private struct TimerWindowSceneReader: UIViewControllerRepresentable {
    let onChange: (UIWindowScene?) -> Void
    let onGeometryChange: () -> Void

    func makeUIViewController(context: Context) -> SceneController {
        let controller = SceneController()
        controller.onChange = onChange
        controller.onGeometryChange = onGeometryChange
        return controller
    }

    func updateUIViewController(_ controller: SceneController, context: Context) {
        controller.onChange = onChange
        controller.onGeometryChange = onGeometryChange
    }

    final class SceneController: UIViewController {
        var onChange: ((UIWindowScene?) -> Void)?
        var onGeometryChange: (() -> Void)?

        override func loadView() {
            let sceneView = SceneView()
            sceneView.onWindowChange = { [weak self] in
                guard let self else { return }
                self.onChange?(self.view.window?.windowScene)
            }
            view = sceneView
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            publishGeometry()
        }

        override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
            super.viewWillTransition(to: size, with: coordinator)
            // Also observe 180° transitions, whose final bounds and safe-area
            // insets can match the previous landscape orientation exactly.
            coordinator.animate(alongsideTransition: { [weak self] _ in
                self?.publishGeometry()
            }, completion: { [weak self] _ in
                self?.publishGeometry()
            })
        }

        private func publishGeometry() {
            DispatchQueue.main.async { [weak self] in self?.onGeometryChange?() }
        }
    }

    final class SceneView: UIView {
        var onWindowChange: (() -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            // Avoid publishing Observable state during SwiftUI's view update.
            DispatchQueue.main.async { [weak self] in self?.onWindowChange?() }
        }
    }
}
