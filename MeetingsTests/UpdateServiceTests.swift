import Foundation
import XCTest

@testable import Meetings

final class ReleaseVersionTests: XCTestCase {
    func testComparesNumericVersionsAndNormalizesShortVersions() {
        XCTAssertEqual(ReleaseVersion("v1.0.0"), ReleaseVersion("1"))
        XCTAssertEqual(ReleaseVersion("1.2"), ReleaseVersion("1.2.0"))
        XCTAssertTrue(ReleaseVersion("1.10.0")! > ReleaseVersion("1.9.9")!)
        XCTAssertTrue(ReleaseVersion("2.0")! > ReleaseVersion("1.99.99")!)
    }

    func testRejectsPrereleaseAndMalformedVersions() {
        for value in ["", "v", "1..0", "-1.0", "1.0-beta", "1.2.3.4", "release-1", "1.0+build", " 1.0"] {
            XCTAssertNil(ReleaseVersion(value), value)
        }
    }
}

@MainActor
final class UpdateServiceTests: XCTestCase {
    private func isolatedDefaults() -> UserDefaults {
        let suite = "MeetingsUpdateTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    private func reply(
        _ tag: String = "v1.10.0", status: Int = 200, draft: Bool = false, prerelease: Bool = false
    ) throws -> (Data, URLResponse) {
        let data = try JSONSerialization.data(withJSONObject: [
            "tag_name": tag, "draft": draft, "prerelease": prerelease,
        ])
        let response = HTTPURLResponse(
            url: URL(string: "https://api.github.com/repos/rb81/meetings/releases/latest")!,
            statusCode: status, httpVersion: nil, headerFields: nil
        )!
        return (data, response)
    }

    func testNewReleaseNotifiesAndDailyChecksAreThrottled() async {
        let defaults = isolatedDefaults()
        var calls = 0
        let service = UpdateService(defaults: defaults, currentVersion: "1.9.0") { request in
            calls += 1
            XCTAssertEqual(request.url?.host, "api.github.com")
            XCTAssertEqual(request.url?.path, "/repos/rb81/meetings/releases/latest")
            XCTAssertNil(request.httpBody)
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            return try self.reply()
        }
        let now = Date()
        await service.check(now: now)
        XCTAssertEqual(service.availableVersion, "v1.10.0")
        let restarted = UpdateService(defaults: defaults, currentVersion: "1.9.0")
        XCTAssertEqual(restarted.availableVersion, "v1.10.0")
        let upgraded = UpdateService(defaults: defaults, currentVersion: "1.10")
        XCTAssertNil(upgraded.availableVersion)
        await service.check(now: now.addingTimeInterval(60))
        XCTAssertEqual(calls, 1)
        await service.check(now: now.addingTimeInterval(86_401))
        XCTAssertEqual(calls, 2)
    }

    func testDismissalPersistsButDoesNotHideTheNextRelease() async {
        let defaults = isolatedDefaults()
        let service = UpdateService(defaults: defaults, currentVersion: "1.0") { _ in try self.reply("v2.0") }
        await service.check(force: true)
        service.dismiss()
        XCTAssertNil(service.availableVersion)
        let restarted = UpdateService(defaults: defaults, currentVersion: "1.0") { _ in try self.reply("v2.0") }
        await restarted.check(force: true)
        XCTAssertNil(restarted.availableVersion)
        let next = UpdateService(defaults: defaults, currentVersion: "1.0") { _ in try self.reply("v3.0") }
        await next.check(force: true)
        XCTAssertEqual(next.availableVersion, "v3.0")
    }

    func testOfflineAndAutomaticOptOutDoNotFetchButManualCheckHonorsOptOut() async {
        let defaults = isolatedDefaults()
        var calls = 0
        let service = UpdateService(defaults: defaults, currentVersion: "1.0") { _ in
            calls += 1
            return try self.reply()
        }
        defaults.set(true, forKey: NetworkPolicy.offlineKey)
        await service.check(force: true)
        XCTAssertEqual(calls, 0)
        defaults.set(false, forKey: NetworkPolicy.offlineKey)
        defaults.set(false, forKey: UpdateService.automaticKey)
        await service.check()
        XCTAssertEqual(calls, 0)
        await service.check(force: true)
        XCTAssertEqual(calls, 1)
    }

    func testEqualAndOlderVersionsDoNotNotify() async {
        for tag in ["v1.0.0", "v0.9.0"] {
            let service = UpdateService(defaults: isolatedDefaults(), currentVersion: "1.0") { _ in
                try self.reply(tag)
            }
            await service.check(force: true)
            XCTAssertNil(service.availableVersion)
            XCTAssertEqual(service.status, "You're up to date.")
        }
    }

    func testMissingReleaseAndServerErrorsAreNotReportedAsUpToDate() async {
        for code in [404, 403, 500] {
            let service = UpdateService(defaults: isolatedDefaults(), currentVersion: "1.0") { _ in
                try self.reply(status: code)
            }
            await service.check(force: true)
            XCTAssertNil(service.availableVersion)
            XCTAssertNotEqual(service.status, "You're up to date.")
            if code != 404 {
                XCTAssertTrue(service.status.contains("Couldn't check"))
            }
        }
    }

    func testDraftPrereleaseAndUnusableTagsAreRejected() async {
        for (tag, draft, prerelease) in [("v2.0", true, false), ("v2.0", false, true), ("nightly", false, false)] {
            let service = UpdateService(defaults: isolatedDefaults(), currentVersion: "1.0") { _ in
                try self.reply(tag, draft: draft, prerelease: prerelease)
            }
            await service.check(force: true)
            XCTAssertNil(service.availableVersion)
            XCTAssertTrue(service.status.contains("Couldn't check"))
        }
    }

    func testSwitchingOfflineDuringRequestDoesNotPublishResult() async {
        let defaults = isolatedDefaults()
        let service = UpdateService(defaults: defaults, currentVersion: "1.0") { _ in
            defaults.set(true, forKey: NetworkPolicy.offlineKey)
            return try self.reply()
        }
        await service.check(force: true)
        XCTAssertNil(service.availableVersion)
        XCTAssertFalse(service.isChecking)
    }

    func testInvalidJSONAndNetworkFailuresAreVisible() async {
        let invalid = UpdateService(defaults: isolatedDefaults(), currentVersion: "1.0") { _ in
            let (_, response) = try self.reply()
            return (Data("not json".utf8), response)
        }
        await invalid.check(force: true)
        XCTAssertTrue(invalid.status.contains("Couldn't check"))
        let unavailable = UpdateService(defaults: isolatedDefaults(), currentVersion: "1.0") { _ in
            throw URLError(.notConnectedToInternet)
        }
        await unavailable.check(force: true)
        XCTAssertTrue(unavailable.status.contains("Couldn't check"))
    }

    func testCancelledRequestDoesNotPreventAnAutomaticRetry() async {
        var calls = 0
        let service = UpdateService(defaults: isolatedDefaults(), currentVersion: "1.0") { _ in
            calls += 1
            if calls == 1 { throw URLError(.cancelled) }
            return try self.reply()
        }
        await service.check()
        XCTAssertFalse(service.isChecking)
        await service.check()
        XCTAssertEqual(calls, 2)
        XCTAssertNotNil(service.availableVersion)
    }
}
