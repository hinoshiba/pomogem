import SpriteKit
import UIKit

/// One runtime texture atlas for every gem-family sprite in the jar
/// (Docs/GemExperienceDesign.md §7.13): the shared light images (halo,
/// glint, contact shadow, the rig's key light and shade) and every baked
/// body — facet bodies and Screen Time rubble alike.
///
/// SpriteKit batches consecutive sprites that share a GPU texture and a blend
/// mode. With the scene's per-body stacking bands (`JarZPosition`) each gem
/// layer is one contiguous run, so a page shared by all of them turns
/// "one draw per sprite" into a few draws for the whole jar. Pixels never
/// change: an atlas entry is the same bitmap as its stand-alone texture.
///
/// A name that is not packed yet is served from a stand-alone texture at
/// once (the fallback is synchronous, never blank). New names start a
/// coalesced rebuild: `SKTextureAtlas(dictionary:)` packs every kept image
/// on a utility queue, preloads the page, and only then re-points the
/// registered sprites on the main thread. Kept images are bounded by
/// `imageByteBudget` (least recently used first).
@MainActor
final class GemTextureAtlas {
    static let shared = GemTextureAtlas()

    enum SharedName {
        static let halo = "gem.shared.halo"
        static let glint = "gem.shared.glint"
        static let shadow = "gem.shared.shadow"
        static let lightAdd = "gem.shared.lightAdd"
        static let lightShade = "gem.shared.lightShade"
    }

    /// Kept source images (RGBA bytes). A full jar needs about 3–7 MB at 3×;
    /// the budget leaves room for the share/plan jars without growing
    /// without bound.
    static let imageByteBudget = 24 * 1_024 * 1_024

    struct Statistics: Equatable {
        var generation: Int
        var packedNames: Int
        var keptImages: Int
        var keptImageBytes: Int
        var standaloneTextures: Int
        /// Pixel size of the installed page, derived from its largest entry.
        var pageSize: CGSize
    }

    private struct Entry {
        let image: UIImage
        let bytes: Int
        var lastUse: UInt64
        let isPinned: Bool
    }

    private var entries: [String: Entry] = [:]
    private var keptBytes = 0
    private var useClock: UInt64 = 0
    /// Resolved textures of the installed generation, by name.
    private var packed: [String: SKTexture] = [:]
    private var standalone: [String: SKTexture] = [:]
    /// Sprites that show a managed texture (weak), re-pointed at every new
    /// generation.
    private let registry = NSMapTable<SKSpriteNode, NSString>(
        keyOptions: .weakMemory,
        valueOptions: .strongMemory
    )
    private var isRebuildScheduled = false
    private var isBuilding = false
    private(set) var generation = 0
    /// Coalescing delay after a new name before the atlas is rebuilt.
    var rebuildDelay: TimeInterval = 0.25
    /// Tests pack synchronously with `rebuildNow()`.
    var rebuildsAutomatically = true

    private init() {
        let shared: [(String, UIImage, SKTexture)] = [
            (SharedName.halo, GemArtwork.haloImage, GemArtwork.haloTexture),
            (SharedName.glint, GemArtwork.glintImage, GemArtwork.glintTexture),
            (SharedName.shadow, GemArtwork.shadowImage, GemArtwork.shadowTexture),
            (SharedName.lightAdd, GemArtwork.lightRigAddImage, GemArtwork.lightRigAddTexture),
            (SharedName.lightShade, GemArtwork.lightRigShadeImage, GemArtwork.lightRigShadeTexture)
        ]
        for (name, image, texture) in shared {
            store(name, image: image, pinned: true)
            standalone[name] = texture
        }
    }

    // MARK: Lookup

    /// The texture for `name`: the packed one when the current page holds
    /// it, else a stand-alone texture of the same bitmap (baked now with
    /// `image` on a miss).
    func texture(named name: String, image makeImage: () -> UIImage) -> SKTexture {
        touch(name)
        if let texture = packed[name] { return texture }
        if let texture = standalone[name] { return texture }
        let image = entries[name]?.image ?? makeImage()
        if entries[name] == nil { store(name, image: image, pinned: false) }
        let texture = SKTexture(image: image)
        texture.filteringMode = .linear
        standalone[name] = texture
        scheduleRebuild()
        return texture
    }

    /// Shows `name` on `sprite` and keeps the sprite on the current page.
    func show(_ name: String, on sprite: SKSpriteNode, image makeImage: () -> UIImage) {
        sprite.texture = texture(named: name, image: makeImage)
        registry.setObject(name as NSString, forKey: sprite)
    }

    /// Shared light images are always kept, so they never need a bake.
    func showShared(_ name: String, on sprite: SKSpriteNode) {
        show(name, on: sprite) { entries[name]?.image ?? GemArtwork.haloImage }
    }

    func textureName(of sprite: SKSpriteNode) -> String? {
        registry.object(forKey: sprite) as String?
    }

    func isPacked(_ name: String) -> Bool { packed[name] != nil }

    func hasImage(named name: String) -> Bool { entries[name] != nil }

    /// Adds images baked elsewhere (the launch pre-bake) without a sprite.
    func insert(_ images: [(name: String, image: UIImage)]) {
        var added = false
        for (name, image) in images where entries[name] == nil {
            store(name, image: image, pinned: false)
            added = true
        }
        if added { scheduleRebuild() }
    }

    /// Drops kept images (tests). Sprites keep what they show.
    func removeImages(named names: [String]) {
        for name in names {
            guard let entry = entries[name], !entry.isPinned else { continue }
            entries[name] = nil
            standalone[name] = nil
            keptBytes -= entry.bytes
        }
    }

    var statistics: Statistics {
        Statistics(
            generation: generation,
            packedNames: packed.count,
            keptImages: entries.count,
            keptImageBytes: keptBytes,
            standaloneTextures: standalone.count,
            pageSize: pageSize
        )
    }

    private var pageSize: CGSize {
        let largest = packed.compactMap { name, texture -> (CGSize, CGRect)? in
            guard let image = entries[name]?.image.cgImage else { return nil }
            return (CGSize(width: image.width, height: image.height), texture.textureRect())
        }.max { $0.0.width < $1.0.width }
        guard let (pixels, rect) = largest, rect.width > 0, rect.height > 0 else { return .zero }
        return CGSize(
            width: (pixels.width / rect.width).rounded(),
            height: (pixels.height / rect.height).rounded()
        )
    }

    // MARK: Baking ahead

    /// One texture to bake: its atlas name and a thread-safe Core Graphics
    /// bake of its image.
    struct BakeRequest: @unchecked Sendable {
        let name: String
        let make: () -> UIImage
    }

    /// Bakes every missing image of `requests` across all cores, then keeps
    /// them. Blocks the caller only for the misses; a restore calls it
    /// before creating its nodes, so a full jar's misses cost one parallel
    /// pass instead of one serial bake per body.
    func bakeMissing(_ requests: [BakeRequest]) {
        var seen = Set<String>()
        let missing = requests.filter { entries[$0.name] == nil && seen.insert($0.name).inserted }
        guard !missing.isEmpty else { return }
        insert(Self.bake(missing))
    }

    /// Bakes `requests` on a utility queue and keeps them when done (the
    /// launch pre-bake). A body needed before it finishes simply bakes on
    /// demand; the later insert skips names that exist by then.
    func prewarm(_ requests: [BakeRequest]) {
        var seen = Set<String>()
        let missing = requests.filter { entries[$0.name] == nil && seen.insert($0.name).inserted }
        guard !missing.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async {
            let baked = Self.bake(missing)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    GemTextureAtlas.shared.insert(baked)
                }
            }
        }
    }

    nonisolated private static func bake(_ requests: [BakeRequest]) -> [(name: String, image: UIImage)] {
        let lock = NSLock()
        var images = [UIImage?](repeating: nil, count: requests.count)
        DispatchQueue.concurrentPerform(iterations: requests.count) { index in
            let image = requests[index].make()
            lock.lock()
            images[index] = image
            lock.unlock()
        }
        return zip(requests, images).compactMap { request, image in
            image.map { (request.name, $0) }
        }
    }

    // MARK: Packing

    /// Packs every kept image now and installs the page (tests, and the
    /// pre-bake when it already runs off the main thread's critical path).
    func rebuildNow() {
        let snapshot = entries.mapValues(\.image)
        let built = Self.pack(snapshot)
        install(built)
    }

    private func scheduleRebuild() {
        guard rebuildsAutomatically, !isRebuildScheduled else { return }
        isRebuildScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + rebuildDelay) { [weak self] in
            MainActor.assumeIsolated {
                self?.startRebuild()
            }
        }
    }

    private func startRebuild() {
        isRebuildScheduled = false
        guard !isBuilding else { return }
        let snapshot = entries.mapValues(\.image)
        guard Set(snapshot.keys) != Set(packed.keys) else { return }
        isBuilding = true
        DispatchQueue.global(qos: .utility).async {
            let built = Self.pack(snapshot)
            built.atlas.preload {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        GemTextureAtlas.shared.finishRebuild(built)
                    }
                }
            }
        }
    }

    private func finishRebuild(_ built: Packed) {
        isBuilding = false
        install(built)
        if Set(entries.keys) != Set(packed.keys) { scheduleRebuild() }
    }

    private struct Packed: @unchecked Sendable {
        let atlas: SKTextureAtlas
        let textures: [String: SKTexture]
    }

    /// Thread-safe: SpriteKit packs the images and every name is resolved
    /// here, off the main thread.
    nonisolated private static func pack(_ images: [String: UIImage]) -> Packed {
        let atlas = SKTextureAtlas(dictionary: images.mapValues(untrimmed))
        var textures: [String: SKTexture] = [:]
        for name in images.keys {
            let texture = atlas.textureNamed(name)
            texture.filteringMode = .linear
            textures[name] = texture
        }
        return Packed(atlas: atlas, textures: textures)
    }

    /// A scale-1 copy of the same bitmap (so the packer keeps every pixel
    /// of a 2× or 3× bake; sprite sizes are always set explicitly) whose
    /// four corner pixels carry alpha 1/255. The packer trims transparent
    /// borders, which would clip the outermost antialiased texels of a
    /// silhouette; with the corners marked, each entry keeps its full
    /// transparent margin and samples exactly like its stand-alone texture.
    nonisolated private static func untrimmed(_ image: UIImage) -> UIImage {
        guard let source = image.cgImage,
              let space = CGColorSpace(name: CGColorSpace.sRGB)
        else { return image }
        let width = source.width
        let height = source.height
        guard width > 1, height > 1,
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: width * 4,
                  space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ),
              let pixels = context.data?.assumingMemoryBound(to: UInt8.self)
        else { return UIImage(cgImage: source, scale: 1, orientation: .up) }
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        for (x, y) in [(0, 0), (width - 1, 0), (0, height - 1), (width - 1, height - 1)] {
            let alpha = pixels + (y * width + x) * 4 + 3
            if alpha.pointee == 0 { alpha.pointee = 1 }
        }
        guard let marked = context.makeImage() else {
            return UIImage(cgImage: source, scale: 1, orientation: .up)
        }
        return UIImage(cgImage: marked, scale: 1, orientation: .up)
    }

    private func install(_ built: Packed) {
        packed = built.textures
        generation += 1
        for name in built.textures.keys where !Self.isShared(name) {
            standalone[name] = nil
        }
        let sprites = registry.keyEnumerator().allObjects.compactMap { $0 as? SKSpriteNode }
        for sprite in sprites {
            guard let name = registry.object(forKey: sprite) as String?,
                  let texture = built.textures[name],
                  sprite.texture !== texture
            else { continue }
            sprite.texture = texture
        }
    }

    // MARK: Kept images

    private static func isShared(_ name: String) -> Bool {
        name.hasPrefix("gem.shared.")
    }

    private func touch(_ name: String) {
        useClock &+= 1
        entries[name]?.lastUse = useClock
    }

    private func store(_ name: String, image: UIImage, pinned: Bool) {
        let bytes = Int(image.size.width * image.scale) * Int(image.size.height * image.scale) * 4
        useClock &+= 1
        entries[name] = Entry(image: image, bytes: bytes, lastUse: useClock, isPinned: pinned)
        keptBytes += bytes
        evictIfNeeded()
    }

    private func evictIfNeeded() {
        guard keptBytes > Self.imageByteBudget else { return }
        let candidates = entries
            .filter { !$0.value.isPinned }
            .sorted { $0.value.lastUse < $1.value.lastUse }
        for (name, entry) in candidates {
            guard keptBytes > Self.imageByteBudget else { break }
            entries[name] = nil
            standalone[name] = nil
            keptBytes -= entry.bytes
        }
    }
}
