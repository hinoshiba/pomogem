import LinkPresentation
import UniformTypeIdentifiers
import UIKit

/// Supplies a GIF file lazily to the system share sheet while keeping a rich,
/// privacy-safe preview header. The actual caption is a separate activity item
/// because each receiving app decides whether it accepts accompanying text.
final class AnimatedGIFActivityItemSource: NSObject, UIActivityItemSource {
    private let url: URL
    private let previewImage: UIImage
    private let title: String

    init(url: URL, previewImage: UIImage, title: String) {
        self.url = url
        self.previewImage = previewImage
        self.title = title
    }

    func activityViewControllerPlaceholderItem(
        _ activityViewController: UIActivityViewController
    ) -> Any {
        url
    }

    func activityViewController(
        _ activityViewController: UIActivityViewController,
        itemForActivityType activityType: UIActivity.ActivityType?
    ) -> Any? {
        url
    }

    func activityViewController(
        _ activityViewController: UIActivityViewController,
        dataTypeIdentifierForActivityType activityType: UIActivity.ActivityType?
    ) -> String {
        UTType.gif.identifier
    }

    func activityViewControllerLinkMetadata(
        _ activityViewController: UIActivityViewController
    ) -> LPLinkMetadata? {
        let metadata = LPLinkMetadata()
        metadata.title = title
        metadata.imageProvider = NSItemProvider(object: previewImage)
        return metadata
    }
}
