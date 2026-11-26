import ImageIO
import UIKit
import XCTest
@testable import AppUnderTest

final class PlanPhotoTests: XCTestCase {
    func testLargePhotoIsResizedAndSurvivesPersistenceForEveryPlanType() throws {
        let input = UIGraphicsImageRenderer(size: CGSize(width: 3000, height: 2000)).image { context in
            UIColor.systemGreen.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 3000, height: 2000))
        }
        let photo = try PlanPhoto.prepare(XCTUnwrap(input.jpegData(compressionQuality: 1)))
        XCTAssertLessThanOrEqual(photo.jpeg.count, 120_000)
        let image = try XCTUnwrap(UIImage(data: photo.jpeg))
        XCTAssertLessThanOrEqual(max(image.size.width, image.size.height), 1600)
        for kind in ItineraryItemKind.allCases {
            var draft = ItineraryItemDraft()
            draft.kind = kind
            draft.title = "Photo plan"
            draft.photos = [photo]
            XCTAssertTrue(draft.isValid)
            XCTAssertEqual(PlanPhoto.decode(try PlanPhoto.encode(draft.photos)), [photo])
        }
    }

    func testInvalidImageAndTooManyOrOversizedPhotosAreRefused() throws {
        XCTAssertThrowsError(try PlanPhoto.prepare(Data("not an image".utf8)))
        let photo = PlanPhoto(id: UUID(), jpeg: Data([0xff, 0xd8, 0xff, 0xd9]))
        XCTAssertThrowsError(try PlanPhoto.encode(Array(repeating: photo, count: 4)))
        XCTAssertThrowsError(try PlanPhoto.encode([photo, photo]))
        XCTAssertThrowsError(try PlanPhoto.encode([PlanPhoto(id: UUID(), jpeg: Data(repeating: 0, count: 120_001))]))
        XCTAssertEqual(PlanPhoto.decode(nil), [])
        XCTAssertEqual(PlanPhoto.decode(try PlanPhoto.encode([])), [])
    }
}
