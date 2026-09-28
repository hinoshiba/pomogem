import CoreGraphics

/// home-11 (the #50 follow-up): where a tapped crystal's card shows once the
/// tip row under the jar has gone. Always under the jar: never over the
/// readout, the time core or the pile, and never over the start button.
///
/// Pure geometry in the Home content's coordinates (y down, 0 at the jar
/// card's top), so a unit test can pin it for every phone.
enum AggregateCardPlacementPolicy {
    enum Placement: Equatable {
        /// The row under the jar, inserted while the card is up (Home scrolls
        /// it into view): at accessibility sizes, where the card is about
        /// 264 pt tall and the jar can be 300 pt, and at default sizes on a
        /// screen with too little room above the start button (large text
        /// on a small phone).
        case row
        /// Hanging under the bottle's base, like the capacity chip, in the
        /// room above the start button. Nothing on the screen moves. Where
        /// the card reaches the theme and time pickers, they give way to it
        /// for its few seconds.
        case underBottle(hidesPickers: Bool)
    }

    /// Between the bottle's base and the card, and between the card and the
    /// row it must stay above.
    static let gap: CGFloat = 6
    /// The default-size card with its two-line caption on a 375 pt phone,
    /// until the laid-out card is measured.
    static let estimatedCardHeight: CGFloat = 64

    /// - Parameters:
    ///   - bottleBase: the bottle's base.
    ///   - cardHeight: the card's laid-out height.
    ///   - pickerTop: the theme and time pickers' top; `nil` without them.
    ///   - launcherTop: the start button's top; `nil` while it is pinned
    ///     below the scroll view or not measured yet.
    static func placement(
        isAccessibilitySize: Bool,
        bottleBase: CGFloat,
        cardHeight: CGFloat,
        pickerTop: CGFloat?,
        launcherTop: CGFloat?
    ) -> Placement {
        guard !isAccessibilitySize, let launcherTop else { return .row }
        let cardBottom = bottleBase + gap + max(0, cardHeight)
        guard cardBottom + gap <= launcherTop else { return .row }
        let hidesPickers = pickerTop.map { cardBottom + gap > $0 } ?? false
        return .underBottle(hidesPickers: hidesPickers)
    }
}
