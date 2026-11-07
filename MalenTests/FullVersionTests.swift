import Foundation
import Testing
@testable import Malen

@MainActor struct FullVersionTests {
    let defaults = UserDefaults(suiteName: "full-version-\(UUID().uuidString)")!

    @Test func firstOwnPhotoIsFree() {
        let fullVersion = FullVersion(defaults: defaults)
        #expect(fullVersion.canCreatePhoto)
        fullVersion.photoCreated()
        #expect(!fullVersion.canCreatePhoto)
    }

    @Test func countSurvivesRelaunch() {
        FullVersion(defaults: defaults).photoCreated()
        let relaunched = FullVersion(defaults: defaults)
        #expect(relaunched.photosCreated == 1)
        #expect(!relaunched.canCreatePhoto)
    }

    @Test func unlockedAllowsAnyNumberOfPhotos() {
        defaults.set(true, forKey: "fullVersion.unlocked")
        let fullVersion = FullVersion(defaults: defaults)
        for _ in 0..<5 { fullVersion.photoCreated() }
        #expect(fullVersion.isUnlocked)
        #expect(fullVersion.canCreatePhoto)
    }
}
