import Foundation
import XCTest
@testable import PomoGem

@MainActor
final class CloudOfflineAccessStateTests: XCTestCase {
    private struct Fixture {
        let directory: URL
        let state: CloudOfflineAccessState
        let binding: ActiveAccountLocalBinding
        var file: URL { directory.appendingPathComponent("access-v1.json") }
    }

    private func fixture() throws -> Fixture {
        let parent = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("OfflineAccess-\(UUID())", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: parent) }
        let directory = parent.appendingPathComponent("CloudOffline", isDirectory: true)
        let binding = try XCTUnwrap(ActiveAccountLocalBinding(namespace: AccountDataNamespace(),
            accountFingerprint: String(repeating: "a", count: 64)))
        return Fixture(directory: directory, state: try CloudOfflineAccessState(directory: directory), binding: binding)
    }

    private func conditions(_ binding: ActiveAccountLocalBinding,
                            selection: PersistenceDeploymentSelectionState? = nil,
                            mount: PersistenceDeploymentMountState? = nil,
                            completePair: Bool = true, pendingTransfer: Bool = false,
                            pendingIntent: Bool = false, validSchema: Bool = true) -> CloudOfflineAccessConditions {
        CloudOfflineAccessConditions(selection: selection ?? .selected(.cloud(binding: binding)),
            mountState: mount ?? .mounted(.cloud(binding: binding)), hasExactCompleteStorePair: completePair,
            hasPendingTransfer: pendingTransfer, hasPendingRemoteIntent: pendingIntent, isSchemaValid: validSchema)
    }

    private func marker(sequence: Int = 7) -> ActivityResetSnapshot {
        ActivityResetSnapshot(id: UUID(), epochID: UUID(), sequence: sequence,
            resetAt: Date(timeIntervalSinceReferenceDate: 123_456.789_123), writerDeviceID: "synthetic-writer")
    }

    @discardableResult
    private func online(_ f: Fixture, marker: ActivityResetSnapshot? = nil,
                        generation: UUID? = nil) throws -> CloudOfflineAccessReceipt {
        try f.state.recordVerifiedOnline(binding: f.binding, datasetGenerationID: generation,
            resetBaseline: marker, expectedReceipt: f.state.load())
    }

    func testOfflineAdmissionPersistsBeforeUseAndRetainsExactOnlineBaselineAfterRestart() throws {
        let f = try fixture()
        let marker = marker()
        let generation = UUID()
        let verified = try online(f, marker: marker, generation: generation)
        XCTAssertFalse(verified.wasUsedOffline)
        let opened = try f.state.markOfflineOpened(binding: f.binding, conditions: conditions(f.binding))
        let reopened = try CloudOfflineAccessState(directory: f.directory)
        XCTAssertEqual(try reopened.load(), opened)
        XCTAssertTrue(opened.wasUsedOffline)
        XCTAssertTrue(opened.hasVerifiedOnlineBaseline)
        XCTAssertEqual(opened.resetBaseline, marker)
        XCTAssertEqual(opened.resetBaseline?.resetAt.timeIntervalSinceReferenceDate.bitPattern,
                       marker.resetAt.timeIntervalSinceReferenceDate.bitPattern)
        XCTAssertEqual(opened.datasetGenerationID, generation)
        XCTAssertNotEqual(opened.revisionID, verified.revisionID)
        // Repeated offline launches cannot replace the baseline with later
        // local observations or imply that server/account state was checked.
        let second = try reopened.markOfflineOpened(binding: f.binding, conditions: conditions(f.binding))
        XCTAssertEqual(second.resetBaseline, marker)
        XCTAssertEqual(second.datasetGenerationID, generation)
        XCTAssertTrue(second.wasUsedOffline)
    }

    func testNoReceiptNeverAuthorizesOfflineEvenWithMountedCompleteStores() throws {
        let f = try fixture()
        XCTAssertEqual(CloudOfflineAccessPolicy.blockReason(conditions: conditions(f.binding), receipt: nil), .missingReceipt)
        XCTAssertThrowsError(try f.state.markOfflineOpened(binding: f.binding, conditions: conditions(f.binding)))
        XCTAssertNil(try f.state.load())
    }

    func testExplicitlyObservedLegacyDatasetAndNoResetAreDifferentFromMissingProof() throws {
        let f = try fixture()
        let receipt = try online(f)
        XCTAssertNil(receipt.datasetGenerationID)
        XCTAssertNil(receipt.resetBaseline)
        XCTAssertTrue(receipt.hasVerifiedOnlineBaseline)
        XCTAssertNil(CloudOfflineAccessPolicy.blockReason(conditions: conditions(f.binding), receipt: receipt))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: f.file)) as? [String: Any])
        XCTAssertTrue(object["datasetGenerationID"] is NSNull)
        XCTAssertTrue(object["resetBaseline"] is NSNull)
    }

    func testEveryIndependentStoreAndTransferPreconditionFailsBeforeAdmissionMutation() throws {
        let f = try fixture()
        let receipt = try online(f)
        let different = try XCTUnwrap(ActiveAccountLocalBinding(namespace: AccountDataNamespace(),
            accountFingerprint: f.binding.accountFingerprint))
        let cases: [(CloudOfflineAccessConditions, CloudOfflineAccessBlockReason)] = [
            (conditions(f.binding, selection: .unselected), .cloudNotSelected),
            (conditions(f.binding, selection: .invalid), .invalidSelection),
            (conditions(f.binding, selection: .selected(.localOnly(namespace: f.binding.namespace))), .cloudNotSelected),
            (conditions(f.binding, mount: .unrecorded), .mountNotRecorded),
            (conditions(f.binding, mount: .invalid), .mountNotRecorded),
            (conditions(f.binding, mount: .mounted(.cloud(binding: different))), .mountMismatch),
            (conditions(f.binding, completePair: false), .incompleteStorePair),
            (conditions(f.binding, pendingTransfer: true), .pendingTransfer),
            (conditions(f.binding, pendingIntent: true), .pendingRemoteIntent),
            (conditions(f.binding, validSchema: false), .invalidSchema)
        ]
        for (conditions, reason) in cases {
            XCTAssertEqual(CloudOfflineAccessPolicy.blockReason(conditions: conditions, receipt: receipt), reason)
            XCTAssertThrowsError(try f.state.markOfflineOpened(binding: f.binding, conditions: conditions)) {
                XCTAssertEqual($0 as? CloudOfflineAccessBlockReason, reason)
            }
            XCTAssertEqual(try f.state.load(), receipt)
        }
    }

    func testDifferentAccountAndDifferentNamespaceCannotBorrowTheReceipt() throws {
        let f = try fixture()
        let receipt = try online(f)
        let others = [
            try XCTUnwrap(ActiveAccountLocalBinding(namespace: f.binding.namespace, accountFingerprint: String(repeating: "b", count: 64))),
            try XCTUnwrap(ActiveAccountLocalBinding(namespace: AccountDataNamespace(), accountFingerprint: f.binding.accountFingerprint))
        ]
        for other in others {
            XCTAssertEqual(CloudOfflineAccessPolicy.blockReason(conditions: conditions(other), receipt: receipt), .bindingMismatch)
            XCTAssertThrowsError(try f.state.markOfflineOpened(binding: other, conditions: conditions(f.binding)))
            XCTAssertThrowsError(try f.state.revoke(binding: other, reason: .accountChanged))
            XCTAssertEqual(try f.state.load(), receipt)
        }
    }

    func testEachKnownAccountRevocationPersistsAndBlocksOfflineUntilNewOnlineVerification() throws {
        for reason in [CloudOfflineRevocationReason.accountChanged, .noAccount, .restricted, .accountMismatch] {
            let f = try fixture()
            let baseline = marker()
            try online(f, marker: baseline)
            try f.state.markOfflineOpened(binding: f.binding, conditions: conditions(f.binding))
            try f.state.revoke(binding: f.binding, reason: reason)
            let restarted = try CloudOfflineAccessState(directory: f.directory)
            let revoked = try XCTUnwrap(restarted.load())
            XCTAssertEqual(revoked.revocation, reason)
            XCTAssertTrue(revoked.wasUsedOffline)
            XCTAssertEqual(revoked.resetBaseline, baseline)
            XCTAssertEqual(CloudOfflineAccessPolicy.blockReason(conditions: conditions(f.binding), receipt: revoked), .revoked(reason))
            XCTAssertThrowsError(try restarted.markOfflineOpened(binding: f.binding, conditions: conditions(f.binding)))
            let newMarker = marker(sequence: 8)
            let verified = try restarted.recordVerifiedOnline(binding: f.binding, datasetGenerationID: UUID(),
                resetBaseline: newMarker, expectedReceipt: revoked)
            XCTAssertNil(verified.revocation)
            XCTAssertFalse(verified.wasUsedOffline)
            XCTAssertEqual(verified.resetBaseline, newMarker)
        }
    }

    func testAccountChangeBeforeFirstReceiptIsDurableAndInvalidatesAnAlreadyStartedVerification() throws {
        let f = try fixture()
        XCTAssertNil(try f.state.load())
        try f.state.revoke(binding: f.binding, reason: .accountChanged)
        let restarted = try CloudOfflineAccessState(directory: f.directory)
        let receipt = try XCTUnwrap(restarted.load())
        XCTAssertFalse(receipt.hasVerifiedOnlineBaseline)
        XCTAssertEqual(receipt.revocation, .accountChanged)
        XCTAssertThrowsError(try restarted.recordVerifiedOnline(binding: f.binding, datasetGenerationID: nil,
            resetBaseline: nil, expectedReceipt: nil)) {
            XCTAssertEqual($0 as? CloudOfflineAccessStateError, .staleReceipt)
        }
        XCTAssertEqual(try restarted.load(), receipt)
        XCTAssertThrowsError(try restarted.markOfflineOpened(binding: f.binding, conditions: conditions(f.binding)))
    }

    func testRepeatedAccountChangesInvalidateVerificationEvenWhenReasonIsUnchanged() throws {
        let f = try fixture()
        let original = try online(f)
        try f.state.revoke(binding: f.binding, reason: .accountChanged)
        let first = try XCTUnwrap(f.state.load())
        try f.state.revoke(binding: f.binding, reason: .accountChanged)
        let second = try XCTUnwrap(f.state.load())
        XCTAssertNotEqual(first.revisionID, second.revisionID)
        for stale in [original, first] {
            XCTAssertThrowsError(try f.state.recordVerifiedOnline(binding: f.binding, datasetGenerationID: nil,
                resetBaseline: nil, expectedReceipt: stale)) {
                XCTAssertEqual($0 as? CloudOfflineAccessStateError, .staleReceipt)
            }
            XCTAssertEqual(try f.state.load(), second)
        }
    }

    func testOpeningOfflineWhileOnlineAttemptWasSuspendedPreventsThatAttemptClearingOfflineUse() throws {
        let f = try fixture()
        let original = try online(f)
        let opened = try f.state.markOfflineOpened(binding: f.binding, conditions: conditions(f.binding))
        XCTAssertThrowsError(try f.state.recordVerifiedOnline(binding: f.binding, datasetGenerationID: nil,
            resetBaseline: nil, expectedReceipt: original))
        XCTAssertEqual(try f.state.load(), opened)
    }

    func testStrictReceiptRejectsMissingUnknownFutureAndMalformedFieldsWithoutRepair() throws {
        let f = try fixture()
        try online(f, marker: marker())
        let original = try Data(contentsOf: f.file)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
        var invalid: [[String: Any]] = []
        for key in object.keys {
            var missing = object; missing.removeValue(forKey: key); invalid.append(missing)
        }
        var unknown = object; unknown["futureAuthority"] = true; invalid.append(unknown)
        var version = object; version["formatVersion"] = 2; invalid.append(version)
        var namespace = object; namespace["namespace"] = "../another-store"; invalid.append(namespace)
        var hash = object; hash["accountFingerprint"] = String(repeating: "A", count: 64); invalid.append(hash)
        var inconsistent = object; inconsistent["hasVerifiedOnlineBaseline"] = false; invalid.append(inconsistent)
        var origin = object; origin["origin"] = "futureOnlineProof"; invalid.append(origin)
        var knowledge = object; knowledge["isDatasetGenerationKnown"] = false; invalid.append(knowledge)
        var nested = try XCTUnwrap(object["resetBaseline"] as? [String: Any])
        nested["unrecognizedOrder"] = 42
        var withNested = object; withNested["resetBaseline"] = nested; invalid.append(withNested)
        nested.removeValue(forKey: "unrecognizedOrder"); nested.removeValue(forKey: "id")
        withNested["resetBaseline"] = nested; invalid.append(withNested)
        for malformed in invalid {
            let bytes = try JSONSerialization.data(withJSONObject: malformed, options: [.sortedKeys])
            try bytes.write(to: f.file)
            XCTAssertThrowsError(try f.state.load())
            XCTAssertThrowsError(try f.state.recordVerifiedOnline(binding: f.binding, datasetGenerationID: nil,
                resetBaseline: nil, expectedReceipt: nil))
            XCTAssertEqual(try Data(contentsOf: f.file), bytes)
        }
    }

    func testUnsupportedResetAndNonfiniteDateNeverBecomeAuthoritativeBaseline() throws {
        let f = try fixture()
        let good = try online(f)
        let unsupported = marker(sequence: ActivityResetPolicy.maximumSupportedSequence + 1)
        let nonfinite = ActivityResetSnapshot(id: UUID(), epochID: UUID(), sequence: 0,
            resetAt: Date(timeIntervalSinceReferenceDate: .infinity), writerDeviceID: "synthetic")
        for marker in [unsupported, nonfinite] {
            XCTAssertThrowsError(try f.state.recordVerifiedOnline(binding: f.binding, datasetGenerationID: nil,
                resetBaseline: marker, expectedReceipt: good))
            XCTAssertEqual(try f.state.load(), good)
        }
    }

    func testStateReadRejectsEmptyOversizeAndLinkedFilesWithoutChangingTheirTargets() throws {
        let f = try fixture()
        try online(f)
        for bytes in [Data(), Data(repeating: 0x20, count: 131_073)] {
            try bytes.write(to: f.file)
            XCTAssertThrowsError(try f.state.load())
        }
        try FileManager.default.removeItem(at: f.file)
        let target = f.directory.appendingPathComponent("foreign.json")
        let original = Data("foreign file must remain intact".utf8)
        try original.write(to: target)
        try FileManager.default.createSymbolicLink(at: f.file, withDestinationURL: target)
        XCTAssertThrowsError(try f.state.load())
        XCTAssertThrowsError(try f.state.revoke(binding: f.binding, reason: .accountChanged))
        XCTAssertEqual(try Data(contentsOf: target), original)
        try FileManager.default.removeItem(at: target)
        XCTAssertThrowsError(try f.state.load())
    }

    func testDirectoryAndAncestorSymlinksAreRejectedIncludingAfterStateWasInitialized() throws {
        let f = try fixture()
        let parent = f.directory.deletingLastPathComponent()
        let foreign = parent.appendingPathComponent("foreign", isDirectory: true)
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: false)
        let alias = parent.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: foreign)
        XCTAssertThrowsError(try CloudOfflineAccessState(directory: alias))
        XCTAssertThrowsError(try CloudOfflineAccessState(directory: alias.appendingPathComponent("CloudOffline")))
        try FileManager.default.removeItem(at: f.directory)
        try FileManager.default.createSymbolicLink(at: f.directory, withDestinationURL: foreign)
        XCTAssertThrowsError(try f.state.load())
        XCTAssertThrowsError(try f.state.revoke(binding: f.binding, reason: .accountChanged))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: foreign.path).isEmpty)
    }

    func testOSAliasAboveSandboxAllowsDurableReceiptWithoutChangingAlias() throws {
        let f = try fixture()
        let parent = f.directory.deletingLastPathComponent()
        let systemRoot = parent.appendingPathComponent("system", isDirectory: true)
        let sandbox = systemRoot.appendingPathComponent("containers/app", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        let alias = parent.appendingPathComponent("os-alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: systemRoot)
        let aliasedSandbox = alias.appendingPathComponent("containers/app", isDirectory: true)
        let support = aliasedSandbox.appendingPathComponent("Library/Application Support", isDirectory: true)
        // This has the physical device's /var -> ... -> sandbox shape. The
        // former root-to-leaf walk rejected the alias before creating state.
        let state = try CloudOfflineAccessState(applicationSupportDirectory: support, sandboxRoot: aliasedSandbox)
        let receipt = try state.recordVerifiedOnline(binding: f.binding, datasetGenerationID: UUID(),
            resetBaseline: marker(), expectedReceipt: nil)
        let restarted = try CloudOfflineAccessState(applicationSupportDirectory: support, sandboxRoot: aliasedSandbox)
        XCTAssertEqual(try restarted.load(), receipt)
        let physicalState = try CloudOfflineAccessState(directory:
            sandbox.appendingPathComponent("Library/Application Support/CloudOffline", isDirectory: true))
        XCTAssertEqual(try physicalState.load(), receipt)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: alias.path), systemRoot.path)
    }

    func testSandboxAnchorStillRejectsEveryLinkedOwnedDirectory() throws {
        for linkedComponent in ["Library", "Library/Application Support", "Library/Application Support/CloudOffline"] {
            let f = try fixture()
            let parent = f.directory.deletingLastPathComponent()
            let sandbox = parent.appendingPathComponent("sandbox", isDirectory: true)
            let link = sandbox.appendingPathComponent(linkedComponent, isDirectory: true)
            try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            let foreign = parent.appendingPathComponent("foreign", isDirectory: true)
            try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: false)
            let sentinel = foreign.appendingPathComponent("sentinel")
            let original = Data("must remain unchanged".utf8)
            try original.write(to: sentinel)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: foreign)
            XCTAssertThrowsError(try CloudOfflineAccessState(applicationSupportDirectory:
                sandbox.appendingPathComponent("Library/Application Support", isDirectory: true), sandboxRoot: sandbox)) {
                XCTAssertEqual($0 as? CloudOfflineAccessStateError, .unsafeDirectory)
            }
            XCTAssertEqual(try Data(contentsOf: sentinel), original)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: foreign.path), ["sentinel"])
        }
    }

    func testSandboxOwnedAncestorReplacementAfterInitializationCannotRedirectRevocation() throws {
        let f = try fixture()
        let parent = f.directory.deletingLastPathComponent()
        let sandbox = parent.appendingPathComponent("sandbox", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: false)
        let library = sandbox.appendingPathComponent("Library", isDirectory: true)
        let support = library.appendingPathComponent("Application Support", isDirectory: true)
        let state = try CloudOfflineAccessState(applicationSupportDirectory: support, sandboxRoot: sandbox)
        try state.recordVerifiedOnline(binding: f.binding, datasetGenerationID: nil,
            resetBaseline: nil, expectedReceipt: nil)
        let originalBytes = try Data(contentsOf: state.directory.appendingPathComponent("access-v1.json"))
        let retired = sandbox.appendingPathComponent("retained-library", isDirectory: true)
        try FileManager.default.moveItem(at: library, to: retired)
        let foreign = parent.appendingPathComponent("foreign", isDirectory: true)
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: library, withDestinationURL: foreign)
        XCTAssertThrowsError(try state.load())
        XCTAssertThrowsError(try state.revoke(binding: f.binding, reason: .accountChanged))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: foreign.path).isEmpty)
        XCTAssertEqual(try Data(contentsOf: retired.appendingPathComponent("Application Support/CloudOffline/access-v1.json")),
            originalBytes)
    }

    func testSandboxAnchorMustExistBeDirectoryAndContainSupportWithoutBeingALink() throws {
        let f = try fixture()
        let parent = f.directory.deletingLastPathComponent()
        let sandbox = parent.appendingPathComponent("sandbox", isDirectory: true)
        let support = sandbox.appendingPathComponent("Library/Application Support", isDirectory: true)
        XCTAssertThrowsError(try CloudOfflineAccessState(applicationSupportDirectory: support, sandboxRoot: sandbox))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sandbox.path))
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: false)
        XCTAssertThrowsError(try CloudOfflineAccessState(applicationSupportDirectory:
            parent.appendingPathComponent("sandbox-sibling/Library/Application Support"), sandboxRoot: sandbox))
        let alias = parent.appendingPathComponent("sandbox-alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: sandbox)
        XCTAssertThrowsError(try CloudOfflineAccessState(applicationSupportDirectory:
            alias.appendingPathComponent("Library/Application Support"), sandboxRoot: alias))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: sandbox.path).isEmpty)
    }

    func testLegacyMountedCopyCanBeAdoptedOfflineWithoutClaimingFreshOnlineOrKnownLineage() throws {
        let f = try fixture()
        let baseline = marker()
        XCTAssertNil(CloudOfflineAccessPolicy.legacyAdoptionBlockReason(conditions: conditions(f.binding), receipt: nil))
        let adopted = try f.state.adoptLegacyMountedCopy(binding: f.binding, resetBaseline: baseline,
            datasetGenerationID: nil, isDatasetGenerationKnown: false,
            conditions: conditions(f.binding), expectedReceipt: nil)
        XCTAssertEqual(adopted.origin, .legacySuccessfulMount)
        XCTAssertFalse(adopted.hasVerifiedOnlineBaseline)
        XCTAssertFalse(adopted.isDatasetGenerationKnown)
        XCTAssertTrue(adopted.wasUsedOffline)
        XCTAssertEqual(adopted.resetBaseline, baseline)
        let restarted = try CloudOfflineAccessState(directory: f.directory)
        XCTAssertEqual(try restarted.load(), adopted)
        XCTAssertNil(CloudOfflineAccessPolicy.blockReason(conditions: conditions(f.binding), receipt: adopted))
        let opened = try restarted.markOfflineOpened(binding: f.binding, conditions: conditions(f.binding))
        XCTAssertEqual(opened.origin, .legacySuccessfulMount)
        XCTAssertFalse(opened.isDatasetGenerationKnown)
        XCTAssertFalse(opened.hasVerifiedOnlineBaseline)
        XCTAssertEqual(opened.resetBaseline, baseline)
    }

    func testLegacyUnknownLineageMatchesOnlyFreshlyVerifiedLegacyServerDataset() throws {
        let f = try fixture()
        let adopted = try f.state.adoptLegacyMountedCopy(binding: f.binding, resetBaseline: marker(),
            datasetGenerationID: nil, isDatasetGenerationKnown: false,
            conditions: conditions(f.binding), expectedReceipt: nil)
        XCTAssertTrue(CloudOfflineAccessPolicy.matchesVerifiedDataset(receipt: adopted, datasetGenerationID: nil))
        XCTAssertFalse(CloudOfflineAccessPolicy.matchesVerifiedDataset(receipt: adopted, datasetGenerationID: UUID()))
        // The comparison alone never upgrades durable authority. Only the
        // completed online mount can replace this exact legacy receipt.
        XCTAssertEqual(try f.state.load(), adopted)
        let verified = try f.state.recordVerifiedOnline(binding: f.binding, datasetGenerationID: nil,
            resetBaseline: adopted.resetBaseline, expectedReceipt: adopted)
        XCTAssertEqual(verified.origin, .verifiedOnline)
        XCTAssertTrue(verified.isDatasetGenerationKnown)
        XCTAssertTrue(verified.hasVerifiedOnlineBaseline)
        XCTAssertFalse(verified.wasUsedOffline)
    }

    func testLegacyPriorAdmissionPreservesExactKnownDatasetInsteadOfDowngradingItToUnknown() throws {
        for generation in [UUID(), nil] as [UUID?] {
            let f = try fixture()
            let adopted = try f.state.adoptLegacyMountedCopy(binding: f.binding, resetBaseline: marker(),
                datasetGenerationID: generation, isDatasetGenerationKnown: true,
                conditions: conditions(f.binding), expectedReceipt: nil)
            XCTAssertTrue(adopted.isDatasetGenerationKnown)
            XCTAssertEqual(adopted.datasetGenerationID, generation)
            XCTAssertTrue(CloudOfflineAccessPolicy.matchesVerifiedDataset(receipt: adopted, datasetGenerationID: generation))
            XCTAssertFalse(CloudOfflineAccessPolicy.matchesVerifiedDataset(receipt: adopted, datasetGenerationID: UUID()))
            if generation != nil {
                XCTAssertFalse(CloudOfflineAccessPolicy.matchesVerifiedDataset(receipt: adopted, datasetGenerationID: nil))
            }
        }
    }

    func testLegacyAdoptionRefusesExistingAndRevokedReceiptsEvenWithMatchingExpectedValue() throws {
        for revoked in [false, true] {
            let f = try fixture()
            if revoked { try f.state.revoke(binding: f.binding, reason: .accountChanged) }
            else { try online(f) }
            let before = try XCTUnwrap(f.state.load())
            XCTAssertEqual(CloudOfflineAccessPolicy.legacyAdoptionBlockReason(
                conditions: conditions(f.binding), receipt: before), .existingReceipt)
            for expected in [nil, before] {
                XCTAssertThrowsError(try f.state.adoptLegacyMountedCopy(binding: f.binding, resetBaseline: marker(),
                    datasetGenerationID: nil, isDatasetGenerationKnown: false,
                    conditions: conditions(f.binding), expectedReceipt: expected)) {
                    XCTAssertEqual($0 as? CloudOfflineAccessStateError, .staleReceipt)
                }
                XCTAssertEqual(try f.state.load(), before)
            }
        }
    }

    func testLegacyAdoptionCannotInventCompletedMountBypassPendingWorkOrAcceptDifferentBinding() throws {
        let f = try fixture()
        let blocked = [conditions(f.binding, mount: .unrecorded), conditions(f.binding, completePair: false),
            conditions(f.binding, pendingTransfer: true), conditions(f.binding, pendingIntent: true),
            conditions(f.binding, validSchema: false), conditions(f.binding, selection: .unselected)]
        for observation in blocked {
            XCTAssertNotNil(CloudOfflineAccessPolicy.legacyAdoptionBlockReason(conditions: observation, receipt: nil))
            XCTAssertThrowsError(try f.state.adoptLegacyMountedCopy(binding: f.binding, resetBaseline: nil,
                datasetGenerationID: nil, isDatasetGenerationKnown: false,
                conditions: observation, expectedReceipt: nil))
            XCTAssertNil(try f.state.load())
        }
        let other = try XCTUnwrap(ActiveAccountLocalBinding(namespace: AccountDataNamespace(),
            accountFingerprint: f.binding.accountFingerprint))
        XCTAssertThrowsError(try f.state.adoptLegacyMountedCopy(binding: other, resetBaseline: nil,
            datasetGenerationID: nil, isDatasetGenerationKnown: false,
            conditions: conditions(f.binding), expectedReceipt: nil))
        // Unknown lineage and a concrete generation cannot coexist on disk.
        XCTAssertThrowsError(try f.state.adoptLegacyMountedCopy(binding: f.binding, resetBaseline: nil,
            datasetGenerationID: UUID(), isDatasetGenerationKnown: false,
            conditions: conditions(f.binding), expectedReceipt: nil))
        XCTAssertNil(try f.state.load())
    }

    func testAccountChangeAfterLegacyAdoptionRetainsBaselineAndBlocksReAdoptionAndOfflineWriters() throws {
        let f = try fixture()
        let adopted = try f.state.adoptLegacyMountedCopy(binding: f.binding, resetBaseline: marker(),
            datasetGenerationID: nil, isDatasetGenerationKnown: false,
            conditions: conditions(f.binding), expectedReceipt: nil)
        try f.state.revoke(binding: f.binding, reason: .accountChanged)
        let restarted = try CloudOfflineAccessState(directory: f.directory)
        let revoked = try XCTUnwrap(restarted.load())
        XCTAssertEqual(revoked.origin, adopted.origin)
        XCTAssertEqual(revoked.resetBaseline, adopted.resetBaseline)
        XCTAssertFalse(revoked.isDatasetGenerationKnown)
        XCTAssertTrue(revoked.wasUsedOffline)
        XCTAssertThrowsError(try restarted.markOfflineOpened(binding: f.binding, conditions: conditions(f.binding)))
        XCTAssertThrowsError(try restarted.adoptLegacyMountedCopy(binding: f.binding, resetBaseline: nil,
            datasetGenerationID: nil, isDatasetGenerationKnown: false,
            conditions: conditions(f.binding), expectedReceipt: nil))
        XCTAssertEqual(try restarted.load(), revoked)
    }
}
