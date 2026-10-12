import CryptoKit
import Foundation

/// Coding agents that load skills from folders in the home folder.
enum SkillAgent: String, CaseIterable, Identifiable, Sendable, Codable {
    case claude = "Claude Code", codex = "Codex", cursor = "Cursor", copilot = "Copilot", gemini = "Gemini CLI", opencode = "OpenCode"

    var id: Self { self }

    /// The agent's own settings folder, which exists once it has run here.
    var home: String {
        switch self {
        case .claude: "~/.claude"
        case .codex: "~/.codex"
        case .cursor: "~/.cursor"
        case .copilot: "~/.copilot"
        case .gemini: "~/.gemini"
        case .opencode: "~/.config/opencode"
        }
    }

    static var installed: [SkillAgent] {
        allCases.filter { FileManager.default.fileExists(atPath: ($0.home as NSString).expandingTildeInPath) }
    }
}

enum SkillSource: Hashable, Sendable {
    /// A folder the user put there, by hand or with a tool we can't tell apart.
    case folder
    /// Installed with `npx skills`; the value is the source repository.
    case skillsSh(String)
    case codexSystem
    case synced
    case plugin(String)

    /// Its app adds and removes it, so Devbar leaves it alone.
    var isManaged: Bool {
        switch self {
        case .folder, .skillsSh: false
        case .codexSystem, .synced, .plugin: true
        }
    }

    var title: String? {
        switch self {
        case .folder: nil
        case .skillsSh(let repository): repository
        case .codexSystem: "Built into Codex"
        case .synced: "Synced from claude.ai"
        case .plugin(let name): "\(name) plugin"
        }
    }
}

/// One skill folder, however many skill folders link to it.
struct Skill: Identifiable, Sendable, Hashable {
    enum Copies: Hashable, Sendable {
        case none
        /// Other folders hold the same files under the same name.
        case same([String])
        /// Other folders use the same name for different files.
        case different([String])
    }

    var name: String
    var description: String
    /// The real folder, with symlinks resolved. For a broken link, the link.
    var path: String
    /// Symlinks in skill folders that point at `path`.
    var links: [String]
    /// Section title: the skill folder or app it lives in.
    var location: String
    /// The real folder sits in a skill folder, rather than in an app that
    /// links it in. Broken links count, since the link is all there is.
    var isInSkillFolder: Bool
    var source: SkillSource
    var agents: [SkillAgent]
    var lines: Int
    var bytes: Int
    /// Problems the user can fix in SKILL.md. Empty for managed skills.
    var issues: [String]
    var isLong: Bool
    /// False when `disable-model-invocation` keeps its description out of context.
    var isModelInvocable: Bool
    var contentHash: String
    var copies: Copies = .none
    /// Agents that load more than one skill with this name.
    var loadedTwiceBy: [SkillAgent] = []
    var modified: Date
    var isBrokenLink: Bool

    var id: String { path }
    var skillFile: String { path + "/SKILL.md" }
    var hasCopies: Bool { copies != .none }
    var hasProblems: Bool { isBrokenLink || isLong || !issues.isEmpty }
    /// Devbar removes only what the user put there: never managed skills,
    /// and never an app's own files, only the links to them.
    var canTrash: Bool { !source.isManaged && (isInSkillFolder || !links.isEmpty) }
    /// The user's skill folders first, then folders apps keep, then managed skills.
    var locationRank: Int { source.isManaged ? 2 : isInSkillFolder ? 0 : 1 }

    /// About four characters a token, which is close for English prose.
    var tokens: Int { bytes / 4 }
    /// What sits in an agent's context every session: the name and
    /// description. Claude Code and Cursor leave out skills that turn off
    /// model invocation, and Claude Code cuts descriptions at 1,536 characters.
    func listingTokens(for agent: SkillAgent) -> Int {
        guard agents.contains(agent) else { return 0 }
        if !isModelInvocable, agent == .claude || agent == .cursor { return 0 }
        return (name.count + min(description.count, 1536)) / 4
    }

    /// Every path the skill can be reached by.
    var paths: [String] { [path] + links }

    static let maxLines = 500
}

/// Finds skills in the global skill folders each agent reads, following
/// the agents' own rules: symlinked skill folders count once, hidden
/// folders are skipped, and Codex also looks in subfolders.
enum SkillScanner {
    struct Root: Sendable {
        var path: String
        var agents: Set<SkillAgent>
        var recursive: Bool
        var source: SkillSource = .folder
    }

    /// Global skill folders and who reads them, from each agent's docs.
    static func roots(home: String = NSHomeDirectory()) -> [Root] {
        [
            Root(path: home + "/.claude/skills", agents: [.claude, .cursor, .opencode], recursive: false),
            Root(path: home + "/.agents/skills", agents: [.codex, .cursor, .copilot, .gemini, .opencode], recursive: true),
            // Codex still reads its older location, and Cursor reads it too.
            Root(path: home + "/.codex/skills", agents: [.codex, .cursor], recursive: true),
            Root(path: home + "/.codex/skills/.system", agents: [.codex], recursive: true, source: .codexSystem),
            Root(path: "/etc/codex/skills", agents: [.codex], recursive: true),
            Root(path: home + "/.cursor/skills", agents: [.cursor], recursive: false),
            Root(path: home + "/.copilot/skills", agents: [.copilot], recursive: false),
            Root(path: home + "/.gemini/skills", agents: [.gemini], recursive: false),
            Root(path: home + "/.config/opencode/skills", agents: [.opencode], recursive: false),
        ] + claudeRoots(home: home)
    }

    static func scan() async -> [Skill] {
        await Task.detached(priority: .userInitiated) {
            scanNow(roots: roots(), installed: Set(SkillAgent.installed))
        }.value
    }

    /// Moves skills to the Trash. A folder in a skill folder goes with every
    /// link to it; a folder another app keeps elsewhere stays, and only the
    /// links to it go.
    static func trash(_ skill: Skill) throws {
        let fm = FileManager.default
        guard skill.canTrash else { return }
        for link in skill.links { try fm.trashItem(at: URL(fileURLWithPath: link), resultingItemURL: nil) }
        if skill.isInSkillFolder {
            try fm.trashItem(at: URL(fileURLWithPath: skill.path), resultingItemURL: nil)
        }
    }

    // MARK: - Scanning

    private struct Entry {
        var root: Root
        /// Where the agent finds it: the folder itself or a symlink to it.
        var path: String
        var real: String
        var isLink: Bool
    }

    private static func scanNow(roots: [Root], installed: Set<SkillAgent>) -> [Skill] {
        var entries: [Entry] = []
        var broken: [Skill] = []
        for root in roots {
            var visited = Set<String>()
            walk(root.path, depth: 1, root: root, visited: &visited, entries: &entries, broken: &broken)
        }
        let lock = skillsShSources()
        var skills: [Skill] = []
        for (real, group) in Dictionary(grouping: entries, by: \.real) {
            let owner = group.first { !$0.isLink } ?? group[0]
            var agents = Set<SkillAgent>()
            for entry in group { agents.formUnion(entry.root.agents) }
            var source = owner.root.source
            let folderName = (real as NSString).lastPathComponent
            if source == .folder, let repository = lock[folderName],
               group.contains(where: { $0.root.path.hasSuffix("/.agents/skills") }) {
                source = .skillsSh(repository)
            }
            let enclosing = roots.filter { $0.source == .folder && real.hasPrefix(realPath($0.path) + "/") }
                .max { $0.path.count < $1.path.count }
            skills.append(skill(
                at: real,
                links: group.filter(\.isLink).map(\.path).sorted(),
                location: source.isManaged ? source.title ?? "" : abbreviated(enclosing?.path ?? (real as NSString).deletingLastPathComponent),
                isInSkillFolder: enclosing != nil,
                source: source,
                agents: SkillAgent.allCases.filter { agents.contains($0) && installed.contains($0) }
            ))
        }
        markCopies(&skills)
        return skills + broken
    }

    private static func walk(_ directory: String, depth: Int, root: Root, visited: inout Set<String>, entries: inout [Entry], broken: inout [Skill]) {
        let fm = FileManager.default
        guard visited.insert(realPath(directory)).inserted,
              let names = try? fm.contentsOfDirectory(atPath: directory) else { return }
        for name in names.sorted() where !name.hasPrefix(".") {
            // Claude Code keeps claude.ai skills here and scans them separately.
            if depth == 1, root.agents.contains(.claude), root.source == .folder, name.lowercased() == "synced" { continue }
            let path = directory + "/" + name
            let isLink = (try? fm.destinationOfSymbolicLink(atPath: path)) != nil
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDirectory) else {
                if isLink { broken.append(brokenLink(path, root: root)) }
                continue
            }
            guard isDirectory.boolValue else { continue }
            if fm.fileExists(atPath: path + "/SKILL.md") {
                entries.append(Entry(root: root, path: path, real: realPath(path), isLink: isLink))
            } else if root.recursive, depth < 4 {
                walk(path, depth: depth + 1, root: root, visited: &visited, entries: &entries, broken: &broken)
            }
        }
    }

    private static func skill(at path: String, links: [String], location: String, isInSkillFolder: Bool, source: SkillSource, agents: [SkillAgent]) -> Skill {
        let folderName = (path as NSString).lastPathComponent
        let data = FileManager.default.contents(atPath: path + "/SKILL.md") ?? Data()
        let text = String(decoding: data, as: UTF8.self)
        let front = FrontMatter.parse(text)
        let lines = text.reduce(into: 0) { count, character in if character == "\n" { count += 1 } }
        var name = front?["name"] ?? folderName
        if case .plugin(let plugin) = source { name = plugin + ":" + name }
        let modified = (try? FileManager.default.attributesOfItem(atPath: path + "/SKILL.md"))?[.modificationDate] as? Date
        return Skill(
            name: name,
            description: front?["description"] ?? "",
            path: path,
            links: links,
            location: location,
            isInSkillFolder: isInSkillFolder,
            source: source,
            agents: agents,
            lines: lines,
            bytes: data.count,
            issues: source.isManaged ? [] : issues(front: front, folderName: folderName),
            isLong: !source.isManaged && lines > Skill.maxLines,
            isModelInvocable: front?["disable-model-invocation"]?.lowercased() != "true",
            contentHash: contentHash(of: path),
            modified: modified ?? .distantPast,
            isBrokenLink: false
        )
    }

    private static func brokenLink(_ path: String, root: Root) -> Skill {
        let target = (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) ?? ""
        return Skill(
            name: (path as NSString).lastPathComponent,
            description: "Points to \(abbreviated(target)), which is gone.",
            path: path, links: [], location: abbreviated(root.path), isInSkillFolder: true, source: root.source,
            agents: [], lines: 0, bytes: 0, issues: [], isLong: false, isModelInvocable: false,
            contentHash: "", modified: .distantPast, isBrokenLink: true
        )
    }

    /// The Agent Skills spec's rules, which every agent can load.
    /// https://agentskills.io/specification
    private static func issues(front: [String: String]?, folderName: String) -> [String] {
        guard let front else { return ["SKILL.md has no front matter"] }
        var issues: [String] = []
        let description = front["description"] ?? ""
        if description.isEmpty {
            issues.append("No description, so agents can't tell when to use it")
        } else if description.count > 1024 {
            issues.append("The description is over 1,024 characters")
        }
        if let name = front["name"] {
            if name != folderName {
                issues.append("The name \u{201C}\(name)\u{201D} doesn't match its folder \u{201C}\(folderName)\u{201D}")
            }
            if name.count > 64 || name.range(of: "^[a-z0-9]+(-[a-z0-9]+)*$", options: .regularExpression) == nil {
                issues.append("Names use lowercase letters, numbers, and single hyphens, up to 64 characters")
            }
        }
        return issues
    }

    /// Same name, different folders: the same files twice, or different ones.
    /// Plugin and synced skills are namespaced, so they never clash.
    private static func markCopies(_ skills: inout [Skill]) {
        let candidates = skills.indices.filter {
            switch skills[$0].source {
            case .plugin, .synced: false
            default: true
            }
        }
        for indices in Dictionary(grouping: candidates, by: { skills[$0].name.lowercased() }).values where indices.count > 1 {
            let isSame = Set(indices.map { skills[$0].contentHash }).count == 1
            var counts: [SkillAgent: Int] = [:]
            for index in indices { for agent in skills[index].agents { counts[agent, default: 0] += 1 } }
            let twice = SkillAgent.allCases.filter { (counts[$0] ?? 0) > 1 }
            for index in indices {
                let others = indices.filter { $0 != index }.map { skills[$0].path }
                skills[index].copies = isSame ? .same(others) : .different(others)
                skills[index].loadedTwiceBy = twice.filter { skills[index].agents.contains($0) }
            }
        }
    }

    // MARK: - Claude Code

    /// claude.ai skills and plugins, plus plugins installed from marketplaces.
    private static func claudeRoots(home: String) -> [Root] {
        var roots: [Root] = []
        if let bucket = newestBucket(home + "/.claude/skills/synced") {
            roots.append(Root(path: bucket, agents: [.claude], recursive: false, source: .synced))
        }
        let settings = Home.file(home + "/.claude/settings.json").flatMap(JSON.object)
        let enabled = JSON.dict(settings?["enabledPlugins"]) ?? [:]
        if let bucket = newestBucket(home + "/.claude/plugins/synced") {
            for folder in (try? FileManager.default.contentsOfDirectory(atPath: bucket)) ?? [] where !folder.hasPrefix(".") {
                // Folders are `<name>~g<generation>`.
                let name = String(folder.split(separator: "~").first ?? Substring(folder))
                guard enabled[name + "@synced"] as? Bool != false else { continue }
                roots.append(Root(path: bucket + "/" + folder + "/skills", agents: [.claude], recursive: false, source: .plugin(name)))
            }
        }
        // `{"plugins": {"<name>@<marketplace>": [{"scope": "user", "installPath": …}]}}`
        let installed = Home.file(home + "/.claude/plugins/installed_plugins.json").flatMap(JSON.object)
        for (id, records) in JSON.dict(installed?["plugins"]) ?? [:] where enabled[id] as? Bool == true {
            let name = String(id.split(separator: "@").first ?? Substring(id))
            for record in records as? [[String: Any]] ?? [] where record["scope"] as? String == "user" {
                guard let path = JSON.text(record["installPath"]) else { continue }
                roots.append(Root(path: path + "/skills", agents: [.claude], recursive: false, source: .plugin(name)))
            }
        }
        return roots
    }

    /// Claude Code keeps a folder per claude.ai account it has signed in
    /// with. Only the most recently synced one is current.
    private static func newestBucket(_ directory: String) -> String? {
        let fm = FileManager.default
        let folders = ((try? fm.contentsOfDirectory(atPath: directory)) ?? [])
            .filter { !$0.hasPrefix(".") }
            .map { directory + "/" + $0 }
        return folders.max { modified($0) < modified($1) }
    }

    private static func modified(_ path: String) -> Date {
        ((try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date) ?? .distantPast
    }

    // MARK: - Helpers

    /// `npx skills` records what it installed in `~/.agents/.skill-lock.json`.
    private static func skillsShSources() -> [String: String] {
        let state = Home.env("XDG_STATE_HOME").map { $0 + "/skills/.skill-lock.json" }
        let lock = (state.flatMap(Home.file) ?? Home.file("~/.agents/.skill-lock.json")).flatMap(JSON.object)
        var sources: [String: String] = [:]
        for (name, value) in JSON.dict(lock?["skills"]) ?? [:] {
            if let source = JSON.text(JSON.dict(value)?["source"]) { sources[name] = source }
        }
        return sources
    }

    /// Every file's path and contents, so renamed or edited files count.
    private static func contentHash(of folder: String) -> String {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: folder) else { return "" }
        var files: [String] = []
        while let file = enumerator.nextObject() as? String {
            let name = (file as NSString).lastPathComponent
            if name == ".git" { enumerator.skipDescendants(); continue }
            if name == ".DS_Store" { continue }
            if (enumerator.fileAttributes?[.type] as? FileAttributeType) == .typeRegular { files.append(file) }
        }
        var hasher = SHA256()
        for file in files.sorted() {
            hasher.update(data: Data(file.utf8))
            if let data = fm.contents(atPath: folder + "/" + file) { hasher.update(data: data) }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func realPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    static func abbreviated(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path == home || path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}

/// The handful of YAML shapes SKILL.md front matter uses: `key: value`,
/// quoted strings, `|` and `>` blocks, and plain text wrapped onto
/// indented lines. Nested maps are skipped.
enum FrontMatter {
    static func parse(_ text: String) -> [String: String]? {
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else { return nil }
        lines = Array(lines[1..<end])
        var fields: [String: String] = [:]
        var index = 0
        while index < lines.count {
            let line = lines[index]
            index += 1
            guard let colon = line.firstIndex(of: ":"), !line.hasPrefix(" "), !line.hasPrefix("\t"), !line.hasPrefix("#") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            // Following indented lines belong to this key.
            var continuation: [String] = []
            while index < lines.count, lines[index].isEmpty || lines[index].hasPrefix(" ") || lines[index].hasPrefix("\t") {
                continuation.append(lines[index].trimmingCharacters(in: .whitespaces))
                index += 1
            }
            while continuation.last?.isEmpty == true { continuation.removeLast() }
            if value.hasPrefix("|") {
                value = continuation.joined(separator: "\n")
            } else if value.hasPrefix(">") {
                value = continuation.joined(separator: " ")
            } else if value.isEmpty {
                // A nested map or list, which no field we read uses.
                continue
            } else {
                value = ([value] + continuation.filter { !$0.isEmpty }).joined(separator: " ")
            }
            fields[key] = unquoted(value).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return fields
    }

    private static func unquoted(_ value: String) -> String {
        if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
            return String(value.dropFirst().dropLast())
                .replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\n", with: "\n")
                .replacingOccurrences(of: "\\\\", with: "\\")
        }
        if value.count >= 2, value.hasPrefix("'"), value.hasSuffix("'") {
            return String(value.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        return value
    }
}
