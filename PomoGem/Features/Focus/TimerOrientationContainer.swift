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
        case .automatic:
            String(localized: "自動", table: "Focus",
                   comment: "Settings: default timer orientation option that follows the device")
        case .up:
            String(localized: "上（縦）", table: "Focus",
                   comment: "Settings: default timer orientation option, top of the timer up (portrait)")
        case .right:
            String(localized: "右（横）", table: "Focus",
                   comment: "Settings: default timer orientation option, top of the timer to the right (landscape)")
        case .down:
            String(localized: "下（縦・上下逆）", table: "Focus",
                   comment: "Settings: default timer orientation option, top of the timer down (portrait, upside down)")
        case .left:
            String(localized: "左（横）", table: "Focus",
                   comment: "Settings: default timer orientation option, top of the timer to the left (landscape)")
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
    /// VoiceOver value of the rotate button: where the top of the timer points.
    var label: String {
        switch self {
        case .up: String(localized: "上", table: "Focus", comment: "VoiceOver value: the timer's top points up")
        case .right: String(localized: "右", table: "Focus", comment: "VoiceOver value: the timer's top points right")
        case .down: String(localized: "下", table: "Focus", comment: "VoiceOver value: the timer's top points down")
        case .left: String(localized: "左", table: "Focus", comment: "VoiceOver value: the timer's top points left")
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

/// A portrait label alone is not enough: UIKit can publish it before the
/// window's bounds and rotation animation have reached their final geometry.
enum TimerPortraitReturnPolicy {
    static func isReady(
        interfaceOrientation: UIInterfaceOrientation,
        windowSize: CGSize,
        isTransitioning: Bool,
        sceneIsActive: Bool
    ) -> Bool {
        sceneIsActive && !isTransitioning && interfaceOrientation == .portrait
            && windowSize.width > 0 && windowSize.height >= windowSize.width
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
    private(set) var isReturningToPortrait = false
    private(set) var canRetryPortraitReturn = false
    @ObservationIgnored private var portraitReturnWatchdog: Task<Void, Never>?
    @ObservationIgnored private var geometryTransitionInProgress = false
    @ObservationIgnored private var portraitRequestPending = false
    @ObservationIgnored private var didRequestPortraitReturn = false
    @ObservationIgnored private var onPortraitReady: (() -> Void)?

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
            // Transition callbacks belong to the old scene. A detached
            // reader may never deliver its completion to this replacement.
            geometryTransitionInProgress = false
            portraitRequestPending = false
            didRequestPortraitReturn = false
        }
        updateGeometry()
        if isReturningToPortrait { continuePortraitReturn() } else { refresh() }
    }

    func updateGeometry() {
        guard let windowScene else { return }
        interfaceOrientation = windowScene.effectiveGeometry.interfaceOrientation
        finishPortraitReturnIfReady()
    }

    func geometryTransitionChanged(isTransitioning: Bool) {
        geometryTransitionInProgress = isTransitioning
        guard !isTransitioning else { return }
        portraitRequestPending = false
        updateGeometry()
        if isReturningToPortrait { continuePortraitReturn() }
    }

    /// The timer's opaque cover remains present until native portrait geometry
    /// has settled. Home, its reward card, and gem physics are revealed only
    /// after this callback, so they never inherit the outgoing landscape scene.
    func prepareToReturnToPortrait(then completion: @escaping () -> Void) {
        guard !isReturningToPortrait else { return }
        isReturningToPortrait = true
        onPortraitReady = completion
        requestGeneration += 1
        setActive(false)
        if let windowScene {
            // Withdraw an earlier landscape request before consulting UIKit's
            // still-portrait geometry; that request may not have begun yet.
            TimerSceneOrientation.shared.claim(windowScene, owner: self, mask: .portrait)
        }
        // Let SwiftUI hide the timer's transformed content before UIKit turns
        // the scene. The cover's background stays opaque throughout the turn.
        DispatchQueue.main.async { [weak self] in self?.retryPortraitReturn() }
    }

    func retryPortraitReturn() {
        guard isReturningToPortrait, onPortraitReady != nil else { return }
        canRetryPortraitReturn = false
        portraitRequestPending = false
        didRequestPortraitReturn = false
        portraitReturnWatchdog?.cancel()
        portraitReturnWatchdog = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            guard let self, self.onPortraitReady != nil,
                  self.windowScene == nil || self.windowScene?.activationState == .foregroundActive else { return }
            // A refused request or missing UIKit callback must not strand the
            // user on a spinner. Success is still gated by actual geometry.
            self.canRetryPortraitReturn = true
            self.portraitRequestPending = false
        }
        continuePortraitReturn()
    }

    private func continuePortraitReturn() {
        guard isReturningToPortrait, onPortraitReady != nil else { return }
        // The scene reader attaches asynchronously. A recovered completion
        // can request dismissal first, so no scene means wait for attachment.
        guard let windowScene else { return }
#if targetEnvironment(macCatalyst)
        completePortraitReturn()
#else
        guard windowScene.activationState == .foregroundActive else { return }
        guard !geometryTransitionInProgress else { return }
        if didRequestPortraitReturn, portraitReturnIsReady {
            updateGeometry()
            return
        }
        guard !portraitRequestPending else { return }
        portraitRequestPending = true
        didRequestPortraitReturn = true
        requestGeneration += 1
        let generation = requestGeneration
        TimerSceneOrientation.shared.claim(windowScene, owner: self, mask: .portrait)
        windowScene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait)) { [weak self, weak windowScene] _ in
            guard let self, let windowScene, self.isReturningToPortrait,
                  self.requestGeneration == generation,
                  TimerSceneOrientation.shared.isOwner(self, of: windowScene) else { return }
            self.portraitRequestPending = false
            self.didRequestPortraitReturn = false
            self.updateGeometry()
            // A rejected request may coincide with an alert's dismissal.
            // Retry at that transition's completion, not after a guessed delay.
            self.retryPortraitReturnAfterPresentationTransition()
        }
        updateGeometry()
#endif
    }

    private var portraitReturnIsReady: Bool {
        guard didRequestPortraitReturn, let windowScene else { return false }
        return TimerPortraitReturnPolicy.isReady(
            interfaceOrientation: windowScene.effectiveGeometry.interfaceOrientation,
            windowSize: windowScene.coordinateSpace.bounds.size,
            isTransitioning: geometryTransitionInProgress,
            sceneIsActive: windowScene.activationState == .foregroundActive
        )
    }

    private func finishPortraitReturnIfReady() {
        guard isReturningToPortrait, onPortraitReady != nil, portraitReturnIsReady else { return }
        // The transition completion and layout callbacks can arrive in the
        // same run loop. Recheck after the final layout before revealing Home.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isReturningToPortrait, self.portraitReturnIsReady else { return }
            self.completePortraitReturn()
        }
    }

    private func completePortraitReturn() {
        let completion = onPortraitReady
        onPortraitReady = nil
        portraitReturnWatchdog?.cancel()
        portraitReturnWatchdog = nil
        completion?()
    }

    private func retryPortraitReturnAfterPresentationTransition() {
        guard let windowScene else { return }
        for window in windowScene.windows {
            var controller = window.rootViewController
            while let current = controller {
                if let transition = current.transitionCoordinator {
                    if transition.animate(alongsideTransition: nil, completion: { [weak self] _ in
                        self?.retryPortraitReturn()
                    }) { return }
                }
                controller = current.presentedViewController
            }
        }
        portraitReturnWatchdog?.cancel()
        canRetryPortraitReturn = true
    }

    func disappear() {
        isPresented = false
        onPortraitReady = nil
        portraitReturnWatchdog?.cancel()
        portraitReturnWatchdog = nil
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
        if active, isReturningToPortrait {
            retryPortraitReturn()
            return
        }
        if !active, isReturningToPortrait { portraitReturnWatchdog?.cancel() }
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
        guard !isReturningToPortrait else { return }
        state.rotate()
        requestSceneOrientation()
    }

    func followDevice() {
        guard !isReturningToPortrait else { return }
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
    let returnToPortraitRequested: Bool
    let onPortraitReady: () -> Void
    let content: (TimerLayoutContext) -> Content

    init(
        sessionID: AnyHashable,
        returnToPortraitRequested: Bool = false,
        onPortraitReady: @escaping () -> Void = {},
        @ViewBuilder content: @escaping (TimerLayoutContext) -> Content
    ) {
        _orientation = State(initialValue: TimerOrientationController(sessionID: sessionID))
        self.returnToPortraitRequested = returnToPortraitRequested
        self.onPortraitReady = onPortraitReady
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
                .opacity(orientation.isReturningToPortrait ? 0 : 1)
                .allowsHitTesting(!orientation.isReturningToPortrait)
                .accessibilityHidden(orientation.isReturningToPortrait)
        }
        .overlay {
            if orientation.isReturningToPortrait {
                if orientation.canRetryPortraitReturn {
                    Button(String(localized: "瓶へ戻る", table: "Focus", comment: "Button: back to the jar"),
                           action: orientation.retryPortraitReturn)
                        .buttonStyle(.bordered)
                        .tint(PomoGemTheme.amber)
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("timer.portrait-return.retry")
                } else {
                    ProgressView()
                        .tint(PomoGemTheme.muted)
                        .accessibilityLabel(Text("瓶へ戻ります", tableName: "Focus",
                                                 comment: "VoiceOver label of the spinner before going back to the jar"))
                }
            }
        }
        .background {
            TimerWindowSceneReader(onChange: { orientation.attach(to: $0) },
                                   onGeometryChange: { orientation.updateGeometry() },
                                   onTransitionChange: { orientation.geometryTransitionChanged(isTransitioning: $0) })
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
        .onChange(of: returnToPortraitRequested, initial: true) { _, requested in
            if requested { orientation.prepareToReturnToPortrait(then: onPortraitReady) }
        }
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
                    // A meaningful key: the same 「自動」 is the longer
                    // Settings option (TimerDefaultOrientation.title).
                    Text(String(
                        localized: "timer.rotation.automatic",
                        defaultValue: "自動",
                        table: "Focus",
                        comment: "Small timer button that goes back to following the device's orientation (keep it short)"
                    ))
                        .font(.caption)
                        // One unbroken word: at AX5 on a 375 pt screen the
                        // header squeezed "Auto" into 「Aut / o」. The icons
                        // beside it do not grow at all.
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(Text("端末の向きに合わせる", tableName: "Focus",
                                         comment: "VoiceOver label: make the timer follow the device's orientation again"))
                .accessibilityIdentifier("timer.rotation.automatic")
            }
            Button(action: orientation.rotate) {
                Image(systemName: "rotate.right")
                    .font(.system(size: 17, weight: .regular))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(Text("タイマーの向きを変える", tableName: "Focus",
                                     comment: "VoiceOver label: the button that rotates the timer"))
            .accessibilityValue(orientation.state.direction.label)
            .accessibilityHint(Text("上、右、下、左の順に回転し、選んだ向きを保ちます", tableName: "Focus",
                                    comment: "VoiceOver hint: each tap turns the timer up, right, down, left, and keeps the chosen direction"))
            .accessibilityIdentifier("timer.rotate")
        }
        .foregroundStyle(PomoGemTheme.muted)
        .buttonStyle(PomoGemBareButtonStyle())
    }
}

private struct TimerWindowSceneReader: UIViewControllerRepresentable {
    let onChange: (UIWindowScene?) -> Void
    let onGeometryChange: () -> Void
    let onTransitionChange: (Bool) -> Void

    func makeUIViewController(context: Context) -> SceneController {
        let controller = SceneController()
        controller.onChange = onChange
        controller.onGeometryChange = onGeometryChange
        controller.onTransitionChange = onTransitionChange
        return controller
    }

    func updateUIViewController(_ controller: SceneController, context: Context) {
        controller.onChange = onChange
        controller.onGeometryChange = onGeometryChange
        controller.onTransitionChange = onTransitionChange
    }

    final class SceneController: UIViewController {
        var onChange: ((UIWindowScene?) -> Void)?
        var onGeometryChange: (() -> Void)?
        var onTransitionChange: ((Bool) -> Void)?

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
            onTransitionChange?(true)
            // Also observe 180° transitions, whose final bounds and safe-area
            // insets can match the previous landscape orientation exactly.
            coordinator.animate(alongsideTransition: { [weak self] _ in
                self?.publishGeometry()
            }, completion: { [weak self] _ in
                DispatchQueue.main.async { [weak self] in
                    self?.onTransitionChange?(false)
                    self?.publishGeometry()
                }
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
