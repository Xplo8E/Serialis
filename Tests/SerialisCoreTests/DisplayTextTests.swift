import XCTest
@testable import SerialisCore

final class DisplayTextTests: XCTestCase {
    func testASCIIRoundTripOffsets() {
        let display = DisplayText(data: Data("abc".utf8))

        XCTAssertEqual(display.text, "abc")
        XCTAssertEqual((0...3).map { display.byteOffset(forUTF16Index: $0) }, [0, 1, 2, 3])
        XCTAssertEqual((0...3).map { display.utf16Index(forByteOffset: $0) }, [0, 1, 2, 3])
    }

    func testUnicodeOffsetsClampInsideScalars() {
        let text = "Aé😀e\u{301}Z"
        let display = DisplayText(data: Data(text.utf8))

        XCTAssertEqual(display.text, text)
        XCTAssertEqual(display.byteOffset(forUTF16Index: 0), 0)
        XCTAssertEqual(display.byteOffset(forUTF16Index: 1), 1)
        XCTAssertEqual(display.byteOffset(forUTF16Index: 2), 3)
        XCTAssertEqual(display.byteOffset(forUTF16Index: 3), 3)
        XCTAssertEqual(display.byteOffset(forUTF16Index: 4), 7)
        XCTAssertEqual(display.utf16Index(forByteOffset: 2), 1)
        XCTAssertEqual(display.utf16Index(forByteOffset: 4), 2)
        XCTAssertEqual(display.utf16Index(forByteOffset: 6), 2)
        XCTAssertEqual(display.utf16Index(forByteOffset: 7), 4)
    }

    func testTabsMapExpansionToSingleOriginalByte() {
        let display = DisplayText(data: Data("a\tb".utf8))

        XCTAssertEqual(display.text, "a    b")
        XCTAssertEqual(display.byteOffset(forUTF16Index: 1), 1)
        XCTAssertEqual(display.byteOffset(forUTF16Index: 2), 1)
        XCTAssertEqual(display.byteOffset(forUTF16Index: 4), 1)
        XCTAssertEqual(display.byteOffset(forUTF16Index: 5), 2)
        XCTAssertEqual(display.utf16Index(forByteOffset: 1), 1)
        XCTAssertEqual(display.utf16Index(forByteOffset: 2), 5)
    }

    func testInvalidUTF8ProducesReplacementAndBoundedOffsets() {
        let display = DisplayText(data: Data([0x41, 0xC3, 0x28, 0x42]))

        XCTAssertEqual(display.text, "A\u{FFFD}(B")
        XCTAssertEqual(display.byteOffset(forUTF16Index: 0), 0)
        XCTAssertEqual(display.byteOffset(forUTF16Index: 1), 1)
        XCTAssertEqual(display.byteOffset(forUTF16Index: 2), 2)
        XCTAssertEqual(display.byteOffset(forUTF16Index: 4), 4)
        XCTAssertEqual(display.byteOffset(forUTF16Index: 40), 4)
        XCTAssertEqual(display.utf16Index(forByteOffset: 1), 1)
        XCTAssertEqual(display.utf16Index(forByteOffset: 2), 2)
        XCTAssertEqual(display.utf16Index(forByteOffset: 99), 4)
    }

    func testTrailingNewlineAndCRLFAreNotRendered() {
        let lf = DisplayText(data: Data("abc\n".utf8))
        let crlf = DisplayText(data: Data("abc\r\n".utf8))
        let cr = DisplayText(data: Data("abc\r".utf8))

        XCTAssertEqual(lf.text, "abc")
        XCTAssertEqual(crlf.text, "abc")
        XCTAssertEqual(cr.text, "abc")
        XCTAssertEqual(lf.byteOffset(forUTF16Index: 3), 3)
        XCTAssertEqual(crlf.byteOffset(forUTF16Index: 3), 3)
        XCTAssertEqual(crlf.utf16Index(forByteOffset: 3), 3)
        XCTAssertEqual(crlf.utf16Index(forByteOffset: 4), 3)
        XCTAssertEqual(crlf.utf16Index(forByteOffset: 5), 3)
    }

    func testNULRendersAsVisibleSymbol() {
        let display = DisplayText(data: Data([0x41, 0x00, 0x42]))

        XCTAssertEqual(display.text, "A␀B")
        XCTAssertEqual(display.byteOffset(forUTF16Index: 2), 2)
        XCTAssertEqual(display.utf16Index(forByteOffset: 2), 2)
    }
}
