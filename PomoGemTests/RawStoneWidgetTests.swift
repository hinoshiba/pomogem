import SwiftUI
import XCTest
@testable import PomoGem

/// D19 (Docs/GemExperienceDesign.md §8.7): the home-screen widget shows a
/// still, colourless raw stone with no account data and opens the start
/// screen. The widget extension stays data-free: no App Group, no stored
/// snapshot, no store — only two small shared sources.
@MainActor
final class RawStoneWidgetTests: XCTestCase {
    private var projectRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    // MARK: The stone

    func testRawStoneIsARoughCrystalLitFromTheUpperLeft() {
        let stone = RawStoneGeometry.standard
        XCTAssertEqual(stone, RawStoneGeometry(), "The same picture every time")
        XCTAssertEqual(stone.facets.count, 16)
        XCTAssertTrue(stone.facets.allSatisfy { $0.points.count == 3 })
        let corners = stone.facets.flatMap(\.points) + stone.outline
        XCTAssertTrue(corners.allSatisfy { ($0.x * $0.x + $0.y * $0.y).squareRoot() <= 1.0001 })

        // One solid: a convex girdle that the faces tile exactly.
        XCTAssertEqual(stone.outline.count, 10)
        XCTAssertEqual(Set(RawStoneGeometry.convexHull(stone.outline).map { "\($0)" }), Set(stone.outline.map { "\($0)" }))
        let faceArea = stone.facets.reduce(0) { $0 + RawStoneGeometry.area($1.points) }
        let girdle = RawStoneGeometry.area(stone.outline)
        XCTAssertEqual(faceArea, girdle, accuracy: girdle * 0.001, "No hole, no overlap")
        XCTAssertGreaterThan(girdle, 2.4, "A full stone (a unit disc is π)")

        // Rough, not a regular solid (no die, no medal): an uneven girdle
        // and faces of many sizes.
        let radii = stone.outline.map { ($0.x * $0.x + $0.y * $0.y).squareRoot() }
        XCTAssertGreaterThan((radii.max() ?? 0) - (radii.min() ?? 0), 0.05)
        let areas = stone.facets.map { RawStoneGeometry.area($0.points) }
        XCTAssertGreaterThan((areas.max() ?? 0) / max(areas.min() ?? 1, 0.0001), 1.5)

        // Lit once from the upper left (the widget never rolls).
        XCTAssertTrue(stone.facets.allSatisfy { (0 ... 1).contains($0.shade) })
        let brightest = stone.facets.max { $0.shade < $1.shade }!
        let centre = brightest.points.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x / 3, y: $0.y + $1.y / 3) }
        XCTAssertLessThan(centre.x, 0)
        XCTAssertGreaterThan(centre.y, 0)
        let darkest = stone.facets.min { $0.shade < $1.shade }!
        let darkCentre = darkest.points.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x / 3, y: $0.y + $1.y / 3) }
        XCTAssertGreaterThan(darkCentre.x - darkCentre.y, 0, "The shade falls to the lower right")
        let shades = stone.facets.map(\.shade)
        XCTAssertGreaterThan((shades.max() ?? 0) - (shades.min() ?? 0), 0.4, "Facets read as light and shade")
        XCTAssertLessThan(stone.sparkle.x, 0)
        XCTAssertGreaterThan(stone.sparkle.y, 0)
        XCTAssertGreaterThan(stone.secondarySparkle.x, 0)
        XCTAssertGreaterThan(stone.secondarySparkle.y, 0)
    }

    /// Colourless: no theme colour enters the stone (ice white facets), and
    /// on its plate the picture is fully opaque (no wallpaper shows through).
    func testRawStoneArtworkIsColourlessAndItsPlateIsOpaque() throws {
        func render(plate: Bool) throws -> (pixels: [UInt8], width: Int, height: Int) {
            let renderer = ImageRenderer(content: RawStoneArtwork(showsPlate: plate).frame(width: 120, height: 120))
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.cgImage)
            var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
            let context = try XCTUnwrap(CGContext(
                data: &data,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: image.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return (data, image.width, image.height)
        }

        let bare = try render(plate: false)
        var drawn = 0
        var saturationSum: CGFloat = 0
        for index in stride(from: 0, to: bare.pixels.count, by: 4) {
            let alpha = CGFloat(bare.pixels[index + 3]) / 255
            guard alpha > 0.35 else { continue }
            let red = CGFloat(bare.pixels[index]) / 255 / alpha
            let green = CGFloat(bare.pixels[index + 1]) / 255 / alpha
            let blue = CGFloat(bare.pixels[index + 2]) / 255 / alpha
            let maximum = max(red, green, blue)
            let minimum = min(red, green, blue)
            saturationSum += maximum > 0 ? (maximum - minimum) / maximum : 0
            drawn += 1
        }
        XCTAssertGreaterThan(drawn, 2_000, "The stone is drawn")
        XCTAssertLessThan(saturationSum / CGFloat(max(drawn, 1)), 0.16, "Ice white, no theme colour")

        let plated = try render(plate: true)
        let centre = ((plated.height / 2) * plated.width + plated.width / 2) * 4
        XCTAssertEqual(plated.pixels[centre + 3], 255, "Opaque where the stone is")
        let nearCorner = ((plated.height / 5) * plated.width + plated.width / 5) * 4
        XCTAssertEqual(plated.pixels[nearCorner + 3], 255, "Opaque plate behind it")
        XCTAssertLessThan(plated.pixels[nearCorner + 2], 90, "Deep navy")
    }

    // MARK: The link

    func testStartLinkOnlyShowsHome() {
        XCTAssertEqual(StartFocusLink.url.absoluteString, "pomogem://start")
        XCTAssertEqual(AppLinks.startFocus, StartFocusLink.url)
        XCTAssertTrue(StartFocusLink.matches(URL(string: "POMOGEM://Start")!))
        XCTAssertFalse(StartFocusLink.matches(URL(string: "pomogem://settings")!))
        XCTAssertFalse(StartFocusLink.matches(URL(string: "https://pomogem.hinoshiba.com/start")!))

        let router = AppRouter()
        router.selectedTab = .settings
        XCTAssertFalse(router.openStartLink(URL(string: "pomogem://other")!))
        XCTAssertEqual(router.selectedTab, .settings)
        XCTAssertTrue(router.openStartLink(StartFocusLink.url))
        XCTAssertEqual(router.selectedTab, .jar, "Home, where the focus button is")
        XCTAssertFalse(router.focusPresentationIsActive, "Nothing starts")
        XCTAssertFalse(router.sharePresented)
        XCTAssertFalse(router.paywallPresented)

        // The scheme the link uses is the one the app registers.
        let schemes = (Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]] ?? [])
            .flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
        XCTAssertTrue(schemes.contains("pomogem"))
    }

    // MARK: The privacy boundary

    func testWidgetExtensionStaysDataFree() throws {
        let widgetDirectory = projectRoot.appendingPathComponent("PomoGemWidgets")
        let entitlements = try XCTUnwrap(
            NSDictionary(contentsOf: widgetDirectory.appendingPathComponent("PomoGemWidgets.entitlements"))
        )
        XCTAssertEqual(entitlements.count, 0, "No App Group, no iCloud: the widget can read nothing")

        let homeWidget = try String(contentsOf: widgetDirectory.appendingPathComponent("JarWidgets.swift"), encoding: .utf8)
        for forbidden in ["UserDefaults(suiteName", "containerURL", "WidgetSnapshot", "ModelContainer", "group.com.hinoshiba", "FileManager"] {
            XCTAssertFalse(homeWidget.contains(forbidden), "The home widget never reads \(forbidden)")
        }
        XCTAssertTrue(homeWidget.contains("RawStoneArtwork("))
        XCTAssertTrue(homeWidget.contains(".widgetURL(StartFocusLink.url)"))
        XCTAssertTrue(homeWidget.contains(".supportedFamilies([.systemSmall, .systemMedium])"))

        // main's duration formatting (Docs/Localization.md) is compiled
        // into the widget too, so it is held to the same boundary.
        for shared in ["RawStoneArtwork.swift", "StartFocusLink.swift", "LocalizedDuration.swift"] {
            let source = try String(contentsOf: projectRoot.appendingPathComponent("Shared/\(shared)"), encoding: .utf8)
            for forbidden in ["UserDefaults", "FileManager", "import UIKit", "import SpriteKit", "import SwiftData", "CloudKit"] {
                XCTAssertFalse(source.contains(forbidden), "\(shared) stays free of \(forbidden)")
            }
        }

        // project.yml (the source of truth) gives the widget exactly these
        // shared sources.
        let project = try String(contentsOf: projectRoot.appendingPathComponent("project.yml"), encoding: .utf8)
        let widgetTarget = try XCTUnwrap(project.components(separatedBy: "\n  PomoGemWidgets:\n").last?
            .components(separatedBy: "\n  PomoGemScreenTimeMonitor:\n").first)
        let sharedSources = widgetTarget.components(separatedBy: "\n")
            .filter { $0.contains("- path: Shared/") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
        XCTAssertEqual(sharedSources, [
            "- path: Shared/FocusActivityAttributes.swift",
            "- path: Shared/LocalizedDuration.swift",
            "- path: Shared/RawStoneArtwork.swift",
            "- path: Shared/StartFocusLink.swift"
        ])
        XCTAssertFalse(widgetTarget.contains("entitlements:\n      properties"), "No entitlement properties for the widget")
    }
}
