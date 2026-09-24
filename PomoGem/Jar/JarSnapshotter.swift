import SpriteKit
import UIKit

enum JarSnapshotError: LocalizedError {
    case sceneNotPresented
    case textureUnavailable
    case imageUnavailable

    var errorDescription: String? {
        switch self {
        case .sceneNotPresented:
            "瓶の描画がまだ準備できていません。"
        case .textureUnavailable:
            "瓶の描画を取得できませんでした。"
        case .imageUnavailable:
            "瓶の画像を生成できませんでした。"
        }
    }
}

struct JarSnapshotOptions {
    var includesSelfReported = true
    var includesTransientEffects = false
    var outputSize: CGSize?
    var backgroundColor: UIColor?
    /// Draws the jar's stage light and the time core (both SwiftUI layers
    /// behind the scene on Home) behind the bottle, so a share shows the
    /// same jar as Home (Docs/GemExperienceDesign.md §7.9, §8.6).
    var includesStage = false

    static let widget = Self(
        includesSelfReported: true,
        includesTransientEffects: false
    )

    static func share(includesSelfReported: Bool, outputSize: CGSize? = nil) -> Self {
        Self(
            includesSelfReported: includesSelfReported,
            includesTransientEffects: false,
            outputSize: outputSize,
            includesStage: true
        )
    }
}

/// Captures the live jar without forcing the physics scene to be rebuilt or unpaused.
@MainActor
final class JarSnapshotter {
    static let shared = JarSnapshotter()

    private var widgetPublication: Task<Void, Error>?

    private init() {}

    func image(
        of scene: JarScene,
        options: JarSnapshotOptions = .widget
    ) throws -> UIImage {
        guard let view = scene.view else { throw JarSnapshotError.sceneNotPresented }

        let originalCameraPosition = scene.camera?.position
        var visibility: [(node: SKNode, wasHidden: Bool)] = []
        scene.enumerateChildNodes(withName: "//*") { node, _ in
            let shouldHidePebble = (node as? PebbleNode).map {
                // Device-local distraction history has no study mass and is
                // never published as part of a study-only share or widget.
                $0.descriptor.isScreenTimeObstacle
                    || (!options.includesSelfReported && !$0.descriptor.isMeasured)
            } ?? false
            let isTransient = node.name?.hasPrefix("drop.") == true
                || node.name?.hasPrefix("ambient.") == true
                || node.name == "obstacle.fusion"
            guard shouldHidePebble || node.name == "obstacle.fusion"
                || (!options.includesTransientEffects && isTransient) else {
                return
            }
            visibility.append((node, node.isHidden))
            node.isHidden = true
        }

        scene.camera?.position = scene.cameraRestPosition
        // Settled stars and alpha-blended light: the capture is deterministic
        // and survives the transparent texture → PNG round trip.
        let restoreLighting = scene.prepareForSnapshot()
        defer {
            restoreLighting()
            scene.camera?.position = originalCameraPosition ?? scene.cameraRestPosition
            visibility.forEach { $0.node.isHidden = $0.wasHidden }
        }

        guard let texture = view.texture(from: scene, crop: scene.snapshotRect) else {
            throw JarSnapshotError.textureUnavailable
        }
        let cgImage = texture.cgImage()
        var source = UIImage(cgImage: cgImage, scale: 1, orientation: .up)
        if options.includesStage {
            source = composited(scene: source, of: scene)
        }
        guard let outputSize = options.outputSize else { return source }
        return scaledImage(
            source,
            size: outputSize,
            backgroundColor: options.backgroundColor
        )
    }

    /// Where the centrepiece sits in a share snapshot (stage points, y down).
    private func shareCoreCenter(of scene: JarScene) -> CGPoint {
        let jar = JarStageArtwork.jarRect(stageSize: scene.size)
        return CGPoint(x: jar.midX, y: jar.minY + jar.height * JarShareCoreArtwork.centerFraction)
    }

    /// Stage light, then the centrepiece, then the captured bottle on top
    /// (the bottle's back glass tints what lies behind it, as on Home).
    private func composited(scene sceneImage: UIImage, of scene: JarScene) -> UIImage {
        let crop = scene.snapshotRect
        let pixelSize = CGSize(
            width: sceneImage.size.width * sceneImage.scale,
            height: sceneImage.size.height * sceneImage.scale
        )
        guard crop.width > 0, crop.height > 0, pixelSize.width > 0 else { return sceneImage }
        let pointsToPixels = pixelSize.width / crop.width
        let stageSize = scene.size
        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = 1
        format.opaque = false
        format.preferredRange = .standard
        return UIGraphicsImageRenderer(size: pixelSize, format: format).image { renderer in
            let context = renderer.cgContext
            context.saveGState()
            context.scaleBy(x: pointsToPixels, y: pointsToPixels)
            // Stage coordinates are y down; the crop's top edge is at
            // stage y = height − crop.maxY.
            context.translateBy(x: -crop.minX, y: -(stageSize.height - crop.maxY))
            JarStageArtwork.draw(in: context, stageSize: stageSize, strength: 1)
            if let core = scene.shareCore {
                JarShareCoreArtwork.draw(
                    core,
                    center: shareCoreCenter(of: scene),
                    in: context,
                    scale: min(3, max(1, pointsToPixels))
                )
            }
            context.restoreGState()
            sceneImage.draw(in: CGRect(origin: .zero, size: pixelSize))
        }
    }

    /// The motion a share GIF lays over the snapshot `image(of:options:)`
    /// returns for `.share` (normalised to it): the centrepiece's stone and
    /// glints on the highest resting gems.
    func shareMotion(of scene: JarScene) -> ShareJarMotion? {
        let crop = scene.snapshotRect
        guard crop.width > 0, crop.height > 0 else { return nil }
        let stageTop = scene.size.height - crop.maxY
        func normalized(stage point: CGPoint) -> CGPoint {
            CGPoint(x: (point.x - crop.minX) / crop.width, y: (point.y - stageTop) / crop.height)
        }
        let glints = scene.shareGlintAnchors().map { point in
            normalized(stage: CGPoint(x: point.x, y: scene.size.height - point.y))
        }
        guard let core = scene.shareCore else {
            return glints.isEmpty ? nil : ShareJarMotion(stone: nil, stoneRect: .zero, glowColor: .white, glints: glints)
        }
        let rect = JarShareCoreArtwork.stoneRect(for: core, center: shareCoreCenter(of: scene))
        let origin = normalized(stage: rect.origin)
        // A pile that reaches the core keeps it behind the gems: then only
        // its glow breathes, never the stone drawn over a body.
        let sceneRect = CGRect(x: rect.minX, y: scene.size.height - rect.maxY, width: rect.width, height: rect.height)
        let stoneIsClear = !scene.hasBody(intersecting: sceneRect)
        return ShareJarMotion(
            stone: stoneIsClear ? JarShareCoreArtwork.stoneImage(for: core, scale: 3) : nil,
            stoneRect: CGRect(x: origin.x, y: origin.y, width: rect.width / crop.width, height: rect.height / crop.height),
            glowColor: core.vesselLitFacets == nil ? GemArtwork.coreRimGlowColor(shares: core.shares) : .white,
            glints: glints
        )
    }

    func pngData(
        of scene: JarScene,
        options: JarSnapshotOptions = .widget
    ) throws -> Data {
        let snapshot = try image(of: scene, options: options)
        guard let data = snapshot.pngData() else { throw JarSnapshotError.imageUnavailable }
        return data
    }

    func publishWidgetSnapshot(
        of scene: JarScene,
        metadata: WidgetSnapshotMetadata
    ) async throws {
        guard ReleaseExternalSurfacePolicy.showsAccountDataInWidgets else { return }
        let snapshot = try image(of: scene, options: .widget)
        let previous = widgetPublication
        let publication = Task { @MainActor in
            _ = try? await previous?.value
            try await WidgetSnapshotStore.shared.save(image: snapshot, metadata: metadata)
        }
        widgetPublication = publication
        try await publication.value
    }

    private func scaledImage(
        _ image: UIImage,
        size: CGSize,
        backgroundColor: UIColor?
    ) -> UIImage {
        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = 1
        format.opaque = backgroundColor != nil
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            if let backgroundColor {
                backgroundColor.setFill()
                context.cgContext.fill(CGRect(origin: .zero, size: size))
            }

            let sourceAspect = image.size.width / max(image.size.height, 1)
            let targetAspect = size.width / max(size.height, 1)
            let drawSize: CGSize
            if sourceAspect > targetAspect {
                drawSize = CGSize(width: size.width, height: size.width / sourceAspect)
            } else {
                drawSize = CGSize(width: size.height * sourceAspect, height: size.height)
            }
            let drawRect = CGRect(
                x: (size.width - drawSize.width) / 2,
                y: (size.height - drawSize.height) / 2,
                width: drawSize.width,
                height: drawSize.height
            )
            image.draw(in: drawRect)
        }
    }
}
