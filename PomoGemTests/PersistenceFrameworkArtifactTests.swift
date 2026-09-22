import Foundation
import XCTest
@testable import PomoGem

/// Filesystem-only regressions for companions produced by real Core Data
/// stores. These tests run in Release without opening a CloudKit container.
@MainActor
final class PersistenceFrameworkArtifactTests: XCTestCase {
    func testPhysicalCloudCompanionsAllowTheExactPreviouslyMountedPair() throws {
        try withDirectory { directory in
            let namespace = AccountDataNamespace()
            let stores = try writeStorePair(namespace: namespace, directory: directory)
            let stem = stores[0].deletingPathExtension().lastPathComponent
            try writeDirectory(stem + "_ckAssets", in: directory)
            try writeDirectory("." + stem + "_SUPPORT", in: directory)

            let history = scan(directory)
            XCTAssertFalse(history.hasInvalidArtifact)
            XCTAssertEqual(history.cloud[namespace]?.hasAuxiliaryArtifact, true)
            XCTAssertEqual(history.cloud[namespace]?.hasCompleteStorePair, true)
            XCTAssertEqual(try cloudValidation(history, namespace: namespace, mounted: true), .valid)
            XCTAssertEqual(try cloudValidation(history, namespace: namespace, mounted: false), .valid)
            XCTAssertEqual(try Data(contentsOf: stores[0]), Data("preserved source".utf8))
        }
    }

    func testEachOrphanedPhysicalCompanionPreventsANewStoreOrChoice() throws {
        for hiddenSupport in [false, true] {
            try withDirectory { directory in
                let namespace = AccountDataNamespace()
                let stem = "PomoGem-\(namespace.rawValue)"
                let name = hiddenSupport ? ".\(stem)_SUPPORT" : "\(stem)_ckAssets"
                try writeDirectory(name, in: directory)
                let history = scan(directory)
                XCTAssertFalse(history.hasInvalidArtifact, name)
                XCTAssertTrue(history.hasAnyArtifact, name)
                XCTAssertTrue(PersistenceStoreTopology.hasCloudStoreHistory(directory: directory), name)
                XCTAssertEqual(history.cloud[namespace]?.hasAuxiliaryArtifact, true, name)
                XCTAssertEqual(try cloudValidation(history, namespace: namespace, mounted: false), .recoveryRequired, name)
                XCTAssertEqual(PersistenceDeploymentState.validate(
                    selectionState: .unselected, mountState: .unrecorded,
                    artifactHistory: history,
                    hasCloudRegistryHistory: false, hasCloudBindingHistory: false
                ), .recoveryRequired, name)
            }
        }
    }

    func testForeignNamespaceCompanionsDoNotAuthorizeTheSelectedPair() throws {
        for hiddenSupport in [false, true] {
            try withDirectory { directory in
                let namespace = AccountDataNamespace()
                let foreign = AccountDataNamespace()
                _ = try writeStorePair(namespace: namespace, directory: directory)
                let stem = "PomoGem-\(foreign.rawValue)"
                try writeDirectory(hiddenSupport ? ".\(stem)_SUPPORT" : "\(stem)_ckAssets", in: directory)
                let history = scan(directory)
                XCTAssertFalse(history.hasInvalidArtifact)
                XCTAssertEqual(history.cloud.count, 2)
                XCTAssertEqual(try cloudValidation(history, namespace: namespace, mounted: true), .recoveryRequired)
            }
        }
    }

    func testMalformedNoncanonicalAndLegacyCompanionNamesFailClosed() throws {
        let namespace = AccountDataNamespace()
        let uppercase = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa".uppercased()
        let names = [
            "PomoGem-\(uppercase)_ckAssets", ".PomoGem-\(uppercase)_SUPPORT",
            "PomoGem-not-a-uuid_ckAssets", ".PomoGem-not-a-uuid_SUPPORT",
            "PomoGem-\(namespace.rawValue)_ckAssets-extra",
            ".PomoGem-\(namespace.rawValue)_SUPPORT-extra",
            ".PomoGem-\(namespace.rawValue)_unexpected",
            "PomoGem_ckAssets", ".PomoGem_SUPPORT"
        ]
        for name in names {
            try withDirectory { directory in
                _ = try writeStorePair(namespace: namespace, directory: directory)
                try writeDirectory(name, in: directory)
                let history = scan(directory)
                XCTAssertTrue(history.hasInvalidArtifact, name)
                XCTAssertEqual(try cloudValidation(history, namespace: namespace, mounted: true), .recoveryRequired, name)
            }
        }
    }

    func testPhysicalCompanionsRejectRegularFilesAndSymlinks() throws {
        for hiddenSupport in [false, true] {
            for shape in ["file", "directory-link", "dangling-link"] {
                try withDirectory { directory in
                    let namespace = AccountDataNamespace()
                    let stores = try writeStorePair(namespace: namespace, directory: directory)
                    let stem = stores[0].deletingPathExtension().lastPathComponent
                    let name = hiddenSupport ? ".\(stem)_SUPPORT" : "\(stem)_ckAssets"
                    let artifact = directory.appendingPathComponent(name)
                    let target = directory.appendingPathComponent("unrelated-target", isDirectory: true)
                    if shape == "file" {
                        try Data("wrong type".utf8).write(to: artifact)
                    } else {
                        if shape == "directory-link" {
                            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
                        }
                        try FileManager.default.createSymbolicLink(at: artifact, withDestinationURL: target)
                    }
                    XCTAssertTrue(scan(directory).hasInvalidArtifact, "\(name): \(shape)")
                    XCTAssertThrowsError(try CompleteDataDeletionPersistentStoreCleaner.removeStores(at: stores), "\(name): \(shape)")
                    // Validation must reject the entire deletion before either
                    // otherwise-valid primary file is removed.
                    XCTAssertTrue(stores.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
                    if shape == "directory-link" {
                        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
                    }
                }
            }
        }
    }

    func testLocalOnlyCompanionsKeepTheirOwnNamespaceAndMode() throws {
        try withDirectory { directory in
            let namespace = AccountDataNamespace()
            let stores = PersistenceStoreTopology.localOnlyPersistentStoreURLs(namespace: namespace, directory: directory)
            for store in stores {
                try Data("local".utf8).write(to: store)
                let stem = store.deletingPathExtension().lastPathComponent
                try writeDirectory("." + stem + "_SUPPORT", in: directory)
            }
            let history = scan(directory)
            XCTAssertFalse(history.hasInvalidArtifact)
            XCTAssertTrue(history.cloud.isEmpty)
            XCTAssertEqual(history.localOnly[namespace]?.hasCompleteStorePair, true)
            XCTAssertEqual(PersistenceDeploymentState.validate(
                selectionState: .selected(.localOnly(namespace: namespace)),
                mountState: .mounted(.localOnly(namespace: namespace)),
                artifactHistory: history,
                hasCloudRegistryHistory: false, hasCloudBindingHistory: false
            ), .valid)
        }
    }

    func testCleanerEnumeratesPhysicalAndLegacyCompanionsExactly() throws {
        try withDirectory { directory in
            let namespace = AccountDataNamespace()
            let stem = "PomoGem-\(namespace.rawValue)"
            let store = directory.appendingPathComponent(stem + ".store")
            let actual = CompleteDataDeletionPersistentStoreCleaner.artifacts(for: store)
            let files = [".store", ".store-wal", ".store-shm", ".store-journal"].map { stem + $0 }
            let directories = [
                stem + ".store_SUPPORT", stem + ".store.ckAssetFiles",
                stem + ".store_ckAssets", stem + "_ckAssets", "." + stem + "_SUPPORT"
            ]
            XCTAssertEqual(Set(actual.map(\.lastPathComponent)), Set(files + directories))
            XCTAssertEqual(Set(actual.filter(\.hasDirectoryPath).map(\.lastPathComponent)), Set(directories))
            XCTAssertTrue(actual.allSatisfy { $0.deletingLastPathComponent() == directory })
        }
    }

    func testCleanerRemovesLiteralPhysicalCompanionsAndLeavesUnrelatedFiles() throws {
        try withDirectory { directory in
            let namespace = AccountDataNamespace()
            let stores = try writeStorePair(namespace: namespace, directory: directory)
            let stem = stores[0].deletingPathExtension().lastPathComponent
            // Literal fixtures deliberately do not come from artifacts(for:).
            let ownedDirectories = [stem + "_ckAssets", "." + stem + "_SUPPORT", stem + ".store.ckAssetFiles"]
            for name in ownedDirectories {
                try writeDirectory(name, in: directory)
                try Data("asset bytes".utf8).write(to: directory.appendingPathComponent(name).appendingPathComponent("payload"))
            }
            try Data("journal".utf8).write(to: directory.appendingPathComponent(stem + ".store-journal"))
            let foreignStem = "PomoGem-\(AccountDataNamespace().rawValue)"
            let unrelatedDirectories = [foreignStem + "_ckAssets", "." + foreignStem + "_SUPPORT", "OtherApp_SUPPORT"]
            for name in unrelatedDirectories { try writeDirectory(name, in: directory) }
            let unrelatedFile = directory.appendingPathComponent("keep-me.txt")
            try Data("unrelated".utf8).write(to: unrelatedFile)

            try CompleteDataDeletionPersistentStoreCleaner.removeStores(at: stores)

            for name in ownedDirectories + [stem + ".store-journal"] {
                XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path), name)
            }
            XCTAssertFalse(stores.contains { FileManager.default.fileExists(atPath: $0.path) })
            for name in unrelatedDirectories {
                XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path), name)
            }
            XCTAssertEqual(try Data(contentsOf: unrelatedFile), Data("unrelated".utf8))
        }
    }

    func testArtifactDerivationPreservesNonStoreFilenamesWithoutInventingANeighbor() throws {
        for filename in ["Archive.sqlite", "Archive.sqlite3", "Archive"] {
            try withDirectory { directory in
                let store = directory.appendingPathComponent(filename)
                let inventedNeighbor = directory.appendingPathComponent("Archive.store")
                try Data("original".utf8).write(to: store)
                try Data("unrelated neighbor".utf8).write(to: inventedNeighbor)
                let artifacts = CompleteDataDeletionPersistentStoreCleaner.artifacts(for: store)
                let expected = [
                    filename, filename + "-wal", filename + "-shm", filename + "-journal",
                    filename + "_SUPPORT", filename + ".ckAssetFiles", filename + "_ckAssets",
                    "Archive_ckAssets", ".Archive_SUPPORT"
                ]
                XCTAssertEqual(Set(artifacts.map(\.lastPathComponent)), Set(expected))
                // The helper standardizes file URLs. Foundation can retain a
                // different URL representation for the caller's appended URL,
                // so compare complete normalized destinations, not raw URL ==.
                let artifactPaths = Set(artifacts.map { $0.standardizedFileURL.path })
                XCTAssertTrue(artifactPaths.contains(store.standardizedFileURL.path))
                XCTAssertFalse(artifactPaths.contains(inventedNeighbor.standardizedFileURL.path))
                let primary = try XCTUnwrap(artifacts.first { $0.lastPathComponent == filename })
                XCTAssertFalse(primary.hasDirectoryPath)
                XCTAssertEqual(try Data(contentsOf: primary), Data("original".utf8))
                // Deletion itself continues to require a configured .store URL.
                XCTAssertThrowsError(try CompleteDataDeletionPersistentStoreCleaner.removeStores(at: [store]))
                XCTAssertEqual(try Data(contentsOf: store), Data("original".utf8))
                XCTAssertEqual(try Data(contentsOf: inventedNeighbor), Data("unrelated neighbor".utf8))
            }
        }
    }

    func testUnrelatedHiddenDirectoriesAreNotPersistenceHistory() throws {
        try withDirectory { directory in
            try writeDirectory(".OtherApp_SUPPORT", in: directory)
            try writeDirectory("OtherApp_ckAssets", in: directory)
            XCTAssertFalse(scan(directory).hasAnyArtifact)
        }
    }

    private func scan(_ directory: URL) -> PersistenceArtifactHistory {
        PersistenceStoreTopology.persistenceArtifactHistory(directory: directory)
    }

    private func cloudValidation(_ history: PersistenceArtifactHistory, namespace: AccountDataNamespace,
                                 mounted: Bool) throws -> PersistenceDeploymentValidation {
        let binding = try XCTUnwrap(ActiveAccountLocalBinding(namespace: namespace, accountFingerprint: String(repeating: "a", count: 64)))
        let selection = PersistenceDeploymentSelection.cloud(binding: binding)
        return PersistenceDeploymentState.validate(
            selectionState: .selected(selection),
            mountState: mounted ? .mounted(selection) : .unrecorded,
            artifactHistory: history,
            hasCloudRegistryHistory: true, hasCloudBindingHistory: true
        )
    }

    private func writeStorePair(namespace: AccountDataNamespace, directory: URL) throws -> [URL] {
        let stores = PersistenceStoreTopology.accountStoreURLs(accountNamespace: namespace, directory: directory)
        try Data("preserved source".utf8).write(to: stores[0])
        try Data("projection".utf8).write(to: stores[1])
        return stores
    }

    private func writeDirectory(_ name: String, in directory: URL) throws {
        try FileManager.default.createDirectory(at: directory.appendingPathComponent(name, isDirectory: true), withIntermediateDirectories: false)
    }

    private func withDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PersistenceFrameworkArtifacts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }
}
