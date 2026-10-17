import AppKit

/// Native status-item menu (Battery-menu style): one summary row per
/// provider with its tightest quota window (every window in its submenu),
/// running dev servers, then Caffeinate / Camera, Worktrees / Skills /
/// Settings, and Quit. All rows are stock menu items: badged rows, plus
/// native capacity indicators on their own lines. ⌥-clicking the icon
/// also shows Refresh with the last update time, like Wi-Fi's ⌥ menu.
@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    let menu = NSMenu()
    private var renderedMenu = NSMenu()
    private let store: UsageStore
    private let updater: UpdateController?
    private var updateItem: NSMenuItem?
    private var refreshItem: NSMenuItem?
    private let caffeinate = Caffeinate()
    private var ports: [ListeningPort] = []
    private var camera: CameraAccess.Scan?
    /// Set when the menu opens with ⌥ held; reveals the Refresh row.
    private var showsDetails = false
    private let onCaffeinateChange: (Bool) -> Void
    private let onWorktrees: () -> Void
    private let onSkills: () -> Void
    private let onSettings: () -> Void
    private let onQuit: () -> Void

    init(
        store: UsageStore,
        updater: UpdateController?,
        onCaffeinateChange: @escaping (Bool) -> Void,
        onWorktrees: @escaping () -> Void,
        onSkills: @escaping () -> Void,
        onSettings: @escaping () -> Void,
        onQuit: @escaping () -> Void
    ) {
        self.store = store
        self.updater = updater
        self.onCaffeinateChange = onCaffeinateChange
        self.onWorktrees = onWorktrees
        self.onSkills = onSkills
        self.onSettings = onSettings
        self.onQuit = onQuit
        super.init()
        menu.delegate = self
        // Explicit enabled states (auto-validation would re-enable
        // actionless rows, defeating the dimmed style).
        menu.autoenablesItems = false
        // Bars stretch to the menu width; this keeps them from getting stubby.
        menu.minimumWidth = Self.minimumWidth
        rebuild()
        Task {
            await refreshPorts()
            self.rebuild()
        }
        Task {
            camera = await CameraAccess.scan()
            self.rebuild()
        }
    }

    static let minimumWidth: CGFloat = 240

    /// Rebuild items from the latest snapshots (cheap, synchronous).
    func rebuild() {
        let previousItems = menu.items
        renderedMenu = NSMenu()
        for id in ProviderID.allCases where SettingsStore.isEnabled(id) {
            addProvider(id)
        }
        if SettingsStore.showDevServers {
            addSeparator()
            addPortsSection()
        }
        addSeparator()
        // Opening the menu already refreshes, so Refresh only shows with ⌥,
        // or while a provider's Keychain message asks for it by name; ⌘R
        // works either way.
        let needsApproval = ProviderID.allCases.contains {
            SettingsStore.isEnabled($0) && store.snapshot(for: $0)?.state.isKeychainDenied == true
        }
        var refreshTitle = "Refresh"
        if store.isRefreshing {
            refreshTitle = "Refreshing…"
        } else if let last = store.lastRefresh {
            refreshTitle += " · Updated \(last.formatted(date: .omitted, time: .shortened))"
        }
        let refresh = NSMenuItem(title: refreshTitle, action: #selector(refreshNow), keyEquivalent: "r")
        refresh.target = self
        refresh.isEnabled = !store.isRefreshing
        refresh.isHidden = !(showsDetails || needsApproval)
        refresh.allowsKeyEquivalentWhenHidden = true
        refreshItem = refresh
        renderedMenu.addItem(refresh)
        let caffeinateItem = NSMenuItem(title: "Caffeinate", action: #selector(toggleCaffeinate), keyEquivalent: "")
        caffeinateItem.target = self
        caffeinateItem.state = caffeinate.isOn ? .on : .off
        renderedMenu.addItem(caffeinateItem)
        let cameraItem = NSMenuItem(title: "Camera", action: nil, keyEquivalent: "")
        cameraItem.submenu = cameraMenu()
        renderedMenu.addItem(cameraItem)
        addSeparator()
        let worktrees = NSMenuItem(title: "Worktrees…", action: #selector(openWorktrees), keyEquivalent: "")
        worktrees.target = self
        renderedMenu.addItem(worktrees)
        let skills = NSMenuItem(title: "Skills…", action: #selector(openSkills), keyEquivalent: "")
        skills.target = self
        renderedMenu.addItem(skills)
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        renderedMenu.addItem(settings)
        // Checking lives in Settings; the menu only offers a ready update.
        updateItem = nil
        if let updater, updater.isReady {
            let item = NSMenuItem(title: updater.title, action: #selector(updateApp), keyEquivalent: "")
            item.target = self
            item.isEnabled = updater.enabled
            updateItem = item
            renderedMenu.addItem(item)
        }
        renderedMenu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Devbar", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        renderedMenu.addItem(quit)
        // Never empty a menu while it is tracking: removing its last item
        // dismisses it. Attach the new rows before retiring the old rows.
        let nextItems = renderedMenu.items
        for item in nextItems {
            renderedMenu.removeItem(item)
            menu.addItem(item)
        }
        for item in previousItems { menu.removeItem(item) }
    }

    /// Separators go between groups only, so an empty group (no dev
    /// servers, no providers) never leaves two in a row.
    private func addSeparator() {
        guard let last = renderedMenu.items.last, !last.isSeparatorItem else { return }
        renderedMenu.addItem(.separator())
    }

    func menuWillOpen(_ menu: NSMenu) {
        showsDetails = NSEvent.modifierFlags.contains(.option)
        rebuild()
        Task {
            await refreshPorts()
            self.rebuild()
        }
        Task {
            camera = await CameraAccess.scan()
            self.rebuild()
        }
        Task {
            await store.refresh(userInitiated: true)
            self.rebuild()
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        showsDetails = false
    }

    func updateUpdateItem() {
        guard let updater else { return }
        // Download progress updates often; only rebuild when the row
        // appears or goes away.
        guard updater.isReady == (updateItem != nil) else { return rebuild() }
        updateItem?.title = updater.title
        updateItem?.isEnabled = updater.enabled
    }

    @objc private func updateApp(_ sender: Any?) {
        updater?.activate()
    }

    // MARK: - Sections

    /// One row per provider: its name, the window closest to running out
    /// (label and reset time as the subtitle, percentage as the badge), and
    /// that window's bar. The submenu holds the plan, the masked account,
    /// and every window. Loading, idle, and error states fill the subtitle.
    private func addProvider(_ id: ProviderID) {
        guard let snap = store.snapshot(for: id) else {
            return addStatusRow(id.displayName, detail: "Loading…")
        }
        if let message = snap.state.message {
            return addStatusRow(id.displayName, detail: message)
        }
        let windows = ([("Session", snap.session), ("Weekly", snap.weekly)]
            + snap.extraRows.map { ($0.label, $0.window) })
            .compactMap { label, window in window.remainingPercent.map { (label: label, window: window, remaining: $0) } }
        let details = NSMenu()
        details.autoenablesItems = false
        details.minimumWidth = Self.minimumWidth
        if let account = accountText(for: snap) {
            details.addItem(.sectionHeader(title: account))
        }
        for window in windows {
            let row = info(window.label)
            row.badge = NSMenuItemBadge(string: [percentText(window.remaining), resetText(window.window.resetsAt)]
                .compactMap { $0 }.joined(separator: " · "))
            details.addItem(row)
            details.addItem(barItem(remaining: window.remaining, label: window.label))
        }
        // min(by:) keeps the first of equal windows, so Session wins ties.
        guard let tightest = windows.min(by: { $0.remaining < $1.remaining }) else {
            // An idle provider still lists its plan and account.
            let row = info(id.displayName)
            setDetail("Idle", on: row)
            if !details.items.isEmpty { row.submenu = details }
            return renderedMenu.addItem(row)
        }
        let row = NSMenuItem(title: id.displayName, action: nil, keyEquivalent: "")
        setDetail([tightest.label, resetPhrase(tightest.window.resetsAt)].compactMap { $0 }.joined(separator: " · "), on: row)
        row.badge = NSMenuItemBadge(string: percentText(tightest.remaining))
        row.submenu = details
        renderedMenu.addItem(row)
        renderedMenu.addItem(barItem(remaining: tightest.remaining, label: "\(id.displayName) \(tightest.label)"))
    }

    private func addStatusRow(_ title: String, detail: String) {
        let row = info(title, dimmed: true)
        setDetail(detail, on: row)
        renderedMenu.addItem(row)
    }

    /// A draining bar on its own line, below the row it belongs to.
    private func barItem(remaining: Double, label: String) -> NSMenuItem {
        let item = NSMenuItem()
        item.view = BarView(remaining: remaining, label: label)
        return item
    }

    private func percentText(_ remaining: Double) -> String {
        (remaining / 100).formatted(.percent.precision(.fractionLength(0)))
    }

    // MARK: - Dev servers

    private func refreshPorts() async {
        guard SettingsStore.showDevServers else {
            ports = []
            return
        }
        ports = await PortScanner.scan(hidden: Set(SettingsStore.hiddenProcesses))
    }

    /// No section header: `localhost:<port>` rows explain themselves. With
    /// nothing running the section is left out entirely.
    private func addPortsSection() {
        for port in ports {
            let row = NSMenuItem(title: "localhost:\(port.port)", action: nil, keyEquivalent: "")
            setDetail("\(port.project) · \(port.process)", on: row)
            row.submenu = portMenu(for: port)
            renderedMenu.addItem(row)
        }
    }

    private func portMenu(for port: ListeningPort) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(portAction("Open in Browser", #selector(openPort), port))
        menu.addItem(portAction("Copy URL", #selector(copyURL), port))
        // Holding Option swaps in the rarer Copy PID.
        let copyPID = portAction("Copy PID", #selector(copyPID), port)
        copyPID.keyEquivalentModifierMask = .option
        copyPID.isAlternate = true
        menu.addItem(copyPID)
        menu.addItem(.separator())
        menu.addItem(portAction("Hide \u{201C}\(port.process)\u{201D}", #selector(hideProcess), port))
        menu.addItem(.separator())
        menu.addItem(portAction("Stop Process", #selector(stopProcess), port))
        // Holding Option swaps in Force Stop, like Force Quit in the Apple menu.
        let force = portAction("Force Stop Process", #selector(forceStopProcess), port)
        force.keyEquivalentModifierMask = .option
        force.isAlternate = true
        menu.addItem(force)
        return menu
    }

    private func portAction(_ title: String, _ action: Selector, _ port: ListeningPort) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = port
        return item
    }

    // MARK: - Camera

    /// Apps in Privacy & Security → Camera, checked while allowed. Clicking
    /// an allowed app revokes it; turning one back on happens in macOS's own
    /// prompt or in System Settings, since only those can grant access.
    private func cameraMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        switch camera {
        case nil:
            menu.addItem(info("Loading…", dimmed: true))
        case .needsFullDiskAccess?:
            menu.addItem(info("Needs Full Disk Access", dimmed: true))
            menu.addItem(action("Open Full Disk Access Settings…", #selector(openFullDiskAccessSettings)))
            return menu
        case .failed?:
            menu.addItem(info("Couldn’t read camera access", dimmed: true))
        case .apps(let apps)?:
            if apps.isEmpty { menu.addItem(info("No apps have asked yet", dimmed: true)) }
            for app in apps { menu.addItem(cameraRow(app)) }
        }
        menu.addItem(.separator())
        menu.addItem(action("Open Camera Settings…", #selector(openCameraSettings)))
        return menu
    }

    private func cameraRow(_ app: CameraApp) -> NSMenuItem {
        let item: NSMenuItem
        switch app.status {
        case .allowed:
            item = action(app.name, #selector(revokeCamera))
            item.state = .on
        case .denied:
            item = action(app.name, #selector(openCameraSettings))
            setDetail("Off · Turn on in Settings", on: item)
        case .asksNextTime:
            item = action(app.name, #selector(openCameraApp))
            setDetail("Asks next time it uses the camera", on: item)
        }
        item.representedObject = app
        let icon = NSWorkspace.shared.icon(forFile: app.path)
        icon.size = NSSize(width: 16, height: 16)
        item.image = icon
        return item
    }

    private func action(_ title: String, _ selector: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        return item
    }

    /// Submenu header: "Max 5x · al•••@example.com", or nil when neither
    /// is known.
    private func accountText(for snap: ProviderSnapshot) -> String? {
        let parts = [snap.plan, snap.account.map(Self.masked)].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "hello@example.com" → "he•••@example.com": enough to tell accounts
    /// apart without showing the full address in screenshots.
    static func masked(_ email: String) -> String {
        guard let at = email.lastIndex(of: "@"), at > email.startIndex else { return email }
        let name = email[..<at]
        let kept = name.prefix(name.count > 3 ? 2 : 1)
        return "\(kept)•••\(email[at...])"
    }

    /// Secondary line under the title. Subtitles need macOS 14.4, so older
    /// systems fold the detail into the title instead.
    private func setDetail(_ detail: String?, on item: NSMenuItem) {
        guard let detail else { return }
        if #available(macOS 14.4, *) {
            item.subtitle = detail
        } else {
            item.title += " · \(detail)"
        }
    }

    /// Non-functional row: full-contrast by default, gray when dimmed.
    private func info(_ text: String, dimmed: Bool = false) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: dimmed ? nil : #selector(noop), keyEquivalent: "")
        item.target = dimmed ? nil : self
        item.isEnabled = !dimmed
        return item
    }

    /// Short reset time for the badge: "in 4h 50m", or a calendar moment
    /// ("Sat 3:30 AM") for longer windows, matching the Claude desktop app.
    private func resetText(_ date: Date?) -> String? {
        guard let date else { return nil }
        let remaining = date.timeIntervalSinceNow
        if remaining <= 0 { return "resetting" }
        if remaining < 86400 {
            let duration = Duration.seconds(remaining).formatted(.units(allowed: [.hours, .minutes], width: .narrow))
            return "in \(duration)"
        }
        let style: Date.FormatStyle = remaining < 6 * 86400
            ? .dateTime.weekday(.abbreviated).hour().minute()
            : .dateTime.month(.abbreviated).day().hour().minute()
        return date.formatted(style)
    }

    /// Reset time for a summary row's subtitle: "resets in 4h 50m".
    private func resetPhrase(_ date: Date?) -> String? {
        guard let date, let text = resetText(date) else { return nil }
        return date.timeIntervalSinceNow <= 0 ? text : "resets \(text)"
    }

    // MARK: - Actions

    @objc private func noop(_ sender: Any?) {}

    @objc private func refreshNow(_ sender: Any?) {
        guard !store.isRefreshing else { return }
        refreshItem?.title = "Refreshing…"
        refreshItem?.isEnabled = false
        Task {
            await store.refresh(userInitiated: true)
            self.rebuild()
        }
    }

    @objc private func toggleCaffeinate(_ sender: Any?) {
        caffeinate.toggle()
        onCaffeinateChange(caffeinate.isOn)
        rebuild()
    }

    @objc private func openPort(_ sender: NSMenuItem) {
        guard let port = sender.representedObject as? ListeningPort else { return }
        NSWorkspace.shared.open(port.url)
    }

    @objc private func copyURL(_ sender: NSMenuItem) {
        guard let port = sender.representedObject as? ListeningPort else { return }
        copy(port.url.absoluteString)
    }

    @objc private func copyPID(_ sender: NSMenuItem) {
        guard let port = sender.representedObject as? ListeningPort else { return }
        copy(String(port.pid))
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func hideProcess(_ sender: NSMenuItem) {
        guard let port = sender.representedObject as? ListeningPort else { return }
        SettingsStore.hiddenProcesses = Array(Set(SettingsStore.hiddenProcesses).union([port.process]))
        ports.removeAll { $0.process == port.process }
        rebuild()
    }

    @objc private func stopProcess(_ sender: NSMenuItem) {
        stop(sender, force: false)
    }

    @objc private func forceStopProcess(_ sender: NSMenuItem) {
        stop(sender, force: true)
    }

    private func stop(_ sender: NSMenuItem, force: Bool) {
        guard let port = sender.representedObject as? ListeningPort else { return }
        PortScanner.stop(port, force: force)
        ports.removeAll { $0.pid == port.pid }
        rebuild()
    }

    @objc private func revokeCamera(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? CameraApp else { return }
        Task {
            if !(await CameraAccess.revoke(app)) { NSSound.beep() }
            camera = await CameraAccess.scan()
            self.rebuild()
        }
    }

    @objc private func openCameraApp(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? CameraApp else { return }
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: app.path), configuration: .init())
    }

    @objc private func openCameraSettings(_ sender: Any?) {
        NSWorkspace.shared.open(CameraAccess.settingsURL)
    }

    @objc private func openFullDiskAccessSettings(_ sender: Any?) {
        NSWorkspace.shared.open(CameraAccess.fullDiskAccessURL)
    }

    @objc private func openWorktrees(_ sender: Any?) {
        onWorktrees()
    }

    @objc private func openSkills(_ sender: Any?) {
        onSkills()
    }

    @objc private func openSettings(_ sender: Any?) {
        onSettings()
    }

    @objc private func quitApp(_ sender: Any?) {
        onQuit()
    }
}

/// AppKit owns capacity rendering and color; this view only supplies menu
/// insets. Its flexible width lets the menu stretch it to the menu width.
final class BarView: NSView {
    private let indicator = NSLevelIndicator()
    private static let horizontalInset: CGFloat = 16

    init(remaining: Double, label: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: StatusMenu.minimumWidth, height: 16))
        autoresizingMask = [.width]
        indicator.levelIndicatorStyle = .continuousCapacity
        indicator.minValue = 0
        indicator.maxValue = 100
        // A critical value below the warning value flags low levels, like
        // Battery: green normally, yellow under 25%, red under 10%.
        indicator.warningValue = 25
        indicator.criticalValue = 10
        indicator.doubleValue = remaining.isFinite ? min(100, max(0, remaining)) : 0
        indicator.isEditable = false
        indicator.setAccessibilityLabel("\(label) quota remaining")
        indicator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(indicator)
        NSLayoutConstraint.activate([
            indicator.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.horizontalInset),
            indicator.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.horizontalInset),
            indicator.centerYAnchor.constraint(equalTo: centerYAnchor),
            indicator.heightAnchor.constraint(equalToConstant: 6),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
