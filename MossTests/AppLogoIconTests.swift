import UIKit
import XCTest
@testable import AppUnderTest

/// `AppLogoIcon` is the logo on sign-in, sign-up and the paywall. It must look
/// like the app icon (`Moss.icon`): the icon's background gradient behind the
/// moss ball, with the icon's dark gradient in dark mode.
final class AppLogoIconTests: XCTestCase {
    private let side = 64

    func testLightLogoHasTheAppIconLightBackgroundBehindTheBall() throws {
        let pixels = try render(.light)
        assertColor(pixels.at(x: 1, y: 1), near: (0xF8, 0xF1, 0xD4), "top of the light gradient")
        assertColor(pixels.at(x: 1, y: side - 2), near: (0xBF, 0xD8, 0xAF), "bottom of the light gradient")
        assertColor(pixels.at(x: side / 2, y: side * 5 / 8), near: (0x2F, 0x69, 0x3C), "moss ball")
    }

    func testDarkLogoHasTheAppIconDarkBackgroundBehindTheBall() throws {
        let pixels = try render(.dark)
        assertColor(pixels.at(x: 1, y: 1), near: (0x04, 0x13, 0x0F), "top of the dark gradient")
        assertColor(pixels.at(x: 1, y: side - 2), near: (0x11, 0x2A, 0x1C), "bottom of the dark gradient")
        assertColor(pixels.at(x: side / 2, y: side * 5 / 8), near: (0x2F, 0x69, 0x3C), "moss ball")
    }

    // MARK: - Helpers

    private struct Pixels {
        let bytes: [UInt8]
        let width: Int

        func at(x: Int, y: Int) -> (r: Int, g: Int, b: Int, a: Int) {
            let i = (y * width + x) * 4
            return (Int(bytes[i]), Int(bytes[i + 1]), Int(bytes[i + 2]), Int(bytes[i + 3]))
        }
    }

    private func render(_ style: UIUserInterfaceStyle) throws -> Pixels {
        let traits = UITraitCollection(userInterfaceStyle: style)
        let image = try XCTUnwrap(
            UIImage(named: "AppLogoIcon", in: Bundle(for: AppServices.self), compatibleWith: traits),
            "AppLogoIcon is missing from the app's asset catalog"
        )
        var bytes = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: side,
                height: side,
                bitsPerComponent: 8,
                bytesPerRow: side * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            UIGraphicsPushContext(context)
            // UIKit draws top-down; flip the bitmap context to match.
            context.translateBy(x: 0, y: CGFloat(side))
            context.scaleBy(x: 1, y: -1)
            image.draw(in: CGRect(x: 0, y: 0, width: side, height: side))
            UIGraphicsPopContext()
            return true
        }
        XCTAssertTrue(drawn, "Could not create a bitmap context")
        return Pixels(bytes: bytes, width: side)
    }

    private func assertColor(
        _ pixel: (r: Int, g: Int, b: Int, a: Int),
        near expected: (Int, Int, Int),
        _ label: String,
        tolerance: Int = 12,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(pixel.a, 255, "\(label) should be opaque", file: file, line: line)
        let matches = abs(pixel.r - expected.0) <= tolerance
            && abs(pixel.g - expected.1) <= tolerance
            && abs(pixel.b - expected.2) <= tolerance
        XCTAssertTrue(
            matches,
            "\(label): got rgb(\(pixel.r), \(pixel.g), \(pixel.b)), expected about rgb\(expected)",
            file: file,
            line: line
        )
    }
}
