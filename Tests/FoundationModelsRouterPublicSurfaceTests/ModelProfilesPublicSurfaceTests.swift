import Testing

import FoundationModelsRouter

/// Holds the API of the builtin named profiles to the access level that a
/// host needs: the list of a settings pane, the default name, and the lookup
/// of a stored name.
///
/// The import is plain, with no `@testable`, so a member that loses `public`
/// stops this file from compiling before a single test runs.
@Suite("Model profiles over a plain import")
struct ModelProfilesPublicSurfaceTests {
    @Test("a host reads the names of the builtin profiles")
    func hostReadsTheBuiltinNames() {
        #expect(ModelProfiles.builtin.map(\.name).contains(ModelProfiles.defaultName))
    }

    @Test("a host finds the profile of the default name")
    func hostFindsTheDefaultProfile() {
        #expect(ModelProfiles.named(ModelProfiles.defaultName)?.name == ModelProfiles.defaultName)
    }
}
