import AppKit
import QuickLook
import SwiftUI

/// Skills found on this Mac. Scans only while the window is open.
@MainActor
@Observable
final class SkillStore {
    private(set) var skills: [Skill] = []
    private(set) var isScanning = false
    private(set) var hasScanned = false
    var failure: String?

    func scan() async {
        guard !isScanning else { return }
        isScanning = true
        skills = await SkillScanner.scan()
        isScanning = false
        hasScanned = true
    }

    func trash(_ targets: [Skill]) async {
        var errors: [String] = []
        for skill in targets {
            do {
                try SkillScanner.trash(skill)
            } catch {
                errors.append("\(skill.name): \(error.localizedDescription)")
            }
        }
        if !errors.isEmpty { failure = errors.joined(separator: "\n") }
        // Copies and links change with every removal, so look again.
        await scan()
    }
}

enum SkillFilter: String, CaseIterable, Identifiable {
    case all = "All", duplicates = "Duplicates", issues = "Issues"

    var id: Self { self }

    func includes(_ skill: Skill) -> Bool {
        switch self {
        case .all: true
        case .duplicates: skill.hasCopies
        case .issues: skill.hasProblems
        }
    }

    var emptyTitle: String {
        switch self {
        case .all: "No Skills"
        case .duplicates: "No Duplicate Skills"
        case .issues: "No Skills with Issues"
        }
    }
}

enum SkillSort: String, CaseIterable, Identifiable {
    case name = "Name", size = "Size", recent = "Recently Changed"

    var id: Self { self }
}

struct SkillsView: View {
    let store: SkillStore
    @State private var selection: Set<Skill.ID> = []
    @State private var filter = SkillFilter.all
    @State private var pendingTrash: [Skill] = []
    @State private var previewURL: URL?
    /// Raw value of the agent to show, or empty for every agent.
    @AppStorage("skills.agent") private var agentName = ""
    @AppStorage("skills.sort") private var sort = SkillSort.name
    /// Collapsed section titles, one per line.
    @AppStorage("skills.collapsedSections") private var collapsedNames = ""

    var body: some View {
        content
            .frame(minWidth: 520, idealWidth: 600, minHeight: 280, idealHeight: 480)
            .safeAreaInset(edge: .top, spacing: 0) { toolbar }
            .safeAreaInset(edge: .bottom, spacing: 0) { footer }
            .quickLookPreview($previewURL)
            .onChange(of: filter) { selection.formIntersection(displayed.map(\.id)) }
            .onChange(of: agentName) { selection.formIntersection(displayed.map(\.id)) }
            .alert(trashTitle, isPresented: confirming) {
                Button("Move to Trash", role: .destructive) {
                    let targets = pendingTrash
                    Task {
                        await store.trash(targets)
                        selection.subtract(targets.map(\.id))
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(trashMessage)
            }
            .alert("Couldn't Move to Trash", isPresented: failed) {
                Button("OK") {}
            } message: {
                Text(store.failure ?? "")
            }
    }

    // MARK: - What's shown

    private var agent: SkillAgent? { SkillAgent(rawValue: agentName) }

    /// Agents that load at least one skill, for the agent menu.
    private var agents: [SkillAgent] {
        SkillAgent.allCases.filter { agent in store.skills.contains { $0.agents.contains(agent) } }
    }

    private var matching: [Skill] {
        store.skills.filter { skill in filter.includes(skill) && (agent.map { skill.agents.contains($0) } ?? true) }
    }

    /// Sections by where skills live; duplicates by name, so copies sit together.
    private var groups: [(title: String, skills: [Skill])] {
        let byName = filter == .duplicates
        // Agents match names regardless of case, so copies do too.
        return Dictionary(grouping: matching, by: { byName ? $0.name.lowercased() : $0.location })
            .map { byName ? ($0.value[0].name, $0.value.sorted(by: sortOrder)) : ($0.key, $0.value.sorted(by: sortOrder)) }
            .sorted { a, b in
                let aRank = byName ? 0 : a.skills[0].locationRank
                let bRank = byName ? 0 : b.skills[0].locationRank
                if aRank != bRank { return aRank < bRank }
                return a.title.localizedStandardCompare(b.title) == .orderedAscending
            }
    }

    private func sortOrder(_ a: Skill, _ b: Skill) -> Bool {
        switch sort {
        case .name: a.name.localizedStandardCompare(b.name) == .orderedAscending
        case .size: a.bytes > b.bytes
        case .recent: a.modified > b.modified
        }
    }

    private var collapsed: Set<String> { Set(collapsedNames.split(separator: "\n").map(String.init)) }

    /// Rows on screen. Selecting and trashing only ever act on these, so
    /// nothing hidden is removed.
    private var displayed: [Skill] {
        groups.filter { !collapsed.contains($0.title) }.flatMap(\.skills)
    }

    private var selected: [Skill] {
        displayed.filter { selection.contains($0.id) }
    }

    private var trashable: [Skill] { selected.filter(\.canTrash) }

    private func isExpanded(_ title: String) -> Binding<Bool> {
        Binding(
            get: { !collapsed.contains(title) },
            set: { expanded in
                var names = collapsed
                if expanded {
                    names.remove(title)
                } else {
                    names.insert(title)
                    let hidden = groups.first { $0.title == title }?.skills.map(\.id) ?? []
                    selection.subtract(hidden)
                }
                collapsedNames = names.sorted().joined(separator: "\n")
            }
        )
    }

    // MARK: - Layout

    @ViewBuilder private var content: some View {
        if !store.hasScanned {
            ProgressView("Looking for skills…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if store.skills.isEmpty {
            ContentUnavailableView(
                "No Skills",
                systemImage: "sparkles",
                description: Text("Skills in ~/.claude/skills, ~/.agents/skills, and other agents' skill folders show up here.")
            )
        } else if groups.isEmpty {
            ContentUnavailableView(filter.emptyTitle, systemImage: "line.3.horizontal.decrease.circle")
        } else {
            list
        }
    }

    private var list: some View {
        List(selection: $selection) {
            ForEach(groups, id: \.title) { group in
                let isExpanded = isExpanded(group.title)
                Section {
                    if isExpanded.wrappedValue {
                        ForEach(group.skills) { skill in
                            SkillRow(skill: skill, showsLocation: filter == .duplicates, onTrash: skill.canTrash ? { pendingTrash = [skill] } : nil)
                        }
                    }
                } header: {
                    CollapsibleHeader(title: group.title, count: group.skills.count, noun: "skills", isExpanded: isExpanded)
                }
            }
        }
        .contextMenu(forSelectionType: Skill.ID.self) { ids in
            rowMenu(store.skills.filter { ids.contains($0.id) })
        } primaryAction: { ids in
            open(store.skills.filter { ids.contains($0.id) })
        }
        .onDeleteCommand { trashSelection() }
        .onKeyPress(.space) { togglePreview() }
    }

    @ViewBuilder private func rowMenu(_ targets: [Skill]) -> some View {
        if !targets.isEmpty {
            let skills = targets.filter { !$0.isBrokenLink }
            Button(skills.count > 1 ? "Open \(skills.count) Skills" : "Open SKILL.md") { open(skills) }
                .disabled(skills.isEmpty)
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting(targets.map { URL(fileURLWithPath: $0.path) })
            }
            Button(targets.count == 1 ? "Copy Path" : "Copy Paths") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(targets.map(\.path).joined(separator: "\n"), forType: .string)
            }
            let removable = targets.filter(\.canTrash)
            if !removable.isEmpty {
                Divider()
                Button(removable.count == 1 ? "Move to Trash…" : "Move \(removable.count) Skills to Trash…") { pendingTrash = removable }
            }
        }
    }

    private var toolbar: some View {
        HStack {
            Picker("Show", selection: $filter) {
                ForEach(SkillFilter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Duplicates share a name with another skill folder. Issues are broken links, long files, and front matter problems.")
            Picker("Agent", selection: $agentName) {
                Text("All Agents").tag("")
                Divider()
                ForEach(agents) { Text($0.rawValue).tag($0.rawValue) }
            }
            .labelsHidden()
            .fixedSize()
            .help("Show the skills one agent loads")
            Spacer()
            if store.isScanning && store.hasScanned {
                ProgressView().controlSize(.small)
            }
            Menu {
                Picker("Sort By", selection: $sort) {
                    ForEach(SkillSort.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Label("Sort", systemImage: "arrow.up.arrow.down")
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Sort by")
            Button {
                Task { await store.scan() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .labelStyle(.iconOnly)
            .keyboardShortcut("r")
            .help("Look for skills again (⌘R)")
            .disabled(store.isScanning)
        }
        .padding(10)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var footer: some View {
        HStack {
            Text(summary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(summaryHelp)
            Spacer()
            Button(trashLabel) { trashSelection() }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(trashable.isEmpty)
                .help("Move the selected skills to the Trash (⌘⌫)")
        }
        .padding(10)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    /// What one agent pays for its skills before any of them is used.
    private var summary: String {
        guard let agent else {
            let count = store.skills.filter { !$0.isBrokenLink }.count
            return count == 1 ? "1 skill" : "\(count) skills"
        }
        let skills = store.skills.filter { $0.agents.contains(agent) }
        let tokens = skills.reduce(0) { $0 + $1.listingTokens(for: agent) }
        return "\(agent.rawValue) loads \(skills.count) skills · about \(Self.tokenCount(tokens)) tokens of descriptions"
    }

    private var summaryHelp: String {
        guard agent != nil else { return "" }
        return "Each skill's name and description sit in the agent's context in every session, so it knows when to use them. The rest of SKILL.md loads only when a skill is used."
    }

    private var trashLabel: String {
        trashable.count > 1 ? "Move \(trashable.count) to Trash" : "Move to Trash"
    }

    private func trashSelection() {
        guard !trashable.isEmpty else { return }
        pendingTrash = trashable
    }

    private func open(_ skills: [Skill]) {
        for skill in skills where !skill.isBrokenLink {
            NSWorkspace.shared.open(URL(fileURLWithPath: skill.skillFile))
        }
    }

    /// Space opens Quick Look on the first selected SKILL.md, and closes it.
    private func togglePreview() -> KeyPress.Result {
        if previewURL != nil {
            previewURL = nil
            return .handled
        }
        guard let skill = selected.first(where: { !$0.isBrokenLink }) else { return .ignored }
        previewURL = URL(fileURLWithPath: skill.skillFile)
        return .handled
    }

    static func tokenCount(_ tokens: Int) -> String {
        tokens < 1000 ? "\(tokens)" : (Double(tokens) / 1000).formatted(.number.precision(.fractionLength(1))) + "k"
    }

    // MARK: - Confirming

    private var confirming: Binding<Bool> {
        Binding(get: { !pendingTrash.isEmpty }, set: { if !$0 { pendingTrash = [] } })
    }

    private var failed: Binding<Bool> {
        Binding(get: { store.failure != nil }, set: { if !$0 { store.failure = nil } })
    }

    private var trashTitle: String {
        if pendingTrash.count == 1, let skill = pendingTrash.first {
            return "Move \u{201C}\(skill.name)\u{201D} to the Trash?"
        }
        return "Move \(pendingTrash.count) skills to the Trash?"
    }

    /// Says what moves, since a skill can be one folder with links to it
    /// from several agents' folders.
    private var trashMessage: String {
        if pendingTrash.count == 1, let skill = pendingTrash.first {
            if skill.isBrokenLink { return "The link goes nowhere, so nothing else changes." }
            let folders = skill.links.map { SkillScanner.abbreviated(($0 as NSString).deletingLastPathComponent) }
                .formatted(.list(type: .and))
            let noun = skill.links.count == 1 ? "link" : "links"
            var lines: [String]
            if !skill.isInSkillFolder {
                let home = SkillScanner.abbreviated((skill.path as NSString).deletingLastPathComponent)
                lines = ["Its \(noun) in \(folders) \(skill.links.count == 1 ? "moves" : "move") to the Trash. Its files stay in \(home), where an app put them."]
            } else if skill.links.isEmpty {
                lines = ["The folder moves to the Trash."]
            } else {
                lines = ["The folder moves to the Trash, along with its \(noun) in \(folders)."]
            }
            lines.append("Agents stop loading it once they restart.")
            if case .skillsSh(let repository) = skill.source {
                lines.append("npx skills still lists it as installed from \(repository).")
            }
            return lines.joined(separator: "\n\n")
        }
        let links = pendingTrash.reduce(0) { $0 + $1.links.count + ($1.isBrokenLink ? 1 : 0) }
        let folders = pendingTrash.filter { $0.isInSkillFolder && !$0.isBrokenLink }.count
        var parts: [String] = []
        if folders > 0 { parts.append(folders == 1 ? "1 folder" : "\(folders) folders") }
        if links > 0 { parts.append(links == 1 ? "1 link" : "\(links) links") }
        return "\(parts.formatted(.list(type: .and)).capitalizedFirst) move to the Trash. Skills that apps put elsewhere keep their files. Agents stop loading them once they restart."
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

private struct SkillRow: View {
    let skill: Skill
    /// Duplicates are grouped by name, so the row says where it lives.
    let showsLocation: Bool
    let onTrash: (() -> Void)?
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(showsLocation ? skill.location : skill.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .help(help)
            Spacer(minLength: 8)
            pills
            // Space stays reserved so pills don't shift when the button shows.
            ZStack {
                if isHovering, let onTrash {
                    Button(action: onTrash) {
                        Label("Move to Trash", systemImage: "trash")
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Move to Trash")
                }
            }
            .frame(width: 18)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .modifier(TrashActions(onTrash: onTrash))
    }

    @ViewBuilder private var pills: some View {
        if skill.isBrokenLink {
            StatusPill(title: "Broken Link", color: .red)
                .help("The link points to a folder that's gone")
        }
        switch skill.copies {
        case .none: EmptyView()
        case .same(let others):
            StatusPill(title: "Duplicate", color: .orange)
                .help("The same files are also in \(Self.folders(others)).\(twiceText) A symlink to one copy keeps them in step.")
        case .different(let others):
            StatusPill(title: "Differs", color: .red)
                .help("A skill with this name but different files is in \(Self.folders(others)).\(twiceText)")
        }
        if skill.isLong {
            StatusPill(title: "\(skill.lines) lines", color: .secondary)
                .help("SKILL.md is over \(Skill.maxLines) lines. Moving detail into separate files keeps it quick to load.")
        }
        if !skill.issues.isEmpty {
            StatusPill(title: skill.issues.count == 1 ? "Issue" : "\(skill.issues.count) Issues", color: .orange)
                .help(skill.issues.joined(separator: "\n"))
        }
    }

    private var twiceText: String {
        skill.loadedTwiceBy.isEmpty ? "" : " \(skill.loadedTwiceBy.map(\.rawValue).formatted(.list(type: .and))) \(skill.loadedTwiceBy.count == 1 ? "loads" : "load") both."
    }

    private static func folders(_ paths: [String]) -> String {
        paths.map { SkillScanner.abbreviated(($0 as NSString).deletingLastPathComponent) }.formatted(.list(type: .and))
    }

    /// Which agents load it, where it came from, and its size.
    private var detail: String {
        if skill.isBrokenLink { return skill.description }
        var parts = [skill.agents.isEmpty ? "No agent loads it" : skill.agents.map(\.rawValue).formatted(.list(type: .and))]
        if case .skillsSh(let repository) = skill.source { parts.append(repository) }
        parts.append("\(SkillsView.tokenCount(skill.tokens)) tokens")
        return parts.joined(separator: " · ")
    }

    private var help: String {
        var lines = [skill.description.isEmpty ? "No description" : skill.description, "", SkillScanner.abbreviated(skill.path)]
        lines += skill.links.map { "Linked from " + SkillScanner.abbreviated($0) }
        return lines.joined(separator: "\n")
    }
}

/// Swipe and VoiceOver actions, only for skills Devbar can remove.
private struct TrashActions: ViewModifier {
    let onTrash: (() -> Void)?

    func body(content: Content) -> some View {
        if let onTrash {
            content
                .swipeActions(edge: .trailing) {
                    Button("Move to Trash", systemImage: "trash", action: onTrash)
                        .tint(.red)
                }
                .accessibilityAction(named: "Move to Trash", onTrash)
        } else {
            content
        }
    }
}

/// The one Skills window, created on first use and reused after. Every
/// open rescans, so the list matches the disk.
@MainActor
final class SkillsWindow {
    private var window: NSWindow?
    private var store: SkillStore?

    func show() {
        let store = self.store ?? SkillStore()
        self.store = store
        let window = self.window ?? makeWindow(store: store)
        self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        Task { await store.scan() }
    }

    private func makeWindow(store: SkillStore) -> NSWindow {
        let window = NSWindow(contentViewController: NSHostingController(rootView: SkillsView(store: store)))
        window.title = "Skills"
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 600, height: 520))
        // Open on the Space the menu was used from, even over a full-screen app.
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.center()
        return window
    }
}
