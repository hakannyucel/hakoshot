import Testing
import Foundation
@testable import HakoShot

@Suite("App bundle")
struct HakoShotTests {
    @Test func infoPlistDeclaresAgentAndURLScheme() throws {
        let info = try #require(Bundle.main.infoDictionary)
        #expect(info["LSUIElement"] as? Bool == true)

        let urlTypes = try #require(info["CFBundleURLTypes"] as? [[String: Any]])
        let schemes = urlTypes.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
        #expect(schemes.contains("hakoshot"))
    }

    @Test func infoPlistExportsProjectUTI() throws {
        let info = try #require(Bundle.main.infoDictionary)
        let exported = try #require(info["UTExportedTypeDeclarations"] as? [[String: Any]])
        let identifiers = exported.compactMap { $0["UTTypeIdentifier"] as? String }
        #expect(identifiers.contains("com.hakanyucel.hakoshot.project"))
    }
}
