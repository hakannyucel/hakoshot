import Testing
@testable import HakoKit

@Suite("HakoKit")
struct HakoKitTests {
    @Test func projectTypeMetadata() {
        #expect(HakoKit.projectFileExtension == "hakoshot")
        #expect(HakoKit.projectTypeIdentifier == "com.hakanyucel.hakoshot.project")
        #expect(!HakoKit.version.isEmpty)
    }
}
