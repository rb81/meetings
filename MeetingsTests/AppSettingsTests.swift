import Foundation
import XCTest

@testable import Meetings

@MainActor
final class AppSettingsTests: XCTestCase {
    func testMenuBarVisibilityPersistsAcrossSettingsInstances() {
        let defaults = UserDefaults.standard
        let key = "showMenuBarIcon"
        let previous = defaults.object(forKey: key)
        defer {
            if let previous {
                defaults.set(previous, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

        defaults.removeObject(forKey: key)
        let settings = AppSettings()
        XCTAssertTrue(settings.showMenuBarIcon)

        settings.showMenuBarIcon = false
        let restarted = AppSettings()
        XCTAssertFalse(restarted.showMenuBarIcon)

        restarted.showMenuBarIcon = true
        XCTAssertTrue(AppSettings().showMenuBarIcon)
    }
}
