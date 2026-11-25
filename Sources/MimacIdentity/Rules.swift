import Foundation

public enum IdentityRuleKey: String, Codable, CaseIterable, Sendable {
    case executablePath
    case commandPattern
    case projectDirectory
    case bundleIdentifier
    case parentEntityID
    case listeningPort
}

public enum RuleGrouping: String, Codable, CaseIterable, Sendable {
    case standalone
    case inheritParent
}

public struct IdentityRule: Codable, Identifiable, Sendable {
    public let id: String
    public let key: IdentityRuleKey
    public let pattern: String
    public let displayName: String
    public let kind: EntityKind
    public let grouping: RuleGrouping
    public let iconName: String?

    public init(
        id: String = UUID().uuidString.lowercased(),
        key: IdentityRuleKey,
        pattern: String,
        displayName: String,
        kind: EntityKind = .unknown,
        grouping: RuleGrouping = .standalone,
        iconName: String? = nil
    ) {
        self.id = id
        self.key = key
        self.pattern = pattern
        self.displayName = displayName
        self.kind = kind
        self.grouping = grouping
        self.iconName = iconName
    }
}

public struct IdentityRuleStoreFile: Codable, Sendable {
    public let schemaVersion: Int
    public let rules: [IdentityRule]

    public init(schemaVersion: Int = 1, rules: [IdentityRule]) {
        self.schemaVersion = schemaVersion
        self.rules = rules
    }
}

public final class IdentityRuleStore: @unchecked Sendable {
    public static let defaultURL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Mimac/rules.json")

    private let url: URL
    private var userRules: [IdentityRule]

    public init(url: URL = IdentityRuleStore.defaultURL) {
        self.url = url
        self.userRules = []
        load()
    }

    public func list() -> [IdentityRule] {
        userRules.sorted { $0.id < $1.id }
    }

    @discardableResult
    public func save(_ rule: IdentityRule) throws -> IdentityRule {
        userRules.removeAll { $0.id == rule.id }
        userRules.append(rule)
        try persist()
        return rule
    }

    public func delete(id: String) throws -> Bool {
        let oldCount = userRules.count
        userRules.removeAll { $0.id == id }
        guard userRules.count != oldCount else { return false }
        try persist()
        return true
    }

    private func load() {
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(IdentityRuleStoreFile.self, from: data),
              file.schemaVersion == 1 else { return }
        userRules = file.rules
    }

    private func persist() throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(IdentityRuleStoreFile(rules: userRules)).write(to: url, options: .atomic)
    }
}

public enum BuiltInIdentityRules {
    public static let all: [IdentityRule] = [
        IdentityRule(id: "builtin-next-dev", key: .commandPattern, pattern: "*next*dev*", displayName: "Next.js dev server", kind: .devServer, iconName: "nextdotjs"),
        IdentityRule(id: "builtin-vite", key: .commandPattern, pattern: "*vite*", displayName: "Vite dev server", kind: .devServer, iconName: "vite"),
        IdentityRule(id: "builtin-astro", key: .commandPattern, pattern: "*astro*dev*", displayName: "Astro dev server", kind: .devServer, iconName: "astro"),
        IdentityRule(id: "builtin-uvicorn", key: .commandPattern, pattern: "*uvicorn*", displayName: "Uvicorn server", kind: .devServer, iconName: "python"),
        IdentityRule(id: "builtin-jupyter", key: .commandPattern, pattern: "*jupyter*", displayName: "Jupyter", kind: .devServer, iconName: "jupyter"),
        IdentityRule(id: "builtin-postgres", key: .commandPattern, pattern: "*postgres*", displayName: "PostgreSQL", kind: .agent, iconName: "postgresql"),
        IdentityRule(id: "builtin-supabase", key: .commandPattern, pattern: "*supabase*", displayName: "Supabase CLI", kind: .agent, iconName: "supabase"),
        IdentityRule(id: "builtin-firebase", key: .commandPattern, pattern: "*firebase*emulator*", displayName: "Firebase emulator", kind: .devServer, iconName: "firebase"),
        IdentityRule(id: "builtin-codex", key: .commandPattern, pattern: "*codex*", displayName: "Codex CLI", kind: .agent, iconName: "sf:chevron.left.forwardslash.chevron.right"),
        IdentityRule(id: "builtin-claude", key: .commandPattern, pattern: "*claude*", displayName: "Claude Code", kind: .agent, iconName: "claude"),
        IdentityRule(id: "builtin-node", key: .commandPattern, pattern: "node", displayName: "Node.js runtime", kind: .helper, iconName: "nodedotjs"),
        IdentityRule(id: "builtin-python", key: .commandPattern, pattern: "python*", displayName: "Python runtime", kind: .helper, iconName: "python"),
        IdentityRule(id: "builtin-docker", key: .commandPattern, pattern: "docker", displayName: "Docker CLI", kind: .agent, iconName: "docker"),
        IdentityRule(id: "builtin-git", key: .commandPattern, pattern: "git", displayName: "Git", kind: .agent, iconName: "git"),
        IdentityRule(id: "builtin-homebrew", key: .commandPattern, pattern: "brew", displayName: "Homebrew", kind: .agent, iconName: "homebrew"),
        IdentityRule(id: "builtin-mimacd", key: .commandPattern, pattern: "mimacd", displayName: "Mimac Collector", kind: .system, iconName: "sf:waveform.path.ecg"),
        IdentityRule(id: "builtin-chronod", key: .commandPattern, pattern: "chronod", displayName: "Widgets & live activities", kind: .system, iconName: "sf:rectangle.stack.badge.clock"),
        IdentityRule(id: "builtin-extensionkit", key: .commandPattern, pattern: "extensionkitservice", displayName: "App extensions", kind: .system, iconName: "sf:puzzlepiece.extension"),
        IdentityRule(id: "builtin-loginwindow", key: .commandPattern, pattern: "loginwindow", displayName: "Login & user session", kind: .system, iconName: "sf:person.crop.circle"),
        IdentityRule(id: "builtin-cfprefsd", key: .commandPattern, pattern: "cfprefsd", displayName: "App preferences", kind: .system, iconName: "sf:slider.horizontal.3"),
        IdentityRule(id: "builtin-mdworker", key: .commandPattern, pattern: "mdworker*", displayName: "Spotlight indexing", kind: .system, iconName: "sf:magnifyingglass"),
        IdentityRule(id: "builtin-mds", key: .commandPattern, pattern: "mds", displayName: "Spotlight search", kind: .system, iconName: "sf:magnifyingglass"),
        IdentityRule(id: "builtin-replayd", key: .commandPattern, pattern: "replayd", displayName: "Screen recording service", kind: .system, iconName: "sf:record.circle"),
        IdentityRule(id: "builtin-swcd", key: .commandPattern, pattern: "swcd", displayName: "Shared web credentials", kind: .system, iconName: "sf:key.horizontal"),
        IdentityRule(id: "builtin-tccd", key: .commandPattern, pattern: "tccd", displayName: "Privacy permissions", kind: .system, iconName: "sf:hand.raised"),
        IdentityRule(id: "builtin-video-decoder", key: .commandPattern, pattern: "VTDecoderXPCService", displayName: "Video decoding", kind: .system, iconName: "sf:film"),
        IdentityRule(id: "builtin-shortcuts-runner", key: .commandPattern, pattern: "BackgroundShortcutRunner", displayName: "Shortcuts automation", kind: .system, iconName: "sf:wand.and.stars"),
        IdentityRule(id: "builtin-user-events", key: .commandPattern, pattern: "UserEventAgent", displayName: "System event delivery", kind: .system, iconName: "sf:bolt.horizontal.circle"),
        IdentityRule(id: "builtin-hi-services", key: .commandPattern, pattern: "com.apple.hiservices-xpcservice", displayName: "App launch services", kind: .system, iconName: "sf:app.badge"),
        IdentityRule(id: "builtin-cursor-ui", key: .commandPattern, pattern: "CursorUIViewService", displayName: "Text cursor service", kind: .system, iconName: "sf:text.cursor"),
        IdentityRule(id: "builtin-pboard", key: .commandPattern, pattern: "pboard", displayName: "Clipboard", kind: .system, iconName: "sf:doc.on.clipboard"),
        IdentityRule(id: "builtin-siri-knowledge", key: .commandPattern, pattern: "siriknowledged", displayName: "Siri knowledge", kind: .system, iconName: "sf:brain"),
        IdentityRule(id: "builtin-duet", key: .commandPattern, pattern: "duetexpertd", displayName: "Activity prediction", kind: .system, iconName: "sf:chart.line.uptrend.xyaxis"),
        IdentityRule(id: "builtin-biome", key: .commandPattern, pattern: "BiomeAgent", displayName: "On-device suggestions", kind: .system, iconName: "sf:lightbulb"),
        IdentityRule(id: "builtin-cloudd", key: .commandPattern, pattern: "cloudd", displayName: "iCloud sync", kind: .system, iconName: "sf:icloud"),
        IdentityRule(id: "builtin-contactsd", key: .commandPattern, pattern: "contactsd", displayName: "Contacts sync", kind: .system, iconName: "sf:person.2"),
        IdentityRule(id: "builtin-photo-analysis", key: .commandPattern, pattern: "photoanalysisd", displayName: "Photos analysis", kind: .system, iconName: "sf:photo"),
        IdentityRule(id: "builtin-file-provider", key: .commandPattern, pattern: "fileproviderd", displayName: "Cloud files", kind: .system, iconName: "sf:folder.badge.gearshape"),
        IdentityRule(id: "builtin-accounts", key: .commandPattern, pattern: "accountsd", displayName: "Internet accounts", kind: .system, iconName: "sf:person.crop.circle.badge.checkmark"),
        IdentityRule(id: "builtin-find-my", key: .commandPattern, pattern: "searchpartyuseragent", displayName: "Find My", kind: .system, iconName: "sf:location"),
        IdentityRule(id: "builtin-widget-renderer", key: .commandPattern, pattern: "*ThemeWidgetControlViewService*", displayName: "Widget rendering", kind: .helper, iconName: "sf:rectangle.stack"),
    ]
}
