import AVFoundation
import os
import XCTest
@testable import PomoGem

/// The Library/Sounds ringtones that notifications and AlarmKit play.
@MainActor
final class AlarmSoundLibraryTests: XCTestCase {
    private var library: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        library = FileManager.default.temporaryDirectory.appendingPathComponent(
            "alarm-sound-library-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: library)
        library = nil
        try super.tearDownWithError()
    }

    func testFileNamesAreVersionedAndDistinctFromTheShortChimes() {
        let names = AlarmSoundChoice.allCases.map(AlarmSoundLibrary.fileName(for:))
        XCTAssertEqual(Set(names).count, AlarmSoundChoice.allCases.count)
        for (choice, name) in zip(AlarmSoundChoice.allCases, names) {
            XCTAssertEqual(name, "pomogem-alarm-\(choice.rawValue)-v\(AlarmSoundLibrary.fileVersion).caf")
            XCTAssertFalse(name.hasPrefix("pomogem-timer-"), "must not collide with TimerCompletionSoundLibrary")
        }
    }

    func testTheSystemAlarmPlaysTheRenderedRingtoneUnlessTurnedOff() {
        XCTAssertTrue(AlarmSoundLibrary.systemAlarmUsesRenderedRingtone)
        XCTAssertEqual(
            AlarmSoundLibrary.systemAlarmSoundFileName(for: .schoolChime),
            AlarmSoundLibrary.fileName(for: .schoolChime)
        )
        XCTAssertNil(AlarmSoundLibrary.systemAlarmSoundFileName(for: .schoolChime, usesRenderedRingtone: false))
    }

    func testRingtoneFilesAreSixteenBitMonoUnderThirtySecondsAndExcludedFromBackup() throws {
        var payloads: [Data] = []
        for choice in [AlarmSoundChoice.standard, .bell, .schoolChime] {
            let url = try AlarmSoundLibrary.ensureRingtoneFile(for: choice, libraryDirectory: library)
            XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "Sounds")
            XCTAssertEqual(url.lastPathComponent, AlarmSoundLibrary.fileName(for: choice))

            let file = try AVAudioFile(forReading: url)
            let format = file.fileFormat.streamDescription.pointee
            XCTAssertEqual(format.mFormatID, kAudioFormatLinearPCM)
            XCTAssertEqual(format.mBitsPerChannel, 16)
            XCTAssertEqual(format.mChannelsPerFrame, 1)
            XCTAssertEqual(file.fileFormat.sampleRate, AlarmSoundSynthesis.sampleRate)
            let seconds = Double(file.length) / file.fileFormat.sampleRate
            XCTAssertLessThan(seconds, 30, "Notification Center plays the default sound for 30 s or longer")
            XCTAssertGreaterThan(seconds, 20)

            let values = try url.resourceValues(forKeys: [.isExcludedFromBackupKey])
            XCTAssertEqual(values.isExcludedFromBackup, true, "rebuildable, so kept out of backups")
            payloads.append(try Data(contentsOf: url))
        }
        XCTAssertEqual(Set(payloads).count, payloads.count)
    }

    func testTheFileHoldsTheRenderedRingtone() throws {
        let url = try AlarmSoundLibrary.ensureRingtoneFile(for: .digital, libraryDirectory: library)
        let expected = AlarmSoundSynthesis.ringtone(AlarmSoundLibrary.source(for: .digital))
        let file = try AVAudioFile(forReading: url)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(file.length)
        ))
        try file.read(into: buffer)
        let decoded = AlarmSoundLibrary.samples(of: buffer)
        XCTAssertEqual(decoded.count, expected.count)
        var worst: Float = 0
        for index in 0..<min(decoded.count, expected.count) {
            worst = max(worst, abs(decoded[index] - expected[index]))
        }
        XCTAssertLessThan(worst, 2 / 32_767, "only 16-bit quantisation may differ")
    }

    func testMaterializationIsIdempotentAndRepairsAnUnreadableFile() throws {
        let url = try AlarmSoundLibrary.ensureRingtoneFile(for: .marimba, libraryDirectory: library)
        let firstWrite = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        XCTAssertEqual(try AlarmSoundLibrary.ensureRingtoneFile(for: .marimba, libraryDirectory: library), url)
        XCTAssertEqual(
            try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
            firstWrite,
            "an existing complete file is reused, not rewritten"
        )

        try Data("not audio".utf8).write(to: url)
        XCTAssertNil(try AlarmSoundLibrary.existingRingtoneFile(for: .marimba, libraryDirectory: library))
        let repaired = try AlarmSoundLibrary.ensureRingtoneFile(for: .marimba, libraryDirectory: library)
        XCTAssertGreaterThan(try AVAudioFile(forReading: repaired).length, 0)
    }

    func testStaleVersionsAndInterruptedWritesAreRemovedButOtherSoundsStay() throws {
        let sounds = try AlarmSoundLibrary.soundsDirectory(libraryDirectory: library)
        let current = try AlarmSoundLibrary.ensureRingtoneFile(for: .bell, libraryDirectory: library)
        let stale = sounds.appendingPathComponent("pomogem-alarm-bell-v0.caf")
        let interrupted = sounds.appendingPathComponent(".pomogem-alarm-digital-v1.caf.writing")
        let unrelated = sounds.appendingPathComponent("pomogem-timer-standard-v1.caf")
        for url in [stale, interrupted, unrelated] {
            try Data("x".utf8).write(to: url)
        }

        // At launch the sweep runs while the chosen sound (or a recovery
        // booking) may be writing: a fresh temporary file is left alone.
        let atLaunch = try AlarmSoundLibrary.removeStaleRingtoneFiles(libraryDirectory: library)
        XCTAssertEqual(atLaunch.map(\.lastPathComponent), [stale.lastPathComponent])
        XCTAssertTrue(FileManager.default.fileExists(atPath: interrupted.path), "a write in progress")

        let later = Date().addingTimeInterval(AlarmSoundLibrary.interruptedWriteAge + 1)
        let removed = try AlarmSoundLibrary.removeStaleRingtoneFiles(libraryDirectory: library, now: later)
        XCTAssertEqual(removed.map(\.lastPathComponent), [interrupted.lastPathComponent], "an interrupted write")
        XCTAssertTrue(FileManager.default.fileExists(atPath: current.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))

        try AlarmSoundLibrary.removeAllRingtoneFiles(libraryDirectory: library)
        XCTAssertFalse(FileManager.default.fileExists(atPath: current.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path), "the short chimes belong to TimerCompletionSoundLibrary")
    }

    /// The launch sweep and the first ringtone write run at the same time
    /// (`FocusEndAlarmMaintenance.maintainSoundFilesOncePerProcess`): the
    /// write must finish, and a file that vanishes mid-sweep must not stop
    /// it.
    func testTheSweepNeverBreaksAWriteInProgress() async throws {
        let sounds = try AlarmSoundLibrary.soundsDirectory(libraryDirectory: library)
        for round in 0 ..< 8 {
            let stale = sounds.appendingPathComponent("pomogem-alarm-bell-v0-\(round).caf")
            try Data("x".utf8).write(to: stale)
            let directory = library!
            let finished = OSAllocatedUnfairLock(initialState: false)
            async let written = Task.detached(priority: .utility) {
                defer { finished.withLock { $0 = true } }
                return try AlarmSoundLibrary.writeFile(
                    .cue,
                    for: .digital,
                    source: AlarmSoundSynthesis.source(for: .digital),
                    libraryDirectory: directory
                )
            }.value
            async let swept = Task.detached(priority: .utility) {
                // Sweep over and over for as long as the write runs.
                var removed: [URL] = []
                repeat {
                    removed += (try? AlarmSoundLibrary.removeStaleRingtoneFiles(libraryDirectory: directory)) ?? []
                } while !finished.withLock { $0 }
                return removed
            }.value
            let (url, removed) = try await (written, swept)
            XCTAssertGreaterThan(try AVAudioFile(forReading: url).length, 0, "round \(round)")
            XCTAssertFalse(removed.contains { $0.lastPathComponent.hasSuffix(AlarmSoundLibrary.temporarySuffix) })
            XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path), "round \(round)")
            try FileManager.default.removeItem(at: url)
        }
    }

    func testLoopAndPreviewBuffersUseThePlayableFormat() throws {
        for choice in AlarmSoundChoice.allCases {
            let source = AlarmSoundLibrary.source(for: choice)
            let loop = try XCTUnwrap(AlarmSoundLibrary.loopBuffer(for: choice), choice.rawValue)
            XCTAssertEqual(loop.format.sampleRate, AlarmSoundSynthesis.sampleRate)
            XCTAssertEqual(loop.format.channelCount, 1)
            XCTAssertEqual(loop.format.commonFormat, .pcmFormatFloat32)
            XCTAssertEqual(Int(loop.frameLength), AlarmSoundSynthesis.frames(source.period), choice.rawValue)

            let preview = try XCTUnwrap(AlarmSoundLibrary.previewBuffer(for: choice), choice.rawValue)
            let previewSeconds = Double(preview.frameLength) / AlarmSoundSynthesis.sampleRate
            XCTAssertGreaterThan(previewSeconds, 0.3, choice.rawValue)
            XCTAssertLessThanOrEqual(previewSeconds, source.period + AlarmSoundSynthesis.tailDuration, choice.rawValue)
        }
        XCTAssertNil(AlarmSoundLibrary.pcmBuffer([]))
    }

    func testTheSynthesisSampleRateMatchesTheInAppEngine() {
        XCTAssertEqual(AlarmSoundSynthesis.sampleRate, Constants.Sound.sampleRate)
    }
}
