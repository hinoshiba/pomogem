import SwiftUI
import WidgetKit

@main
struct TsumibenWidgetsBundle: WidgetBundle {
    var body: some Widget {
        JarHomeWidget()
        JarLockScreenWidget()
        FocusLiveActivityWidget()
    }
}
