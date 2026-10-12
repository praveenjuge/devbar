import AppKit
import QuickLook
import SwiftUI

/// Worktrees found on this Mac. Scans only while the window is open.
@MainActor
@Observable
final class WorktreeStore {
    private(set) var worktrees: [Worktree] = []
    private(set) var isScanning = false
    private(set) var hasScanned = false
    private(set) var deleting: Set<String> = []
    var failure: String?

    func scan() async {
        guard !isScanning else { return }
        isScanning = true
        worktrees = await WorktreeScanner.scan()
        isScanning = false
        hasScanned = true
    }

    func delete(_ targets: [Worktree], deleteMergedBranches: Bool) async {
        var errors: [String] = []
        for worktree in targets {
            deleting.insert(worktree.id)
            do {
                try await WorktreeScanner.delete(worktree, deleteMergedBranch: deleteMergedBranches)
                worktrees.removeAll { $0.id == worktree.id }
            } catch {
                errors.append("\(worktree.name): \(error.localizedDescription)")
            }
            deleting.remove(worktree.id)
        }
        guard !errors.isEmpty else { return }
        failure = errors.joined(separator: "\n")
        // A failed removal can still get partway, so show what's left.
        await scan()
    }
}

enum WorktreeFilter: String, CaseIterable, Identifiable {
    case all = "All", merged = "Merged", changes = "Has Changes", stale = "Stale"

    var id: Self { self }

    func includes(_ worktree: Worktree) -> Bool {
        switch self {
        case .all: true
        case .merged: worktree.isMerged
        case .changes: worktree.hasChanges
        case .stale: worktree.isStale
        }
    }

    var emptyTitle: String {
        switch self {
        case .all: "No Worktrees"
        case .merged: "No Merged Worktrees"
        case .changes: "No Worktrees with Changes"
        case .stale: "No Stale Worktrees"
        }
    }
}

enum WorktreeSort: String, CaseIterable, Identifiable {
    case recent = "Recently Used", name = "Name"

    var id: Self { self }
}

/// Quick picks in the Select menu. Locked worktrees are never picked:
/// Claude Code locks its own while an agent is still running in it.
enum WorktreePick: CaseIterable, Identifiable {
    case merged, clean, missing, agents, olderThanDay, olderThanWeek, olderThanMonth

    var id: Self { self }

    var title: String {
        switch self {
        case .merged: "Merged"
        case .clean: "No Changes"
        case .missing: "Missing Folders"
        case .agents: "Agent Worktrees"
        case .olderThanDay: "Older Than a Day"
        case .olderThanWeek: "Older Than a Week"
        case .olderThanMonth: "Older Than a Month"
        }
    }

    func matches(_ worktree: Worktree) -> Bool {
        guard !worktree.isLocked else { return false }
        return switch self {
        case .merged: worktree.isMerged
        case .clean: !worktree.hasChanges
        case .missing: worktree.isMissing
        case .agents: worktree.isAgent
        case .olderThanDay: worktree.lastActive < Date(timeIntervalSinceNow: -86400)
        case .olderThanWeek: worktree.lastActive < Date(timeIntervalSinceNow: -Worktree.staleAge)
        case .olderThanMonth: worktree.lastActive < Date(timeIntervalSinceNow: -30 * 86400)
        }
    }
}

struct WorktreesView: View {
    let store: WorktreeStore
    @State private var selection: Set<Worktree.ID> = []
    @State private var filter = WorktreeFilter.all
    @State private var pendingDelete: [Worktree] = []
    @State private var previewURL: URL?
    @AppStorage("worktrees.deleteMergedBranches") private var deleteMergedBranches = true
    @AppStorage("worktrees.sort") private var sort = WorktreeSort.recent
    /// Collapsed repository names, one per line.
    @AppStorage("worktrees.collapsedRepositories") private var collapsedNames = ""

    var body: some View {
        content
            .frame(minWidth: 480, idealWidth: 540, minHeight: 280, idealHeight: 440)
            .safeAreaInset(edge: .top, spacing: 0) { toolbar }
            .safeAreaInset(edge: .bottom, spacing: 0) { footer }
            .quickLookPreview($previewURL)
            .onChange(of: filter) { selection.formIntersection(displayed.map(\.id)) }
            .alert(deleteTitle, isPresented: confirming) {
                Button("Delete", role: .destructive) {
                    let targets = pendingDelete
                    let deleteBranches = deleteMergedBranches
                    Task {
                        await store.delete(targets, deleteMergedBranches: deleteBranches)
                        selection.subtract(targets.map(\.id))
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(deleteMessage)
            }
            .alert("Couldn't Delete", isPresented: failed) {
                Button("OK") {}
            } message: {
                Text(store.failure ?? "")
            }
    }

    // MARK: - What's shown

    /// Repositories by name, then worktrees in the chosen order.
    private var groups: [(repository: String, worktrees: [Worktree])] {
        Dictionary(grouping: store.worktrees.filter(filter.includes), by: \.repository)
            .map { ($0.key, $0.value.sorted(by: sortOrder)) }
            .sorted { $0.repository.localizedStandardCompare($1.repository) == .orderedAscending }
    }

    private func sortOrder(_ a: Worktree, _ b: Worktree) -> Bool {
        switch sort {
        case .recent: a.lastActive > b.lastActive
        case .name: a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    private var collapsed: Set<String> { Set(collapsedNames.split(separator: "\n").map(String.init)) }

    /// Rows on screen: matching the filter, in expanded sections. Picks and
    /// deletes only ever act on these, so nothing hidden gets deleted.
    private var displayed: [Worktree] {
        groups.filter { !collapsed.contains($0.repository) }.flatMap(\.worktrees)
    }

    private var selected: [Worktree] {
        displayed.filter { selection.contains($0.id) && !store.deleting.contains($0.id) }
    }

    private func isExpanded(_ repository: String) -> Binding<Bool> {
        Binding(
            get: { !collapsed.contains(repository) },
            set: { expanded in
                var names = collapsed
                if expanded {
                    names.remove(repository)
                } else {
                    names.insert(repository)
                    selection.subtract(store.worktrees.filter { $0.repository == repository }.map(\.id))
                }
                collapsedNames = names.sorted().joined(separator: "\n")
            }
        )
    }

    // MARK: - Layout

    @ViewBuilder private var content: some View {
        if !store.hasScanned {
            ProgressView("Looking for worktrees…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if store.worktrees.isEmpty {
            ContentUnavailableView(
                "No Worktrees",
                systemImage: "arrow.triangle.branch",
                description: Text("Git worktrees in your home folder show up here.")
            )
        } else if groups.isEmpty {
            ContentUnavailableView(filter.emptyTitle, systemImage: "line.3.horizontal.decrease.circle")
        } else {
            list
        }
    }

    private var list: some View {
        List(selection: $selection) {
            ForEach(groups, id: \.repository) { group in
                let isExpanded = isExpanded(group.repository)
                let merged = group.worktrees.filter(WorktreePick.merged.matches)
                Section {
                    if isExpanded.wrappedValue {
                        ForEach(group.worktrees) { worktree in
                            WorktreeRow(worktree: worktree, isDeleting: store.deleting.contains(worktree.id)) {
                                pendingDelete = [worktree]
                            }
                        }
                    }
                } header: {
                    CollapsibleHeader(
                        title: group.repository,
                        count: group.worktrees.count,
                        noun: "worktrees",
                        isExpanded: isExpanded,
                        action: merged.isEmpty ? nil : (
                            "Select Merged",
                            "Select this repository's merged worktrees",
                            { selection = Set(merged.map(\.id)) }
                        )
                    )
                }
            }
        }
        .contextMenu(forSelectionType: Worktree.ID.self) { ids in
            rowMenu(store.worktrees.filter { ids.contains($0.id) && !store.deleting.contains($0.id) })
        }
        .onDeleteCommand { deleteSelection() }
        .onKeyPress(.space) { togglePreview() }
    }

    @ViewBuilder private func rowMenu(_ targets: [Worktree]) -> some View {
        if !targets.isEmpty {
            let folders = targets.filter { !$0.isMissing }.map { URL(fileURLWithPath: $0.path) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(folders) }
                .disabled(folders.isEmpty)
            Button(targets.count == 1 ? "Copy Path" : "Copy Paths") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(targets.map(\.path).joined(separator: "\n"), forType: .string)
            }
            Divider()
            Button(targets.count == 1 ? "Delete…" : "Delete \(targets.count) Worktrees…") { pendingDelete = targets }
        }
    }

    private var toolbar: some View {
        HStack {
            Picker("Show", selection: $filter) {
                ForEach(WorktreeFilter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Stale worktrees haven't been used in a week and aren't locked")
            Spacer()
            if store.isScanning && store.hasScanned {
                ProgressView().controlSize(.small)
            }
            Menu {
                Picker("Sort By", selection: $sort) {
                    ForEach(WorktreeSort.allCases) { Text($0.rawValue).tag($0) }
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
            .help("Look for worktrees again (⌘R)")
            .disabled(store.isScanning)
        }
        .padding(10)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var footer: some View {
        HStack {
            Toggle("Delete merged branches", isOn: $deleteMergedBranches)
                .help("When deleting a worktree, also delete its branch if everything on it is already in the default branch")
            Spacer()
            selectMenu
            Button(deleteLabel) { deleteSelection() }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(selected.isEmpty)
                .help("Delete the selected worktrees (⌘⌫)")
        }
        .padding(10)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private var selectMenu: some View {
        Menu("Select") {
            Button("All") { selection = Set(displayed.map(\.id)) }
            Divider()
            ForEach(WorktreePick.allCases) { pick in
                Button(pick.title) { selection = Set(displayed.filter(pick.matches).map(\.id)) }
                    .disabled(!displayed.contains(where: pick.matches))
                if pick == .agents { Divider() }
            }
            Divider()
            Button("None") { selection = [] }
                .disabled(selection.isEmpty)
        }
        .fixedSize()
        .disabled(displayed.isEmpty)
        .help("Locked worktrees are never picked")
    }

    private var deleteLabel: String {
        selected.count > 1 ? "Delete \(selected.count) Worktrees" : "Delete Worktree"
    }

    private func deleteSelection() {
        guard !selected.isEmpty else { return }
        pendingDelete = selected
    }

    /// Space opens Quick Look on the first selected folder, and closes it.
    private func togglePreview() -> KeyPress.Result {
        if previewURL != nil {
            previewURL = nil
            return .handled
        }
        guard let worktree = selected.first(where: { !$0.isMissing }) else { return .ignored }
        previewURL = URL(fileURLWithPath: worktree.path)
        return .handled
    }

    // MARK: - Confirming

    private var confirming: Binding<Bool> {
        Binding(get: { !pendingDelete.isEmpty }, set: { if !$0 { pendingDelete = [] } })
    }

    private var failed: Binding<Bool> {
        Binding(get: { store.failure != nil }, set: { if !$0 { store.failure = nil } })
    }

    private var deleteTitle: String {
        if pendingDelete.count == 1, let worktree = pendingDelete.first {
            return "Delete \u{201C}\(worktree.name)\u{201D}?"
        }
        return "Delete \(pendingDelete.count) worktrees?"
    }

    /// What happens to branches, so nobody is surprised a branch is gone.
    private var branchMessage: String {
        let merged = deleteMergedBranches ? pendingDelete.filter(\.isMerged) : []
        if pendingDelete.count == 1, let branch = pendingDelete[0].branch {
            return merged.isEmpty
                ? "Its branch \u{201C}\(branch)\u{201D} is kept, so committed work stays in the repository."
                : "Its branch \u{201C}\(branch)\u{201D} is already merged, so it's deleted too."
        }
        if pendingDelete.count == 1 { return "" }
        if merged.isEmpty { return "Branches are kept, so committed work stays in the repository." }
        let count = merged.count == 1 ? "1 merged branch is" : "\(merged.count) merged branches are"
        return "\(count) deleted too. Other branches are kept."
    }

    private var deleteMessage: String {
        let single = pendingDelete.count == 1
        var lines = [((single ? "The folder is" : "Their folders are") + " permanently deleted. " + branchMessage)
            .trimmingCharacters(in: .whitespaces)]
        let changed = pendingDelete.filter(\.hasChanges).count
        if single, changed == 1 {
            lines.append("It has uncommitted changes, which will be lost.")
        } else if changed > 0 {
            lines.append("\(changed) of them \(changed == 1 ? "has" : "have") uncommitted changes, which will be lost.")
        }
        let locked = pendingDelete.filter(\.isLocked).count
        if single, locked == 1 {
            lines.append("It's locked, so an app may still be using it.")
        } else if locked > 0 {
            lines.append("\(locked) of them \(locked == 1 ? "is" : "are") locked, so an app may still be using \(locked == 1 ? "it" : "them").")
        }
        return lines.joined(separator: "\n\n")
    }
}

private struct WorktreeRow: View {
    let worktree: Worktree
    let isDeleting: Bool
    let onDelete: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(worktree.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .help("\(worktree.branch ?? "Detached HEAD")\n\(worktree.path)")
            Spacer(minLength: 8)
            if worktree.isMerged {
                StatusPill(title: "Merged", color: .green)
                    .help("Everything on its branch is already in the default branch")
            }
            if worktree.hasChanges {
                StatusPill(title: worktree.changedFiles == 1 ? "1 change" : "\(worktree.changedFiles) changes", color: .orange)
                    .help("Uncommitted changes")
            }
            if worktree.isLocked {
                StatusPill(title: "Locked", color: .secondary)
                    .help("An app may be using it")
            }
            if worktree.isMissing {
                StatusPill(title: "Missing", color: .red)
                    .help("The folder is gone, so deleting only clears git's record of it")
            }
            // Space stays reserved so pills don't shift when the button shows.
            ZStack {
                if isDeleting {
                    ProgressView().controlSize(.small)
                } else if isHovering {
                    Button(action: onDelete) {
                        Label("Delete", systemImage: "trash")
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Delete worktree")
                }
            }
            .frame(width: 18)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .swipeActions(edge: .trailing) {
            Button("Delete", systemImage: "trash", action: onDelete)
                .tint(.red)
        }
        .accessibilityAction(named: "Delete", onDelete)
    }

    /// The branch only when the folder name doesn't already say it: git
    /// names a new branch after its folder, and Claude Code adds `claude/`
    /// or `worktree-` in front.
    private var detail: String {
        var parts: [String] = []
        if let branch = worktree.branch {
            let last = (branch as NSString).lastPathComponent
            if last != worktree.name, last != "worktree-" + worktree.name { parts.append(branch) }
        } else {
            parts.append("Detached")
        }
        if worktree.lastActive > .distantPast {
            parts.append(worktree.lastActive.formatted(.relative(presentation: .named)))
        }
        return parts.joined(separator: " · ")
    }
}

/// The one Worktrees window, created on first use and reused after. Every
/// open rescans, so the list matches the disk.
@MainActor
final class WorktreesWindow {
    private var window: NSWindow?
    private var store: WorktreeStore?

    func show() {
        let store = self.store ?? WorktreeStore()
        self.store = store
        let window = self.window ?? makeWindow(store: store)
        self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        Task { await store.scan() }
    }

    private func makeWindow(store: WorktreeStore) -> NSWindow {
        let window = NSWindow(contentViewController: NSHostingController(rootView: WorktreesView(store: store)))
        window.title = "Worktrees"
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 540, height: 480))
        // Open on the Space the menu was used from, even over a full-screen app.
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.center()
        return window
    }
}
