import Foundation

/// The editor owns its draft until its parent accepts a valid duration.
/// Parsing never rewrites an incomplete input or silently clamps a paste.
struct CustomDurationEditingState: Equatable {
    enum Mode: CaseIterable, Hashable {
        case input, scroll
    }

    private enum Confirmation: Equatable {
        case editing, submitting, accepted, cancelled
    }

    private(set) var minutesText: String
    private(set) var secondsText: String
    private(set) var mode: Mode = .input
    private var confirmation: Confirmation = .editing
    private var parentRejectedConfirmation = false

    init(initialSeconds: Int) {
        minutesText = String(initialSeconds / Constants.Timer.secondsPerMinute)
        secondsText = String(initialSeconds % Constants.Timer.secondsPerMinute)
    }

    var totalSeconds: Int? {
        guard let minutes = Self.decimalInteger(minutesText),
              let seconds = Self.decimalInteger(secondsText),
              (Constants.Timer.customMinimumMinutes...Constants.Timer.customMaximumMinutes).contains(minutes),
              (0..<Constants.Timer.secondsPerMinute).contains(seconds),
              minutes < Constants.Timer.customMaximumMinutes || seconds == 0 else { return nil }
        return minutes * Constants.Timer.secondsPerMinute + seconds
    }

    var canConfirm: Bool { confirmation == .editing && totalSeconds != nil }
    var canChangeMode: Bool { canConfirm }
    var isEditing: Bool { confirmation == .editing }

    var validationMessage: String? {
        if minutesText.isEmpty { return "分を入力してください。" }
        if secondsText.isEmpty { return "秒を入力してください。" }
        guard let minutes = Self.decimalInteger(minutesText),
              (Constants.Timer.customMinimumMinutes...Constants.Timer.customMaximumMinutes).contains(minutes) else {
            return "分は1〜360で入力してください。"
        }
        guard let seconds = Self.decimalInteger(secondsText),
              (0..<Constants.Timer.secondsPerMinute).contains(seconds) else {
            return "秒は0〜59で入力してください。"
        }
        if minutes == Constants.Timer.customMaximumMinutes, seconds != 0 {
            return "360分にする場合は、秒を0にしてください。"
        }
        return parentRejectedConfirmation ? "設定できませんでした。もう一度お試しください。" : nil
    }

    var wheelMinutes: Int { Self.decimalInteger(minutesText) ?? Constants.Timer.customMinimumMinutes }
    var wheelSeconds: Int { Self.decimalInteger(secondsText) ?? 0 }
    var maximumWheelSeconds: Int {
        wheelMinutes == Constants.Timer.customMaximumMinutes ? 0 : Constants.Timer.secondsPerMinute - 1
    }

    mutating func editMinutes(_ text: String) {
        guard isEditing else { return }
        minutesText = text
        parentRejectedConfirmation = false
    }

    mutating func editSeconds(_ text: String) {
        guard isEditing else { return }
        secondsText = text
        parentRejectedConfirmation = false
    }

    @discardableResult
    mutating func selectMode(_ selection: Mode) -> Bool {
        guard canChangeMode else { return false }
        mode = selection
        return true
    }

    mutating func selectWheelMinutes(_ minutes: Int) {
        guard isEditing, mode == .scroll,
              (Constants.Timer.customMinimumMinutes...Constants.Timer.customMaximumMinutes).contains(minutes) else { return }
        minutesText = String(minutes)
        // Selecting the six-hour wheel endpoint also visibly selects zero
        // seconds; numeric entry instead keeps an invalid draft for correction.
        if minutes == Constants.Timer.customMaximumMinutes { secondsText = "0" }
        parentRejectedConfirmation = false
    }

    mutating func selectWheelSeconds(_ seconds: Int) {
        guard isEditing, mode == .scroll, (0...maximumWheelSeconds).contains(seconds) else { return }
        secondsText = String(seconds)
        parentRejectedConfirmation = false
    }

    mutating func beginConfirmation() -> Int? {
        guard canConfirm, let seconds = totalSeconds else { return nil }
        confirmation = .submitting
        return seconds
    }

    mutating func finishConfirmation(accepted: Bool) {
        guard confirmation == .submitting else { return }
        confirmation = accepted ? .accepted : .editing
        parentRejectedConfirmation = !accepted
    }

    mutating func cancel() {
        guard confirmation != .accepted else { return }
        confirmation = .cancelled
    }

    private static func decimalInteger(_ text: String) -> Int? {
        guard !text.isEmpty else { return nil }
        var value = 0
        for character in text {
            guard character.unicodeScalars.allSatisfy(CharacterSet.decimalDigits.contains),
                  let digit = character.wholeNumberValue else { return nil }
            let multiplied = value.multipliedReportingOverflow(by: 10)
            let added = multiplied.partialValue.addingReportingOverflow(digit)
            guard !multiplied.overflow, !added.overflow else { return nil }
            value = added.partialValue
        }
        return value
    }
}
