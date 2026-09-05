import SwiftData
import XCTest
@testable import Tsumiben

@MainActor
final class PersistenceStoreTopologyTests: XCTestCase {
    func testVersionOneExternalSurfacesAreAccountNeutral() {
        XCTAssertFalse(ReleaseExternalSurfacePolicy.showsAccountDataInWidgets)
        XCTAssertTrue(ReleaseExternalSurfacePolicy.supportsLiveActivities)
    }

    func testLiveActivityAttributesContainNoUserAuthoredOrAccountData() throws {
        let sessionID = UUID()
        let attributes = FocusActivityAttributes(
            sessionID: sessionID,
            durationSeconds: 1_500
        )

        XCTAssertEqual(attributes.sessionID, sessionID)
        XCTAssertEqual(attributes.durationSeconds, 1_500)
        XCTAssertEqual(
            Set(Mirror(reflecting: attributes).children.compactMap(\.label)),
            ["sessionID", "durationSeconds"]
        )
    }

    func testLiveActivityPreferenceDefaultsOnAndRespectsLocalOptOut() throws {
        let suiteName = "FocusActivityPreferenceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertTrue(FocusActivityPreference.isEnabled(defaults: defaults))
        defaults.set(false, forKey: FocusActivityPreference.enabledDefaultsKey)
        XCTAssertFalse(FocusActivityPreference.isEnabled(defaults: defaults))
        defaults.set(true, forKey: FocusActivityPreference.enabledDefaultsKey)
        XCTAssertTrue(FocusActivityPreference.isEnabled(defaults: defaults))
    }

    func testLiveActivityContentStatesAreExclusiveClampedAndCodable() throws {
        let endDate = Date(timeIntervalSince1970: 1_788_000_000)
        let running = FocusActivityAttributes.ContentState.running(until: endDate)
        let paused = FocusActivityAttributes.ContentState.paused(remainingSeconds: -1)
        let completed = FocusActivityAttributes.ContentState.completed()

        XCTAssertEqual(running.phase, .running)
        XCTAssertEqual(running.endDate, endDate)
        XCTAssertNil(running.pausedRemainingSeconds)
        XCTAssertEqual(paused.phase, .paused)
        XCTAssertNil(paused.endDate)
        XCTAssertEqual(paused.pausedRemainingSeconds, 0)
        XCTAssertEqual(completed.phase, .completed)
        XCTAssertNil(completed.endDate)
        XCTAssertNil(completed.pausedRemainingSeconds)

        for state in [running, paused, completed] {
            let encoded = try JSONEncoder().encode(state)
            XCTAssertEqual(
                try JSONDecoder().decode(
                    FocusActivityAttributes.ContentState.self,
                    from: encoded
                ),
                state
            )
        }
    }

    func testLiveActivityEncodedPayloadUsesReviewedKeysAndStaysBelowFourKB() throws {
        let attributes = FocusActivityAttributes(
            sessionID: UUID(),
            durationSeconds: 90 * 60
        )
        let state = FocusActivityAttributes.ContentState.running(
            until: Date(timeIntervalSince1970: 1_788_005_400)
        )
        let encoder = JSONEncoder()
        let attributesData = try encoder.encode(attributes)
        let stateData = try encoder.encode(state)

        let attributeObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: attributesData) as? [String: Any]
        )
        let stateObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: stateData) as? [String: Any]
        )
        XCTAssertEqual(Set(attributeObject.keys), ["sessionID", "durationSeconds"])
        XCTAssertEqual(Set(stateObject.keys), ["phase", "endDate"])
        XCTAssertLessThan(attributesData.count + stateData.count, 4_096)

        let encodedText = String(
            decoding: attributesData + stateData,
            as: UTF8.self
        )
        for forbiddenMarker in [
            "subject", "theme", "memo", "account", "CloudKit", "grams"
        ] {
            XCTAssertFalse(
                encodedText.localizedCaseInsensitiveContains(forbiddenMarker),
                "Live Activity payload must not contain \(forbiddenMarker)"
            )
        }
    }

    func testDisabledWidgetPublicationIsANoOpBeforeEncodingOrSharedStorage() async throws {
        try await WidgetSnapshotStore.shared.save(
            imageData: Data("private-account-snapshot".utf8),
            metadata: WidgetSnapshotMetadata(
                totalGrams: 12_750,
                measuredGrams: 12_500,
                pebbleCount: 51,
                goldCount: 3,
                prismCount: 1
            )
        )

        XCTAssertNil(WidgetSnapshotStore.shared.lastSavedAt)
        XCTAssertNil(WidgetSnapshotStore.shared.lastErrorDescription)
    }

    func testCloudProfileAllowsAThenBlocksBThenAllowsAAgain() throws {
        let namespaceA = try XCTUnwrap(AccountDataNamespace(
            rawValue: "10000000-0000-4000-8000-000000000001"
        ))
        let fingerprintA = String(repeating: "a", count: 64)
        let fingerprintB = String(repeating: "b", count: 64)
        let bindingA = try XCTUnwrap(ActiveAccountLocalBinding(
            namespace: namespaceA,
            accountFingerprint: fingerprintA
        ))
        var reconstructedRegistry = AppleAccountNamespaceRegistry()
        XCTAssertEqual(
            reconstructedRegistry.resolve(
                .verified(fingerprint: fingerprintA),
                expectedBinding: bindingA
            ),
            .allow(bindingA)
        )

        var registry = AppleAccountNamespaceRegistry()

        XCTAssertEqual(
            registry.resolve(
                .verified(fingerprint: fingerprintA),
                makeNamespace: { namespaceA }
            ),
            .allow(bindingA)
        )
        XCTAssertEqual(
            registry.resolve(
                .verified(fingerprint: fingerprintB),
                expectedBinding: bindingA
            ),
            .block(.accountMismatch)
        )
        XCTAssertEqual(
            registry.resolve(
                .verified(fingerprint: fingerprintA),
                expectedBinding: bindingA
            ),
            .allow(bindingA)
        )
        XCTAssertEqual(registry.entries.count, 1)

        let roundTripped = try JSONDecoder().decode(
            AppleAccountNamespaceRegistry.self,
            from: JSONEncoder().encode(registry)
        )
        XCTAssertEqual(roundTripped, registry)
    }

    func testAccountNamespaceResolutionAlwaysBlocksOfflineAndUnavailable() throws {
        let namespace = try XCTUnwrap(AccountDataNamespace(
            rawValue: "30000000-0000-4000-8000-000000000003"
        ))
        let fingerprint = String(repeating: "a", count: 64)
        var registry = AppleAccountNamespaceRegistry()
        _ = registry.resolve(
            .verified(fingerprint: fingerprint),
            makeNamespace: { namespace }
        )
        let verifiedRegistry = registry

        XCTAssertEqual(
            registry.resolve(.offline),
            .block(.identityUnavailable)
        )
        XCTAssertEqual(
            registry.resolve(.unavailable),
            .block(.identityUnavailable)
        )
        XCTAssertEqual(registry, verifiedRegistry)

        var freshRegistry = AppleAccountNamespaceRegistry()
        XCTAssertEqual(
            freshRegistry.resolve(.offline),
            .block(.identityUnavailable)
        )
    }

    func testInvalidVerifiedFingerprintsFailClosedWithoutCreatingMappings() throws {
        var registry = AppleAccountNamespaceRegistry()

        for invalid in [
            "",
            String(repeating: "a", count: 63),
            String(repeating: "A", count: 64),
            String(repeating: "g", count: 64)
        ] {
            XCTAssertEqual(
                registry.resolve(.verified(fingerprint: invalid)),
                .block(.invalidVerifiedIdentity)
            )
        }
        XCTAssertTrue(registry.entries.isEmpty)

        let namespace = AccountDataNamespace()
        _ = registry.resolve(
            .verified(fingerprint: String(repeating: "a", count: 64)),
            makeNamespace: { namespace }
        )
        let encoded = try JSONEncoder().encode(registry)
        let validJSON = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        let noncanonicalJSON = validJSON.replacingOccurrences(
            of: String(repeating: "a", count: 64),
            with: String(repeating: "A", count: 64)
        )
        XCTAssertThrowsError(try JSONDecoder().decode(
            AppleAccountNamespaceRegistry.self,
            from: Data(noncanonicalJSON.utf8)
        ))
    }

    func testStorageSelectionIsExplicitPersistentAndImmutable() throws {
        let localSuite = "PersistenceDeploymentState.local.\(UUID().uuidString)"
        let localDefaults = try XCTUnwrap(UserDefaults(suiteName: localSuite))
        defer { localDefaults.removePersistentDomain(forName: localSuite) }
        let namespace = try XCTUnwrap(AccountDataNamespace(
            rawValue: "40000000-0000-4000-8000-000000000004"
        ))
        let cloudBinding = try XCTUnwrap(ActiveAccountLocalBinding(
            namespace: AccountDataNamespace(),
            accountFingerprint: String(repeating: "c", count: 64)
        ))

        XCTAssertEqual(
            PersistenceDeploymentState.load(defaults: localDefaults),
            .unselected
        )
        try PersistenceDeploymentState.select(
            .localOnly(namespace: namespace),
            defaults: localDefaults
        )
        XCTAssertEqual(
            PersistenceDeploymentState.load(defaults: localDefaults),
            .selected(.localOnly(namespace: namespace))
        )
        XCTAssertThrowsError(try PersistenceDeploymentState.select(
            .cloud(binding: cloudBinding),
            defaults: localDefaults
        )) {
            XCTAssertEqual(
                $0 as? PersistenceDeploymentStateError,
                .selectionAlreadyMade
            )
        }

        let cloudSuite = "PersistenceDeploymentState.cloud.\(UUID().uuidString)"
        let cloudDefaults = try XCTUnwrap(UserDefaults(suiteName: cloudSuite))
        defer { cloudDefaults.removePersistentDomain(forName: cloudSuite) }
        try PersistenceDeploymentState.select(
            .cloud(binding: cloudBinding),
            defaults: cloudDefaults
        )
        XCTAssertEqual(
            PersistenceDeploymentState.load(defaults: cloudDefaults),
            .selected(.cloud(binding: cloudBinding))
        )
        XCTAssertThrowsError(try PersistenceDeploymentState.select(
            .localOnly(namespace: AccountDataNamespace()),
            defaults: cloudDefaults
        )) {
            XCTAssertEqual(
                $0 as? PersistenceDeploymentStateError,
                .selectionAlreadyMade
            )
        }
    }

    func testSuccessfulMountMarkerIsBoundToTheImmutableSelection() throws {
        let suite = "PersistenceDeploymentMount.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let selection = PersistenceDeploymentSelection.localOnly(
            namespace: AccountDataNamespace()
        )

        XCTAssertEqual(
            PersistenceDeploymentState.loadMountState(defaults: defaults),
            .unrecorded
        )
        try PersistenceDeploymentState.select(selection, defaults: defaults)
        try PersistenceDeploymentState.recordSuccessfulMount(
            selection,
            defaults: defaults
        )
        XCTAssertEqual(
            PersistenceDeploymentState.loadMountState(defaults: defaults),
            .mounted(selection)
        )
        try PersistenceDeploymentState.recordSuccessfulMount(
            selection,
            defaults: defaults
        )
        XCTAssertThrowsError(try PersistenceDeploymentState
            .recordSuccessfulMount(
                .localOnly(namespace: AccountDataNamespace()),
                defaults: defaults
            )) {
                XCTAssertEqual(
                    $0 as? PersistenceDeploymentStateError,
                    .invalidPersistedSelection
                )
            }

        defaults.set(
            Data("not-json".utf8),
            forKey: "persistence.deployment-mounted-selection.v1"
        )
        XCTAssertEqual(
            PersistenceDeploymentState.loadMountState(defaults: defaults),
            .invalid
        )
    }

    func testLateCloudCommitCannotOverwriteLocalOnlyChoice() async throws {
        let suite = "PersistenceDeploymentRace.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let localSelection = PersistenceDeploymentSelection.localOnly(
            namespace: AccountDataNamespace()
        )
        let cloudBinding = try XCTUnwrap(ActiveAccountLocalBinding(
            namespace: AccountDataNamespace(),
            accountFingerprint: String(repeating: "d", count: 64)
        ))

        let lateCloudCommit = Task { @MainActor in
            await Task.yield()
            do {
                try PersistenceDeploymentState.select(
                    .cloud(binding: cloudBinding),
                    defaults: defaults
                )
                return Optional<PersistenceDeploymentStateError>.none
            } catch {
                return error as? PersistenceDeploymentStateError
            }
        }
        try PersistenceDeploymentState.select(
            localSelection,
            defaults: defaults
        )

        let lateCommitError = await lateCloudCommit.value
        XCTAssertEqual(lateCommitError, .selectionAlreadyMade)
        XCTAssertEqual(
            PersistenceDeploymentState.load(defaults: defaults),
            .selected(localSelection)
        )
        XCTAssertEqual(
            PersistenceDeploymentState.loadMountState(defaults: defaults),
            .unrecorded
        )
    }

    func testCloudMountAuthorizationRequiresExactIdentityLifecycleAndGeneration() throws {
        let bindingA = try XCTUnwrap(ActiveAccountLocalBinding(
            namespace: AccountDataNamespace(),
            accountFingerprint: String(repeating: "a", count: 64)
        ))
        let bindingB = try XCTUnwrap(ActiveAccountLocalBinding(
            namespace: AccountDataNamespace(),
            accountFingerprint: String(repeating: "b", count: 64)
        ))
        let selectedA = PersistenceDeploymentSelectionState.selected(
            .cloud(binding: bindingA)
        )

        func evaluate(
            verified: ActiveAccountLocalBinding = bindingA,
            selection: PersistenceDeploymentSelectionState = selectedA,
            generationMatches: Bool = true,
            sceneActive: Bool = true,
            applicationActive: Bool = true
        ) -> CloudMountAuthorizationDecision {
            CloudMountAuthorizationPolicy.evaluate(
                expectedBinding: bindingA,
                verifiedBinding: verified,
                selectionState: selection,
                generationMatches: generationMatches,
                isSceneActive: sceneActive,
                isApplicationActive: applicationActive
            )
        }

        XCTAssertEqual(evaluate(), .allow)
        XCTAssertEqual(
            evaluate(generationMatches: false),
            .staleGeneration
        )
        XCTAssertEqual(evaluate(sceneActive: false), .sceneInactive)
        XCTAssertEqual(
            evaluate(applicationActive: false),
            .applicationInactive
        )
        XCTAssertEqual(
            evaluate(selection: .selected(.localOnly(
                namespace: bindingA.namespace
            ))),
            .selectionMismatch
        )
        XCTAssertEqual(evaluate(verified: bindingB), .identityMismatch)
    }

    func testContainerRetirementPollBudgetTimesOutAndNeverAuthorizesStaleGeneration() {
        var budget = PersistenceContainerRetirementPollBudget(maximumPolls: 2)
        XCTAssertEqual(
            budget.observe(isReleased: false, generationMatches: true),
            .continueWaiting
        )
        XCTAssertEqual(
            budget.observe(isReleased: false, generationMatches: true),
            .continueWaiting
        )
        XCTAssertEqual(
            budget.observe(isReleased: false, generationMatches: true),
            .timedOut
        )
        XCTAssertEqual(
            budget.observe(isReleased: true, generationMatches: true),
            .retired
        )

        var stale = PersistenceContainerRetirementPollBudget(maximumPolls: 80)
        XCTAssertEqual(
            stale.observe(isReleased: true, generationMatches: false),
            .cancelled
        )
    }

    func testDeploymentValidationRequiresChoiceOnlyForTrulyFreshInstall() throws {
        let localNamespace = AccountDataNamespace()
        let cloudBinding = try XCTUnwrap(ActiveAccountLocalBinding(
            namespace: AccountDataNamespace(),
            accountFingerprint: String(repeating: "c", count: 64)
        ))
        let emptyHistory = PersistenceArtifactHistory()

        XCTAssertEqual(PersistenceDeploymentState.validate(
            selectionState: .unselected,
            mountState: .unrecorded,
            artifactHistory: emptyHistory,
            hasCloudRegistryHistory: false,
            hasCloudBindingHistory: false
        ), .needsExplicitChoice)
        XCTAssertEqual(PersistenceDeploymentState.validate(
            selectionState: .unselected,
            mountState: .unrecorded,
            artifactHistory: emptyHistory,
            hasCloudRegistryHistory: true,
            hasCloudBindingHistory: false
        ), .recoveryRequired)

        XCTAssertEqual(PersistenceDeploymentState.validate(
            selectionState: .invalid,
            mountState: .unrecorded,
            artifactHistory: emptyHistory,
            hasCloudRegistryHistory: false,
            hasCloudBindingHistory: false
        ), .recoveryRequired)

        var orphanedLocalHistory = PersistenceArtifactHistory()
        orphanedLocalHistory.localOnly[localNamespace] = .init(
            hasSourceStore: true,
            hasProjectionStore: true
        )
        XCTAssertEqual(PersistenceDeploymentState.validate(
            selectionState: .unselected,
            mountState: .unrecorded,
            artifactHistory: orphanedLocalHistory,
            hasCloudRegistryHistory: false,
            hasCloudBindingHistory: false
        ), .recoveryRequired)
        XCTAssertEqual(PersistenceDeploymentState.validate(
            selectionState: .unselected,
            mountState: .unrecorded,
            artifactHistory: emptyHistory,
            hasCloudRegistryHistory: false,
            hasCloudBindingHistory: true
        ), .recoveryRequired)

        // Persisting the immutable profile happens before ModelContainer is
        // created. Zero files is therefore the one valid commit/mount boundary.
        XCTAssertEqual(PersistenceDeploymentState.validate(
            selectionState: .selected(.localOnly(
                namespace: localNamespace
            )),
            mountState: .unrecorded,
            artifactHistory: emptyHistory,
            hasCloudRegistryHistory: false,
            hasCloudBindingHistory: false
        ), .valid)
        XCTAssertEqual(PersistenceDeploymentState.validate(
            selectionState: .selected(.cloud(binding: cloudBinding)),
            mountState: .unrecorded,
            artifactHistory: emptyHistory,
            hasCloudRegistryHistory: false,
            hasCloudBindingHistory: false
        ), .valid)
        XCTAssertEqual(PersistenceDeploymentState.validate(
            selectionState: .selected(.cloud(binding: cloudBinding)),
            mountState: .mounted(.cloud(binding: cloudBinding)),
            artifactHistory: emptyHistory,
            hasCloudRegistryHistory: false,
            hasCloudBindingHistory: false
        ), .recoveryRequired)

        XCTAssertEqual(PersistenceDeploymentState.validate(
            selectionState: .unselected,
            mountState: .mounted(.cloud(binding: cloudBinding)),
            artifactHistory: emptyHistory,
            hasCloudRegistryHistory: false,
            hasCloudBindingHistory: false
        ), .recoveryRequired)
    }

    func testDeploymentValidationRejectsPartialSidecarAndMultipleStores() throws {
        let namespace = AccountDataNamespace()
        let otherNamespace = AccountDataNamespace()
        var partial = PersistenceArtifactHistory()
        partial.localOnly[namespace] = .init(hasSourceStore: true)
        XCTAssertEqual(PersistenceDeploymentState.validate(
            selectionState: .selected(.localOnly(namespace: namespace)),
            mountState: .unrecorded,
            artifactHistory: partial,
            hasCloudRegistryHistory: false,
            hasCloudBindingHistory: false
        ), .resumeInitialMount)
        XCTAssertEqual(PersistenceDeploymentState.validate(
            selectionState: .selected(.localOnly(namespace: namespace)),
            mountState: .mounted(.localOnly(namespace: namespace)),
            artifactHistory: partial,
            hasCloudRegistryHistory: false,
            hasCloudBindingHistory: false
        ), .recoveryRequired)

        var sidecarOnly = PersistenceArtifactHistory()
        sidecarOnly.localOnly[namespace] = .init(
            hasMigrationSidecar: true
        )
        XCTAssertEqual(PersistenceDeploymentState.validate(
            selectionState: .selected(.localOnly(namespace: namespace)),
            mountState: .unrecorded,
            artifactHistory: sidecarOnly,
            hasCloudRegistryHistory: false,
            hasCloudBindingHistory: false
        ), .recoveryRequired)

        var complete = PersistenceArtifactHistory()
        complete.localOnly[namespace] = .init(
            hasSourceStore: true,
            hasProjectionStore: true
        )
        XCTAssertEqual(PersistenceDeploymentState.validate(
            selectionState: .selected(.localOnly(namespace: namespace)),
            mountState: .unrecorded,
            artifactHistory: complete,
            hasCloudRegistryHistory: false,
            hasCloudBindingHistory: false
        ), .valid)
        complete.localOnly[otherNamespace] = .init(
            hasSourceStore: true,
            hasProjectionStore: true
        )
        XCTAssertEqual(PersistenceDeploymentState.validate(
            selectionState: .selected(.localOnly(namespace: namespace)),
            mountState: .unrecorded,
            artifactHistory: complete,
            hasCloudRegistryHistory: false,
            hasCloudBindingHistory: false
        ), .recoveryRequired)

        let cloudBinding = try XCTUnwrap(ActiveAccountLocalBinding(
            namespace: namespace,
            accountFingerprint: String(repeating: "e", count: 64)
        ))
        var partialCloud = PersistenceArtifactHistory()
        partialCloud.cloud[namespace] = .init(hasSourceStore: true)
        XCTAssertEqual(PersistenceDeploymentState.validate(
            selectionState: .selected(.cloud(binding: cloudBinding)),
            mountState: .unrecorded,
            artifactHistory: partialCloud,
            hasCloudRegistryHistory: false,
            hasCloudBindingHistory: false
        ), .resumeInitialMount)

        var completeCloud = PersistenceArtifactHistory()
        completeCloud.cloud[namespace] = .init(
            hasSourceStore: true,
            hasProjectionStore: true
        )
        XCTAssertEqual(PersistenceDeploymentState.validate(
            selectionState: .selected(.cloud(binding: cloudBinding)),
            mountState: .mounted(.cloud(binding: cloudBinding)),
            artifactHistory: completeCloud,
            hasCloudRegistryHistory: false,
            hasCloudBindingHistory: true
        ), .valid)
        completeCloud.cloud[otherNamespace] = .init(
            hasSourceStore: true,
            hasProjectionStore: true
        )
        XCTAssertEqual(PersistenceDeploymentState.validate(
            selectionState: .selected(.cloud(binding: cloudBinding)),
            mountState: .mounted(.cloud(binding: cloudBinding)),
            artifactHistory: completeCloud,
            hasCloudRegistryHistory: false,
            hasCloudBindingHistory: true
        ), .recoveryRequired)
    }

    func testLocalOnlyConfigurationsUseSeparateNamespacedNonCloudStores() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TsumibenLocalOnlyTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let namespace = try XCTUnwrap(AccountDataNamespace(
            rawValue: "41000000-0000-4000-8000-000000000004"
        ))
        let configurations = PersistenceStoreTopology.localOnlyConfigurations(
            namespace: namespace,
            directory: directory
        )
        let cloudURLs = PersistenceStoreTopology.accountStoreURLs(
            accountNamespace: namespace,
            directory: directory
        )

        XCTAssertEqual(configurations.count, 2)
        XCTAssertTrue(configurations.allSatisfy {
            $0.cloudKitContainerIdentifier == nil
        })
        XCTAssertEqual(
            configurations.map(\.url),
            PersistenceStoreTopology.localOnlyPersistentStoreURLs(
                namespace: namespace,
                directory: directory
            )
        )
        XCTAssertTrue(Set(configurations.map(\.url)).isDisjoint(
            with: Set(cloudURLs)
        ))

        let container = try ModelContainer(
            for: PersistenceStoreTopology.shippingSchema,
            configurations: configurations
        )
        container.mainContext.insert(Subject(
            name: "端末内だけ",
            colorHex: Constants.Color.english,
            sortOrder: 0
        ))
        container.mainContext.insert(GachaState())
        try container.mainContext.save()
        XCTAssertEqual(
            try container.mainContext.fetchCount(FetchDescriptor<Subject>()),
            1
        )
        let history = PersistenceStoreTopology.persistenceArtifactHistory(
            directory: directory
        )
        XCTAssertFalse(history.hasInvalidArtifact)
        XCTAssertEqual(history.localOnly.count, 1)
        XCTAssertTrue(
            history.localOnly[namespace]?.hasCompleteStorePair == true
        )
        XCTAssertEqual(PersistenceDeploymentState.validate(
            selectionState: .selected(.localOnly(namespace: namespace)),
            mountState: .mounted(.localOnly(namespace: namespace)),
            artifactHistory: history,
            hasCloudRegistryHistory: false,
            hasCloudBindingHistory: false
        ), .valid)
    }

    func testInitialLocalMountResumesSourceOnlyWithoutDeletingExistingRows() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TsumibenSourceResume-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let namespace = AccountDataNamespace()
        let selection = PersistenceDeploymentSelection.localOnly(
            namespace: namespace
        )
        let urls = PersistenceStoreTopology.localOnlyPersistentStoreURLs(
            namespace: namespace,
            directory: directory
        )

        var partialContainer: ModelContainer? = try ModelContainer(
            for: PersistenceStoreTopology.cloudSchema,
            configurations: [ModelConfiguration(
                PersistenceStoreTopology.localOnlySourceStoreName,
                schema: PersistenceStoreTopology.cloudSchema,
                url: urls[0],
                cloudKitDatabase: .none
            )]
        )
        partialContainer?.mainContext.insert(Subject(
            name: "crash-survivor",
            colorHex: Constants.Color.english,
            sortOrder: 0
        ))
        try partialContainer?.mainContext.save()
        partialContainer = nil

        let interrupted = PersistenceStoreTopology.persistenceArtifactHistory(
            directory: directory
        )
        XCTAssertEqual(PersistenceDeploymentState.validate(
            selectionState: .selected(selection),
            mountState: .unrecorded,
            artifactHistory: interrupted,
            hasCloudRegistryHistory: false,
            hasCloudBindingHistory: false
        ), .resumeInitialMount)
        XCTAssertFalse(FileManager.default.fileExists(atPath: urls[1].path))

        let resumed = try ModelContainer(
            for: PersistenceStoreTopology.shippingSchema,
            configurations: PersistenceStoreTopology.localOnlyConfigurations(
                namespace: namespace,
                directory: directory
            )
        )
        XCTAssertEqual(
            try resumed.mainContext.fetchCount(FetchDescriptor<Subject>()),
            1
        )
        XCTAssertTrue(PersistenceStoreTopology.persistenceArtifactHistory(
            directory: directory
        ).hasExactCompleteStorePair(for: selection))
    }

    func testInitialLocalMountResumesProjectionOnlyWithoutDeletingExistingRows() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TsumibenProjectionResume-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let namespace = AccountDataNamespace()
        let selection = PersistenceDeploymentSelection.localOnly(
            namespace: namespace
        )
        let urls = PersistenceStoreTopology.localOnlyPersistentStoreURLs(
            namespace: namespace,
            directory: directory
        )

        var partialContainer: ModelContainer? = try ModelContainer(
            for: PersistenceStoreTopology.localProjectionSchema,
            configurations: [ModelConfiguration(
                PersistenceStoreTopology.localOnlyProjectionStoreName,
                schema: PersistenceStoreTopology.localProjectionSchema,
                url: urls[1],
                cloudKitDatabase: .none
            )]
        )
        partialContainer?.mainContext.insert(GachaState())
        try partialContainer?.mainContext.save()
        partialContainer = nil

        let interrupted = PersistenceStoreTopology.persistenceArtifactHistory(
            directory: directory
        )
        XCTAssertEqual(PersistenceDeploymentState.validate(
            selectionState: .selected(selection),
            mountState: .unrecorded,
            artifactHistory: interrupted,
            hasCloudRegistryHistory: false,
            hasCloudBindingHistory: false
        ), .resumeInitialMount)
        XCTAssertFalse(FileManager.default.fileExists(atPath: urls[0].path))

        let resumed = try ModelContainer(
            for: PersistenceStoreTopology.shippingSchema,
            configurations: PersistenceStoreTopology.localOnlyConfigurations(
                namespace: namespace,
                directory: directory
            )
        )
        XCTAssertEqual(
            try resumed.mainContext.fetchCount(FetchDescriptor<GachaState>()),
            1
        )
        XCTAssertTrue(PersistenceStoreTopology.persistenceArtifactHistory(
            directory: directory
        ).hasExactCompleteStorePair(for: selection))
    }

    func testCloudStoreHistoryDetectionDoesNotTreatLocalOnlyStoreAsCloud() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TsumibenHistoryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let namespace = AccountDataNamespace()
        let localURL = PersistenceStoreTopology.localOnlyPersistentStoreURLs(
            namespace: namespace,
            directory: directory
        )[0]
        XCTAssertTrue(FileManager.default.createFile(
            atPath: localURL.path,
            contents: Data()
        ))
        let localHistory = PersistenceStoreTopology.persistenceArtifactHistory(
            directory: directory
        )
        XCTAssertEqual(
            localHistory.localOnly[namespace]?.hasSourceStore,
            true
        )
        XCTAssertEqual(
            localHistory.localOnly[namespace]?.hasProjectionStore,
            false
        )
        XCTAssertFalse(PersistenceStoreTopology.hasCloudStoreHistory(
            directory: directory
        ))

        let cloudURL = PersistenceStoreTopology.accountStoreURLs(
            accountNamespace: namespace,
            directory: directory
        )[0]
        XCTAssertTrue(FileManager.default.createFile(
            atPath: cloudURL.path,
            contents: Data()
        ))
        XCTAssertTrue(PersistenceStoreTopology.hasCloudStoreHistory(
            directory: directory
        ))
        let projectionURL = PersistenceStoreTopology.accountStoreURLs(
            accountNamespace: namespace,
            directory: directory
        )[1]
        XCTAssertTrue(FileManager.default.createFile(
            atPath: projectionURL.path,
            contents: Data()
        ))
        XCTAssertTrue(PersistenceStoreTopology.persistenceArtifactHistory(
            directory: directory
        ).cloud[namespace]?.hasCompleteStorePair == true)
    }

    func testArtifactScannerFailsClosedForSidecarOnlyUnknownAndSymlink() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TsumibenArtifactScanner-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let namespace = AccountDataNamespace()

        let sidecarDirectory = root.appendingPathComponent("sidecar")
        try FileManager.default.createDirectory(
            at: sidecarDirectory,
            withIntermediateDirectories: true
        )
        let sidecar = sidecarDirectory.appendingPathComponent(
            ".tumiben-local-projection-local-only-\(namespace.rawValue)-v1.json"
        )
        XCTAssertTrue(FileManager.default.createFile(
            atPath: sidecar.path,
            contents: Data("{}".utf8)
        ))
        let sidecarHistory = PersistenceStoreTopology
            .persistenceArtifactHistory(directory: sidecarDirectory)
        XCTAssertFalse(sidecarHistory.hasInvalidArtifact)
        XCTAssertEqual(
            sidecarHistory.localOnly[namespace]?.hasMigrationSidecar,
            true
        )
        XCTAssertEqual(PersistenceDeploymentState.validate(
            selectionState: .selected(.localOnly(namespace: namespace)),
            mountState: .unrecorded,
            artifactHistory: sidecarHistory,
            hasCloudRegistryHistory: false,
            hasCloudBindingHistory: false
        ), .recoveryRequired)

        let unknownDirectory = root.appendingPathComponent("unknown")
        try FileManager.default.createDirectory(
            at: unknownDirectory,
            withIntermediateDirectories: true
        )
        let unknown = unknownDirectory.appendingPathComponent(
            "TsumibenLocalOnly-\(namespace.rawValue).store-unrecognized"
        )
        XCTAssertTrue(FileManager.default.createFile(
            atPath: unknown.path,
            contents: Data()
        ))
        XCTAssertTrue(PersistenceStoreTopology.persistenceArtifactHistory(
            directory: unknownDirectory
        ).hasInvalidArtifact)

        let symlinkDirectory = root.appendingPathComponent("symlink")
        try FileManager.default.createDirectory(
            at: symlinkDirectory,
            withIntermediateDirectories: true
        )
        let unrelatedTarget = root.appendingPathComponent("target")
        XCTAssertTrue(FileManager.default.createFile(
            atPath: unrelatedTarget.path,
            contents: Data()
        ))
        let symlink = PersistenceStoreTopology.localOnlyPersistentStoreURLs(
            namespace: namespace,
            directory: symlinkDirectory
        )[0]
        try FileManager.default.createSymbolicLink(
            at: symlink,
            withDestinationURL: unrelatedTarget
        )
        XCTAssertTrue(PersistenceStoreTopology.persistenceArtifactHistory(
            directory: symlinkDirectory
        ).hasInvalidArtifact)

        let noncanonicalDirectory = root.appendingPathComponent("uppercase")
        try FileManager.default.createDirectory(
            at: noncanonicalDirectory,
            withIntermediateDirectories: true
        )
        let noncanonical = noncanonicalDirectory.appendingPathComponent(
            "TsumibenLocalOnly-\(namespace.rawValue.uppercased()).store"
        )
        XCTAssertTrue(FileManager.default.createFile(
            atPath: noncanonical.path,
            contents: Data()
        ))
        XCTAssertTrue(PersistenceStoreTopology.persistenceArtifactHistory(
            directory: noncanonicalDirectory
        ).hasInvalidArtifact)

        let legacyDirectory = root.appendingPathComponent("legacy")
        try FileManager.default.createDirectory(
            at: legacyDirectory,
            withIntermediateDirectories: true
        )
        let legacyStore = legacyDirectory.appendingPathComponent(
            "Tsumiben.store"
        )
        XCTAssertTrue(FileManager.default.createFile(
            atPath: legacyStore.path,
            contents: Data()
        ))
        XCTAssertTrue(PersistenceStoreTopology.persistenceArtifactHistory(
            directory: legacyDirectory
        ).hasInvalidArtifact)
    }

    func testAccountNamespacesIsolateStoreURLsDefaultsKeysAndWidgetFiles() throws {
        let namespaceA = try XCTUnwrap(AccountDataNamespace(
            rawValue: "50000000-0000-4000-8000-000000000005"
        ))
        let namespaceB = try XCTUnwrap(AccountDataNamespace(
            rawValue: "60000000-0000-4000-8000-000000000006"
        ))
        let directory = URL(fileURLWithPath: "/tmp/account-boundary-tests")
        let urlsA = PersistenceStoreTopology.accountStoreURLs(
            accountNamespace: namespaceA,
            directory: directory
        )
        let urlsB = PersistenceStoreTopology.accountStoreURLs(
            accountNamespace: namespaceB,
            directory: directory
        )

        XCTAssertEqual(urlsA.count, 2)
        XCTAssertEqual(urlsB.count, 2)
        XCTAssertTrue(Set(urlsA).isDisjoint(with: Set(urlsB)))
        XCTAssertTrue(urlsA.allSatisfy {
            $0.lastPathComponent.contains(namespaceA.rawValue)
        })
        XCTAssertNotEqual(
            AccountScopedLocalState.defaultsKey(
                base: "focus.persisted-engine",
                namespace: namespaceA
            ),
            AccountScopedLocalState.defaultsKey(
                base: "focus.persisted-engine",
                namespace: namespaceB
            )
        )
        XCTAssertNotEqual(
            AccountScopedLocalState.fileName(
                base: IntegrationConstants.widgetSnapshotMetadataFileName,
                namespace: namespaceA
            ),
            AccountScopedLocalState.fileName(
                base: IntegrationConstants.widgetSnapshotMetadataFileName,
                namespace: namespaceB
            )
        )
    }

    func testCloudLocalScopeHasNoLegacyFallbackBeforeVerification() throws {
        let suiteName = "AccountScopedLocalStateTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let namespace = try XCTUnwrap(AccountDataNamespace(
            rawValue: "70000000-0000-4000-8000-000000000007"
        ))
        let fingerprint = String(repeating: "7", count: 64)

        AccountScopedLocalState.beginCloudBoundary(
            standardDefaults: defaults,
            appGroupDefaults: nil
        )
        XCTAssertNotEqual(
            AccountScopedLocalState.defaultsKey(
                base: "focus.persisted-engine",
                defaults: defaults
            ),
            "focus.persisted-engine"
        )
        XCTAssertNil(AccountScopedLocalState.verifiedWidgetFileName(
            base: IntegrationConstants.widgetSnapshotMetadataFileName,
            defaults: defaults
        ))

        try AccountScopedLocalState.activate(
            try XCTUnwrap(ActiveAccountLocalBinding(
                namespace: namespace,
                accountFingerprint: fingerprint
            )),
            standardDefaults: defaults,
            appGroupDefaults: nil
        )
        XCTAssertNil(AccountScopedLocalState.verifiedWidgetFileName(
            base: IntegrationConstants.widgetSnapshotMetadataFileName,
            defaults: defaults
        ))
    }

    func testLocalOnlyNamespaceScopesDefaultsWithoutCloudBinding() throws {
        let suiteName = "AccountScopedLocalOnlyTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let namespace = AccountDataNamespace()

        AccountScopedLocalState.activateLocalOnly(
            namespace: namespace,
            standardDefaults: defaults,
            appGroupDefaults: nil
        )

        XCTAssertNil(AccountScopedLocalState.activeBinding(defaults: defaults))
        XCTAssertEqual(
            AccountScopedLocalState.activeNamespace(defaults: defaults),
            namespace
        )
        XCTAssertEqual(
            AccountScopedLocalState.defaultsKey(
                base: "focus.persisted-engine",
                defaults: defaults
            ),
            AccountScopedLocalState.defaultsKey(
                base: "focus.persisted-engine",
                namespace: namespace
            )
        )
        XCTAssertNil(AccountScopedLocalState.verifiedWidgetBinding(
            defaults: defaults
        ))
    }

    func testBeginningCloudBoundaryArchivesPreviousVerifiedBindingAcrossColdLaunch() throws {
        let suiteName = "AccountScopedBoundaryArchiveTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let binding = try XCTUnwrap(ActiveAccountLocalBinding(
            namespace: AccountDataNamespace(),
            accountFingerprint: String(repeating: "a", count: 64)
        ))
        try AccountScopedLocalState.activate(
            binding,
            standardDefaults: defaults,
            appGroupDefaults: nil
        )

        AccountScopedLocalState.beginCloudBoundary(
            standardDefaults: defaults,
            appGroupDefaults: nil
        )

        XCTAssertNil(AccountScopedLocalState.activeBinding(defaults: defaults))
        XCTAssertEqual(
            AccountScopedLocalState.pendingPreviousBinding(defaults: defaults),
            binding
        )
        AccountScopedLocalState.clearPendingPreviousBinding(defaults: defaults)
        XCTAssertNil(
            AccountScopedLocalState.pendingPreviousBinding(defaults: defaults)
        )
    }

    func testSchemaAssignmentsAreDisjointAndComplete() throws {
        let cloudNames = Set(PersistenceStoreTopology.cloudSchema.entities.map(\.name))
        let localNames = Set(PersistenceStoreTopology.localProjectionSchema.entities.map(\.name))
        let allNames = Set(PersistenceStoreTopology.shippingSchema.entities.map(\.name))

        XCTAssertEqual(cloudNames, [
            "Subject",
            "StudySession",
            "AchievementStone",
            "Prefs",
            "ActivityResetMarker",
            "SyncedFocusTimer",
            "FocusTimerDeviceClaim"
        ])
        XCTAssertEqual(localNames, [
            "AggregatePebble",
            "Stratum",
            "Bedrock",
            "GachaState"
        ])
        XCTAssertTrue(cloudNames.isDisjoint(with: localNames))
        XCTAssertEqual(cloudNames.union(localNames), allNames)

        for schema in [
            PersistenceStoreTopology.cloudSchema,
            PersistenceStoreTopology.localProjectionSchema
        ] {
            let names = Set(schema.entities.map(\.name))
            for entity in schema.entities {
                for relationship in entity.relationships {
                    XCTAssertTrue(
                        names.contains(relationship.destination),
                        "\(entity.name).\(relationship.name) crosses into \(relationship.destination)"
                    )
                }
            }
        }
        XCTAssertTrue(
            PersistenceStoreTopology.localProjectionSchema.entities
                .allSatisfy(\.relationships.isEmpty)
        )
    }

    func testVersionOneRareRewardGateUsesNormalSessionAndNoRawCloudBackend() {
        XCTAssertFalse(RareRewardReleasePolicy.isEnabled)
        XCTAssertEqual(RareRewardLedgerRuntime.backend, .disabledInMemory)

        let sessionID = UUID()
        let epochID = UUID()
        let subjectID = UUID()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let completion = PomodoroCompletion(
            sessionID: sessionID,
            startedAt: start,
            endedAt: start.addingTimeInterval(1_500),
            observedAt: start.addingTimeInterval(1_501),
            duration: .twentyFiveMinutes,
            seconds: 1_500,
            grams: 250,
            source: .timer
        )
        let session = FocusCompletionSessionFactory.normalSession(
            completion: completion,
            subject: nil,
            subjectSnapshot: FocusSubjectSnapshot(
                id: subjectID,
                name: "英語",
                colorHex: Constants.Color.english
            ),
            dataEpochID: epochID
        )

        XCTAssertEqual(session.id, sessionID)
        XCTAssertEqual(session.dataEpochID, epochID)
        XCTAssertEqual(session.pebbleKind, .normal)
        XCTAssertNil(session.rareRewardRuleVersion)
        XCTAssertNil(session.rareRewardParticipated)
        XCTAssertNil(session.rareRewardCreditedGrams)
        XCTAssertNil(session.rareRewardOutcomesRawValue)
        XCTAssertEqual(session.subjectIDSnapshot, subjectID)
        XCTAssertEqual(session.startAt, completion.startedAt)
        XCTAssertEqual(session.endAt, completion.endedAt)
        XCTAssertEqual(session.seconds, completion.seconds)
        XCTAssertEqual(session.grams, completion.grams)
        XCTAssertTrue(
            StudySessionIntegrityPolicy.isSupported(
                session,
                relativeTo: completion.observedAt
            )
        )
    }

#if DEBUG
    func testDebugDemoCompletionPersistsCanonicalReleaseSessionShape() {
        let sessionID = UUID()
        let subjectID = UUID()
        let endedAt = Date(timeIntervalSince1970: 1_800_001_500)
        let completion = PomodoroCompletion(
            sessionID: sessionID,
            startedAt: endedAt.addingTimeInterval(
                -TimeInterval(Constants.Timer.demoSeconds)
            ),
            endedAt: endedAt,
            observedAt: endedAt,
            duration: .demo,
            seconds: Constants.Timer.demoSeconds,
            grams: Constants.Mass.measuredPebbleGrams,
            source: .timer
        )

        let session = FocusCompletionSessionFactory.normalSession(
            completion: completion,
            subject: nil,
            subjectSnapshot: FocusSubjectSnapshot(
                id: subjectID,
                name: "UI test",
                colorHex: Constants.Color.english
            ),
            dataEpochID: nil
        )

        let canonicalSeconds = Constants.Timer.twentyFiveMinutes
            * Constants.Timer.secondsPerMinute
        XCTAssertEqual(session.id, sessionID)
        XCTAssertEqual(session.endAt, endedAt)
        XCTAssertEqual(
            session.startAt,
            endedAt.addingTimeInterval(-TimeInterval(canonicalSeconds))
        )
        XCTAssertEqual(session.seconds, canonicalSeconds)
        XCTAssertEqual(session.grams, Constants.Mass.measuredPebbleGrams)
        XCTAssertEqual(session.source, .timer)
        XCTAssertTrue(
            StudySessionIntegrityPolicy.isSupported(
                session,
                relativeTo: endedAt
            )
        )

        let malformedDemo = PomodoroCompletion(
            sessionID: UUID(),
            startedAt: endedAt.addingTimeInterval(-13),
            endedAt: endedAt,
            observedAt: endedAt,
            duration: .demo,
            seconds: 13,
            grams: Constants.Mass.measuredPebbleGrams,
            source: .timer
        )
        let rejectedShape = FocusCompletionSessionFactory.normalSession(
            completion: malformedDemo,
            subject: nil,
            subjectSnapshot: FocusSubjectSnapshot(
                id: subjectID,
                name: "UI test",
                colorHex: Constants.Color.english
            ),
            dataEpochID: nil
        )
        XCTAssertEqual(rejectedShape.seconds, 13)
        XCTAssertFalse(
            StudySessionIntegrityPolicy.isSupported(
                rejectedShape,
                relativeTo: endedAt
            )
        )
    }
#endif

    func testDeletionArtifactsContainBothStoresAndOnlyTheMigrationSidecar() throws {
        let stores = Set(try PersistenceStoreTopology.persistentStoreURLs(
            for: .persistentSimulator
        ))
        let artifacts = Set(try PersistenceStoreTopology.deletionArtifactURLs(
            for: .persistentSimulator
        ))

        XCTAssertEqual(stores.count, 2)
        XCTAssertTrue(stores.isSubset(of: artifacts))
        let migrationArtifacts = artifacts.subtracting(stores)
        XCTAssertEqual(migrationArtifacts.count, 2)
        XCTAssertTrue(migrationArtifacts.allSatisfy {
            $0.lastPathComponent.hasPrefix(".tumiben-local-projection-")
        })
        XCTAssertFalse(artifacts.contains { $0.lastPathComponent.contains("receipt") })
        XCTAssertFalse(artifacts.contains { $0.lastPathComponent.contains("journal") })
    }

    func testFreshSplitContainerPersistsBothStoresIndependently() throws {
        try withTemporaryStores { cloudURL, localURL, defaults, identifier in
            var container: ModelContainer? = try PersistenceStoreTopology
                .makeTestingSplitContainer(
                    cloudStoreURL: cloudURL,
                    localStoreURL: localURL,
                    defaults: defaults,
                    migrationIdentifier: identifier
                )
            let subjectID = UUID()
            let aggregateID = UUID()
            let context = try XCTUnwrap(container).mainContext
            context.insert(Subject(
                id: subjectID,
                name: "英語",
                colorHex: Constants.Color.english,
                sortOrder: 0
            ))
            context.insert(AggregatePebble(
                id: aggregateID,
                level: 1,
                pebbleCount: 1,
                grams: 250,
                colorMixJSON: "[]",
                periodStart: .now,
                periodEnd: .now
            ))
            try context.save()
            container = nil

            let reopened = try PersistenceStoreTopology.makeTestingSplitContainer(
                cloudStoreURL: cloudURL,
                localStoreURL: localURL,
                defaults: defaults,
                migrationIdentifier: identifier
            )
            XCTAssertEqual(
                try reopened.mainContext.fetch(FetchDescriptor<Subject>()).map(\.id),
                [subjectID]
            )
            XCTAssertEqual(
                try reopened.mainContext.fetch(FetchDescriptor<AggregatePebble>()).map(\.id),
                [aggregateID]
            )
            XCTAssertEqual(reopened.configurations.count, 2)
            XCTAssertEqual(Set(reopened.configurations.map(\.url)), [cloudURL, localURL])
        }
    }

    func testInMemoryPreviewContainerUsesTheShippingSchema() throws {
        let container = try PersistenceStoreTopology.makeContainer(
            for: .inMemoryPreview
        )
        container.mainContext.insert(Subject(
            name: "Preview",
            colorHex: Constants.Color.english,
            sortOrder: 0
        ))
        container.mainContext.insert(GachaState())
        try container.mainContext.save()

        XCTAssertEqual(
            try container.mainContext.fetch(FetchDescriptor<Subject>()).count,
            1
        )
        XCTAssertEqual(
            try container.mainContext.fetch(FetchDescriptor<GachaState>()).count,
            1
        )
    }

    func testMonolithicStoreMigratesProjectionWithoutLosingCloudRowsAndReopensIdempotently() throws {
        try withTemporaryStores { cloudURL, localURL, defaults, identifier in
            let subjectID = UUID()
            let sessionID = UUID()
            let aggregateID = UUID()
            let stratumID = UUID()
            let gachaID = UUID()
            let instant = Date(timeIntervalSince1970: 1_800_000_000)

            var legacy: ModelContainer? = try ModelContainer(
                for: PersistenceStoreTopology.shippingSchema,
                configurations: [ModelConfiguration(
                    "LegacyMonolithicTest",
                    schema: PersistenceStoreTopology.shippingSchema,
                    url: cloudURL,
                    cloudKitDatabase: .none
                )]
            )
            let legacyContext = try XCTUnwrap(legacy).mainContext
            let subject = Subject(
                id: subjectID,
                name: "数学",
                colorHex: Constants.Color.mathematics,
                sortOrder: 0
            )
            legacyContext.insert(subject)
            legacyContext.insert(StudySession(
                id: sessionID,
                subject: subject,
                startAt: instant.addingTimeInterval(-1_500),
                endAt: instant,
                seconds: 1_500,
                source: .timer,
                grams: 250,
                deviceDayKey: "migration",
                isBaked: true
            ))
            legacyContext.insert(AggregatePebble(
                id: aggregateID,
                createdAt: instant,
                level: 1,
                pebbleCount: 1,
                grams: 250,
                measuredPebbleCount: 1,
                colorMixJSON: "[]",
                periodStart: instant,
                periodEnd: instant,
                sessionIDs: [sessionID]
            ))
            legacyContext.insert(Stratum(
                id: stratumID,
                bakedAt: instant,
                pebbleCount: 1,
                heightPt: 10,
                colorMixJSON: "[]",
                monthLabel: "移行",
                grams: 250,
                sessionIDs: [sessionID]
            ))
            legacyContext.insert(Bedrock(hours: 40, importedAt: instant))
            legacyContext.insert(GachaState(
                id: gachaID,
                sinceLastGold: 7,
                rewardCreditGrams: 500
            ))
            try legacyContext.save()
            legacy = nil

            var split: ModelContainer? = try PersistenceStoreTopology
                .makeTestingSplitContainer(
                    cloudStoreURL: cloudURL,
                    localStoreURL: localURL,
                    defaults: defaults,
                    migrationIdentifier: identifier
                )
            try assertMigratedRows(
                in: XCTUnwrap(split),
                subjectID: subjectID,
                sessionID: sessionID,
                aggregateID: aggregateID,
                stratumID: stratumID,
                gachaID: gachaID
            )
            split = nil

            let reopened = try PersistenceStoreTopology.makeTestingSplitContainer(
                cloudStoreURL: cloudURL,
                localStoreURL: localURL,
                defaults: defaults,
                migrationIdentifier: identifier
            )
            try assertMigratedRows(
                in: reopened,
                subjectID: subjectID,
                sessionID: sessionID,
                aggregateID: aggregateID,
                stratumID: stratumID,
                gachaID: gachaID
            )
        }
    }

    func testCloudRepairRemainsDurableWhenLocalProjectionSaveFailsThenRetries() throws {
        try withTemporaryStores { cloudURL, localURL, _, _ in
            // Materialize an empty local SQLite store before reopening it as
            // read-only. This gives the test a deterministic local-store save
            // failure without making the cloud configuration read-only.
            do {
                let setup = try makeDirectSplitContainer(
                    cloudURL: cloudURL,
                    localURL: localURL,
                    localAllowsSave: true
                )
                let temporary = GachaState()
                setup.mainContext.insert(temporary)
                try setup.mainContext.save()
                setup.mainContext.delete(temporary)
                try setup.mainContext.save()
            }

            do {
                let readOnlyLocal = try makeDirectSplitContainer(
                    cloudURL: cloudURL,
                    localURL: localURL,
                    localAllowsSave: false
                )
                XCTAssertThrowsError(
                    try SeedData.bootstrap(context: readOnlyLocal.mainContext)
                )
                readOnlyLocal.mainContext.rollback()

                // The first, cloud-only phase committed before the disposable
                // local phase failed. There is no half-created local cache.
                XCTAssertEqual(
                    try readOnlyLocal.mainContext.fetch(FetchDescriptor<Prefs>()).count,
                    1
                )
                XCTAssertEqual(
                    try readOnlyLocal.mainContext.fetch(FetchDescriptor<Subject>()).count,
                    SeedData.subjects.count
                )
            }

            // SwiftData can keep an unsaved inserted object registered in the
            // failed context even after rollback. Reopening the physical local
            // store proves that no row crossed the read-only boundary.
            do {
                let localVerification = try ModelContainer(
                    for: PersistenceStoreTopology.localProjectionSchema,
                    configurations: [ModelConfiguration(
                        "TopologyFailureLocalVerification",
                        schema: PersistenceStoreTopology.localProjectionSchema,
                        url: localURL,
                        cloudKitDatabase: .none
                    )]
                )
                XCTAssertTrue(
                    try localVerification.mainContext
                        .fetch(FetchDescriptor<GachaState>()).isEmpty
                )
            }

            let retried = try makeDirectSplitContainer(
                cloudURL: cloudURL,
                localURL: localURL,
                localAllowsSave: true
            )
            try SeedData.bootstrap(context: retried.mainContext)
            XCTAssertEqual(
                try retried.mainContext.fetch(FetchDescriptor<Prefs>()).count,
                1
            )
            XCTAssertEqual(
                try retried.mainContext.fetch(FetchDescriptor<Subject>()).count,
                SeedData.subjects.count
            )
            XCTAssertEqual(
                try retried.mainContext.fetch(FetchDescriptor<GachaState>()).count,
                1
            )
        }
    }

    private func assertMigratedRows(
        in container: ModelContainer,
        subjectID: UUID,
        sessionID: UUID,
        aggregateID: UUID,
        stratumID: UUID,
        gachaID: UUID
    ) throws {
        let context = container.mainContext
        XCTAssertEqual(try context.fetch(FetchDescriptor<Subject>()).map(\.id), [subjectID])
        XCTAssertEqual(try context.fetch(FetchDescriptor<StudySession>()).map(\.id), [sessionID])
        XCTAssertEqual(
            try context.fetch(FetchDescriptor<AggregatePebble>()).map(\.id),
            [aggregateID]
        )
        XCTAssertEqual(
            try context.fetch(FetchDescriptor<AggregatePebble>())
                .map(\.projectionValidationVersion),
            [0]
        )
        XCTAssertEqual(try context.fetch(FetchDescriptor<Stratum>()).map(\.id), [stratumID])
        XCTAssertEqual(try context.fetch(FetchDescriptor<Bedrock>()).map(\.hours), [40])
        XCTAssertEqual(try context.fetch(FetchDescriptor<GachaState>()).map(\.id), [gachaID])
    }

    private func withTemporaryStores(
        _ body: (
            _ cloudURL: URL,
            _ localURL: URL,
            _ defaults: UserDefaults,
            _ identifier: String
        ) throws -> Void
    ) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PersistenceStoreTopologyTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let suiteName = "PersistenceStoreTopologyTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        try body(
            directory.appendingPathComponent("Cloud.store"),
            directory.appendingPathComponent("Local.store"),
            defaults,
            UUID().uuidString
        )
    }

    private func makeDirectSplitContainer(
        cloudURL: URL,
        localURL: URL,
        localAllowsSave: Bool
    ) throws -> ModelContainer {
        try ModelContainer(
            for: PersistenceStoreTopology.shippingSchema,
            configurations: [
                ModelConfiguration(
                    "TopologyFailureCloud",
                    schema: PersistenceStoreTopology.cloudSchema,
                    url: cloudURL,
                    cloudKitDatabase: .none
                ),
                ModelConfiguration(
                    "TopologyFailureLocal",
                    schema: PersistenceStoreTopology.localProjectionSchema,
                    url: localURL,
                    allowsSave: localAllowsSave,
                    cloudKitDatabase: .none
                )
            ]
        )
    }
}
