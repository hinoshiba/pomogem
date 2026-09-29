import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum AnimatedShareExportError: LocalizedError {
    case noFrames
    case cannotCreateDestination
    case cannotFinalize
    case fileTooLarge
    case frameCountMismatch

    var errorDescription: String? {
        switch self {
        case .noFrames:
            return String(localized: "GIFにする画像がありません。", table: "Share",
                          comment: "Share error: no card image was rendered to encode as a GIF")
        case .cannotCreateDestination:
            return String(localized: "GIFの保存先を準備できませんでした。", table: "Share",
                          comment: "Share error: the temporary GIF file could not be created")
        case .cannotFinalize:
            return String(localized: "GIFを書き出せませんでした。", table: "Share",
                          comment: "Share error: the GIF could not be written")
        case .fileTooLarge:
            return String(localized: "GIFの容量を小さくできませんでした。静止画で共有してください。", table: "Share",
                          comment: "Share error: the GIF stays over the share size limit even at the smallest scale")
        case .frameCountMismatch:
            return String(localized: "GIFのフレーム数が一致しません。", table: "Share",
                          comment: "Share error: the GIF writer received a different number of frames than it expected")
        }
    }
}

/// Encodes a short, looped GIF without uploading study or work data.
///
/// The renderer supplies already-composited frames, so the output contains no
/// source theme names, achievement notes, location metadata, or CloudKit IDs.
enum AnimatedShareExporter {
    /// Eight deliberately distinct poses preserve a readable loop while
    /// keeping generation and upload latency humane on older supported phones.
    static let frameCount = 8
    static let renderedPoseCount = 4
    static let frameDelay = 0.18
    static let maximumShareBytes = 15 * 1_024 * 1_024
    /// Render scales tried in order for the GIF's poses on the 360-point
    /// share canvas; the first file within `maximumShareBytes` is used.
    /// 2x gives 720×900 (feed) and 720×1280 (story) pixels, so the 7–9 pt
    /// URL, disclosure and tag lines stay legible after a platform
    /// recompresses the upload. The GIF used to start at 1.25x (450 px wide)
    /// although four poses sit far below the size cap (history-07); the
    /// smaller steps remain only as a fallback for unusually heavy cards.
    static let renderScaleLadder: [CGFloat] = [2, 1.25, 1]
    static let temporaryFilePrefix = "pomogem-share-"
    static let staleFileAge: TimeInterval = 24 * 60 * 60

    static func makeTemporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(temporaryFilePrefix)\(UUID().uuidString)")
            .appendingPathExtension("gif")
    }

    /// Removes only expired GIFs created by this exporter. The UUID suffix,
    /// extension, nonrecursive directory listing, and age threshold keep this
    /// cleanup bounded even when the system temporary directory is shared.
    @discardableResult
    static func removeStaleTemporaryFiles(
        in directory: URL = FileManager.default.temporaryDirectory,
        now: Date = .now,
        olderThan age: TimeInterval = staleFileAge,
        fileManager: FileManager = .default
    ) -> [URL] {
        let keys: Set<URLResourceKey> = [
            .contentModificationDateKey,
            .creationDateKey,
            .isRegularFileKey
        ]
        guard let candidates = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else { return [] }

        let cutoff = now.addingTimeInterval(-max(0, age))
        var removed: [URL] = []
        for url in candidates {
            guard isOwnedTemporaryGIF(url) else { continue }
            guard let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true else { continue }
            let fileDate = values.contentModificationDate ?? values.creationDate
            guard let fileDate, fileDate <= cutoff else { continue }
            do {
                try fileManager.removeItem(at: url)
                removed.append(url)
            } catch {
                continue
            }
        }
        return removed
    }

    static func isOwnedTemporaryGIF(_ url: URL) -> Bool {
        guard url.pathExtension.lowercased() == "gif" else { return false }
        let stem = url.deletingPathExtension().lastPathComponent
        guard stem.hasPrefix(temporaryFilePrefix) else { return false }
        let suffix = String(stem.dropFirst(temporaryFilePrefix.count))
        return UUID(uuidString: suffix) != nil
    }

    static func write(
        frames: [CGImage],
        to url: URL,
        frameDelay: Double = frameDelay,
        loopCount: Int = 0
    ) throws {
        guard !frames.isEmpty else { throw AnimatedShareExportError.noFrames }
        let writer = try Writer(
            url: url,
            frameCount: frames.count,
            frameDelay: frameDelay,
            loopCount: loopCount
        )
        try frames.forEach(writer.add)
        try writer.finalize()
    }

    static func fileSize(at url: URL) -> Int {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return values?.fileSize ?? 0
    }

    /// Creates the in-between pose used by the eight-frame loop. Rendering
    /// four full SwiftUI cards keeps export latency predictable; blending each
    /// adjacent pair prevents the visible two-frame holds that made the old
    /// loop feel like a slideshow. The final blend wraps to the first pose, so
    /// frame seven does not introduce a special reset jump.
    static func intermediateFrame(
        from first: CGImage,
        to second: CGImage,
        progress: CGFloat = 0.5
    ) -> CGImage? {
        guard first.width == second.width,
              first.height == second.height,
              first.width > 0,
              first.height > 0 else { return nil }
        let colorSpace = first.colorSpace
            ?? second.colorSpace
            ?? CGColorSpace(name: CGColorSpace.sRGB)
            ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: first.width,
            height: first.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: first.width, height: first.height)
        context.draw(first, in: bounds)
        context.saveGState()
        context.setAlpha(min(max(progress, 0), 1))
        context.draw(second, in: bounds)
        context.restoreGState()
        return context.makeImage()
    }

#if DEBUG
    /// A read-only, DEBUG-only inspection used by the end-to-end share test.
    /// It validates the exact file leased to `UIActivityViewController`; the
    /// probe never copies the GIF or exposes its temporary path.
    struct DebugGIFInspection: Equatable {
        let isOwnedTemporaryFile: Bool
        let fileExists: Bool
        let byteCount: Int
        let isGIF: Bool
        let frameCount: Int

        var isValidExport: Bool {
            isOwnedTemporaryFile
                && fileExists
                && byteCount > 0
                && byteCount <= AnimatedShareExporter.maximumShareBytes
                && isGIF
                && frameCount == AnimatedShareExporter.frameCount
        }
    }

    static func debugInspection(
        at url: URL,
        fileManager: FileManager = .default
    ) -> DebugGIFInspection {
        let exists = fileManager.fileExists(atPath: url.path)
        let bytes = exists ? fileSize(at: url) : 0
        guard exists,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return DebugGIFInspection(
                isOwnedTemporaryFile: isOwnedTemporaryGIF(url),
                fileExists: exists,
                byteCount: bytes,
                isGIF: false,
                frameCount: 0
            )
        }
        return DebugGIFInspection(
            isOwnedTemporaryFile: isOwnedTemporaryGIF(url),
            fileExists: true,
            byteCount: bytes,
            isGIF: CGImageSourceGetType(source) as String? == UTType.gif.identifier,
            frameCount: CGImageSourceGetCount(source)
        )
    }
#endif

    /// Adds each frame directly to Image I/O so the app doesn't retain an
    /// uncompressed 720×1280 frame array while exporting on older devices.
    final class Writer {
        private let url: URL
        private let expectedFrameCount: Int
        private let destination: CGImageDestination
        private let frameProperties: CFDictionary
        private var addedFrameCount = 0
        private var isFinalized = false

        init(
            url: URL,
            frameCount: Int,
            frameDelay: Double = AnimatedShareExporter.frameDelay,
            loopCount: Int = 0
        ) throws {
            guard frameCount > 0 else { throw AnimatedShareExportError.noFrames }
            self.url = url
            expectedFrameCount = frameCount

            try? FileManager.default.removeItem(at: url)
            guard let destination = CGImageDestinationCreateWithURL(
                url as CFURL,
                UTType.gif.identifier as CFString,
                frameCount,
                nil
            ) else {
                throw AnimatedShareExportError.cannotCreateDestination
            }
            self.destination = destination

            let fileProperties: [CFString: Any] = [
                kCGImagePropertyGIFDictionary: [
                    kCGImagePropertyGIFLoopCount: max(0, loopCount),
                    // Round 12: every frame gets its own 256-colour table
                    // (one global table left the gems matte and the bed
                    // dithered: most of it went to the dark card).
                    kCGImagePropertyGIFHasGlobalColorMap: false
                ],
                kCGImageMetadataShouldExcludeGPS: true,
                kCGImageMetadataShouldExcludeXMP: true
            ]
            CGImageDestinationSetProperties(destination, fileProperties as CFDictionary)

            // GIF readers commonly clamp sub-100 ms delays. Keep the authored
            // timing above that threshold so motion is consistent across apps.
            let delay = max(0.1, frameDelay)
            let properties: [CFString: Any] = [
                kCGImagePropertyGIFDictionary: [
                    kCGImagePropertyGIFDelayTime: delay,
                    kCGImagePropertyGIFUnclampedDelayTime: delay
                ]
            ]
            frameProperties = properties as CFDictionary
        }

        func add(_ frame: CGImage) throws {
            guard !isFinalized, addedFrameCount < expectedFrameCount else {
                throw AnimatedShareExportError.frameCountMismatch
            }
            CGImageDestinationAddImage(destination, frame, frameProperties)
            addedFrameCount += 1
        }

        func finalize() throws {
            guard !isFinalized, addedFrameCount == expectedFrameCount else {
                throw AnimatedShareExportError.frameCountMismatch
            }
            isFinalized = true
            guard CGImageDestinationFinalize(destination) else {
                try? FileManager.default.removeItem(at: url)
                throw AnimatedShareExportError.cannotFinalize
            }
        }
    }
}

enum ShareCopy {
    /// Selected by default, in the language of the app: ja #ポモジェム
    /// #ポモドーロ, en #PomoGem #pomodoro (the tags a reader of that language
    /// searches for). Resolved once per process; a language change relaunches
    /// the app.
    static let hashtags = [
        String(localized: "#ポモジェム", table: "Share",
               comment: "Default share hashtag (selected): the app's name, a valid hashtag (letters, numbers, _ only). en: #PomoGem"),
        String(localized: "#ポモドーロ", table: "Share",
               comment: "Default share hashtag (selected): the Pomodoro technique, a valid hashtag (letters, numbers, _ only). en: #pomodoro")
    ]
    /// Common study-post tags, offered unselected after the defaults.
    /// Tags stay opt-in: nothing here is shared unless the person taps it.
    /// One localized list, because each language has its own community tags
    /// and not the same number of them: ja #勉強記録 #勉強垢, en #studywithme.
    static let suggestedHashtags = String(
        localized: "#勉強記録 #勉強垢",
        table: "Share",
        comment: "Suggested share hashtags (unselected), separated by single spaces: community tags for posting study logs. Each must be a valid hashtag (letters, numbers, _ only) and differ from the default tags. en: #studywithme"
    )
    .split(separator: " ")
    .compactMap { ShareHashtagPolicy.normalized(String($0)) }
    .filter { !hashtags.contains($0) }
    /// Every chip the composer offers, in display order.
    static var hashtagChoices: [String] { hashtags + suggestedHashtags }
    static let websiteURL = AppLinks.marketingWebsite
    static let websiteDisplayName = "pomogem.hinoshiba.com"
    static let wordmark = "POMOGEM"

    /// - Parameter focusTime: the focus the mass stands for (「4時間10分」),
    ///   stated after the grams because a follower cannot convert grams into
    ///   time (history-08). Omitted when the card holds no focus.
    static func caption(
        subject: String,
        grams: String,
        focusTime: String? = nil,
        includesSelfReportedFocus: Bool,
        achievementCount: Int,
        rewardDetail: String? = nil,
        visualDisclosure: String? = nil,
        hashtags: [String] = hashtags
    ) -> String {
        let disclosure = ShareDisclosurePolicy(
            includesSelfReportedFocus: includesSelfReportedFocus,
            achievementCount: achievementCount
        )
        let details = [rewardDetail, visualDisclosure]
            .compactMap { detail -> String? in
                guard let detail else { return nil }
                let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : sentence(trimmed)
            }
        let detailLine = details.isEmpty
            ? ""
            : "\n\(SentenceText.join(details))"
        let uniqueHashtags = hashtags.reduce(into: [String]()) { values, hashtag in
            guard let normalized = ShareHashtagPolicy.normalized(hashtag),
                  !values.contains(where: {
                      $0.compare(normalized, options: [.caseInsensitive, .widthInsensitive]) == .orderedSame
                  })
            else { return }
            values.append(normalized)
        }
        let hashtagLine = uniqueHashtags.isEmpty
            ? ""
            : "\n\(uniqueHashtags.joined(separator: " "))"
        let websiteLine = "\n\(websiteURL.absoluteString)"
        let claim = claimSentence(
            subject: subject,
            grams: grams,
            focusTime: focusTime,
            disclosure: disclosure.captionDisclosure
        )
        return "\(claim)\(detailLine)\(websiteLine)\(hashtagLine)"
    }

    /// The caption's first sentence, one format per shape so English can
    /// reorder it: 「これまでの集中を 2,500g（4時間10分）積みました（記念石は自己申告）。」
    private static func claimSentence(subject: String, grams: String, focusTime: String?, disclosure: String?) -> String {
        switch (focusTime, disclosure) {
        case let (time?, disclosure?):
            String(
                localized: "\(subject)を \(grams)（\(time)）積みました（\(disclosure)）。",
                table: "Share",
                comment: "Share caption, first sentence. Arguments: what the card holds (e.g. これまでの集中, sentence start in en), mass (2,500g), focus time (4時間10分), what is self-reported (a sentence without its period in en)"
            )
        case let (time?, nil):
            String(
                localized: "\(subject)を \(grams)（\(time)）積みました。",
                table: "Share",
                comment: "Share caption, first sentence. Arguments: what the card holds (e.g. これまでの集中, sentence start in en), mass (2,500g), focus time (4時間10分)"
            )
        case let (nil, disclosure?):
            String(
                localized: "\(subject)を \(grams) 積みました（\(disclosure)）。",
                table: "Share",
                comment: "Share caption, first sentence of a card with under a minute of focus. Arguments: what the card holds (sentence start in en), mass (0g), what is self-reported (a sentence without its period in en)"
            )
        case (nil, nil):
            String(
                localized: "\(subject)を \(grams) 積みました。",
                table: "Share",
                comment: "Share caption, first sentence of a card with under a minute of focus. Arguments: what the card holds (sentence start in en), mass (0g)"
            )
        }
    }

    /// Ends one complete statement as a sentence (ja 「。」, en "."), so
    /// several of them can be joined with `SentenceText.join`.
    static func sentence(_ text: String) -> String {
        String(
            localized: "\(text)。",
            table: "Share",
            comment: "Ends one statement of the share caption or the card's VoiceOver text as a sentence. en: '%@.'"
        )
    }
}

/// Keeps editable social copy predictable and private. A hashtag may contain
/// Unicode letters/numbers and underscores, but never whitespace, punctuation,
/// line breaks, mentions, URLs, or an invisible tracking suffix.
enum ShareHashtagPolicy {
    static let maximumBodyLength = 30

    static func normalized(_ rawValue: String) -> String? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
        guard !body.isEmpty,
              body.count <= maximumBodyLength,
              body.unicodeScalars.allSatisfy({ scalar in
                  CharacterSet.alphanumerics.contains(scalar) || scalar.value == 0x5F
              })
        else { return nil }
        return "#\(body)"
    }
}

struct ShareDisclosurePolicy: Equatable {
    let includesSelfReportedFocus: Bool
    let achievementCount: Int

    var hasSelfReportedContent: Bool {
        includesSelfReportedFocus || achievementCount > 0
    }

    var cardBadge: String? {
        switch (includesSelfReportedFocus, achievementCount > 0) {
        case (true, true):
            String(localized: "自己申告込み・記念石は自己申告", table: "Share",
                   comment: "Badge drawn on the share card: the card includes self-reported focus, and milestone stones are self-reported")
        case (true, false):
            String(localized: "自己申告込み", table: "Share",
                   comment: "Badge drawn on the share card: the card includes self-reported focus")
        case (false, true):
            Self.stonesAreSelfReported
        case (false, false):
            nil
        }
    }

    /// Also a sentence of the card's VoiceOver text, and in English its own
    /// sentence of the caption, so it reads as a statement without a period.
    var captionDisclosure: String? {
        switch (includesSelfReportedFocus, achievementCount > 0) {
        case (true, true):
            String(localized: "自己申告の集中を含む・記念石は自己申告", table: "Share",
                   comment: "Share caption and VoiceOver: the card includes self-reported focus, and milestone stones are self-reported. A statement without its final period (sentence case in en)")
        case (true, false):
            String(localized: "自己申告の集中を含む", table: "Share",
                   comment: "Share caption and VoiceOver: the card includes self-reported focus. A statement without its final period (sentence case in en)")
        case (false, true):
            Self.stonesAreSelfReported
        case (false, false):
            nil
        }
    }

    var accessibilityDisclosure: String {
        captionDisclosure ?? Self.measuredOnly
    }

    /// Only timed focus (timer or Screen Time) is on the card.
    static var measuredOnly: String {
        String(localized: "実測のみ", table: "Share",
               comment: "Share: only timed focus (timer or Screen Time) is on the card. An item of the settings summary and a VoiceOver sentence without its period")
    }

    private static var stonesAreSelfReported: String {
        String(localized: "記念石は自己申告", table: "Share",
               comment: "Share card badge, caption and VoiceOver: milestone stones are entered by hand. A statement without its final period (sentence case in en)")
    }
}
