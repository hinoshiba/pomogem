import CoreGraphics

/// D5 (GemExperienceDesign §8.1): where Home's jar readout sits.
///
/// Above the mouth, a compact readout (「瓶N杯」, 積み上げた集中, the mass, the
/// count pill and the next-target line) leaves the bottle to the time core
/// and the gems, as in the reference image. The bottle then gives up the
/// readout's height. Where that would leave a bottle under 320 pt (an
/// iPhone SE, a 12 mini while the crystal tip row takes 72 pt) and at every
/// accessibility text size, the readout goes back inside the jar exactly as
/// before (#47's mouth-following position, #50's plates).
///
/// Pure geometry in the jar card's coordinates (y down). The decision is
/// taken from the card's resting height, so a completion card, which
/// shortens the jar for a few seconds, never moves the readout in and out:
/// above the mouth the bottle keeps at least 320 pt and the card grows past
/// the viewport instead (it scrolls, the completion card covers its foot).
struct JarHUDLayout: Equatable, Sendable {
    enum Placement: Equatable, Sendable {
        case aboveMouth
        case inside
    }

    let placement: Placement
    /// The jar card: the readout above the mouth (if any) and the stage.
    let cardHeight: CGFloat
    /// The SpriteKit stage in the card.
    let stageTop: CGFloat
    let stageHeight: CGFloat

    /// The shortest bottle the readout may leave (§8.1).
    static let minimumBottleHeight: CGFloat = 320
    /// Air between the readout and the collar.
    static let mouthGap: CGFloat = 6
    /// Above the mouth, at most this much spare room on each side of the
    /// readout and bottle (tall phones), so the readout still hugs the
    /// mouth instead of floating under the menu.
    static let maximumSlack: CGFloat = 18
    /// Inside, the stage never grows past this (the bottle is at most
    /// `Constants.Jar.height` and centred in it).
    static let maximumInsideStageHeight: CGFloat = 520
    static let minimumInsideStageHeight: CGFloat = 320

    var isAboveMouth: Bool { placement == .aboveMouth }

    /// The readout's bottom edge above the mouth; nil inside.
    var hudBottom: CGFloat? {
        isAboveMouth ? stageTop - Self.mouthGap : nil
    }

    /// - Parameters:
    ///   - keepsReadoutInside: the readout stays inside whatever the room
    ///     (Home handles accessibility text sizes itself: its plates are
    ///     capped there, the card under the jar repeats them in full-size
    ///     text and the jar is at least 300 pt; the Debug review seam).
    ///   - restingRoom: the room Home has for the jar card with no completion
    ///     card up (the viewport less the controls under the jar).
    ///   - room: the room now (a completion card shortens it).
    ///   - readoutHeight: the compact readout's height above the mouth.
    static func resolve(
        keepsReadoutInside: Bool = false,
        restingRoom: CGFloat,
        room: CGFloat,
        readoutHeight: CGFloat
    ) -> JarHUDLayout {
        let reserve = max(0, readoutHeight) + mouthGap
        let bottle = Constants.Jar.height
        let restingBottle = min(bottle, max(0, restingRoom) - reserve)
        guard !keepsReadoutInside, restingBottle >= minimumBottleHeight else {
            let height = min(maximumInsideStageHeight, max(minimumInsideStageHeight, room))
            return JarHUDLayout(placement: .inside, cardHeight: height, stageTop: 0, stageHeight: height)
        }
        let card = min(reserve + bottle + maximumSlack * 2, max(reserve + minimumBottleHeight, room))
        let stage = min(bottle, card - reserve)
        let slack = max(0, card - reserve - stage)
        return JarHUDLayout(
            placement: .aboveMouth,
            cardHeight: card,
            stageTop: slack / 2 + reserve,
            stageHeight: stage
        )
    }
}
