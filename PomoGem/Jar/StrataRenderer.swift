import CryptoKit
import SpriteKit

struct JarStratumVisual: Identifiable, Equatable, Sendable {
    let id: UUID
    let bakedAt: Date
    let pebbleCount: Int
    let grams: Int
    let height: CGFloat
    let colorMix: [StratumColorFraction]
    let monthLabel: String
    let sessionIDs: [UUID]

    init(
        id: UUID = UUID(),
        bakedAt: Date = .now,
        pebbleCount: Int,
        grams: Int? = nil,
        height: CGFloat,
        colorMix: [StratumColorFraction],
        monthLabel: String,
        sessionIDs: [UUID] = []
    ) {
        self.id = id
        self.bakedAt = bakedAt
        self.pebbleCount = NonnegativeIntPolicy.clamped(pebbleCount)
        self.grams = NonnegativeIntPolicy.clamped(
            grams ?? NonnegativeIntPolicy.multiplying(
                pebbleCount,
                Constants.Mass.measuredPebbleGrams
            )
        )
        self.height = height
        self.colorMix = colorMix
        self.monthLabel = monthLabel
        self.sessionIDs = Set(sessionIDs).sorted {
            $0.uuidString < $1.uuidString
        }
    }

    init(stratum: Stratum) {
        let mix = StrataMath.decodeColorMix(stratum.colorMixJSON)
        self.init(
            id: stratum.id,
            bakedAt: stratum.bakedAt,
            pebbleCount: stratum.pebbleCount,
            grams: stratum.grams,
            height: CGFloat(stratum.heightPt),
            colorMix: mix,
            monthLabel: stratum.monthLabel,
            sessionIDs: stratum.sessionIDs
        )
    }

    /// Mirrors bootstrap reconciliation for a frame that arrives before SwiftData has
    /// persisted the merge: duplicate IDs are combined, then overlapping membership is
    /// assigned to the oldest layer exactly once.
    static func normalized(_ values: [Self]) -> [Self] {
        var strataByID: [UUID: Self] = [:]
        for value in values {
            guard let existing = strataByID[value.id] else {
                strataByID[value.id] = value
                continue
            }
            let usesValueAsCanonical = value.bakedAt < existing.bakedAt
            let canonical = usesValueAsCanonical ? value : existing
            let alternate = usesValueAsCanonical ? existing : value
            strataByID[value.id] = Self(
                id: canonical.id,
                bakedAt: canonical.bakedAt,
                pebbleCount: max(existing.pebbleCount, value.pebbleCount),
                grams: max(existing.grams, value.grams),
                height: max(existing.height, value.height),
                colorMix: canonical.colorMix.isEmpty
                    ? alternate.colorMix
                    : canonical.colorMix,
                monthLabel: canonical.monthLabel.isEmpty
                    ? alternate.monthLabel
                    : canonical.monthLabel,
                sessionIDs: existing.sessionIDs + value.sessionIDs
            )
        }

        let ordered = strataByID.values.sorted { lhs, rhs in
            if lhs.bakedAt == rhs.bakedAt {
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return lhs.bakedAt < rhs.bakedAt
        }
        var claimedSessionIDs = Set<UUID>()
        var result: [Self] = []
        for value in ordered {
            let membership = Set(value.sessionIDs)
            guard !membership.isEmpty else {
                result.append(value)
                continue
            }
            let uniqueMembership = membership.subtracting(claimedSessionIDs)
            guard !uniqueMembership.isEmpty else { continue }
            claimedSessionIDs.formUnion(uniqueMembership)
            guard uniqueMembership.count != membership.count else {
                result.append(value)
                continue
            }
            let retainedFraction = CGFloat(uniqueMembership.count) / CGFloat(membership.count)
            result.append(
                Self(
                    id: value.id,
                    bakedAt: value.bakedAt,
                    pebbleCount: uniqueMembership.count,
                    grams: NonnegativeIntPolicy.clamped(
                        (Double(value.grams) * Double(uniqueMembership.count)
                            / Double(max(membership.count, 1))).rounded()
                    ),
                    height: value.height * retainedFraction,
                    colorMix: value.colorMix,
                    monthLabel: value.monthLabel,
                    sessionIDs: Array(uniqueMembership)
                )
            )
        }
        return result
    }

    /// Legacy strata are presented as movable aggregate pebbles during the
    /// non-destructive migration window. They never raise the bottle floor.
    var aggregateDescriptor: PebbleDescriptor {
        let subjects = colorMix.enumerated().map { index, item in
            AggregateSubjectFraction(
                name: index == 0 ? "過去の集中" : "過去の集中 \(index + 1)",
                colorHex: item.hex,
                pebbleCount: NonnegativeIntPolicy.clamped(
                    (item.fraction * Double(max(pebbleCount, 1))).rounded()
                )
            )
        }
        let metadata = AggregateMetadata(
            level: max(1, StrataMath.decimalAggregateLevel(forPebbleCount: pebbleCount)),
            pebbleCount: pebbleCount,
            childAggregateCount: 0,
            colorMix: colorMix,
            subjectMix: subjects,
            periodStart: bakedAt,
            periodEnd: bakedAt,
            sessionIDs: sessionIDs,
            measuredPebbleCount: pebbleCount,
            manualPebbleCount: 0,
            goldPebbleCount: 0,
            prismPebbleCount: 0
        )
        return PebbleDescriptor(
            id: id,
            subjectName: metadata.primarySubjectName,
            colorHex: metadata.dominantColorHex,
            source: .timer,
            kind: .normal,
            aggregate: metadata,
            grams: grams,
            radius: CGFloat(StrataMath.aggregateRadius(level: metadata.level)),
            createdAt: bakedAt
        )
    }
}

struct JarBedrockVisual: Equatable, Sendable {
    let hours: Int
    let importedAt: Date

    init(hours: Int, importedAt: Date = .now) {
        self.hours = hours
        self.importedAt = importedAt
    }

    init(bedrock: Bedrock) {
        self.init(hours: bedrock.hours, importedAt: bedrock.importedAt)
    }

    var height: CGFloat { CGFloat(StrataMath.bedrockHeight(hours: hours)) }
}

struct JarAggregateRequest: Identifiable {
    let id: UUID
    let createdAt: Date
    let pebbles: [PebbleDescriptor]
    let height: CGFloat
    let colorMix: [StratumColorFraction]
    let monthLabel: String
    let calculation: AggregateCalculation

    init?(
        id: UUID? = nil,
        createdAt: Date = .now,
        pebbles: [PebbleDescriptor],
        innerWidth: CGFloat,
        calendar: Calendar = .current
    ) {
        guard !pebbles.contains(where: \.isScreenTimeObstacle) else { return nil }
        let sources = pebbles.map(\.aggregateSource)
        guard let calculation = StrataMath.aggregate(sources: sources) else { return nil }
        self.id = id ?? Self.deterministicID(
            sourceIDs: pebbles.map(\.id),
            outputLevel: calculation.level
        )
        self.createdAt = createdAt
        self.pebbles = pebbles
        self.calculation = calculation
        self.height = CGFloat(
            StrataMath.stratumHeight(
                pebbleRadii: pebbles.map { Double($0.radius) },
                innerWidth: Double(innerWidth)
            )
        )
        self.colorMix = calculation.colorMix
        self.monthLabel = StrataMath.monthLabel(
            for: createdAt,
            timeZone: calendar.timeZone
        )
    }

    var pebbleIDs: [UUID] { pebbles.map(\.id) }
    var sourceCount: Int { pebbles.count }
    var pebbleCount: Int { calculation.pebbleCount }
    var containedPebbleCount: Int { calculation.pebbleCount }
    var grams: Int { calculation.grams }
    var outputLevel: Int { calculation.level }
    var childAggregateIDs: [UUID] { calculation.childAggregateIDs }

    var outputDescriptor: PebbleDescriptor {
        let metadata = AggregateMetadata(
            level: calculation.level,
            pebbleCount: calculation.pebbleCount,
            childAggregateCount: calculation.childAggregateCount,
            colorMix: calculation.colorMix,
            subjectMix: calculation.subjectMix,
            periodStart: calculation.periodStart,
            periodEnd: calculation.periodEnd,
            sessionIDs: calculation.sessionIDs,
            measuredPebbleCount: calculation.measuredPebbleCount,
            manualPebbleCount: calculation.manualPebbleCount,
            goldPebbleCount: calculation.goldPebbleCount,
            prismPebbleCount: calculation.prismPebbleCount
        )
        return PebbleDescriptor(
            id: id,
            subjectName: metadata.primarySubjectName,
            colorHex: metadata.dominantColorHex,
            source: calculation.manualPebbleCount > calculation.measuredPebbleCount
                ? .manual
                : .timer,
            kind: .normal,
            aggregate: metadata,
            grams: calculation.grams,
            radius: CGFloat(calculation.radius),
            createdAt: createdAt
        )
    }

    var visual: JarStratumVisual {
        JarStratumVisual(
            id: id,
            bakedAt: createdAt,
            pebbleCount: containedPebbleCount,
            grams: grams,
            height: height,
            colorMix: colorMix,
            monthLabel: monthLabel,
            sessionIDs: calculation.sessionIDs
        )
    }

    func encodedColorMix() -> String {
        StrataMath.encodeColorMix(colorMix)
    }

    func makeStratum() -> Stratum {
        Stratum(
            id: id,
            bakedAt: createdAt,
            pebbleCount: containedPebbleCount,
            heightPt: Double(height),
            colorMixJSON: encodedColorMix(),
            monthLabel: monthLabel,
            grams: grams,
            sessionIDs: pebbleIDs
        )
    }

    func makeAggregatePebble() -> AggregatePebble {
        AggregatePebble(
            id: id,
            createdAt: createdAt,
            level: calculation.level,
            pebbleCount: calculation.pebbleCount,
            childAggregateCount: calculation.childAggregateCount,
            grams: calculation.grams,
            measuredPebbleCount: calculation.measuredPebbleCount,
            manualPebbleCount: calculation.manualPebbleCount,
            goldPebbleCount: calculation.goldPebbleCount,
            prismPebbleCount: calculation.prismPebbleCount,
            colorMixJSON: encodedColorMix(),
            subjectMixJSON: StrataMath.encodeSubjectMix(calculation.subjectMix),
            periodStart: calculation.periodStart,
            periodEnd: calculation.periodEnd,
            sessionIDs: calculation.sessionIDs,
            childAggregateIDs: calculation.childAggregateIDs
        )
    }

    /// Produces one CloudKit-safe identity for the same unordered pebble set on every device.
    /// UUID version 8 denotes the app-defined SHA-256 name scheme while retaining the RFC
    /// variant bits expected by UUID tooling.
    static func deterministicID(sourceIDs: [UUID], outputLevel: Int) -> UUID {
        let canonicalIDs = Set(sourceIDs)
            .map(\.uuidString)
            .sorted()
        var input = Data("jp.pomogem.aggregate.v2.level.\(max(1, outputLevel))".utf8)
        for identifier in canonicalIDs {
            input.append(0)
            input.append(contentsOf: identifier.utf8)
        }

        var bytes = Array(SHA256.hash(data: input).prefix(16))
        let versionByteIndex = 6
        let variantByteIndex = 8
        let lowNibbleMask: UInt8 = 0x0F
        let uuidVariantMask: UInt8 = 0x3F
        let customVersionBits: UInt8 = 0x80
        let rfcVariantBits: UInt8 = 0x80
        bytes[versionByteIndex] = (bytes[versionByteIndex] & lowNibbleMask)
            | customVersionBits
        bytes[variantByteIndex] = (bytes[variantByteIndex] & uuidVariantMask)
            | rfcVariantBits

        return UUID(
            uuid: (
                bytes[0], bytes[1], bytes[2], bytes[3],
                bytes[4], bytes[5], bytes[6], bytes[7],
                bytes[8], bytes[9], bytes[10], bytes[11],
                bytes[12], bytes[13], bytes[14], bytes[15]
            )
        )
    }

    static func deterministicID(pebbleIDs: [UUID]) -> UUID {
        deterministicID(sourceIDs: pebbleIDs, outputLevel: 1)
    }
}

/// Source compatibility while Home transitions from fixed layers to movable
/// aggregates. The payload now describes a decimal aggregate request.
typealias JarBakeRequest = JarAggregateRequest

/// Procedurally renders the immutable layers under the live SpriteKit bodies.
@MainActor
final class StrataRenderer {
    private let rootNode = SKNode()
    private let layersNode = SKNode()
    private(set) var strata: [JarStratumVisual] = []
    private(set) var bedrock: JarBedrockVisual?
    private(set) var showsMonthLabels = false
    private(set) var totalHeight: CGFloat = .zero
    private(set) var compactionScale: CGFloat = 1

    func install(in parent: SKNode) {
        guard rootNode.parent !== parent else { return }
        rootNode.removeFromParent()
        rootNode.name = "jar.strata"
        rootNode.zPosition = JarZPosition.strata
        parent.addChild(rootNode)
    }

    func render(
        strata: [JarStratumVisual],
        bedrock: JarBedrockVisual?,
        in interiorRect: CGRect,
        showsMonthLabels: Bool,
        animatedStratumID: UUID? = nil,
        reduceMotion: Bool
    ) {
        self.strata = strata
        self.bedrock = bedrock
        self.showsMonthLabels = showsMonthLabels
        rootNode.removeAllChildren()
        // Fixed strata and bedrock were retired. Legacy inputs are converted to
        // movable aggregate descriptors by JarScene; this renderer deliberately
        // occupies no height and therefore can never raise the physics floor.
        compactionScale = 1
        totalHeight = 0
        rootNode.position = CGPoint(x: .zero, y: interiorRect.minY)
        rootNode.yScale = 1
        layersNode.removeAllChildren()
    }

}
