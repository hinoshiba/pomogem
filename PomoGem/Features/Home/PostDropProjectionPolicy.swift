import Foundation

/// sync-03 (owner-approved, 2026-09-24). Which projection the post-focus
/// reward card may show in iCloud mode.
///
/// The card's receipt freezes the totals the app computed from this device's
/// records at completion. In iCloud mode the app's own session save always
/// revoked presentation trust, so before this the receipt could never be
/// published again: iCloud users never saw the weekly total or the progress
/// of the focus they had just finished — only 「生涯合計は確認後に表示します」.
///
/// Now the card shows:
/// - `.receipt`: the frozen values, exactly as before, whenever the receipt
///   was frozen under the projection that is still current (and always for
///   local-only storage);
/// - `.receiptWhileVerifying`: the same frozen, device-confirmed values with
///   an 「iCloudを確認中」 caption while iCloud verification is pending;
/// - `.verifiedProjection`: once verification has completed after the receipt
///   froze, values re-derived from the verified projection — the offer is
///   re-stamped rather than left unpublishable.
/// Nothing is written, exported or shared from the values shown while
/// verifying; the share chip still waits for `allowsAggregateSummaries`.
enum PostDropProjectionPolicy {
    enum Source: Equatable, Sendable {
        case receipt
        case receiptWhileVerifying
        case verifiedProjection
    }

    static func source(
        usesCloudPersistence: Bool,
        isVerificationPending: Bool,
        receiptWasCloudUnverified: Bool,
        receiptStampIsCurrentVerified: Bool,
        verifiedProjectionIsLoaded: Bool
    ) -> Source {
        guard usesCloudPersistence else { return .receipt }
        if isVerificationPending { return .receiptWhileVerifying }
        if !receiptWasCloudUnverified, receiptStampIsCurrentVerified { return .receipt }
        // Verified, but its page has not been read yet: keep the caption for
        // the moment it takes rather than show a total that is still empty.
        return verifiedProjectionIsLoaded ? .verifiedProjection : .receiptWhileVerifying
    }
}
