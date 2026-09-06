import Foundation

/// Stores deletion recovery state outside UserDefaults and SwiftData so both
/// stores can be erased without losing the ability to resume after a crash.
actor CompleteDataDeletionFileStateStore: CompleteDataDeletionStateStoring {
    static let directoryName = "CompleteDataDeletion"
    static let pendingFilename = "pending-v1.json"
    static let receiptFilename = "generation-receipt-v1.json"

    private let directoryURL: URL

    init(directoryURL: URL) {
        self.directoryURL = directoryURL.standardizedFileURL
    }

    static func live(fileManager: FileManager = .default) throws -> Self {
        guard let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw CocoaError(.fileNoSuchFile)
        }
        return Self(directoryURL: applicationSupport.appendingPathComponent(
            directoryName,
            isDirectory: true
        ))
    }

    func loadPendingMarker() throws -> CompleteDataDeletionPendingMarker? {
        try decodeIfPresent(
            CompleteDataDeletionPendingMarker.self,
            from: pendingURL
        )
    }

    func savePendingMarker(
        _ marker: CompleteDataDeletionPendingMarker
    ) throws {
        try encodeAtomically(marker, to: pendingURL)
    }

    func removePendingMarker() throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: pendingURL.path) else { return }
        try fileManager.removeItem(at: pendingURL)
    }

    func loadGenerationReceipt() throws -> CompleteDataDeletionGenerationReceipt? {
        let receipt = try decodeIfPresent(
            CompleteDataDeletionGenerationReceipt.self,
            from: receiptURL
        )
        guard let receipt else { return nil }
        guard receipt.formatVersion == CompleteDataDeletionGenerationReceipt.formatVersion,
              receipt.sequence >= 0
        else {
            throw CompleteDataDeletionError.invalidState(
                "未対応または不正なgeneration receiptです"
            )
        }
        return receipt
    }

    func saveGenerationReceipt(
        _ receipt: CompleteDataDeletionGenerationReceipt
    ) throws {
        try encodeAtomically(receipt, to: receiptURL)
    }

    private var pendingURL: URL {
        directoryURL.appendingPathComponent(Self.pendingFilename, isDirectory: false)
    }

    private var receiptURL: URL {
        directoryURL.appendingPathComponent(Self.receiptFilename, isDirectory: false)
    }

    private func decodeIfPresent<Value: Decodable>(
        _ type: Value.Type,
        from url: URL
    ) throws -> Value? {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }

    private func encodeAtomically<Value: Encodable>(
        _ value: Value,
        to url: URL
    ) throws {
        let fileManager = FileManager.default
        let protection = FileProtectionType.completeUntilFirstUserAuthentication
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: protection]
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        try data.write(to: url, options: .atomic)
        try fileManager.setAttributes(
            [.protectionKey: protection],
            ofItemAtPath: url.path
        )
    }
}
