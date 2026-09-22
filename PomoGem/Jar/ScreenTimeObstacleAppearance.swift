import SpriteKit
import UIKit

/// Matte, chipped rubble uses only native paths. It shares the jar's physical
/// collision shape, but has none of the study crystals' glow or reward marks.
enum ScreenTimeObstacleAppearance {
    static func apply(
        to node: SKShapeNode,
        descriptor: ScreenTimeObstacleDescriptor,
        radius: CGFloat
    ) {
        let bytes = Array(descriptor.id.uuidString.utf8)
        let points: [CGPoint] = (0..<12).map { index in
            let angle = CGFloat(index) / 12 * .pi * 2
            let variation = CGFloat(bytes[index % bytes.count] % 11) / 100
            let scale: CGFloat = index.isMultiple(of: 3) ? 0.78 + variation : 0.90 + variation
            return CGPoint(x: cos(angle) * radius * scale, y: sin(angle) * radius * scale)
        }
        let outline = CGMutablePath()
        outline.move(to: points[0])
        points.dropFirst().forEach { outline.addLine(to: $0) }
        outline.closeSubpath()
        node.path = outline
        node.fillColor = UIColor(red: 0.12, green: 0.12, blue: 0.14, alpha: 1)
        node.strokeColor = UIColor(red: 0.39, green: 0.38, blue: 0.42, alpha: 1)
        node.lineWidth = 1.2
        node.glowWidth = 0

        for index in stride(from: 0, to: points.count, by: 2) {
            let facetPath = CGMutablePath()
            facetPath.move(to: CGPoint(x: -radius * 0.08, y: radius * 0.06))
            facetPath.addLine(to: points[index])
            facetPath.addLine(to: points[(index + 1) % points.count])
            facetPath.closeSubpath()
            let facet = SKShapeNode(path: facetPath)
            facet.name = "obstacle.roughFacet"
            facet.fillColor = UIColor(white: index < 6 ? 0.36 : 0.05, alpha: 0.70)
            facet.strokeColor = UIColor(white: 0.48, alpha: 0.25)
            facet.lineWidth = 0.5
            facet.zPosition = 0.1
            node.addChild(facet)
        }

        let crackPath = CGMutablePath()
        crackPath.move(to: CGPoint(x: -radius * 0.5, y: radius * 0.45))
        crackPath.addLine(to: CGPoint(x: radius * 0.1, y: radius * 0.08))
        crackPath.addLine(to: CGPoint(x: -radius * 0.02, y: -radius * 0.52))
        let crack = SKShapeNode(path: crackPath)
        crack.name = "obstacle.crack"
        crack.strokeColor = UIColor(white: 0.02, alpha: 0.92)
        crack.lineWidth = max(1, radius * 0.08)
        crack.zPosition = 0.2
        node.addChild(crack)

        if descriptor.level > 0 || descriptor.isHistoryPile {
            let label = SKLabelNode(fontNamed: "AvenirNext-DemiBold")
            label.name = "obstacle.count"
            label.text = descriptor.isHistoryPile ? "…" : "×\(descriptor.representedUnits.formatted())"
            label.fontSize = descriptor.level > 3 ? 7 : 9
            label.fontColor = UIColor(white: 0.82, alpha: 1)
            label.horizontalAlignmentMode = .center
            label.verticalAlignmentMode = .center
            label.zPosition = 0.4
            if label.frame.width > radius * 1.6 {
                label.setScale(radius * 1.6 / label.frame.width)
            }
            node.addChild(label)
        }
    }
}
