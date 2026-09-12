import Foundation
import CryptoKit
import XCTest
@testable import PomoGem

@MainActor
final class StorageTransferStoreFilesTests: XCTestCase {
    private struct Fixture {
        let files: StorageTransferStoreFiles
        let root: URL
        let stores: URL
        let transfers: URL
        let source: PersistenceDeploymentSelection
        let destination: PersistenceDeploymentSelection
    }

    private func fixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("StorageTransferFiles-" + UUID().uuidString)
        let stores = root.appendingPathComponent("stores", isDirectory: true)
        let transfers = root.appendingPathComponent("transfers", isDirectory: true)
        try FileManager.default.createDirectory(at: stores, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let source = PersistenceDeploymentSelection.localOnly(namespace: AccountDataNamespace())
        let binding = ActiveAccountLocalBinding(namespace: AccountDataNamespace(), accountFingerprint: String(repeating: "a", count: 64))!
        let destination = PersistenceDeploymentSelection.cloud(binding: binding)
        return Fixture(files: try StorageTransferStoreFiles(transactionID: UUID(), transferRoot: transfers, storeDirectory: stores), root: root,
            stores: stores, transfers: transfers, source: source, destination: destination)
    }

    private func seed(_ urls: [URL], companions: Bool = true) throws {
        try FileManager.default.createDirectory(at: urls[0].deletingLastPathComponent(), withIntermediateDirectories: true)
        for (index, url) in urls.enumerated() {
            try Data("synthetic primary \(index)".utf8).write(to: url)
            if companions {
                let artifacts = PersistenceStoreArtifactLayout.artifacts(for: url)
                for (artifact, variant) in zip(artifacts, PersistenceStoreArtifactLayout.variants) where !variant.isPrimaryStore {
                    if variant.isDirectory {
                        let nested = artifact.appendingPathComponent("nested", isDirectory: true)
                        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
                        try Data("retained asset \(variant.suffix)".utf8).write(to: nested.appendingPathComponent("asset.bin"))
                    } else { try Data("companion \(variant.suffix)".utf8).write(to: artifact) }
                }
            }
        }
    }

    private func journal(_ fixture: Fixture, through phase: StorageTransferJournal.Phase) throws {
        let store = StorageTransferJournalStore(directory: fixture.transfers)
        guard case .cloud(let binding) = fixture.destination else { return XCTFail("Cloud destination expected") }
        var current: StorageTransferJournal
        if let existing = try store.load() { current = existing }
        else {
            current = try StorageTransferJournal(transactionID: fixture.files.transactionID,
                choice: .enableCloudKeepingCloud, source: fixture.source,
                destination: fixture.destination, cloudBinding: binding)
            try store.begin(current)
        }
        for next in StorageTransferJournal.Phase.allCases where next > current.phase && next <= phase {
            if next == .selectionCommitted { try store.commitSelection(for: current) }
            let value = try current.advancing(to: next,
                sourceDigest: next == .sourceSaved ? String(repeating: "a", count: 64) : nil,
                destinationDigest: next == .destinationSaved ? String(repeating: "a", count: 64) : nil)
            try store.save(value, replacing: current)
            current = value
        }
    }

    private func writeIntent(_ manifest: StorageTransferArtifactManifest, name: String, fixture: Fixture) throws {
        try JSONEncoder().encode(manifest).write(to: fixture.files.transactionDirectory.appendingPathComponent(name), options: .atomic)
    }

    func testFreezeCopiesEveryRecognizedFamilyAndLeavesSourceBytesUntouched() throws {
        let f = try fixture()
        let source = f.files.storeURLs(for: f.source, location: .source)
        try seed(source)
        let manifest = try f.files.freeze(selection: f.source)
        XCTAssertTrue(manifest.entries.contains { $0.relativePath.contains("_ckAssets/nested/asset.bin") })
        XCTAssertTrue(manifest.entries.contains { $0.relativePath.hasPrefix(".") && $0.relativePath.contains("_SUPPORT/") })
        for entry in manifest.entries where entry.kind == .file {
            let copied = f.files.storeURLs(for: f.source, location: .frozen)[0].deletingLastPathComponent().appendingPathComponent(entry.relativePath)
            XCTAssertEqual(try Data(contentsOf: f.stores.appendingPathComponent(entry.relativePath)), try Data(contentsOf: copied))
        }
        XCTAssertEqual(try f.files.freeze(selection: f.source), manifest)
        XCTAssertEqual(try f.files.loadFrozenManifest(selection: f.source), manifest)
    }

    func testFreezeRetryNeverAdoptsChangedSourceOrCorruptFrozenFile() throws {
        for changeSource in [false, true] {
            let f = try fixture()
            let source = f.files.storeURLs(for: f.source, location: .source)
            try seed(source, companions: false)
            let original = try f.files.freeze(selection: f.source)
            let changed = changeSource ? source[0] : f.files.storeURLs(for: f.source, location: .frozen)[0]
            try Data("changed".utf8).write(to: changed)
            XCTAssertThrowsError(try f.files.freeze(selection: f.source))
            XCTAssertEqual(try f.files.loadFrozenManifest(selection: f.source), original)
        }
    }

    func testIncompleteAndUnknownAndSymlinkArtifactsFailBeforeSnapshotProof() throws {
        for problem in 0 ..< 4 {
            let f = try fixture()
            let source = f.files.storeURLs(for: f.source, location: .source)
            try seed(source, companions: false)
            switch problem {
            case 0: try FileManager.default.removeItem(at: source[1])
            case 1: try Data().write(to: URL(fileURLWithPath: source[0].path + ".unknown"))
            case 2:
                try FileManager.default.removeItem(at: source[0])
                try FileManager.default.createSymbolicLink(at: source[0], withDestinationURL: f.root.appendingPathComponent("missing"))
            default:
                let support = PersistenceStoreArtifactLayout.artifacts(for: source[0]).last!
                try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
                try FileManager.default.createSymbolicLink(at: support.appendingPathComponent("unsafe"), withDestinationURL: f.root)
            }
            XCTAssertThrowsError(try f.files.freeze(selection: f.source))
            XCTAssertNil(try f.files.loadFrozenManifest(selection: f.source))
        }
    }

    func testInterruptedFreezeReusesOriginalManifestAndCopiesOnlyMissingRoots() throws {
        let f = try fixture()
        try seed(f.files.storeURLs(for: f.source, location: .source))
        let manifest = try f.files.freeze(selection: f.source)
        let frozen = f.files.storeURLs(for: f.source, location: .frozen)
        try FileManager.default.removeItem(at: frozen[0])
        let reopened = try StorageTransferStoreFiles(transactionID: f.files.transactionID, transferRoot: f.transfers, storeDirectory: f.stores)
        XCTAssertEqual(try reopened.freeze(selection: f.source), manifest)
        XCTAssertTrue(FileManager.default.fileExists(atPath: frozen[0].path))
    }

    func testReaderMutationCannotChangeFrozenBaselineOrNextReaderCopy() throws {
        let f = try fixture()
        let source = f.files.storeURLs(for: f.source, location: .source)
        try seed(source)
        let manifest = try f.files.freeze(selection: f.source)
        let first = try f.files.makeFrozenReaderCopy(selection: f.source)
        try Data("reader checkpoint changes".utf8).write(to: first[0])
        let second = try f.files.makeFrozenReaderCopy(selection: f.source)
        XCTAssertNotEqual(first[0].deletingLastPathComponent(), second[0].deletingLastPathComponent())
        XCTAssertEqual(try Data(contentsOf: second[0]), try Data(contentsOf: source[0]))
        XCTAssertEqual(try Data(contentsOf: first[0]), Data("reader checkpoint changes".utf8))
        XCTAssertEqual(try f.files.freeze(selection: f.source), manifest)
    }

    func testHalfMovedPromotionResumesAndRemainsIdempotentAfterCompletion() throws {
        let f = try fixture()
        let staged = f.files.storeURLs(for: f.destination, location: .staged)
        let final = f.files.storeURLs(for: f.destination, location: .source)
        try seed(staged)
        let manifest = try f.files.sealStaged(destination: f.destination)
        try FileManager.default.moveItem(at: staged[0], to: final[0])
        let reopened = try StorageTransferStoreFiles(transactionID: f.files.transactionID, transferRoot: f.transfers, storeDirectory: f.stores)
        XCTAssertEqual(try reopened.loadStagedManifest(destination: f.destination), manifest)
        try reopened.promoteStaged(destination: f.destination, manifest: manifest)
        try reopened.promoteStaged(destination: f.destination, manifest: manifest)
        for entry in manifest.entries where entry.kind == .file {
            XCTAssertTrue(FileManager.default.fileExists(atPath: f.stores.appendingPathComponent(entry.relativePath).path))
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(at: staged[0].deletingLastPathComponent(), includingPropertiesForKeys: nil).isEmpty)
    }

    func testMissingTamperedDuplicatedAndForeignPromotedRootsRefuseBeforeFurtherMoves() throws {
        for problem in 0 ..< 4 {
            let f = try fixture()
            let staged = f.files.storeURLs(for: f.destination, location: .staged)
            let final = f.files.storeURLs(for: f.destination, location: .source)
            try seed(staged, companions: false)
            let manifest = try f.files.sealStaged(destination: f.destination)
            switch problem {
            case 0: try FileManager.default.removeItem(at: staged[0])
            case 1:
                try FileManager.default.moveItem(at: staged[0], to: final[0])
                try Data("different".utf8).write(to: final[0])
            case 2: try FileManager.default.copyItem(at: staged[0], to: final[0])
            default: try Data("foreign WAL".utf8).write(to: URL(fileURLWithPath: final[0].path + "-wal"))
            }
            XCTAssertThrowsError(try f.files.promoteStaged(destination: f.destination, manifest: manifest))
            XCTAssertTrue(FileManager.default.fileExists(atPath: staged[1].path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: final[1].path))
        }
    }

    func testPromotionRejectsWrongTransactionAndSelectionWithoutTouchingStage() throws {
        let f = try fixture()
        let staged = f.files.storeURLs(for: f.destination, location: .staged)
        try seed(staged, companions: false)
        let manifest = try f.files.sealStaged(destination: f.destination)
        let forged = StorageTransferArtifactManifest(formatVersion: 1, transactionID: UUID(), selection: manifest.selection, entries: manifest.entries)
        XCTAssertThrowsError(try f.files.promoteStaged(destination: f.destination, manifest: forged))
        XCTAssertThrowsError(try f.files.promoteStaged(destination: f.source, manifest: manifest))
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged[0].path))
    }

    func testSealedManifestCannotBeReplacedByChangedStagedBaseline() throws {
        let f = try fixture()
        let staged = f.files.storeURLs(for: f.destination, location: .staged)
        try seed(staged, companions: false)
        let manifest = try f.files.sealStaged(destination: f.destination)
        try Data("changed after seal".utf8).write(to: staged[0])
        XCTAssertThrowsError(try f.files.sealStaged(destination: f.destination))
        XCTAssertEqual(try f.files.loadStagedManifest(destination: f.destination), manifest)
    }

    func testStagedReaderWorksBeforeSealAndNeverMutatesOriginalOrLaterReader() throws {
        let f = try fixture()
        let stage = f.files.storeURLs(for: f.destination, location: .staged)
        try seed(stage)
        let original = try Data(contentsOf: stage[0])
        let first = try f.files.makeStagedReaderCopy(destination: f.destination)
        XCTAssertNil(try f.files.loadStagedManifest(destination: f.destination))
        try Data("private reader checkpoint".utf8).write(to: first[0])
        let sealed = try f.files.sealStaged(destination: f.destination)
        let second = try f.files.makeStagedReaderCopy(destination: f.destination)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try Data(contentsOf: second[0]), original)
        XCTAssertEqual(try Data(contentsOf: stage[0]), original)
        XCTAssertEqual(try f.files.loadStagedManifest(destination: f.destination), sealed)
    }

    func testSourceRetirementRequiresCommittedSelectionAndPreservesFrozenBackup() throws {
        let f = try fixture()
        let source = f.files.storeURLs(for: f.source, location: .source)
        try seed(source)
        let original = try Data(contentsOf: source[0])
        _ = try f.files.freeze(selection: f.source)
        XCTAssertThrowsError(try f.files.retireSource(selection: f.source))
        try journal(f, through: .destinationVerified)
        XCTAssertThrowsError(try f.files.retireSource(selection: f.source))
        XCTAssertEqual(try Data(contentsOf: source[0]), original)
        try journal(f, through: .selectionCommitted)
        try f.files.retireSource(selection: f.source)
        try f.files.retireSource(selection: f.source)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source[0].path))
        XCTAssertEqual(try Data(contentsOf: f.files.storeURLs(for: f.source, location: .frozen)[0]), original)
    }

    func testSourceRetirementResumesAfterCrashInsideAnAssetDirectory() throws {
        let f = try fixture()
        let source = f.files.storeURLs(for: f.source, location: .source)
        try seed(source)
        let manifest = try f.files.freeze(selection: f.source)
        try journal(f, through: .selectionCommitted)
        try writeIntent(manifest, name: "source-retirement-v1.json", fixture: f)
        let nested = try XCTUnwrap(manifest.entries.first { $0.relativePath.contains("/nested/") && $0.kind == .file })
        try FileManager.default.removeItem(at: f.stores.appendingPathComponent(nested.relativePath))
        try FileManager.default.removeItem(at: source[0])
        try f.files.retireSource(selection: f.source)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source[1].path))
        XCTAssertEqual(try f.files.loadFrozenManifest(selection: f.source), manifest)
    }

    func testSourceRetirementRefusesChangedUnknownAndSymlinkRemainingEntries() throws {
        for problem in 0 ..< 3 {
            let f = try fixture()
            let source = f.files.storeURLs(for: f.source, location: .source)
            try seed(source)
            let manifest = try f.files.freeze(selection: f.source)
            try journal(f, through: .selectionCommitted)
            try writeIntent(manifest, name: "source-retirement-v1.json", fixture: f)
            switch problem {
            case 0: try Data("changed".utf8).write(to: source[0])
            case 1:
                let support = PersistenceStoreArtifactLayout.artifacts(for: source[0]).last!
                try Data("foreign".utf8).write(to: support.appendingPathComponent("foreign"))
            default:
                try FileManager.default.removeItem(at: source[0])
                try FileManager.default.createSymbolicLink(at: source[0], withDestinationURL: f.root.appendingPathComponent("absent"))
            }
            XCTAssertThrowsError(try f.files.retireSource(selection: f.source))
            XCTAssertTrue(FileManager.default.fileExists(atPath: source[1].path))
        }
    }

    func testDiscardUnacknowledgedPartialFamilyAndRetryLeavesSourceIntact() throws {
        let f = try fixture()
        let source = f.files.storeURLs(for: f.source, location: .source)
        try seed(source)
        try journal(f, through: .preparingDestination)
        let stage = f.files.storeURLs(for: f.destination, location: .staged)
        try seed([stage[0]])
        try f.files.discardUnacknowledgedStaged(destination: f.destination)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(at: stage[0].deletingLastPathComponent(), includingPropertiesForKeys: nil).isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source[0].path))
        // A new failed import gets a new intent after the preceding stage was
        // completely emptied; an old partial baseline is never substituted.
        try seed([stage[1]], companions: false)
        try f.files.discardUnacknowledgedStaged(destination: f.destination)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stage[1].path))
    }

    func testDiscardRefusesSealedAcknowledgedAndUnjournaledStage() throws {
        for problem in 0 ..< 4 {
            let f = try fixture()
            let stage = f.files.storeURLs(for: f.destination, location: .staged)
            try seed(stage, companions: false)
            if problem == 0 {
                try journal(f, through: .preparingDestination)
                _ = try f.files.sealStaged(destination: f.destination)
            } else if problem == 1 { try journal(f, through: .destinationSaved) }
            else if problem == 3 {
                try journal(f, through: .preparingDestination)
                let checkpoint = StorageTransferRuntimeCheckpoint(transactionID: f.files.transactionID,
                    importedPayloadDigest: String(repeating: "a", count: 64))
                let checkpointFile = try StorageTransferStateFile<StorageTransferRuntimeCheckpoint>(
                    url: f.files.transactionDirectory.appendingPathComponent("runtime-v1.json"))
                try checkpointFile.save(checkpoint, replacing: nil)
            }
            XCTAssertThrowsError(try f.files.discardUnacknowledgedStaged(destination: f.destination))
            XCTAssertTrue(FileManager.default.fileExists(atPath: stage[0].path))
        }
    }

    func testDiscardCrashRetryUsesExactPriorPartialManifest() throws {
        for tamper in [false, true] {
            let f = try fixture()
            try journal(f, through: .preparingDestination)
            let stage = f.files.storeURLs(for: f.destination, location: .staged)
            try seed(stage, companions: false)
            let entries = try stage.map { url -> StorageTransferArtifactManifest.Entry in
                let data = try Data(contentsOf: url)
                let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                return .init(relativePath: url.lastPathComponent, kind: .file, byteCount: Int64(data.count), sha256: digest)
            }.sorted { $0.relativePath < $1.relativePath }
            let manifest = StorageTransferArtifactManifest(formatVersion: 1, transactionID: f.files.transactionID,
                selection: f.destination, entries: entries)
            try writeIntent(manifest, name: "staged-discard-v1.json", fixture: f)
            try FileManager.default.removeItem(at: stage[0])
            if tamper {
                try Data("changed remaining".utf8).write(to: stage[1])
                XCTAssertThrowsError(try f.files.discardUnacknowledgedStaged(destination: f.destination))
                XCTAssertTrue(FileManager.default.fileExists(atPath: stage[1].path))
            } else {
                try f.files.discardUnacknowledgedStaged(destination: f.destination)
                XCTAssertFalse(FileManager.default.fileExists(atPath: stage[1].path))
            }
        }
    }
}
