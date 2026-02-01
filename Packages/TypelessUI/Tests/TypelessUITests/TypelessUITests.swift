import Testing
@testable import TypelessUI

@Suite("TypelessUI Tests")
struct TypelessUITests {

    @Test("UI module is importable")
    func moduleImport() {
        // Verifies the TypelessUI module compiles and links
        #expect(true)
    }
}
