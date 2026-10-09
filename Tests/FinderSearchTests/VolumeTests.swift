import XCTest
@testable import FinderSearch

final class VolumeTests: XCTestCase {
    @MainActor private func waitForVolumes(_ workspace: BrowserWorkspace) async throws {
        for _ in 0..<100 {
            if !workspace.volumes.isEmpty { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Volume refresh timed out")
    }

    @MainActor func testStartupDiskCannotBeEjected() async throws {
        let root = MountedVolume(url: URL(fileURLWithPath: "/", isDirectory: true), canEject: true)
        let workspace = BrowserWorkspace(volumeLoader: { [root] }, volumeEjector: { _ in
            XCTFail("The startup disk must never reach the eject API")
        })
        try await waitForVolumes(workspace)
        XCTAssertFalse(root.canEject)
        workspace.eject(root) { _ in XCTFail("A non-ejectable volume is ignored") }
        XCTAssertTrue(workspace.ejectingVolumes.isEmpty)
        XCTAssertEqual(workspace.volumes, [root])
    }

    @MainActor func testFailedEjectKeepsVolumeAndPreventsDuplicateRequests() async throws {
        let fixture = VolumeFixture(fails: true)
        let workspace = BrowserWorkspace(volumeLoader: { await fixture.volumes },
            volumeEjector: { try await fixture.eject($0) })
        try await waitForVolumes(workspace)
        let volume = try XCTUnwrap(workspace.volumes.first)
        var errors: [String] = []
        workspace.eject(volume) { errors.append($0) }
        workspace.eject(volume) { errors.append($0) }
        XCTAssertEqual(workspace.ejectingVolumes, [volume.id])
        for _ in 0..<100 {
            if workspace.ejectingVolumes.isEmpty { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(workspace.ejectingVolumes.isEmpty)
        XCTAssertEqual(workspace.volumes, [volume])
        XCTAssertEqual(errors, ["Could not eject ‘FinderSearch-test-volume’: Volume is in use."])
        let attempts = await fixture.attempts
        XCTAssertEqual(attempts, 1)
    }

    @MainActor func testSuccessfulEjectRemovesVolumeAndRefreshesLocations() async throws {
        let fixture = VolumeFixture(fails: false)
        let workspace = BrowserWorkspace(volumeLoader: { await fixture.volumes },
            volumeEjector: { try await fixture.eject($0) })
        try await waitForVolumes(workspace)
        let volume = try XCTUnwrap(workspace.volumes.first)
        workspace.eject(volume) { _ in XCTFail("Expected a successful eject") }
        for _ in 0..<100 {
            if workspace.ejectingVolumes.isEmpty { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(workspace.ejectingVolumes.isEmpty)
        XCTAssertTrue(workspace.volumes.isEmpty)
        let attempts = await fixture.attempts
        XCTAssertEqual(attempts, 1)
    }
}

private actor VolumeFixture {
    var volumes = [MountedVolume(url: URL(fileURLWithPath: "/Volumes/FinderSearch-test-volume",
        isDirectory: true), canEject: true)]
    var attempts = 0
    let fails: Bool
    init(fails: Bool) { self.fails = fails }
    func eject(_ url: URL) async throws {
        attempts += 1
        try await Task.sleep(for: .milliseconds(30))
        if fails { throw Engine.Failure.message("Volume is in use.") }
        volumes.removeAll { $0.url == url }
    }
}
