import Foundation
import XCTest
@testable import MimacIdentity

final class IdentityResolverTests: XCTestCase {
    func testUserRuleWinsAndPersists() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mimac-rules-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = IdentityRuleStore(url: url)
        let rule = IdentityRule(key: .commandPattern, pattern: "*worker.js*", displayName: "ChatAPI worker", kind: .agent)
        try store.save(rule)

        let loaded = IdentityRuleStore(url: url)
        XCTAssertEqual(loaded.list().first?.displayName, "ChatAPI worker")

        let resolver = IdentityResolver(ruleStore: loaded)
        let process = ProcessTelemetry(
            pid: 999_991,
            startTime: 1,
            name: "node",
            path: "/usr/local/bin/node",
            arguments: ["node", "/tmp/worker.js"],
            cwd: "/tmp",
            cpuPercent: 2,
            cpuSeconds: 0.1,
            pCoreCPUSeconds: 0,
            residentBytes: 1,
            diskReadBytes: 0,
            diskWrittenBytes: 0,
            wakeups: 0,
            energyJoules: 0
        )

        let result = resolver.resolve(processes: [process])
        XCTAssertEqual(result.processes.first?.identity.displayName, "ChatAPI worker")
        XCTAssertEqual(result.processes.first?.identity.matchSource, "user-rule")
        XCTAssertEqual(result.entities.count, 1)
    }

    func testWorkloadGroupsProcessesByProjectRoot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mimac-project-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try Data("{\"name\":\"mimac-fixture\"}".utf8).write(to: root.appendingPathComponent("package.json"))
        defer { try? FileManager.default.removeItem(at: root) }

        let rulesURL = FileManager.default.temporaryDirectory.appendingPathComponent("mimac-empty-\(UUID().uuidString).json")
        let resolver = IdentityResolver(ruleStore: IdentityRuleStore(url: rulesURL))
        let first = ProcessTelemetry(pid: 999_992, startTime: 1, name: "vite", path: "/usr/local/bin/vite", arguments: ["vite", "--host"], cwd: root.path, cpuPercent: 1, cpuSeconds: 0.1, pCoreCPUSeconds: 0, residentBytes: 1, diskReadBytes: 0, diskWrittenBytes: 0, wakeups: 0, energyJoules: 0)
        let second = ProcessTelemetry(pid: 999_993, startTime: 1, name: "next", path: "/usr/local/bin/next", arguments: ["next", "dev"], cwd: root.path, cpuPercent: 1, cpuSeconds: 0.1, pCoreCPUSeconds: 0, residentBytes: 1, diskReadBytes: 0, diskWrittenBytes: 0, wakeups: 0, energyJoules: 0)
        let result = resolver.resolve(processes: [first, second])
        XCTAssertEqual(result.entities.count, 2)
        XCTAssertEqual(result.workloads.first?.project, "mimac-fixture")
        XCTAssertEqual(result.workloads.first?.processCount, 2)
    }

    func testCommandRuleIdentityIsStableAcrossArgumentChanges() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mimac-stable-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let resolver = IdentityResolver(ruleStore: IdentityRuleStore(url: root.appendingPathComponent("rules.json")))
        let first = ProcessTelemetry(pid: 999_994, startTime: 1, name: "vite", path: "/usr/local/bin/vite", arguments: ["vite", "--host", "--random=one"], cwd: root.path, cpuPercent: 0, cpuSeconds: 0, pCoreCPUSeconds: 0, residentBytes: 0, diskReadBytes: 0, diskWrittenBytes: 0, wakeups: 0, energyJoules: 0)
        let second = ProcessTelemetry(pid: 999_995, startTime: 2, name: "vite", path: "/usr/local/bin/vite", arguments: ["vite", "--host", "--random=two"], cwd: root.path, cpuPercent: 0, cpuSeconds: 0, pCoreCPUSeconds: 0, residentBytes: 0, diskReadBytes: 0, diskWrittenBytes: 0, wakeups: 0, energyJoules: 0)
        XCTAssertEqual(resolver.resolve(processes: [first]).processes.first?.identity.entityID, resolver.resolve(processes: [second]).processes.first?.identity.entityID)
    }

    func testEntityPowerAndActivityAreComputedUsingSampleInterval() throws {
        let rulesURL = FileManager.default.temporaryDirectory.appendingPathComponent("mimac-power-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: rulesURL) }
        let resolver = IdentityResolver(ruleStore: IdentityRuleStore(url: rulesURL))
        let process = ProcessTelemetry(
            pid: 999_996,
            startTime: 1,
            name: "fixture",
            path: "/tmp/fixture",
            cpuPercent: 1,
            cpuSeconds: 0.02,
            pCoreCPUSeconds: 0,
            residentBytes: 1,
            diskReadBytes: 0,
            diskWrittenBytes: 0,
            wakeups: 0,
            energyJoules: 4
        )

        let entity = try XCTUnwrap(resolver.resolve(processes: [process], sampleIntervalSeconds: 2).entities.first)
        XCTAssertEqual(entity.powerWatts, 2, accuracy: 0.0001)
        XCTAssertEqual(entity.activityLevel, .high)
        XCTAssertEqual(entity.activityCause, "Elevated measured energy")
    }

    func testBuiltInRulesProvideHumanNamesAndIconMetadata() throws {
        let rulesURL = FileManager.default.temporaryDirectory.appendingPathComponent("mimac-known-tools-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: rulesURL) }
        let resolver = IdentityResolver(ruleStore: IdentityRuleStore(url: rulesURL))
        let node = ProcessTelemetry(
            pid: 999_997,
            startTime: 1,
            name: "node",
            path: "/opt/homebrew/bin/node",
            arguments: ["node", "server.js"],
            cwd: "/tmp",
            cpuPercent: 0,
            cpuSeconds: 0,
            pCoreCPUSeconds: 0,
            residentBytes: 0,
            diskReadBytes: 0,
            diskWrittenBytes: 0,
            wakeups: 0,
            energyJoules: 0
        )
        let chrono = ProcessTelemetry(
            pid: 999_998,
            startTime: 1,
            name: "chronod",
            path: "/usr/libexec/chronod",
            arguments: ["chronod"],
            cwd: "/",
            cpuPercent: 0,
            cpuSeconds: 0,
            pCoreCPUSeconds: 0,
            residentBytes: 0,
            diskReadBytes: 0,
            diskWrittenBytes: 0,
            wakeups: 0,
            energyJoules: 0
        )
        let widget = ProcessTelemetry(
            pid: 999_990,
            startTime: 1,
            name: "ThemeWidgetControlViewService (Zen)",
            path: "/System/Library/Frameworks/WidgetKit.framework/ThemeWidgetControlViewService",
            arguments: ["ThemeWidgetControlViewService (Zen)"],
            cwd: "/",
            cpuPercent: 0,
            cpuSeconds: 0,
            pCoreCPUSeconds: 0,
            residentBytes: 0,
            diskReadBytes: 0,
            diskWrittenBytes: 0,
            wakeups: 0,
            energyJoules: 0
        )

        let result = resolver.resolve(processes: [node, chrono, widget])
        let nodeIdentity = try XCTUnwrap(result.processes.first { $0.pid == node.pid }?.identity)
        XCTAssertEqual(nodeIdentity.displayName, "Node.js runtime")
        XCTAssertEqual(nodeIdentity.iconName, "nodedotjs")
        let chronoIdentity = try XCTUnwrap(result.processes.first { $0.pid == chrono.pid }?.identity)
        XCTAssertEqual(chronoIdentity.displayName, "Widgets & live activities")
        XCTAssertEqual(chronoIdentity.iconName, "sf:rectangle.stack.badge.clock")
        let widgetIdentity = try XCTUnwrap(result.processes.first { $0.pid == widget.pid }?.identity)
        XCTAssertEqual(widgetIdentity.displayName, "Zen widgets")
        XCTAssertEqual(widgetIdentity.iconName, "sf:rectangle.stack")
    }

    func testBundleIdentityPrecedesBroadBuiltInCLIRule() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mimac-bundle-\(UUID().uuidString)")
        let app = root.appendingPathComponent("Codex.app")
        let executable = app.appendingPathComponent("Contents/MacOS/Codex")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleIdentifier": "com.openai.codex.fixture",
            "CFBundleName": "Codex Fixture"
        ]
        let plistData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try plistData.write(to: app.appendingPathComponent("Contents/Info.plist"))
        try Data().write(to: executable)
        defer { try? FileManager.default.removeItem(at: root) }

        let resolver = IdentityResolver(ruleStore: IdentityRuleStore(url: root.appendingPathComponent("rules.json")))
        let process = ProcessTelemetry(
            pid: 999_999,
            startTime: 1,
            name: "codex",
            path: executable.path,
            arguments: ["codex", "--help"],
            cwd: "/tmp",
            cpuPercent: 0,
            cpuSeconds: 0,
            pCoreCPUSeconds: 0,
            residentBytes: 0,
            diskReadBytes: 0,
            diskWrittenBytes: 0,
            wakeups: 0,
            energyJoules: 0
        )

        let identity = try XCTUnwrap(resolver.resolve(processes: [process]).processes.first?.identity)
        XCTAssertEqual(identity.displayName, "Codex Fixture")
        XCTAssertEqual(identity.bundleIdentifier, "com.openai.codex.fixture")
        XCTAssertEqual(identity.matchSource, "bundle-signature")
        XCTAssertNil(identity.iconName)
    }

    // Identities are cached per process between samples; these pin down what
    // must still invalidate a cached identity.

    private func fixtureProcess(pid: Int32, name: String, path: String, parentPID: Int32 = 1) -> ProcessTelemetry {
        ProcessTelemetry(pid: pid, startTime: 7, name: name, path: path, parentPID: parentPID, arguments: [name], cwd: "/", cpuPercent: 1, cpuSeconds: 0.01, pCoreCPUSeconds: 0, residentBytes: 1, diskReadBytes: 0, diskWrittenBytes: 0, wakeups: 0, energyJoules: 0)
    }

    func testRuleSavedBetweenSamplesAppliesToAlreadyResolvedProcess() throws {
        let rulesURL = FileManager.default.temporaryDirectory.appendingPathComponent("mimac-cache-rule-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: rulesURL) }
        let resolver = IdentityResolver(ruleStore: IdentityRuleStore(url: rulesURL))
        let process = fixtureProcess(pid: 999_801, name: "fixtured", path: "/tmp/mimac-fixture/fixtured")

        XCTAssertEqual(resolver.resolve(processes: [process]).processes.first?.identity.displayName, "fixtured")
        try resolver.saveRule(IdentityRule(key: .executablePath, pattern: "/tmp/mimac-fixture/*", displayName: "Fixture Service", kind: .devServer))
        XCTAssertEqual(resolver.resolve(processes: [process]).processes.first?.identity.displayName, "Fixture Service")
    }

    func testCachedChildFollowsNewParentAfterReparenting() throws {
        let rulesURL = FileManager.default.temporaryDirectory.appendingPathComponent("mimac-cache-parent-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: rulesURL) }
        let resolver = IdentityResolver(ruleStore: IdentityRuleStore(url: rulesURL))
        let firstParent = fixtureProcess(pid: 999_802, name: "alpha", path: "/tmp/mimac-fixture/alpha")
        let secondParent = fixtureProcess(pid: 999_803, name: "beta", path: "/tmp/mimac-fixture/beta")
        // "helper" in the name makes the child group under whichever parent it has.
        let child = fixtureProcess(pid: 999_804, name: "render-helper", path: "/tmp/mimac-fixture/render-helper", parentPID: firstParent.pid)
        let reparented = fixtureProcess(pid: child.pid, name: child.name, path: "/tmp/mimac-fixture/render-helper", parentPID: secondParent.pid)

        let before = resolver.resolve(processes: [firstParent, secondParent, child])
        XCTAssertEqual(before.processes.first { $0.pid == child.pid }?.identity.displayName, "alpha")
        let after = resolver.resolve(processes: [firstParent, secondParent, reparented])
        XCTAssertEqual(after.processes.first { $0.pid == child.pid }?.identity.displayName, "beta")
    }
}
