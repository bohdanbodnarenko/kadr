import Testing
@testable import Shared

@Suite("Image format")
struct ImageFormatTests {
    @Test("A filename extension names the format that writes it", arguments: [
        ("png", ImageFormat.png),
        ("PNG", .png),
        ("jpg", .jpeg),
        ("jpeg", .jpeg),
        ("heic", .heic),
        ("heif", .heic),
        ("webp", .webp)
    ])
    func fileExtension(ext: String, expected: ImageFormat) {
        #expect(ImageFormat(fileExtension: ext) == expected)
    }

    @Test("An unknown extension is not a format Kadr writes")
    func unknownExtension() {
        #expect(ImageFormat(fileExtension: "bmp") == nil)
        #expect(ImageFormat(fileExtension: "kadr") == nil)
        #expect(ImageFormat(fileExtension: "") == nil)
    }
}
