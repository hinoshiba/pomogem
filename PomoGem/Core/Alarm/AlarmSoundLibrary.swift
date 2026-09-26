import AVFoundation
import Foundation

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
        let temporary = directory.appendingPathComponent(".\(name).writing")
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

    /// Removes alarm ringtones written by an older `fileVersion` (or any
    /// interrupted write), leaving the current files and every other sound
    /// in Library/Sounds untouched.
    @discardableResult
    static func removeStaleRingtoneFiles(
        libraryDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) throws -> [URL] {
        let directory = try soundsDirectory(
            libraryDirectory: libraryDirectory,
            fileManager: fileManager
        )
        let current = Set(AlarmSoundChoice.allCases.map(fileName(for:)))
        let contents = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        var removed: [URL] = []
        for url in contents {
            let name = url.lastPathComponent
            let isOurs = name.hasPrefix(fileNamePrefix)
                || name.hasPrefix(".\(fileNamePrefix)")
            guard isOurs, !current.contains(name) else { continue }
            try fileManager.removeItem(at: url)
            removed.append(url)
        }
        return removed
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
