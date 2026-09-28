import AVFoundation
import Foundation
import UserNotifications

/// The samples one choice plays in the app, rendered off the main thread:
/// the seamless loop (standard and maximum) and one cycle (the gentle
/// preset's repeat and the single cue after a return).
struct RenderedAlarmSound: Sendable {
    let loop: [Float]
    let cue: [Float]
}

/// The two Library/Sounds files a choice can have.
enum AlarmSoundFileKind: String, Sendable {
    /// ≤ 28 s: the Time Sensitive notification at the standard and maximum
    /// presets, and the AlarmKit alarm.
    case ringtone
    /// One cycle: the notification at the gentle preset, for the five new
    /// sounds (the original chimes keep `TimerCompletionSoundLibrary`).
    case cue
}

/// Turns `AlarmSoundSynthesis` renderings into playable buffers and into the
/// long CAF files that notifications and AlarmKit play from Library/Sounds.
///
/// Notification Center (and AlarmKit's `.named`) can only play files already
/// in the app bundle or in Library/Sounds. The repository must not contain
/// audio files (Scripts/check-oss-readiness.sh), so the files are rendered on
/// this device from the same arithmetic as the in-app sound. They can always
/// be rebuilt, so they are excluded from backups.
enum AlarmSoundLibrary {
    /// Bump whenever the synthesis or mastering changes: an existing file
    /// with the current name is reused as-is.
    static let fileVersion = 1
    static let fileNamePrefix = "pomogem-alarm-"
    static let fileExtension = "caf"
    /// Whether the AlarmKit alarm plays the rendered ringtone
    /// (`.named(<file>)`) or the system alarm sound (`.default`). AlarmKit
    /// was reported to ignore Library/Sounds on iOS 26.0 betas; if the
    /// real-device check confirms that, turn this off rather than shipping a
    /// bundled audio file (which the OSS gate forbids).
    static let systemAlarmUsesRenderedRingtone = true

    // MARK: Sources

    /// The unmastered pattern for any choice. The three original chimes come
    /// from `SoundSynth` (main actor), so this entry point is main-actor
    /// isolated; `synthesizedSource(for:)` may run anywhere.
    @MainActor
    static func source(for choice: AlarmSoundChoice) -> AlarmSoundSource {
        if let sound = choice.synthesizedSound {
            return synthesizedSource(for: sound)
        }
        let legacy = choice.legacySound ?? .standard
        let buffer = SoundSynth.makeTimerCompletionBuffer(for: legacy)
        return AlarmSoundSynthesis.legacySource(chime: samples(of: buffer))
    }

    static func synthesizedSource(for sound: AlarmSynthesizedSound) -> AlarmSoundSource {
        AlarmSoundSynthesis.source(for: sound)
    }

    /// The only part of rendering that needs the main actor: a legacy
    /// choice's original chime from `SoundSynth`. Nil for the new sounds.
    @MainActor
    static func legacyChime(for choice: AlarmSoundChoice) -> [Float]? {
        choice.legacySound.map {
            samples(of: SoundSynth.makeTimerCompletionBuffer(for: $0))
        }
    }

    /// Nonisolated `source(for:)`, given `legacyChime(for:)`.
    static func source(for choice: AlarmSoundChoice, legacyChime: [Float]?) -> AlarmSoundSource {
        if let sound = choice.synthesizedSound {
            return synthesizedSource(for: sound)
        }
        return AlarmSoundSynthesis.legacySource(chime: legacyChime ?? [])
    }

    /// Renders the in-app loop and cue. A legacy choice's cue is its
    /// original chime, untouched (the gentle preset is today's sound).
    static func render(_ choice: AlarmSoundChoice, legacyChime: [Float]?) -> RenderedAlarmSound {
        let source = source(for: choice, legacyChime: legacyChime)
        return RenderedAlarmSound(
            loop: AlarmSoundSynthesis.loop(source),
            cue: legacyChime ?? AlarmSoundSynthesis.preview(source)
        )
    }

    // MARK: Buffers

    /// A mono float buffer at `AlarmSoundSynthesis.sampleRate`, the format
    /// `SoundSynth` already plays.
    static func pcmBuffer(_ samples: [Float]) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty,
              let format = AVAudioFormat(
                standardFormatWithSampleRate: AlarmSoundSynthesis.sampleRate,
                channels: 1
              ),
              let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(samples.count)
              ),
              let channel = buffer.floatChannelData?[0]
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            guard let base = source.baseAddress else { return }
            channel.update(from: base, count: samples.count)
        }
        return buffer
    }

    /// One seamless cycle for `scheduleBuffer(_:at:options: .loops)`.
    @MainActor
    static func loopBuffer(for choice: AlarmSoundChoice) -> AVAudioPCMBuffer? {
        pcmBuffer(AlarmSoundSynthesis.loop(source(for: choice)))
    }

    /// One cycle with its natural decay, for the Settings preview.
    @MainActor
    static func previewBuffer(for choice: AlarmSoundChoice) -> AVAudioPCMBuffer? {
        pcmBuffer(AlarmSoundSynthesis.preview(source(for: choice)))
    }

    static func samples(of buffer: AVAudioPCMBuffer) -> [Float] {
        guard let channel = buffer.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }

    // MARK: Library/Sounds

    /// The file name to hand to `FocusEndAlarmScheduler.schedule`, or nil
    /// for the system alarm sound.
    static func systemAlarmSoundFileName(
        for choice: AlarmSoundChoice,
        usesRenderedRingtone: Bool = systemAlarmUsesRenderedRingtone
    ) -> String? {
        usesRenderedRingtone ? fileName(for: choice) : nil
    }

    static func fileName(for choice: AlarmSoundChoice) -> String {
        "\(fileNamePrefix)\(choice.rawValue)-v\(fileVersion).\(fileExtension)"
    }

    static func fileName(_ kind: AlarmSoundFileKind, for choice: AlarmSoundChoice) -> String {
        switch kind {
        case .ringtone:
            fileName(for: choice)
        case .cue:
            "\(fileNamePrefix)\(choice.rawValue)-cue-v\(fileVersion).\(fileExtension)"
        }
    }

    /// Every file name this version writes. Anything else with the prefix
    /// is stale (`removeStaleRingtoneFiles`).
    static var currentFileNames: Set<String> {
        var names = Set(AlarmSoundChoice.allCases.map { fileName(.ringtone, for: $0) })
        for choice in AlarmSoundChoice.allCases where choice.synthesizedSound != nil {
            names.insert(fileName(.cue, for: choice))
        }
        return names
    }

    static func soundsDirectory(
        libraryDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) throws -> URL {
        let library = try libraryDirectory ?? fileManager.url(
            for: .libraryDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = library.appendingPathComponent("Sounds", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Writes the ≤ 28 s ringtone for `choice` into Library/Sounds, or
    /// returns the existing file. Main-actor convenience for any choice.
    @MainActor
    @discardableResult
    static func ensureRingtoneFile(
        for choice: AlarmSoundChoice,
        libraryDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) throws -> URL {
        if let existing = try existingRingtoneFile(
            for: choice,
            libraryDirectory: libraryDirectory,
            fileManager: fileManager
        ) {
            return existing
        }
        return try writeRingtoneFile(
            for: choice,
            source: source(for: choice),
            libraryDirectory: libraryDirectory,
            fileManager: fileManager
        )
    }

    /// The file for `choice` when it is already complete and readable.
    static func existingRingtoneFile(
        for choice: AlarmSoundChoice,
        libraryDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) throws -> URL? {
        let destination = try soundsDirectory(
            libraryDirectory: libraryDirectory,
            fileManager: fileManager
        ).appendingPathComponent(fileName(for: choice))
        guard fileManager.fileExists(atPath: destination.path),
              let file = try? AVAudioFile(forReading: destination),
              file.length > 0,
              file.fileFormat.channelCount == 1,
              file.fileFormat.sampleRate == AlarmSoundSynthesis.sampleRate,
              Double(file.length) / file.fileFormat.sampleRate
                <= AlarmSoundSynthesis.ringtoneMaximumDuration
        else { return nil }
        return destination
    }

    /// Renders and atomically writes the ringtone. Nonisolated so a caller
    /// holding a source (a synthesized one needs no main actor) can render
    /// off the main thread.
    @discardableResult
    static func writeRingtoneFile(
        for choice: AlarmSoundChoice,
        source: AlarmSoundSource,
        libraryDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) throws -> URL {
        let directory = try soundsDirectory(
            libraryDirectory: libraryDirectory,
            fileManager: fileManager
        )
        let name = fileName(for: choice)
        let destination = directory.appendingPathComponent(name)
        let temporary = directory.appendingPathComponent(temporaryFileName(for: name))
        if fileManager.fileExists(atPath: temporary.path) {
            try fileManager.removeItem(at: temporary)
        }
        do {
            try writeCAF(AlarmSoundSynthesis.ringtone(source), to: temporary)
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.moveItem(at: temporary, to: destination)
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }
        var excluded = destination
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? excluded.setResourceValues(values)
        return destination
    }

    /// A temporary `.writing` file younger than this may belong to a write
    /// in progress (the launch sweep runs while the chosen sound and a
    /// recovery booking prepare their files), so only an older one counts
    /// as interrupted.
    static let interruptedWriteAge: TimeInterval = 10 * 60

    /// Removes alarm ringtones written by an older `fileVersion` and writes
    /// interrupted at least `interruptedWriteAge` ago, leaving the current
    /// files, writes in progress and every other sound in Library/Sounds
    /// untouched. A file that disappears meanwhile (a write that just moved
    /// its temporary file into place) does not stop the sweep.
    @discardableResult
    static func removeStaleRingtoneFiles(
        libraryDirectory: URL? = nil,
        fileManager: FileManager = .default,
        now: Date = Date()
    ) throws -> [URL] {
        let directory = try soundsDirectory(
            libraryDirectory: libraryDirectory,
            fileManager: fileManager
        )
        let current = currentFileNames
        let contents = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )
        var removed: [URL] = []
        for url in contents {
            let name = url.lastPathComponent
            let isOurs = name.hasPrefix(fileNamePrefix)
                || name.hasPrefix(".\(fileNamePrefix)")
            guard isOurs, !current.contains(name) else { continue }
            if name.hasSuffix(temporarySuffix) {
                guard let modified = try? url.resourceValues(
                    forKeys: [.contentModificationDateKey]
                ).contentModificationDate,
                      now.timeIntervalSince(modified) >= interruptedWriteAge
                else { continue }
            }
            guard (try? fileManager.removeItem(at: url)) != nil else { continue }
            removed.append(url)
        }
        return removed
    }

    static let temporarySuffix = ".writing"

    static func temporaryFileName(for name: String) -> String {
        ".\(name)\(temporarySuffix)"
    }

    /// Removes every alarm ringtone this library wrote.
    static func removeAllRingtoneFiles(
        libraryDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) throws {
        let directory = try soundsDirectory(
            libraryDirectory: libraryDirectory,
            fileManager: fileManager
        )
        for url in try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            let name = url.lastPathComponent
            if name.hasPrefix(fileNamePrefix) || name.hasPrefix(".\(fileNamePrefix)") {
                try fileManager.removeItem(at: url)
            }
        }
    }

    // MARK: Prepared off the main thread

    /// Writes (or finds) `kind` for `choice` without rendering on the main
    /// thread, and returns its URL. Concurrent requests for the same file
    /// share one write. A cue for one of the three original chimes is not
    /// written here (`TimerCompletionSoundLibrary` owns those).
    @MainActor
    static func preparedFile(
        _ kind: AlarmSoundFileKind,
        for choice: AlarmSoundChoice,
        libraryDirectory: URL? = nil
    ) async throws -> URL {
        if kind == .cue, choice.legacySound != nil {
            throw CocoaError(.fileNoSuchFile)
        }
        let name = fileName(kind, for: choice)
        let key = "\(libraryDirectory?.path ?? "")/\(name)"
        if let inFlight = preparations[key] {
            return try await inFlight.value
        }
        let legacyChime = legacyChime(for: choice)
        let task = Task<URL, Error> {
            try await Task.detached(priority: .utility) {
                if let existing = try existingFile(kind, for: choice, libraryDirectory: libraryDirectory) {
                    return existing
                }
                let source = source(for: choice, legacyChime: legacyChime)
                return try writeFile(kind, for: choice, source: source, libraryDirectory: libraryDirectory)
            }.value
        }
        preparations[key] = task
        defer { preparations[key] = nil }
        return try await task.value
    }

    @MainActor
    private static var preparations: [String: Task<URL, Error>] = [:]

    /// The notification sound for a prepared file, or nil when it could not
    /// be written (the caller falls back to the short chime).
    @MainActor
    static func notificationSound(
        _ kind: AlarmSoundFileKind,
        for choice: AlarmSoundChoice
    ) async -> UNNotificationSound? {
        guard let url = try? await preparedFile(kind, for: choice) else { return nil }
        return UNNotificationSound(named: UNNotificationSoundName(rawValue: url.lastPathComponent))
    }

    /// `existingRingtoneFile` for either kind.
    static func existingFile(
        _ kind: AlarmSoundFileKind,
        for choice: AlarmSoundChoice,
        libraryDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) throws -> URL? {
        let destination = try soundsDirectory(
            libraryDirectory: libraryDirectory,
            fileManager: fileManager
        ).appendingPathComponent(fileName(kind, for: choice))
        guard fileManager.fileExists(atPath: destination.path),
              let file = try? AVAudioFile(forReading: destination),
              file.length > 0,
              file.fileFormat.channelCount == 1,
              file.fileFormat.sampleRate == AlarmSoundSynthesis.sampleRate,
              Double(file.length) / file.fileFormat.sampleRate
                <= AlarmSoundSynthesis.ringtoneMaximumDuration
        else { return nil }
        return destination
    }

    /// `writeRingtoneFile` for either kind.
    @discardableResult
    static func writeFile(
        _ kind: AlarmSoundFileKind,
        for choice: AlarmSoundChoice,
        source: AlarmSoundSource,
        libraryDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) throws -> URL {
        switch kind {
        case .ringtone:
            return try writeRingtoneFile(
                for: choice,
                source: source,
                libraryDirectory: libraryDirectory,
                fileManager: fileManager
            )
        case .cue:
            let directory = try soundsDirectory(
                libraryDirectory: libraryDirectory,
                fileManager: fileManager
            )
            let name = fileName(.cue, for: choice)
            let destination = directory.appendingPathComponent(name)
            let temporary = directory.appendingPathComponent(temporaryFileName(for: name))
            if fileManager.fileExists(atPath: temporary.path) {
                try fileManager.removeItem(at: temporary)
            }
            do {
                try writeCAF(AlarmSoundSynthesis.preview(source), to: temporary)
                if fileManager.fileExists(atPath: destination.path) {
                    try fileManager.removeItem(at: destination)
                }
                try fileManager.moveItem(at: temporary, to: destination)
            } catch {
                try? fileManager.removeItem(at: temporary)
                throw error
            }
            var excluded = destination
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? excluded.setResourceValues(values)
            return destination
        }
    }

    // MARK: Writers

    /// 16-bit little-endian linear PCM, mono: a format both Notification
    /// Center and AlarmKit accept for custom sounds.
    static func writeCAF(_ samples: [Float], to url: URL) throws {
        try writePCM16(samples, to: url)
    }

    /// The same PCM in a WAV container, for auditioning renderings off device.
    static func writeWAV(_ samples: [Float], to url: URL) throws {
        try writePCM16(samples, to: url)
    }

    /// `AVAudioFile` picks the container from the extension (.caf or .wav).
    private static func writePCM16(_ samples: [Float], to url: URL) throws {
        guard let buffer = pcmBuffer(samples) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: AlarmSoundSynthesis.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        try file.write(from: buffer)
    }
}
