import AppKit
import CryptoKit
import Foundation
import Security
import MimacCore

public struct IdentityResolution: Sendable {
    public let processes: [ProcessTelemetry]
    public let entities: [EntityTelemetry]
    public let workloads: [WorkloadTelemetry]
    public let errors: [String]

    public init(processes: [ProcessTelemetry], entities: [EntityTelemetry], workloads: [WorkloadTelemetry], errors: [String] = []) {
        self.processes = processes
        self.entities = entities
        self.workloads = workloads
        self.errors = errors
    }
}

public final class IdentityResolver: @unchecked Sendable {
    private struct ProcessKey: Hashable {
        let pid: Int32
        let startTime: UInt64
    }

    private struct BundleEvidence {
        let root: String?
        let identifier: String?
        let displayName: String?
        let iconPath: String?
        let teamIdentifier: String?
        let signingIdentifier: String?
    }

    private struct ProjectInfo {
        let root: String
        let name: String
    }

    private struct CachedEvidence {
        let arguments: [String]?
        let cwd: String?
        let listeningPorts: [UInt16]
        let bundle: BundleEvidence
        let project: ProjectInfo?
    }

    private struct ProcessEvidence {
        let process: ProcessTelemetry
        let arguments: [String]?
        let cwd: String?
        let listeningPorts: [UInt16]
        let bundle: BundleEvidence
        let project: ProjectInfo?
    }

    private struct EntityAccumulator {
        var displayName: String
        var kind: EntityKind
        var project: String?
        var processIDs: [Int32] = []
        var cpuPercent = 0.0
        var cpuSeconds = 0.0
        var pCoreCPUSeconds = 0.0
        var residentBytes: UInt64 = 0
        var diskReadBytes: UInt64 = 0
        var diskWrittenBytes: UInt64 = 0
        var wakeups: UInt64 = 0
        var energyJoules = 0.0
        var gpuPercent: Double?
        var gpuEnergyJoules: Double?
        var foreground = false
        var confidence: IdentityConfidence
        var groupedAutomatically = false
    }

    private struct WorkloadAccumulator {
        let project: String
        let projectRoot: String
        var entityIDs = Set<String>()
        var processCount = 0
        var cpuPercent = 0.0
        var cpuSeconds = 0.0
        var residentBytes: UInt64 = 0
        var diskReadBytes: UInt64 = 0
        var diskWrittenBytes: UInt64 = 0
        var wakeups: UInt64 = 0
        var energyJoules = 0.0
    }

    /// A process's identity is a pure function of its evidence (read once per
    /// process lifetime), its parent's identity, and the rules. Remembering it
    /// skips rule matching, hashing and path parsing for the ~500 processes that
    /// did not change since the last sample, which was most of a tick's cost.
    private struct CachedResolution {
        let parentPID: Int32
        let parent: ResolvedIdentity?
        let identity: ResolvedIdentity
    }

    private let ruleStore: IdentityRuleStore
    private var rules: [IdentityRule] = []
    private var resolutionCache: [ProcessKey: CachedResolution] = [:]
    private var stableIDCache: [String: String] = [:]
    private var evidenceCache: [ProcessKey: CachedEvidence] = [:]
    private var signingCache: [String: (teamIdentifier: String?, signingIdentifier: String?)] = [:]
    private var gitRootCache: [String: String?] = [:]
    private var metadataCache: [String: (modificationDate: Date?, name: String?)] = [:]

    public init(ruleStore: IdentityRuleStore = IdentityRuleStore()) {
        self.ruleStore = ruleStore
    }

    public func listRules() -> [IdentityRule] {
        ruleStore.list()
    }

    @discardableResult
    public func saveRule(_ rule: IdentityRule) throws -> IdentityRule {
        guard !rule.pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !rule.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NSError(domain: "MimacIdentity", code: 1, userInfo: [NSLocalizedDescriptionKey: "Rule pattern and display name are required"])
        }
        let saved = try ruleStore.save(rule)
        resolutionCache.removeAll()
        return saved
    }

    public func deleteRule(id: String) throws -> Bool {
        let deleted = try ruleStore.delete(id: id)
        if deleted { resolutionCache.removeAll() }
        return deleted
    }

    public func resolve(processes: [ProcessTelemetry], sampleIntervalSeconds: Double = 1) -> IdentityResolution {
        guard !processes.isEmpty else {
            return IdentityResolution(processes: [], entities: [], workloads: [])
        }

        let liveKeys = Set(processes.map { ProcessKey(pid: $0.pid, startTime: $0.startTime) })
        evidenceCache = evidenceCache.filter { liveKeys.contains($0.key) }
        resolutionCache = resolutionCache.filter { liveKeys.contains($0.key) }
        if stableIDCache.count > 4096 { stableIDCache.removeAll() }
        rules = ruleStore.list()
        let evidence = processes.map(makeEvidence(for:))
        let byPID = Dictionary(uniqueKeysWithValues: evidence.map { ($0.process.pid, $0) })
        var resolvedByPID: [Int32: ResolvedIdentity] = [:]
        var resolving = Set<Int32>()

        for item in evidence {
            _ = resolve(item, byPID: byPID, resolvedByPID: &resolvedByPID, resolving: &resolving)
        }

        let resolvedProcesses = processes.map { process in
            let identity = resolvedByPID[process.pid] ?? .unresolved(name: process.name)
            let item = byPID[process.pid]
            return ProcessTelemetry(
                pid: process.pid,
                startTime: process.startTime,
                name: process.name,
                path: process.path,
                parentPID: process.parentPID,
                parentChain: parentChain(for: process, byPID: byPID),
                arguments: item?.arguments,
                cwd: item?.cwd,
                listeningPorts: item?.listeningPorts ?? [],
                cpuPercent: process.cpuPercent,
                cpuSeconds: process.cpuSeconds,
                pCoreCPUSeconds: process.pCoreCPUSeconds,
                residentBytes: process.residentBytes,
                diskReadBytes: process.diskReadBytes,
                diskWrittenBytes: process.diskWrittenBytes,
                wakeups: process.wakeups,
                energyJoules: process.energyJoules,
                gpuPercent: process.gpuPercent,
                gpuEnergyJoules: process.gpuEnergyJoules,
                isForeground: process.isForeground,
                identity: identity
            )
        }

        var entityAccumulators: [String: EntityAccumulator] = [:]
        for process in resolvedProcesses {
            let identity = process.identity
            if entityAccumulators[identity.entityID] == nil {
                entityAccumulators[identity.entityID] = EntityAccumulator(
                    displayName: identity.displayName,
                    kind: identity.kind,
                    project: identity.project,
                    confidence: identity.confidence
                )
            }
            guard var entity = entityAccumulators[identity.entityID] else { continue }
            entity.processIDs.append(process.pid)
            entity.cpuPercent += process.cpuPercent
            entity.cpuSeconds += process.cpuSeconds
            entity.pCoreCPUSeconds += process.pCoreCPUSeconds
            entity.residentBytes += process.residentBytes
            entity.diskReadBytes += process.diskReadBytes
            entity.diskWrittenBytes += process.diskWrittenBytes
            entity.wakeups += process.wakeups
            entity.energyJoules += process.energyJoules
            if let gpu = process.gpuPercent { entity.gpuPercent = (entity.gpuPercent ?? 0) + gpu }
            if let gpu = process.gpuEnergyJoules { entity.gpuEnergyJoules = (entity.gpuEnergyJoules ?? 0) + gpu }
            entity.foreground = entity.foreground || process.isForeground
            entity.confidence = worse(entity.confidence, identity.confidence)
            entity.groupedAutomatically = entity.groupedAutomatically || identity.groupedAutomatically
            entityAccumulators[identity.entityID] = entity
        }

        let entities = entityAccumulators.map { id, value in
            let interval = max(0.001, sampleIntervalSeconds)
            let powerWatts = value.energyJoules / interval
            let diskBytesPerSecond = Double(value.diskReadBytes + value.diskWrittenBytes) / interval
            let activity = Self.activityLevel(
                powerWatts: powerWatts,
                cpuPercent: value.cpuPercent,
                gpuPercent: value.gpuPercent ?? 0,
                diskBytesPerSecond: diskBytesPerSecond,
                wakeupsPerSecond: Double(value.wakeups) / interval
            )
            return EntityTelemetry(
                entityID: id,
                displayName: value.displayName,
                kind: value.kind,
                project: value.project,
                processIDs: value.processIDs.sorted(),
                processCount: value.processIDs.count,
                cpuPercent: value.cpuPercent,
                cpuSeconds: value.cpuSeconds,
                pCoreCPUSeconds: value.pCoreCPUSeconds,
                residentBytes: value.residentBytes,
                diskReadBytes: value.diskReadBytes,
                diskWrittenBytes: value.diskWrittenBytes,
                wakeups: value.wakeups,
                energyJoules: value.energyJoules,
                foreground: value.foreground,
                powerWatts: powerWatts,
                gpuPercent: value.gpuPercent,
                gpuEnergyJoules: value.gpuEnergyJoules,
                activityLevel: activity.level,
                activityCause: activity.cause,
                confidence: value.confidence,
                groupedAutomatically: value.groupedAutomatically
            )
        }.sorted { lhs, rhs in
            if lhs.powerWatts != rhs.powerWatts { return lhs.powerWatts > rhs.powerWatts }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }

        var workloadsByRoot: [String: WorkloadAccumulator] = [:]
        for process in resolvedProcesses {
            guard let projectRoot = process.identity.projectRoot,
                  let project = process.identity.project else { continue }
            if workloadsByRoot[projectRoot] == nil {
                workloadsByRoot[projectRoot] = WorkloadAccumulator(project: project, projectRoot: projectRoot)
            }
            guard var workload = workloadsByRoot[projectRoot] else { continue }
            workload.entityIDs.insert(process.identity.entityID)
            workload.processCount += 1
            workload.cpuPercent += process.cpuPercent
            workload.cpuSeconds += process.cpuSeconds
            workload.residentBytes += process.residentBytes
            workload.diskReadBytes += process.diskReadBytes
            workload.diskWrittenBytes += process.diskWrittenBytes
            workload.wakeups += process.wakeups
            workload.energyJoules += process.energyJoules
            workloadsByRoot[projectRoot] = workload
        }

        let workloads = workloadsByRoot.map { root, value in
            WorkloadTelemetry(
                workloadID: stableID("workload:\(root)"),
                displayName: "\(value.project) development",
                project: value.project,
                projectRoot: root,
                entityIDs: value.entityIDs.sorted(),
                processCount: value.processCount,
                cpuPercent: value.cpuPercent,
                cpuSeconds: value.cpuSeconds,
                residentBytes: value.residentBytes,
                diskReadBytes: value.diskReadBytes,
                diskWrittenBytes: value.diskWrittenBytes,
                wakeups: value.wakeups,
                energyJoules: value.energyJoules
            )
        }.sorted { $0.energyJoules > $1.energyJoules }

        return IdentityResolution(processes: resolvedProcesses, entities: entities, workloads: workloads)
    }

    public static func activityLevel(
        powerWatts: Double,
        cpuPercent: Double,
        gpuPercent: Double = 0,
        diskBytesPerSecond: Double,
        wakeupsPerSecond: Double
    ) -> (level: ActivityLevel, cause: String?) {
        let level: ActivityLevel
        if powerWatts >= 3 || cpuPercent >= 100 || gpuPercent >= 60 || diskBytesPerSecond >= 100_000_000 {
            level = .veryHigh
        } else if powerWatts >= 1.5 || cpuPercent >= 50 || gpuPercent >= 30 || diskBytesPerSecond >= 30_000_000 {
            level = .high
        } else if powerWatts >= 0.5 || cpuPercent >= 15 || gpuPercent >= 10 || diskBytesPerSecond >= 5_000_000 || wakeupsPerSecond >= 50 {
            level = .medium
        } else if powerWatts >= 0.05 || cpuPercent >= 2 || gpuPercent >= 2 || diskBytesPerSecond >= 250_000 || wakeupsPerSecond >= 5 {
            level = .low
        } else {
            level = .idle
        }

        let cause: String?
        if diskBytesPerSecond >= 5_000_000 {
            cause = "Heavy disk activity"
        } else if gpuPercent >= 10 && gpuPercent >= cpuPercent {
            cause = "Sustained GPU work"
        } else if cpuPercent >= 15 {
            cause = "Sustained CPU work"
        } else if gpuPercent >= 10 {
            cause = "Sustained GPU work"
        } else if powerWatts >= 0.5 {
            cause = "Elevated measured energy"
        } else if wakeupsPerSecond >= 50 {
            cause = "Frequent wakeups"
        } else {
            cause = nil
        }
        return (level, cause)
    }

    private func makeEvidence(for process: ProcessTelemetry) -> ProcessEvidence {
        let key = ProcessKey(pid: process.pid, startTime: process.startTime)
        if let cached = evidenceCache[key] {
            return ProcessEvidence(process: process, arguments: cached.arguments, cwd: cached.cwd, listeningPorts: cached.listeningPorts, bundle: cached.bundle, project: cached.project)
        }

        let arguments = process.arguments ?? ProcAPI.arguments(for: process.pid)
        let cwd = process.cwd ?? ProcAPI.cwd(for: process.pid)
        let ports = process.listeningPorts.isEmpty ? ProcAPI.listeningPorts(for: process.pid) : process.listeningPorts
        let bundle = bundleEvidence(for: process)
        let project = projectInfo(cwd: cwd)
        let cached = CachedEvidence(arguments: arguments, cwd: cwd, listeningPorts: ports, bundle: bundle, project: project)
        evidenceCache[key] = cached
        return ProcessEvidence(process: process, arguments: arguments, cwd: cwd, listeningPorts: ports, bundle: bundle, project: project)
    }

    private func resolve(
        _ item: ProcessEvidence,
        byPID: [Int32: ProcessEvidence],
        resolvedByPID: inout [Int32: ResolvedIdentity],
        resolving: inout Set<Int32>
    ) -> ResolvedIdentity {
        if let existing = resolvedByPID[item.process.pid] { return existing }
        if resolving.contains(item.process.pid) {
            return fallbackIdentity(for: item)
        }
        resolving.insert(item.process.pid)
        defer { resolving.remove(item.process.pid) }

        let parent = byPID[item.process.parentPID].map {
            resolve($0, byPID: byPID, resolvedByPID: &resolvedByPID, resolving: &resolving)
        }

        let key = ProcessKey(pid: item.process.pid, startTime: item.process.startTime)
        if let cached = resolutionCache[key],
           cached.parentPID == item.process.parentPID,
           cached.parent == parent {
            resolvedByPID[item.process.pid] = cached.identity
            return cached.identity
        }
        let identity = computeIdentity(item, parent: parent)
        resolutionCache[key] = CachedResolution(parentPID: item.process.parentPID, parent: parent, identity: identity)
        resolvedByPID[item.process.pid] = identity
        return identity
    }

    private func computeIdentity(_ item: ProcessEvidence, parent: ResolvedIdentity?) -> ResolvedIdentity {
        // User corrections are authoritative. Built-in CLI names are applied
        // later so they cannot split a real app bundle into generic sub-entities.
        if let match = rules.first(where: { matches($0, item: item, parent: parent) }) {
            return ruleIdentity(match, item: item, parent: parent)
        }

        if let bundleID = item.bundle.identifier {
            let identity = ResolvedIdentity(
                entityID: stableID("bundle:\(bundleID)"),
                displayName: item.bundle.displayName ?? item.process.name,
                kind: .app,
                project: item.project?.name,
                projectRoot: item.project?.root,
                confidence: .high,
                matchSource: "bundle-signature",
                bundleIdentifier: bundleID,
                iconPath: item.bundle.iconPath,
                teamIdentifier: item.bundle.teamIdentifier,
                signingIdentifier: item.bundle.signingIdentifier
            )
            if let parent, shouldGroup(item, under: parent) {
                return inheritedIdentity(from: parent)
            }
            return identity
        }

        if let parent, shouldGroup(item, under: parent) {
            return inheritedIdentity(from: parent)
        }

        if let match = BuiltInIdentityRules.all.first(where: { matches($0, item: item, parent: parent) }) {
            return ruleIdentity(match, item: item, parent: parent)
        }

        return fallbackIdentity(for: item)
    }

    private func ruleIdentity(_ rule: IdentityRule, item: ProcessEvidence, parent: ResolvedIdentity?) -> ResolvedIdentity {
        if rule.grouping == .inheritParent, let parent {
            return inheritedIdentity(from: parent)
        }
        let keyValue: String
        if let projectRoot = item.project?.root, rule.key == .commandPattern || rule.key == .projectDirectory {
            keyValue = projectRoot
        } else {
            keyValue = item.process.path ?? rule.pattern
        }
        return ResolvedIdentity(
            entityID: stableID("rule:\(rule.id):\(rule.key.rawValue):\(keyValue)"),
            displayName: contextualDisplayName(for: rule, processName: item.process.name),
            kind: rule.kind,
            project: item.project?.name,
            projectRoot: item.project?.root,
            confidence: .high,
            matchSource: rule.id.hasPrefix("builtin-") ? "built-in-rule" : "user-rule",
            bundleIdentifier: item.bundle.identifier,
            iconPath: item.bundle.iconPath,
            iconName: rule.iconName,
            teamIdentifier: item.bundle.teamIdentifier,
            signingIdentifier: item.bundle.signingIdentifier
        )
    }

    private func contextualDisplayName(for rule: IdentityRule, processName: String) -> String {
        guard rule.id == "builtin-widget-renderer",
              let open = processName.lastIndex(of: "("),
              let close = processName.lastIndex(of: ")"),
              open < close else { return rule.displayName }
        let host = processName[processName.index(after: open)..<close]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return host.isEmpty ? rule.displayName : "\(host) widgets"
    }

    private func matches(_ rule: IdentityRule, item: ProcessEvidence, parent: ResolvedIdentity?) -> Bool {
        switch rule.key {
        case .executablePath:
            return item.process.path.map { wildcard(rule.pattern, $0) } ?? false
        case .commandPattern:
            let command = (item.arguments ?? []).joined(separator: " ")
            return wildcard(rule.pattern, command) || wildcard(rule.pattern, item.process.name)
        case .projectDirectory:
            guard let root = item.project?.root else { return false }
            return pathMatches(rule.pattern, root)
        case .bundleIdentifier:
            return item.bundle.identifier?.caseInsensitiveCompare(rule.pattern) == .orderedSame
        case .parentEntityID:
            return parent?.entityID == rule.pattern
        case .listeningPort:
            return item.listeningPorts.contains { String($0) == rule.pattern }
        }
    }

    private func matchedValue(for rule: IdentityRule, item: ProcessEvidence) -> String? {
        switch rule.key {
        case .executablePath: return item.process.path
        case .commandPattern: return (item.arguments ?? [item.process.name]).joined(separator: " ")
        case .projectDirectory: return item.project?.root
        case .bundleIdentifier: return item.bundle.identifier
        case .parentEntityID: return item.process.parentPID == 0 ? nil : String(item.process.parentPID)
        case .listeningPort: return rule.pattern
        }
    }

    private func fallbackIdentity(for item: ProcessEvidence) -> ResolvedIdentity {
        let path = item.process.path ?? item.process.name
        // NSString path parsing, not URL(fileURLWithPath:), which lstat()s the path.
        let lastComponent = (path as NSString).lastPathComponent
        let displayName = lastComponent.isEmpty ? item.process.name : lastComponent
        let kind: EntityKind = path.hasPrefix("/System/") || path.hasPrefix("/usr/") ? .system : .unknown
        let scopedKey = item.project.map { "\(path):\($0.root)" } ?? path
        return ResolvedIdentity(
            entityID: stableID("process:\(scopedKey)"),
            displayName: displayName,
            kind: kind,
            project: item.project?.name,
            projectRoot: item.project?.root,
            confidence: .low,
            matchSource: "executable-name",
            bundleIdentifier: item.bundle.identifier,
            iconPath: item.bundle.iconPath,
            teamIdentifier: item.bundle.teamIdentifier,
            signingIdentifier: item.bundle.signingIdentifier
        )
    }

    private func parentChain(for process: ProcessTelemetry, byPID: [Int32: ProcessEvidence]) -> [Int32] {
        var chain: [Int32] = []
        var current = process.parentPID
        var hops = 0
        while current > 1, hops < 8 {
            chain.append(current)
            guard let parent = byPID[current] else { break }
            current = parent.process.parentPID
            hops += 1
        }
        return chain
    }

    private func inheritedIdentity(from parent: ResolvedIdentity) -> ResolvedIdentity {
        ResolvedIdentity(
            entityID: parent.entityID,
            displayName: parent.displayName,
            kind: parent.kind,
            project: parent.project,
            projectRoot: parent.projectRoot,
            confidence: .medium,
            groupedAutomatically: true,
            matchSource: "parent-tree",
            bundleIdentifier: parent.bundleIdentifier,
            iconPath: parent.iconPath,
            iconName: parent.iconName,
            teamIdentifier: parent.teamIdentifier,
            signingIdentifier: parent.signingIdentifier
        )
    }

    private func shouldGroup(_ item: ProcessEvidence, under parent: ResolvedIdentity) -> Bool {
        let name = item.process.name.lowercased()
        let helperName = ["helper", "renderer", "gpu", "crashpad", "plugin", "worker", "viewservice", "xpcservice", "widgetcontrol"].contains { name.contains($0) }
        let sameBundleFamily: Bool = {
            guard let current = item.bundle.identifier, let parentID = parent.bundleIdentifier else { return false }
            return current == parentID || current.hasPrefix(parentID + ".") || parentID.hasPrefix(current + ".")
        }()
        let sameTeam = item.bundle.teamIdentifier != nil && item.bundle.teamIdentifier == parent.teamIdentifier
        let appChild = item.process.path?.contains(".app/Contents/") ?? false
        return helperName || sameBundleFamily || (sameTeam && appChild)
    }

    private func bundleEvidence(for process: ProcessTelemetry) -> BundleEvidence {
        var rootURL: URL?
        if let app = NSRunningApplication(processIdentifier: process.pid) {
            rootURL = app.bundleURL
        }
        if rootURL == nil, let path = process.path {
            var url = URL(fileURLWithPath: path)
            for _ in 0..<8 {
                if url.pathExtension == "app" { rootURL = url; break }
                let parent = url.deletingLastPathComponent()
                if parent == url { break }
                url = parent
            }
        }

        let bundle = rootURL.flatMap { Bundle(url: $0) }
        let identifier = bundle?.bundleIdentifier ?? NSRunningApplication(processIdentifier: process.pid)?.bundleIdentifier
        let displayName = NSRunningApplication(processIdentifier: process.pid)?.localizedName
            ?? bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
        let iconPath: String? = {
            guard let bundle, let value = bundle.object(forInfoDictionaryKey: "CFBundleIconFile") as? String else { return nil }
            let filename = value.hasSuffix(".icns") ? value : "\(value).icns"
            return bundle.url(forResource: filename, withExtension: nil)?.path
        }()
        let signing = signingMetadata(for: process.path)
        return BundleEvidence(root: rootURL?.path, identifier: identifier, displayName: displayName, iconPath: iconPath, teamIdentifier: signing.teamIdentifier, signingIdentifier: signing.signingIdentifier)
    }

    private func signingMetadata(for path: String?) -> (teamIdentifier: String?, signingIdentifier: String?) {
        guard let path else { return (nil, nil) }
        if let cached = signingCache[path] { return cached }
        var code: SecStaticCode?
        var result = (teamIdentifier: Optional<String>.none, signingIdentifier: Optional<String>.none)
        if SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess,
           let code {
            var info: CFDictionary?
            if SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
               let dictionary = info as? [String: Any] {
                result.teamIdentifier = dictionary[kSecCodeInfoTeamIdentifier as String] as? String
                result.signingIdentifier = dictionary[kSecCodeInfoIdentifier as String] as? String
            }
        }
        signingCache[path] = result
        return result
    }

    private func projectInfo(cwd: String?) -> ProjectInfo? {
        guard let cwd, !cwd.isEmpty else { return nil }
        if let cached = gitRootCache[cwd] {
            return cached.map { ProjectInfo(root: $0, name: projectName(root: $0)) }
        }

        var current = URL(fileURLWithPath: cwd).standardizedFileURL
        var gitRoot: String?
        for _ in 0..<8 {
            let gitURL = current.appendingPathComponent(".git")
            if FileManager.default.fileExists(atPath: gitURL.path) {
                gitRoot = current.path
                break
            }
            let parent = current.deletingLastPathComponent()
            if parent == current { break }
            current = parent
        }
        gitRootCache[cwd] = gitRoot
        guard let root = gitRoot else { return nil }
        return ProjectInfo(root: root, name: projectName(root: root))
    }

    private func projectName(root: String) -> String {
        let rootURL = URL(fileURLWithPath: root)
        for filename in ["package.json", "pyproject.toml", "Cargo.toml"] {
            let url = rootURL.appendingPathComponent(filename)
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let modified = attributes[.modificationDate] as? Date else { continue }
            let cached = metadataCache[url.path]
            if cached?.modificationDate != modified {
                metadataCache[url.path] = (modified, packageName(url: url, filename: filename))
            }
            if let name = metadataCache[url.path]?.name, !name.isEmpty { return name }
        }
        return rootURL.lastPathComponent
    }

    private func packageName(url: URL, filename: String) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        if filename == "package.json",
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let name = object["name"] as? String {
            return name
        }
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let pattern = "(?m)^\\s*name\\s*=\\s*[\\\"']([^\\\"']+)[\\\"']"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    private func pathMatches(_ pattern: String, _ path: String) -> Bool {
        path == pattern || path.hasPrefix(pattern.hasSuffix("/") ? pattern : "\(pattern)/")
    }

    private func wildcard(_ pattern: String, _ value: String) -> Bool {
        let pieces = pattern.lowercased().split(separator: "*", omittingEmptySubsequences: false).map(String.init)
        let candidate = value.lowercased()
        guard pieces.count > 1 else { return candidate == pattern.lowercased() }
        var index = candidate.startIndex
        for (offset, piece) in pieces.enumerated() where !piece.isEmpty {
            guard let range = candidate.range(of: piece, range: index..<candidate.endIndex) else { return false }
            if offset == 0 && !pattern.hasPrefix("*") && range.lowerBound != candidate.startIndex { return false }
            index = range.upperBound
        }
        if !pattern.hasSuffix("*"), let last = pieces.last, !last.isEmpty {
            return candidate.hasSuffix(last)
        }
        return true
    }

    private func worse(_ lhs: IdentityConfidence, _ rhs: IdentityConfidence) -> IdentityConfidence {
        switch (lhs, rhs) {
        case (.low, _), (_, .low): return .low
        case (.medium, _), (_, .medium): return .medium
        default: return .high
        }
    }

    private func stableID(_ key: String) -> String {
        if let cached = stableIDCache[key] { return cached }
        let digest = SHA256.hash(data: Data(key.utf8))
        let hex: [Character] = Array("0123456789abcdef")
        var id = "entity-"
        id.reserveCapacity(31)
        for byte in digest.prefix(12) {
            id.append(hex[Int(byte >> 4)])
            id.append(hex[Int(byte & 0x0f)])
        }
        stableIDCache[key] = id
        return id
    }
}
