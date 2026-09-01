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

    static let widget = Self(
        includesSelfReported: true,
        includesTransientEffects: false
    )

    static func share(includesSelfReported: Bool, outputSize: CGSize? = nil) -> Self {
        Self(
            includesSelfReported: includesSelfReported,
            includesTransientEffects: false,
            outputSize: outputSize
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
                !options.includesSelfReported && !$0.descriptor.isMeasured
            } ?? false
            let isTransient = node.name?.hasPrefix("drop.") == true
                || node.name?.hasPrefix("ambient.") == true
            guard shouldHidePebble || (!options.includesTransientEffects && isTransient) else {
                return
            }
            visibility.append((node, node.isHidden))
            node.isHidden = true
        }

        scene.camera?.position = scene.cameraRestPosition
        defer {
            scene.camera?.position = originalCameraPosition ?? scene.cameraRestPosition
            visibility.forEach { $0.node.isHidden = $0.wasHidden }
        }

        guard let texture = view.texture(from: scene, crop: scene.snapshotRect) else {
            throw JarSnapshotError.textureUnavailable
        }
        let cgImage = texture.cgImage()
        let source = UIImage(cgImage: cgImage, scale: 1, orientation: .up)
        guard let outputSize = options.outputSize else { return source }
        return scaledImage(
            source,
            size: outputSize,
            backgroundColor: options.backgroundColor
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
