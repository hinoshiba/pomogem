import SwiftData
import XCTest
@testable import PomoGem

/// Configuration checks and isolated disk fixtures. These never open or modify
/// the application's default stores, or construct a CloudKit transport.
@MainActor
final class CloudOfflineStoreTopologyTests: XCTestCase {
    func testOfflineConfigurationsKeepTheExactPriorCloudURLsAndNames() throws {
        let namespace = AccountDataNamespace()
        let expectedURLs = PersistenceStoreTopology.shippingPersistentStoreURLs(accountNamespace: namespace)
        let offline = PersistenceStoreTopology.offlineCloudConfigurations(accountNamespace: namespace)
        XCTAssertEqual(offline.count, 2)
        XCTAssertEqual(offline.map(\.url), expectedURLs)
        XCTAssertEqual(offline.map(\.name), ["PomoGem", "PomoGemLocalProjection"])
        XCTAssertEqual(offline.map(\.url.lastPathComponent), [
            "PomoGem-\(namespace.rawValue).store",
            "PomoGemLocalProjection-\(namespace.rawValue).store"
        ])
        XCTAssertEqual(PersistenceStoreTopology.offlineCloudConfigurations(accountNamespace: namespace).map(\.url),
            expectedURLs, "Reentry cannot invent a new namespace")
        XCTAssertTrue(Set(offline.map(\.url)).isDisjoint(with:
            Set(PersistenceStoreTopology.localOnlyPersistentStoreURLs(namespace: namespace))),
            "Offline cloud access must never select the separate local-only dataset")
        let anotherNamespace = AccountDataNamespace()
        XCTAssertTrue(Set(offline.map(\.url)).isDisjoint(with:
            Set(PersistenceStoreTopology.offlineCloudConfigurations(accountNamespace: anotherNamespace).map(\.url))))
    }

    func testOfflineConfigurationsKeepSevenSourceAndFourProjectionModelsWithCloudDisabled() throws {
        let namespace = AccountDataNamespace()
        let configurations = PersistenceStoreTopology.offlineCloudConfigurations(accountNamespace: namespace)
        let source = try XCTUnwrap(configurations.first)
        let projection = try XCTUnwrap(configurations.last)
        let sourceSchema = try XCTUnwrap(source.schema)
        let projectionSchema = try XCTUnwrap(projection.schema)
        let sourceNames = Set(sourceSchema.entities.map(\.name))
        let projectionNames = Set(projectionSchema.entities.map(\.name))
        XCTAssertEqual(sourceNames, Set([
            "Subject", "StudySession", "AchievementStone", "Prefs", "ActivityResetMarker",
            "SyncedFocusTimer", "FocusTimerDeviceClaim"
        ]))
        XCTAssertEqual(projectionNames, Set(["AggregatePebble", "Stratum", "Bedrock", "GachaState"]))
        XCTAssertTrue(sourceNames.isDisjoint(with: projectionNames))
        XCTAssertEqual(sourceNames.union(projectionNames),
            Set(PersistenceStoreTopology.shippingSchema.entities.map(\.name)))
        for configuration in configurations {
            XCTAssertNil(configuration.cloudKitContainerIdentifier)
            XCTAssertFalse(configuration.isStoredInMemoryOnly)
            XCTAssertTrue(configuration.allowsSave)
            // ModelConfiguration exposes Hashable, while its CloudKitDatabase
            // value intentionally has no public equality/introspection API.
            // Compare against an explicit .none configuration using this same
            // schema object, in addition to the effective container check.
            XCTAssertEqual(configuration, ModelConfiguration(configuration.name,
                schema: configuration.schema, url: configuration.url, cloudKitDatabase: .none))
        }
    }

    func testReadOnlyConfigurationsUseTheExactShippingFilesAndPreventSavesInBothSchemas() throws {
        let namespace = AccountDataNamespace()
        let configurations = PersistenceStoreTopology.readOnlyCloudConfigurations(accountNamespace: namespace)
        XCTAssertEqual(configurations.map(\.url),
            PersistenceStoreTopology.shippingPersistentStoreURLs(accountNamespace: namespace))
        XCTAssertEqual(configurations.map(\.name), ["PomoGem", "PomoGemLocalProjection"])
        XCTAssertEqual(configurations.map { $0.schema?.entities.count }, [7, 4])
        for configuration in configurations {
            XCTAssertFalse(configuration.allowsSave)
            XCTAssertNil(configuration.cloudKitContainerIdentifier)
            XCTAssertFalse(configuration.isStoredInMemoryOnly)
            XCTAssertEqual(configuration, ModelConfiguration(configuration.name, schema: configuration.schema,
                url: configuration.url, allowsSave: false, cloudKitDatabase: .none))
        }
    }

    func testActualReadOnlyReaderFindsLatestMarkerAndRejectsSourceAndProjectionChanges() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ReadOnlyHistory-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let namespace = AccountDataNamespace()
        let lifetimes = PersistenceContainerLifetimeTracker<ModelContainer>()
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let marker = ActivityResetSnapshot(id: UUID(), epochID: UUID(), sequence: 4,
            resetAt: date, writerDeviceID: "read-only-fixture")
        let initial = try autoreleasepool {
            let configurations = PersistenceStoreTopology.readOnlyCloudConfigurations(
                accountNamespace: namespace, directory: directory).map {
                    ModelConfiguration($0.name, schema: $0.schema, url: $0.url,
                        allowsSave: true, cloudKitDatabase: .none)
                }
            let container = try ModelContainer(for: PersistenceStoreTopology.shippingSchema, configurations: configurations)
            lifetimes.track(container)
            let context = container.mainContext
            context.autosaveEnabled = false
            let subject = Subject(name: "original subject", colorHex: "#abcdef", sortOrder: 0)
            context.insert(subject)
            context.insert(StudySession(subject: subject, startAt: date, endAt: date, seconds: 1_800,
                source: .manual, deviceDayKey: "fixture-day", dataEpochID: marker.epochID))
            context.insert(ActivityResetMarker(sequence: 1, resetAt: date, writerDeviceID: "older-fixture"))
            context.insert(ActivityResetMarker(id: marker.id, epochID: marker.epochID, sequence: marker.sequence,
                resetAt: marker.resetAt, writerDeviceID: marker.writerDeviceID))
            context.insert(AggregatePebble(level: 2, pebbleCount: 1, grams: 300,
                colorMixJSON: "[]", periodStart: date, periodEnd: date))
            try context.save()
            return try PomoGemStorageSnapshot.capture(from: context)
        }
        try lifetimes.requireAllReleased()
        try autoreleasepool {
            let container = try PersistenceStoreTopology.makeReadOnlyCloudContainer(
                accountNamespace: namespace, directory: directory)
            lifetimes.track(container)
            XCTAssertFalse(container.mainContext.autosaveEnabled)
            let context = ModelContext(container)
            context.autosaveEnabled = false
            XCTAssertEqual(try ActivityResetStore.latestSnapshot(context: context), marker)
            let snapshot = try PomoGemStorageSnapshot.capture(from: context)
            XCTAssertTrue(try snapshot.isEquivalent(to: initial))
            let subject = try XCTUnwrap(context.fetch(FetchDescriptor<Subject>()).first)
            subject.name = "must never reach the original store"
            XCTAssertThrowsError(try context.save())
            context.rollback()
            let projection = try XCTUnwrap(context.fetch(FetchDescriptor<AggregatePebble>()).first)
            projection.grams = 99_999
            XCTAssertThrowsError(try context.save())
            context.rollback()
        }
        try lifetimes.requireAllReleased()
        try autoreleasepool {
            let container = try PersistenceStoreTopology.makeReadOnlyCloudContainer(
                accountNamespace: namespace, directory: directory)
            lifetimes.track(container)
            let reader = ModelContext(container)
            reader.autosaveEnabled = false
            XCTAssertTrue(try PomoGemStorageSnapshot.capture(from: reader).isEquivalent(to: initial))
            XCTAssertEqual(try ActivityResetStore.latestSnapshot(context: reader), marker)
            XCTAssertEqual(try reader.fetchCount(FetchDescriptor<StudySession>()), 1)
        }
        try lifetimes.requireAllReleased()
    }
}
