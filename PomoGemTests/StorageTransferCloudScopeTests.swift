import Foundation
import XCTest
@testable import PomoGem

/// L2 / P0-3. The device-side admission receipt carried no CloudKit
/// environment, and it lives in the app container, which is keyed by bundle id
/// alone. A Debug build (Development) and a Release build (Production) of the
/// same bundle id therefore shared one receipt while reading two completely
/// unrelated databases, and the generation earned in one was presented to the
/// other as proof that "the iCloud data was replaced".
///
/// This is the recurrence-prevention half of the fix: without it, one
/// `xcodebuild test -scheme PomoGem` against a real device reproduces the
/// whole defect, because the scheme's test action builds Debug.
@MainActor
final class StorageTransferCloudScopeTests: XCTestCase {
    private let account = String(repeating: "7", count: 64)
    private let container = "iCloud.com.hinoshiba.pomogem"

    private func binding() throws -> ActiveAccountLocalBinding {
        try XCTUnwrap(ActiveAccountLocalBinding(namespace: AccountDataNamespace(),
                                                accountFingerprint: account))
    }

    private func scope(_ environment: StorageTransferCloudEnvironment) -> StorageTransferCloudScope {
        StorageTransferCloudScope(environment: environment, containerIdentifier: container)
    }

    // MARK: - Resolving the environment

    /// The environment is decided by the signed entitlement, which
    /// `project.yml` fills per build configuration. Reading it is the only way
    /// the runtime can know; nothing else in the app models the concept.
    func testTheEnvironmentIsReadFromTheEntitlementValue() {
        XCTAssertEqual(StorageTransferCloudScope.environment(fromEntitlement: "Development"), .development)
        XCTAssertEqual(StorageTransferCloudScope.environment(fromEntitlement: "Production"), .production)
        // Some toolchains hand back an array for this key.
        XCTAssertEqual(StorageTransferCloudScope.environment(fromEntitlement: ["Production"]), .production)
    }

    /// Anything unrecognised falls back to the build configuration, never to a
    /// guess that could accuse the other environment.
    func testAnUnreadableEntitlementFallsBackToTheBuildConfiguration() {
        let fallback = StorageTransferCloudScope.buildConfigurationEnvironment
        XCTAssertNotEqual(fallback, .unknown, "The fallback must always be decidable")
        XCTAssertEqual(StorageTransferCloudScope.environment(fromEntitlement: nil), fallback)
        XCTAssertEqual(StorageTransferCloudScope.environment(fromEntitlement: "nonsense"), fallback)
        XCTAssertEqual(StorageTransferCloudScope.environment(fromEntitlement: [Int]()), fallback)
        #if DEBUG
        XCTAssertEqual(fallback, .development, "A Debug build talks to Development")
        #endif
    }

    func testTheResolvedScopeIsAlwaysKnownAndNamesTheContainer() {
        let resolved = StorageTransferCloudScope.current()
        XCTAssertTrue(resolved.isKnown)
        XCTAssertEqual(resolved.containerIdentifier,
                       CloudSyncConfiguration.synchronizedDataContainerIdentifier)
    }

    // MARK: - Comparison

    func testAnUnknownScopeNeverAccusesAKnownOne() {
        XCTAssertFalse(StorageTransferCloudScope.unknown.isProvenDifferent(from: scope(.production)))
        XCTAssertFalse(scope(.production).isProvenDifferent(from: .unknown))
        XCTAssertTrue(scope(.development).isProvenDifferent(from: scope(.production)))
    }

    func testADifferentContainerIdentifierIsAlsoAScopeChange() {
        let other = StorageTransferCloudScope(environment: .production,
                                              containerIdentifier: "iCloud.example.other")
        XCTAssertTrue(scope(.production).isProvenDifferent(from: other))
    }

    // MARK: - The admission decision

    /// The headline requirement: the same generation seen from a different
    /// environment must never be reported as a replacement.
    func testSameGenerationInADifferentEnvironmentIsNotAReplacement() throws {
        let binding = try binding()
        let generation = UUID()
        let found = StorageTransferDatasetAdmission(binding: binding,
            datasetGenerationID: generation, cloudScope: scope(.development))
        let decision = StorageTransferAdmissionPolicy.decide(found: found, binding: binding,
            scope: scope(.production), serverGenerationID: generation)
        XCTAssertEqual(decision, .refuse(.cloudEnvironmentMismatch))
        XCTAssertNotEqual(decision, .refuse(.datasetReplacedRemotely))
    }

    /// And a differing generation across environments is an environment
    /// explanation too, not a replacement accusation.
    func testDifferentGenerationsInDifferentEnvironmentsExplainTheEnvironment() throws {
        let binding = try binding()
        let found = StorageTransferDatasetAdmission(binding: binding,
            datasetGenerationID: UUID(), cloudScope: scope(.development))
        XCTAssertEqual(StorageTransferAdmissionPolicy.decide(found: found, binding: binding,
            scope: scope(.production), serverGenerationID: UUID()),
            .refuse(.cloudEnvironmentMismatch))
    }

    /// An unscoped legacy receipt that still matches is adopted, not refused:
    /// an ordinary upgrade in the SAME environment must stay silent.
    func testALegacyReceiptThatStillMatchesIsRescopedRatherThanRefused() throws {
        let binding = try binding()
        let generation = UUID()
        let found = StorageTransferDatasetAdmission(binding: binding, datasetGenerationID: generation)
        XCTAssertEqual(StorageTransferAdmissionPolicy.decide(found: found, binding: binding,
            scope: scope(.production), serverGenerationID: generation),
            .rescope(StorageTransferDatasetAdmission(binding: binding,
                datasetGenerationID: generation, cloudScope: scope(.production))))
    }

    // MARK: - File naming and the one-time migration

    func testTheReceiptFileNameCarriesTheEnvironment() throws {
        let namespace = AccountDataNamespace()
        let development = StorageTransferRuntime.admissionFileName(namespace: namespace,
                                                                   scope: scope(.development))
        let production = StorageTransferRuntime.admissionFileName(namespace: namespace,
                                                                  scope: scope(.production))
        XCTAssertNotEqual(development, production)
        XCTAssertTrue(development.contains(namespace.rawValue))
        XCTAssertTrue(production.contains(namespace.rawValue))
        XCTAssertEqual(StorageTransferRuntime.admissionFileName(namespace: namespace, scope: .unknown),
                       "admission-\(namespace.rawValue).json",
                       "An unknown scope keeps the legacy name so nothing is orphaned")
    }

    private struct Fixture {
        let parent: URL
        let root: URL
        let binding: ActiveAccountLocalBinding
        let store: StorageTransferJournalStore
    }

    private func fixture() throws -> Fixture {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("CloudScope-\(UUID())")
        let root = parent.appendingPathComponent("StorageTransfer", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: parent) }
        return Fixture(parent: parent, root: root, binding: try binding(),
                       store: StorageTransferJournalStore(directory: root))
    }

    private func file(_ root: URL, _ binding: ActiveAccountLocalBinding,
                      _ scope: StorageTransferCloudScope)
        throws -> StorageTransferStateFile<StorageTransferDatasetAdmission> {
        try StorageTransferStateFile(url: root.appendingPathComponent(
            StorageTransferRuntime.admissionFileName(namespace: binding.namespace, scope: scope)))
    }

    private func committedControl(previous: UUID? = nil) throws -> StorageTransferRecoveryControl {
        let payload = Data("cloud scope payload".utf8)
        let manifest = try StorageTransferRecoveryManifest(transactionID: UUID(),
            accountFingerprint: account, payload: payload, previousDatasetGenerationID: previous)
        return try StorageTransferRecoveryControl(manifest: manifest)
            .advancing(to: .backupVerified)
            .advancing(to: .replacing)
            .advancing(to: .committed,
                       verifiedDestinationSHA256: StorageTransferRecoverySchema.digest(payload))
    }

    /// A legacy `admission-<namespace>.json` written by a build that did not
    /// record the environment is read once, confirmed against the server, and
    /// rewritten under the scoped name. The legacy file is retired so a later
    /// build in the OTHER environment cannot pick it up again - which is the
    /// exact mechanism that produced the reported block.
    func testTheLegacyReceiptIsMigratedOnceIntoTheScopedName() async throws {
        let f = try fixture()
        let current = scope(.production)
        let control = try committedControl()
        let generation = try XCTUnwrap(control.datasetGenerationID)
        let legacy = try file(f.root, f.binding, .unknown)
        try legacy.save(StorageTransferDatasetAdmission(binding: f.binding,
            datasetGenerationID: generation), replacing: nil)

        let runtime = StorageTransferRuntime(store: f.store, root: f.root, cloudScope: current)
        try await runtime.preflightCloudMount(binding: f.binding,
            readControl: { control }, validateAccess: {})

        let migrated = try XCTUnwrap(try file(f.root, f.binding, current).load())
        XCTAssertEqual(migrated.datasetGenerationID, generation)
        XCTAssertEqual(migrated.cloudScope, current)
        XCTAssertNil(try legacy.load(), "The legacy receipt is retired exactly once")
        XCTAssertEqual(try runtime.localDatasetAdmission(binding: f.binding), migrated)
    }

    /// ROOT-CAUSE §2, reproduced end to end: a receipt earned in Development is
    /// presented to a Production database that has no transfer ledger at all.
    /// Before the fix this was `datasetRefreshRequired` with the 「別の端末」
    /// sentence. It must now be a lineage/environment explanation, and it must
    /// not consume the legacy receipt.
    func testTheReportedRecurrenceNoLongerClaimsAReplacement() async throws {
        let f = try fixture()
        let developmentGeneration = UUID()
        let legacy = try file(f.root, f.binding, .unknown)
        let receipt = StorageTransferDatasetAdmission(binding: f.binding,
            datasetGenerationID: developmentGeneration)
        try legacy.save(receipt, replacing: nil)

        let runtime = StorageTransferRuntime(store: f.store, root: f.root,
                                             cloudScope: scope(.production))
        do {
            try await runtime.preflightCloudMount(binding: f.binding,
                readControl: { nil }, validateAccess: {})
            XCTFail("A Production database without a ledger must not admit a Development receipt")
        } catch {
            let observed = error as? StorageTransferRuntimeError
            XCTAssertTrue(observed == .cloudLineageUnavailable || observed == .cloudEnvironmentMismatch,
                          "Expected a lineage/environment explanation, got \(String(describing: observed))")
            XCTAssertNotEqual(observed, .datasetReplacedRemotely)
            XCTAssertFalse(try XCTUnwrap(observed).localizedDescription.contains("別の端末"))
        }
        XCTAssertEqual(try legacy.load(), receipt, "A refusal must not rewrite or retire the receipt")
        XCTAssertNil(try file(f.root, f.binding, scope(.production)).load())
        XCTAssertNil(try f.store.load())
    }

    /// The structural half: once receipts are scoped, the two environments no
    /// longer see each other's state at all, so neither can accuse the other.
    func testTheTwoEnvironmentsNoLongerShareAReceipt() async throws {
        let f = try fixture()
        let developmentControl = try committedControl()
        try await StorageTransferRuntime(store: f.store, root: f.root, cloudScope: scope(.development))
            .preflightCloudMount(binding: f.binding, readControl: { developmentControl },
                                 validateAccess: {})
        XCTAssertEqual(try file(f.root, f.binding, scope(.development)).load()?.datasetGenerationID,
                       developmentControl.datasetGenerationID)

        // The Production build sees no receipt of its own and enrols cleanly
        // into the Production lineage instead of being blocked by the other
        // environment's generation.
        let productionControl = try committedControl()
        let production = StorageTransferRuntime(store: f.store, root: f.root,
                                                cloudScope: scope(.production))
        try await production.preflightCloudMount(binding: f.binding,
            readControl: { productionControl }, validateAccess: {})
        XCTAssertEqual(try file(f.root, f.binding, scope(.production)).load()?.datasetGenerationID,
                       productionControl.datasetGenerationID)
        XCTAssertNotEqual(developmentControl.datasetGenerationID, productionControl.datasetGenerationID)
    }
}
