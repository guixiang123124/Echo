import Testing
@testable import EchoUI

@Suite("EchoUI Tests")
struct EchoUITests {

    @Test("UI module is importable")
    func moduleImport() {
        // Verifies the EchoUI module compiles and links
        #expect(true)
    }
}
