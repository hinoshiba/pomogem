import CoreGraphics

/// Seats 記念石 on whatever is actually under them in the drawn share bottle.
///
/// `ShareJarGraphic` put every stone on a shelf 7 pt above the highest gem
/// row, whatever lay beneath it. Gems fill their rows from the left, so with
/// a few gems the stones hovered over empty glass, and jar-04 sends many
/// lifetime cards to this drawing. Each stone now rests on the highest gem,
/// crystal or earlier stone below its middle, or on the bottle floor.
enum ShareJarPileLayout {
    /// Something already in the bottle: its horizontal extent, in points from
    /// the bottle's centre line, and the height above the floor at which the
    /// next thing rests on it.
    struct Footprint: Equatable {
        let minX: CGFloat
        let maxX: CGFloat
        let top: CGFloat
    }

    /// The height above the floor of each stone's bottom edge, in order.
    ///
    /// - Parameters:
    ///   - centerXs: Each stone's horizontal centre.
    ///   - stoneSize: The side of a stone's square frame.
    ///   - stackingHeight: How much a seated stone raises the pile under it.
    ///   - floor: The bottle's inner floor.
    ///   - footprints: Gems and crystals already drawn.
    static func stoneBottoms(
        centerXs: [CGFloat],
        stoneSize: CGFloat,
        stackingHeight: CGFloat,
        floor: CGFloat,
        footprints: [Footprint]
    ) -> [CGFloat] {
        var pile = footprints
        // Only a stone's middle has to find support. Its artwork is rounded,
        // so a corner overlapping a neighbour's edge must not lift it.
        let contactHalfWidth = stoneSize * 0.3
        return centerXs.map { x in
            let minX = x - contactHalfWidth
            let maxX = x + contactHalfWidth
            let support = pile
                .filter { $0.maxX > minX && $0.minX < maxX }
                .map(\.top)
                .max() ?? floor
            let bottom = max(floor, support)
            pile.append(Footprint(
                minX: x - stoneSize / 2,
                maxX: x + stoneSize / 2,
                top: bottom + stackingHeight
            ))
            return bottom
        }
    }
}
