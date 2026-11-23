import AppKit
import Carbon
import UniformTypeIdentifiers

struct AppSourceRule: Codable, Equatable {
    var bundleID: String
    var name: String
    var sourceID: String
}


struct AppSourceRules {
    let defaults: UserDefaults
    var enabled: Bool {
        get { defaults.bool(forKey: "appSourcesEnabled") }
        nonmutating set { defaults.set(newValue, forKey: "appSourcesEnabled") }
    }
    var rules: [AppSourceRule] {
        get {
            guard let data = defaults.data(forKey: "appSources"), let rules = try? JSONDecoder().decode([AppSourceRule].self, from: data) else { return [] }
            return rules
        }
        nonmutating set { defaults.set(try? JSONEncoder().encode(newValue), forKey: "appSources") }
    }
    func set(_ rule: AppSourceRule) {
        var list = rules.filter { $0.bundleID != rule.bundleID }
        list.append(rule)
        rules = list.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    func remove(_ bundleID: String) { rules = rules.filter { $0.bundleID != bundleID } }
}

// Only app activation requests a default. Source changes and window changes within the app never request one.
// A window that takes the keyboard without activating its app (Alfred's search) is tracked separately, and never
// becomes `pid`: coming back to the app underneath is not a switch to it.
struct AppSourceFocus {
    enum Change: Equatable {
        case none
        case entered(pid_t)
        case returned(String, enforced: String?)
        case abandoned
    }
    // The lock screen, and the other Mac under Universal Control, take the front without the user leaving the app.
    static let passing: Set<String> = ["com.apple.loginwindow", universalControlID]
    private(set) var pid: pid_t?
    private(set) var generation = 0
    private var away = false
    private var left: pid_t?
    // The app whose window has the keyboard without being frontmost, and the frontmost app it covers.
    private(set) var overlay: pid_t?
    private(set) var covered: pid_t?
    private(set) var origin: String?
    private(set) var enforced: String?
    private(set) var overlayGeneration = 0
    mutating func activate(_ pid: pid_t, frontmost: pid_t, passing: Bool = false) -> Int? {
        if passing {
            if !away { away = true; left = self.pid }
            generation += 1
            return nil
        }
        guard pid == frontmost else { return nil }
        // Coming back to the app is not a switch to it: the source it was left in stays.
        let back = away && left == pid
        away = false
        self.pid = pid; generation += 1
        return back ? nil : generation
    }
    // The app in front when this starts had no activation to see.
    mutating func begin(_ pid: pid_t?) { if self.pid == nil { self.pid = pid } }
    // A hand switch wins over an activation on its way. An overlay already showing is not that request.
    mutating func cancel() { generation += 1 }
    func accepts(_ generation: Int, pid: pid_t) -> Bool { self.generation == generation && self.pid == pid }
    // `focused` is set only for an app this should follow. Anything else, including no focus, is the overlay going away.
    // Replacing one such window with another keeps the source from before the first: the second may already have switched.
    mutating func note(focused: pid_t?, frontmost: pid_t, source: String?) -> Change {
        if let covered, frontmost != covered { dropOverlay(); return .abandoned }
        if let focused, focused != frontmost {
            if overlay == focused { return .none }
            let replacing = overlay != nil
            overlay = focused
            if !replacing { covered = frontmost; origin = source }
            overlayGeneration += 1
            return .entered(focused)
        }
        guard overlay != nil else { return .none }
        let saved = origin, forced = enforced
        dropOverlay()
        return saved.map { .returned($0, enforced: forced) } ?? .none
    }
    mutating func setEnforced(_ id: String?) { enforced = id }
    // Invalidates a switch on the way, including one that is putting the old source back. No key is sent from here.
    mutating func dropOverlay() {
        overlay = nil; covered = nil; origin = nil; enforced = nil; overlayGeneration += 1
    }
    func acceptsOverlay(_ generation: Int, pid: pid_t) -> Bool { overlayGeneration == generation && overlay == pid }
    func acceptsReturn(_ generation: Int) -> Bool { overlayGeneration == generation && overlay == nil }
    // `early` is the source from before the overlay's own selection. A selection that just landed on the target
    // replaced it, so the one before that selection is where typing was.
    static func overlayOrigin(early: String?, current: String?, target: String?, previous: String?, changedRecently: Bool) -> String? {
        if let early { return early }
        if changedRecently, let current, current == target, let previous { return previous }
        return current
    }
}

extension AppDelegate {
    var appSourceRules: AppSourceRules { AppSourceRules(defaults: engine.defaults) }
    // The sources switching goes between: the managed ones left on, or Korean and English when they are not managed.
    var appSourceChoices: [InputSourceIdentity] {
        engine.addedSourcesEnabled ? activeSources() : enabledSources().filter { isKorean($0) || isEnglish($0) }
    }
    // Secure input does not stop it: the shortcut still switches, and any app can leave secure input on for days.
    var appSourcesActive: Bool {
        appSourceRules.enabled && engine.active && !engine.paused && engine.accessibilityTrusted() && !engine.sessionAway()
    }
    func appSourceActivated(_ app: NSRunningApplication) {
        let pid = app.processIdentifier, bundle = app.bundleIdentifier
        guard let frontmost = frontmostPID(),
              let generation = appSourceFocus.activate(pid, frontmost: frontmost, passing: bundle.map(AppSourceFocus.passing.contains) ?? false),
              bundle != Bundle.main.bundleIdentifier, let bundle else { return }
        applyAppSource(bundle, pid: pid, generation: generation)
    }
    private func applyAppSource(_ bundle: String, pid: pid_t, generation: Int, from: InputSourceIdentity? = nil, retries: Int = 2) {
        // Rapid A -> B -> A can deliver all three notices after A is already frontmost. Coalesce them before sending
        // a shortcut: two switches sent during activation can toggle back even after the first reports its landing.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self, self.appSourceFocus.accepts(generation, pid: pid), self.frontmostPID() == pid, self.appSourcesActive,
                  let rule = self.appSourceRules.rules.first(where: { $0.bundleID == bundle }) else { return }
            self.appSourcesSettings.showError(nil, bundleID: bundle)
            // A source no longer in use waits, shown as such in the app's row.
            guard let target = self.appSourceChoices.first(where: { $0.id == rule.sourceID }) else { return }
            guard let current = from ?? self.logicalSource, current.id != target.id,
                  let pulse = nativeSwitchPulse(keyCode: self.engine.target.keyCode, marker: self.nativePulseMarker) else { return }
            self.cancelLongPress()
            self.rememberCapsBeforeSwitch()
            let attempt = self.landingGeneration
            let switched = self.switchSource(to: target, from: current, pulse: pulse, owner: pid)
            guard !switched, self.frontmostPID() == pid else { return }
            // A click stops a switch that is still selecting its sources, which is not a failure. Clicked within the
            // app, such as the second of a double click, it starts over from the same source, as the selections may
            // be half made. Once the shortcut is sent it is not sent again: one sent to a busy app is still waiting
            // there, and a second would bring the source back.
            if attempt != self.landingGeneration {
                if retries > 0, let again = self.appSourceFocus.activate(pid, frontmost: pid) {
                    self.applyAppSource(bundle, pid: pid, generation: again, from: current, retries: retries - 1)
                }
                return
            }
            self.appSourcesSettings.showError("입력 소스를 전환하지 못했습니다.", bundleID: bundle)
        }
    }
    // The shortcut still switches while an overlay has the keyboard. The per-app list is a separate choice.
    var inputSwitchReady: Bool {
        engine.active && !engine.paused && engine.accessibilityTrusted() && !engine.sessionAway()
    }
    // Alfred's Force Keyboard, read from its preferences. Empty means Alfred keeps whatever is current.
    // An app rule, when the feature is on, wins. A rule whose source is not in use does not fall through to this.
    func overlayTarget(bundle: String) -> InputSourceIdentity? {
        if appSourceRules.enabled, let rule = appSourceRules.rules.first(where: { $0.bundleID == bundle }) {
            return appSourceChoices.first { $0.id == rule.sourceID }
        }
        guard bundle == AlfredForcedKeyboard.bundleID, let id = alfredForcedID() else { return nil }
        return enabledSources().first { $0.id == id }
    }
    func overlayManaged(_ bundle: String) -> Bool {
        if bundle == Bundle.main.bundleIdentifier || AppSourceFocus.passing.contains(bundle) { return false }
        if appSourceRules.enabled && appSourceRules.rules.contains(where: { $0.bundleID == bundle }) { return true }
        return bundle == AlfredForcedKeyboard.bundleID && alfredForcedID() != nil
    }
    func alfredForcedID() -> String? {
        let now = ProcessInfo.processInfo.systemUptime
        if let alfredLocaleCache, now - alfredLocaleCache.at < 2 { return alfredLocaleCache.id }
        let id = alfredLocale()
        alfredLocaleCache = (now, id)
        return id
    }
    // One check after the current event, so a launcher has shown its window and selected its source first.
    func scheduleFocusCheck() {
        guard inputSwitchReady else { return }
        if pendingOverlayOrigin == nil {
            pendingOverlayOrigin = currentSource?.id
            pendingOverlayOriginAt = ProcessInfo.processInfo.systemUptime
        }
        focusRecheck = true
        guard !focusCheckScheduled else { return }
        focusCheckScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.focusCheckScheduled = false
            self.noteKeyboardFocus()
        }
    }
    func noteKeyboardFocus() {
        guard let frontmost = frontmostPID() else { return }
        guard inputSwitchReady else { dropKeyboardOverlay(); return }
        let recheck = focusRecheck
        focusRecheck = false
        guard let focusedPID = focusedWindowOwner() else {
            // No window to read. An app that came forward is not the overlay closing.
            if let covered = appSourceFocus.covered, covered != frontmost { dropKeyboardOverlay() }
            else { scheduleOverlayRecheck(recheck) }
            return
        }
        let bundle = NSRunningApplication(processIdentifier: focusedPID)?.bundleIdentifier
        if bundle.map(AppSourceFocus.passing.contains) == true { dropKeyboardOverlay(); return }
        // This app's window is not an overlay. Passing it as none lets a real activation cancel the search.
        let managed = focusedPID != getpid() && (bundle.map { overlayManaged($0) } ?? false)
        let early = pendingOverlayOrigin, earlyAt = pendingOverlayOriginAt
        let currentID = currentSource?.id
        let target = bundle.flatMap { overlayTarget(bundle: $0) }
        let recent = ProcessInfo.processInfo.systemUptime - sourceChangedAt < 0.2
        let source = AppSourceFocus.overlayOrigin(early: early, current: currentID, target: target?.id,
            previous: currentID.flatMap { sourceHistory.previous(of: $0) }, changedRecently: recent)
        let change = appSourceFocus.note(focused: managed ? focusedPID : nil, frontmost: frontmost, source: source)
        let token = appSourceFocus.overlayGeneration
        if change != .none || ProcessInfo.processInfo.systemUptime - earlyAt > 0.35 { pendingOverlayOrigin = nil }
        switch change {
        case .none:
            // The key that opens a launcher is delivered before its window exists.
            if appSourceFocus.overlay == nil { scheduleOverlayRecheck(recheck) }
        case .abandoned: break
        case .entered(let pid):
            appSourceFocus.setEnforced(target?.id)
            if let bundle, let target { enforceOverlay(bundle, pid: pid, generation: token, target: target) }
        case .returned(let origin, let enforced):
            restoreOverlay(origin, generation: token, enforced: enforced)
        }
    }
    // One look later, not a poll. The event's own check has already kept the source from before the launcher.
    private func scheduleOverlayRecheck(_ enabled: Bool) {
        guard enabled, pendingOverlayOrigin != nil, !focusCheckScheduled else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in self?.noteKeyboardFocus() }
    }
    func dropKeyboardOverlay() {
        pendingOverlayOrigin = nil
        appSourceFocus.dropOverlay()
    }
    // The owner is the app still in front, not the overlay: a switch is cancelled when its owner is no longer frontmost.
    // Alfred selects at the end of the event, and the front app's input source can snap that straight back, so check again.
    private func enforceOverlay(_ bundle: String, pid: pid_t, generation: Int, target: InputSourceIdentity, delay: TimeInterval = 0.08, confirms: Int = 2) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.appSourceFocus.acceptsOverlay(generation, pid: pid), self.inputSwitchReady,
                  let covered = self.appSourceFocus.covered, self.frontmostPID() == covered else { return }
            let ruled = self.appSourceRules.enabled && self.appSourceRules.rules.contains { $0.bundleID == bundle }
            if ruled { self.appSourcesSettings.showError(nil, bundleID: bundle) }
            guard let current = self.logicalSource else { return }
            if current.id == target.id {
                if confirms > 0 { self.enforceOverlay(bundle, pid: pid, generation: generation, target: target, delay: 0.2, confirms: confirms - 1) }
                return
            }
            guard let pulse = nativeSwitchPulse(keyCode: self.engine.target.keyCode, marker: self.nativePulseMarker) else {
                if ruled { self.appSourcesSettings.showError("입력 소스를 전환하지 못했습니다.", bundleID: bundle) }
                return
            }
            self.cancelLongPress()
            self.rememberCapsBeforeSwitch()
            let attempt = self.landingGeneration
            let switched = self.switchSource(to: target, from: current, pulse: pulse, owner: covered)
            if switched || attempt != self.landingGeneration {
                if confirms > 0 { self.enforceOverlay(bundle, pid: pid, generation: generation, target: target, delay: 0.2, confirms: confirms - 1) }
                return
            }
            if ruled { self.appSourcesSettings.showError("입력 소스를 전환하지 못했습니다.", bundleID: bundle) }
        }
    }
    // Restores the source from before the overlay selected its own. One later check undoes that source coming back,
    // and leaves a source the user picked after the overlay closed.
    private func restoreOverlay(_ origin: String, generation: Int, enforced: String?, again: Bool = true) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            guard let self, self.appSourceFocus.acceptsReturn(generation), self.inputSwitchReady,
                  let current = self.logicalSource, current.id != origin,
                  let target = self.enabledSources().first(where: { $0.id == origin }),
                  let pulse = nativeSwitchPulse(keyCode: self.engine.target.keyCode, marker: self.nativePulseMarker) else { return }
            self.cancelLongPress()
            self.rememberCapsBeforeSwitch()
            _ = self.switchSource(to: target, from: current, pulse: pulse, owner: self.frontmostPID())
            guard again, let enforced else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard let self, self.appSourceFocus.acceptsReturn(generation), self.switchLanding == nil,
                      self.currentSource?.id == enforced else { return }
                self.restoreOverlay(origin, generation: generation, enforced: nil, again: false)
            }
        }
    }
    func startKeyboardFocusWatch() {
        keyboardFocus.onChange = { [weak self] in self?.scheduleFocusCheck() }
        keyboardFocus.start()
        scheduleFocusCheck()
    }
    func stopKeyboardFocusWatch() {
        let running = keyboardFocus.running
        keyboardFocus.stop()
        if running { dropKeyboardOverlay() }
    }
}

// Alfred stores Force Keyboard under the preferences bundle named in ~/Library/Application Support/Alfred/prefs.json.
// The hash is one path component, and the bundle stays inside that folder: the file is not an arbitrary path.
struct AlfredForcedKeyboard {
    static let bundleID = "com.runningwithcrayons.Alfred"
    static func locale(in directory: URL) -> String? {
        let root = directory.standardizedFileURL.resolvingSymlinksInPath()
        guard let data = try? Data(contentsOf: root.appendingPathComponent("prefs.json")),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let current = object["current"] as? String, let hash = object["localhash"] as? String,
              validHash(hash) else { return nil }
        let bundle = URL(fileURLWithPath: current).standardizedFileURL.resolvingSymlinksInPath()
        guard bundle.lastPathComponent == "Alfred.alfredpreferences", contains(root, bundle) else { return nil }
        let plist = bundle.appendingPathComponent("preferences/local/\(hash)/keyboard/prefs.plist").standardizedFileURL
        guard contains(bundle, plist), let dict = NSDictionary(contentsOf: plist),
              let locale = dict["locale"] as? String, !locale.isEmpty else { return nil }
        return locale
    }
    private static func validHash(_ hash: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        return !hash.isEmpty && hash.count <= 128 && hash.unicodeScalars.allSatisfy(allowed.contains)
    }
    private static func contains(_ root: URL, _ url: URL) -> Bool {
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return url.path.hasPrefix(prefix)
    }
}

enum KeyboardFocus {
    // The focused window first: a non-activating panel is a window of an app that is not frontmost.
    static func owner() -> pid_t? {
        let system = AXUIElementCreateSystemWide()
        if let pid = pid(system, kAXFocusedWindowAttribute as CFString) { return pid }
        return pid(system, kAXFocusedApplicationAttribute as CFString)
    }
    private static func pid(_ element: AXUIElement, _ attribute: CFString) -> pid_t? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success, let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        var pid: pid_t = 0
        guard AXUIElementGetPid(unsafeBitCast(value, to: AXUIElement.self), &pid) == .success, pid > 0 else { return nil }
        return pid
    }
}

// Focus notifications are per app. The system-wide element does not accept them.
final class KeyboardFocusWatch {
    var onChange: () -> Void = {}
    private var observer: AXObserver?
    private var watched: Set<pid_t> = []
    private var notices: [NSObjectProtocol] = []
    var running: Bool { observer != nil }
    func start() {
        guard observer == nil else { return }
        var created: AXObserver?
        guard AXObserverCreate(getpid(), { _, _, _, refcon in
            guard let refcon else { return }
            let watch = Unmanaged<KeyboardFocusWatch>.fromOpaque(refcon).takeUnretainedValue()
            DispatchQueue.main.async { [weak watch] in watch?.onChange() }
        }, &created) == .success, let created else { return }
        observer = created
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes)
        let center = NSWorkspace.shared.notificationCenter
        notices.append(center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] notice in
            guard let app = notice.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.watch(app.processIdentifier)
        })
        notices.append(center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] notice in
            guard let app = notice.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.unwatch(app.processIdentifier)
        })
        for app in NSWorkspace.shared.runningApplications { watch(app.processIdentifier) }
    }
    func stop() {
        guard let observer else { return }
        let pids = watched
        for pid in pids { unwatch(pid) }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        self.observer = nil
        watched.removeAll()
        for notice in notices { NSWorkspace.shared.notificationCenter.removeObserver(notice) }
        notices.removeAll()
    }
    private func watch(_ pid: pid_t) {
        guard let observer, pid > 0, pid != getpid(), !watched.contains(pid) else { return }
        let element = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let window = AXObserverAddNotification(observer, element, kAXFocusedWindowChangedNotification as CFString, refcon)
        let focused = AXObserverAddNotification(observer, element, kAXFocusedUIElementChangedNotification as CFString, refcon)
        if axRegistered(window) || axRegistered(focused) { watched.insert(pid) }
    }
    private func unwatch(_ pid: pid_t) {
        guard let observer else { return }
        let element = AXUIElementCreateApplication(pid)
        AXObserverRemoveNotification(observer, element, kAXFocusedWindowChangedNotification as CFString)
        AXObserverRemoveNotification(observer, element, kAXFocusedUIElementChangedNotification as CFString)
        watched.remove(pid)
    }
    private func axRegistered(_ error: AXError) -> Bool {
        error == .success || error.rawValue == AXError.notificationAlreadyRegistered.rawValue
    }
}

private final class AppSourcePicker: NSPopUpButton { var bundleID = "" }

final class AppSourcesSettings: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    unowned let owner: AppDelegate
    let enable = NSButton(checkboxWithTitle: "활성화", target: nil, action: nil)
    let edit = NSButton(title: "앱별 설정", target: nil, action: nil)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 380), styleMask: [.titled], backing: .buffered, defer: false)
    let table = NSTableView()
    let add = NSButton(title: "+", target: nil, action: nil)
    let remove = NSButton(title: "−", target: nil, action: nil)
    private var errors: [String: String] = [:]
    private var rows: [AppSourceRule] = []
    private var signature = ""
    private var installed = false

    init(owner: AppDelegate) { self.owner = owner; super.init() }
    func install(in panel: NSStackView) {
        enable.target = self; enable.action = #selector(toggle)
        edit.target = self; edit.action = #selector(showSheet); edit.bezelStyle = .rounded
        let section = NSStackView(views: [enable, edit]); section.orientation = .vertical; section.alignment = .leading; section.spacing = 8
        section.setCustomSpacing(10, after: enable)
        panel.addArrangedSubview(section)
        buildSheet(); installed = true; refresh(force: true)
    }
    // The list looks like the keyboards in the advanced settings.
    private func buildSheet() {
        window.title = "앱별 설정"; window.isReleasedWhenClosed = false
        let title = NSTextField(labelWithString: "앱별 설정")
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("app")); column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil; table.style = .fullWidth; table.rowHeight = 42; table.intercellSpacing = .zero
        table.usesAlternatingRowBackgroundColors = true
        table.allowsColumnReordering = false; table.allowsColumnResizing = false
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.dataSource = self; table.delegate = self
        table.setAccessibilityLabel("앱별 입력 소스")
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        let list = NSBox(); list.boxType = .custom; list.titlePosition = .noTitle
        list.cornerRadius = 7; list.borderWidth = 1; list.borderColor = .separatorColor; list.fillColor = .controlBackgroundColor
        list.contentViewMargins = .zero
        scroll.translatesAutoresizingMaskIntoConstraints = false; list.contentView!.addSubview(scroll)
        add.target = self; add.action = #selector(addApp); add.bezelStyle = .rounded; add.setAccessibilityLabel("앱 추가")
        remove.target = self; remove.action = #selector(removeApp); remove.bezelStyle = .rounded; remove.setAccessibilityLabel("선택한 앱 삭제")
        let buttons = NSStackView(views: [add, remove]); buttons.spacing = 4
        let done = NSButton(title: "완료", target: self, action: #selector(closeSheet)); done.bezelStyle = .rounded; done.keyEquivalent = "\r"
        let content = window.contentView!
        for view in [title, list, buttons, done] { view.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(view) }
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: list.contentView!.leadingAnchor, constant: 1),
            scroll.trailingAnchor.constraint(equalTo: list.contentView!.trailingAnchor, constant: -1),
            scroll.topAnchor.constraint(equalTo: list.contentView!.topAnchor, constant: 1),
            scroll.bottomAnchor.constraint(equalTo: list.contentView!.bottomAnchor, constant: -1),
            title.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),
            title.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            list.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 16),
            list.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            list.bottomAnchor.constraint(equalTo: done.topAnchor, constant: -18),
            buttons.leadingAnchor.constraint(equalTo: list.leadingAnchor),
            buttons.centerYAnchor.constraint(equalTo: done.centerYAnchor),
            done.trailingAnchor.constraint(equalTo: list.trailingAnchor),
            done.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18),
            done.widthAnchor.constraint(greaterThanOrEqualToConstant: 72)
        ])
    }
    // Repair calls this every second; a hidden window catches up within a second of being shown.
    func refresh(force: Bool = false) {
        guard installed, force || owner.window?.isVisible == true else { return }
        let trusted = owner.engine.accessibilityTrusted()
        let on = owner.appSourceRules.enabled
        enable.state = on ? .on : .off; enable.isEnabled = trusted; edit.isEnabled = trusted && on
        add.isEnabled = trusted
        let rules = owner.appSourceRules.rules
        let signature = "\(rules)\(owner.appSourceChoices.map(\.id))\(errors)\(trusted)"
        if self.signature != signature {
            // The table keeps a selection by row, and a new app can sort in above it.
            let selected = rows.indices.contains(table.selectedRow) ? rows[table.selectedRow].bundleID : nil
            self.signature = signature; rows = rules; table.reloadData()
            if let selected { select(selected) }
        }
        remove.isEnabled = trusted && rows.indices.contains(table.selectedRow)
    }
    private func select(_ bundleID: String) {
        guard let row = rows.firstIndex(where: { $0.bundleID == bundleID }) else { return }
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false); table.scrollRowToVisible(row)
    }
    func showError(_ message: String?, bundleID: String) { errors[bundleID] = message; refresh() }
    @objc func toggle() {
        owner.appSourceRules.enabled = enable.state == .on
        if enable.state == .on { owner.setSync(false) }
        owner.appSourceFocus.cancel(); errors.removeAll()
        refresh(force: true)
    }
    @objc func showSheet() { refresh(force: true); owner.window.beginSheet(window) }
    @objc func closeSheet() { owner.window.endSheet(window); window.orderOut(nil) }
    @objc func addApp() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false; panel.canChooseDirectories = false; panel.canChooseFiles = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications"); panel.prompt = "추가"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url, let bundle = Bundle(url: url),
                  let id = bundle.bundleIdentifier, id != Bundle.main.bundleIdentifier else { return }
            if self.rows.contains(where: { $0.bundleID == id }) { self.select(id); return }
            let choices = self.owner.appSourceChoices
            guard let source = choices.first(where: { $0.id == self.owner.currentSource?.id }) ?? choices.first else { return }
            // As Finder shows it, which is with ".app" when Finder shows all extensions.
            let shown = FileManager.default.displayName(atPath: url.path)
            let name = shown.hasSuffix(".app") ? String(shown.dropLast(4)) : shown
            self.owner.appSourceRules.set(AppSourceRule(bundleID: id, name: name, sourceID: source.id))
            self.refresh(force: true); self.select(id)
        }
    }
    @objc func removeApp() {
        guard rows.indices.contains(table.selectedRow) else { return }
        let id = rows[table.selectedRow].bundleID
        owner.appSourceRules.remove(id); errors[id] = nil; owner.appSourceFocus.cancel(); refresh(force: true)
    }
    @objc private func changeSource(_ sender: AppSourcePicker) {
        guard let id = sender.selectedItem?.representedObject as? String,
              var rule = rows.first(where: { $0.bundleID == sender.bundleID }) else { return }
        rule.sourceID = id; owner.appSourceRules.set(rule)
        errors[rule.bundleID] = nil; owner.appSourceFocus.cancel(); refresh(force: true)
    }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableViewSelectionDidChange(_ notification: Notification) { remove.isEnabled = owner.engine.accessibilityTrusted() && rows.indices.contains(table.selectedRow) }
    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        let rule = rows[row], cell = NSTableCellView()
        let name = NSTextField(labelWithString: rule.name); name.font = .systemFont(ofSize: 12); name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal); name.toolTip = rule.bundleID
        cell.textField = name
        let labels = NSStackView(views: [name]); labels.orientation = .vertical; labels.alignment = .leading; labels.spacing = 1
        if let error = errors[rule.bundleID] {
            let warning = NSTextField(labelWithString: error); warning.font = .systemFont(ofSize: 10); warning.textColor = .systemOrange
            warning.lineBreakMode = .byTruncatingTail; warning.toolTip = error; labels.addArrangedSubview(warning)
        }
        let picker = AppSourcePicker(); picker.bundleID = rule.bundleID
        // Without this the menu enables the item again as it opens.
        picker.autoenablesItems = false
        picker.controlSize = .small; picker.font = .systemFont(ofSize: NSFont.systemFontSize(for: .small))
        let sources = owner.appSourceChoices
        for source in sources {
            picker.addItem(withTitle: AppDelegate.sourceTitle(source.id)); picker.lastItem?.representedObject = source.id
        }
        // Chosen earlier and no longer in use: kept, and applied again once it is back.
        if !sources.contains(where: { $0.id == rule.sourceID }) {
            picker.addItem(withTitle: "\(AppDelegate.sourceTitle(rule.sourceID))(비활성)"); picker.lastItem?.representedObject = rule.sourceID; picker.lastItem?.isEnabled = false
        }
        picker.select(picker.itemArray.first { $0.representedObject as? String == rule.sourceID })
        picker.target = self; picker.action = #selector(changeSource(_:)); picker.isEnabled = owner.engine.accessibilityTrusted()
        picker.setAccessibilityLabel("\(rule.name) 입력 소스")
        for view in [labels, picker] { view.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(view) }
        NSLayoutConstraint.activate([
            labels.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 12), labels.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            labels.trailingAnchor.constraint(lessThanOrEqualTo: picker.leadingAnchor, constant: -16),
            picker.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -12), picker.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            picker.widthAnchor.constraint(equalToConstant: 200)
        ])
        return cell
    }
}

#if TESTS
func runAppSourceTests() {
    let name = "io.gksdud.app-source-tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    let rules = AppSourceRules(defaults: defaults)
    precondition(!rules.enabled && rules.rules.isEmpty)
    let blender = AppSourceRule(bundleID: "org.blenderfoundation.blender", name: "Blender", sourceID: "com.apple.keylayout.ABC")
    rules.set(blender); rules.enabled = true
    let reloaded = AppSourceRules(defaults: UserDefaults(suiteName: name)!)
    precondition(reloaded.enabled && reloaded.rules == [blender], "Rules and activation survive restart")
    var changed = blender; changed.sourceID = "com.apple.inputmethod.Korean.2SetKorean"
    rules.set(changed)
    precondition(rules.rules == [changed], "A new choice updates the app instead of adding a duplicate")
    rules.set(AppSourceRule(bundleID: "com.example.Removed", name: "Removed", sourceID: "com.example.DisabledSource"))
    precondition(rules.rules.count == 2, "Unavailable apps and input sources retain their rules")
    rules.remove(blender.bundleID)
    precondition(rules.rules.count == 1 && rules.rules[0].bundleID == "com.example.Removed")
    defaults.set(Data("bad-data".utf8), forKey: "appSources")
    precondition(rules.rules.isEmpty, "Malformed saved rules do not crash or select a source")

    var focus = AppSourceFocus()
    var first = focus.activate(101, frontmost: 101)!
    precondition(focus.accepts(first, pid: 101))
    let repeated = focus.activate(101, frontmost: 101)!
    precondition(!focus.accepts(first, pid: 101) && focus.accepts(repeated, pid: 101),
        "A reentry still applies when the intervening app's notice arrived after it lost focus")
    first = repeated
    precondition(focus.activate(102, frontmost: 101) == nil && focus.accepts(first, pid: 101), "A late notice for an app no longer focused cannot cancel the current request")
    let next = focus.activate(102, frontmost: 102)!
    precondition(!focus.accepts(first, pid: 101) && focus.accepts(next, pid: 102), "Moving even to an unregistered app invalidates the old request")
    let returned = focus.activate(101, frontmost: 101)!
    precondition(!focus.accepts(first, pid: 101) && focus.accepts(returned, pid: 101), "A -> B -> A must not revive A's first request")
    focus.cancel()
    precondition(!focus.accepts(returned, pid: 101), "Disabling or changing a rule cancels its scheduled application")
    let entered = focus.activate(101, frontmost: 101)!
    precondition(focus.activate(55, frontmost: 55, passing: true) == nil && !focus.accepts(entered, pid: 101), "Locking drops a request on its way")
    precondition(focus.activate(101, frontmost: 101) == nil, "Unlocking returns to the app without asking for its source again")
    precondition(focus.activate(101, frontmost: 101) != nil, "The next entry asks as usual")
    _ = focus.activate(55, frontmost: 101, passing: true)
    precondition(focus.activate(102, frontmost: 102) != nil, "Another app after the lock screen is a switch to it")
    var started = AppSourceFocus()
    started.begin(101)
    _ = started.activate(55, frontmost: 55, passing: true)
    precondition(started.activate(101, frontmost: 101) == nil, "Unlocked into the app that was in front before this one started")
    _ = started.activate(55, frontmost: 55, passing: true)
    precondition(started.activate(102, frontmost: 102) != nil, "The app in front was quit from the Force Quit window: the next one is a switch to it")
    var unknown = AppSourceFocus()
    _ = unknown.activate(55, frontmost: 55, passing: true)
    precondition(unknown.activate(101, frontmost: 101) != nil, "With no app known to have been in front, there is none to come back to")

    var overlay = AppSourceFocus()
    precondition(overlay.note(focused: nil, frontmost: 1, source: "ko") == .none)
    precondition(overlay.note(focused: 1, frontmost: 1, source: "ko") == .none, "The frontmost app's own window is not an overlay")
    precondition(overlay.note(focused: 9, frontmost: 1, source: "ko") == .entered(9))
    let overlayToken = overlay.overlayGeneration
    precondition(overlay.acceptsOverlay(overlayToken, pid: 9))
    precondition(overlay.note(focused: 9, frontmost: 1, source: "en") == .none, "The same overlay does not ask again")
    precondition(overlay.note(focused: 10, frontmost: 1, source: "en") == .entered(10))
    precondition(overlay.note(focused: 1, frontmost: 1, source: "en") == .returned("ko", enforced: nil),
        "A second overlay keeps the source from before the first")
    precondition(overlay.acceptsReturn(overlay.overlayGeneration))
    precondition(overlay.note(focused: 9, frontmost: 1, source: "abc") == .entered(9), "After it closes, the next one starts again")
    overlay.setEnforced("abc")
    let enforcedToken = overlay.overlayGeneration
    overlay.cancel()
    precondition(overlay.acceptsOverlay(enforcedToken, pid: 9), "A hand switch does not drop an overlay that is already showing")
    precondition(overlay.note(focused: nil, frontmost: 1, source: "ko") == .returned("abc", enforced: "abc"))
    precondition(overlay.note(focused: 9, frontmost: 1, source: "ko") == .entered(9))
    let abandoned = overlay.overlayGeneration
    precondition(overlay.note(focused: 9, frontmost: 2, source: "ko") == .abandoned)
    precondition(!overlay.acceptsOverlay(abandoned, pid: 9) && !overlay.acceptsReturn(abandoned),
        "Another app in front is not the overlay closing, and is not a switch back")
    var noOrigin = AppSourceFocus()
    precondition(noOrigin.note(focused: 9, frontmost: 1, source: nil) == .entered(9))
    precondition(noOrigin.note(focused: nil, frontmost: 1, source: "ko") == .none)
    precondition(AppSourceFocus.overlayOrigin(early: "ko", current: "abc", target: "abc", previous: "en", changedRecently: true) == "ko")
    precondition(AppSourceFocus.overlayOrigin(early: nil, current: "abc", target: "abc", previous: "ko", changedRecently: true) == "ko",
        "A selection that just landed on the overlay's source replaced the one typing was in")
    precondition(AppSourceFocus.overlayOrigin(early: nil, current: "ja", target: "abc", previous: "ko", changedRecently: true) == "ja")
    precondition(AppSourceFocus.overlayOrigin(early: nil, current: "abc", target: "abc", previous: "ko", changedRecently: false) == "abc")

    let alfredRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent("gksdud-alfred-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: alfredRoot) }
    let alfredKeyboard = alfredRoot.appendingPathComponent("Alfred.alfredpreferences/preferences/local/abc123/keyboard", isDirectory: true)
    do {
        try FileManager.default.createDirectory(at: alfredKeyboard, withIntermediateDirectories: true)
        let bundle = alfredRoot.appendingPathComponent("Alfred.alfredpreferences")
        let keyboardPlist = alfredKeyboard.appendingPathComponent("prefs.plist")
        try (["locale": "com.apple.keylayout.ABC"] as NSDictionary).write(to: keyboardPlist)
        let prefs = try JSONSerialization.data(withJSONObject: ["current": bundle.path, "localhash": "abc123"])
        try prefs.write(to: alfredRoot.appendingPathComponent("prefs.json"))
        precondition(AlfredForcedKeyboard.locale(in: alfredRoot) == "com.apple.keylayout.ABC")
        try (["locale": ""] as NSDictionary).write(to: keyboardPlist)
        precondition(AlfredForcedKeyboard.locale(in: alfredRoot) == nil, "An empty Force Keyboard keeps the current source")
        try (["locale": "com.apple.keylayout.ABC"] as NSDictionary).write(to: keyboardPlist)
        let escaped = try JSONSerialization.data(withJSONObject: ["current": bundle.path, "localhash": "../abc123"])
        try escaped.write(to: alfredRoot.appendingPathComponent("prefs.json"))
        precondition(AlfredForcedKeyboard.locale(in: alfredRoot) == nil)
        let outside = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent("Alfred.alfredpreferences")
        let elsewhere = try JSONSerialization.data(withJSONObject: ["current": outside.path, "localhash": "abc123"])
        try elsewhere.write(to: alfredRoot.appendingPathComponent("prefs.json"))
        precondition(AlfredForcedKeyboard.locale(in: alfredRoot) == nil, "The preferences bundle stays inside Alfred's folder")
    } catch { preconditionFailure("\(error)") }

    let engine = Engine(defaults: defaults, discover: { [] })
    engine.accessibilityTrusted = { true }; engine.sessionAway = { false }
    let delegate = AppDelegate(engine: engine)
    defaults.set(false, forKey: "active")
    precondition(!delegate.appSourcesActive)
    rules.enabled = true; defaults.set(true, forKey: "active")
    precondition(delegate.appSourcesActive)
    rules.enabled = false
    precondition(delegate.inputSwitchReady && !delegate.appSourcesActive, "Alfred's own source does not wait for the per-app list")
    rules.enabled = true
    engine.paused = true; precondition(!delegate.appSourcesActive); engine.paused = false
    engine.sessionAway = { true }; precondition(!delegate.appSourcesActive); engine.sessionAway = { false }
    engine.accessibilityTrusted = { false }; precondition(!delegate.appSourcesActive); engine.accessibilityTrusted = { true }
    // A switch made by hand, or the tap going away, drops the app's source on its way.
    var waiting = delegate.appSourceFocus.activate(7, frontmost: 7)!
    delegate.rememberCapsBeforeSwitch()
    precondition(!delegate.appSourceFocus.accepts(waiting, pid: 7))
    waiting = delegate.appSourceFocus.activate(7, frontmost: 7)!
    delegate.stopKeyTap()
    precondition(!delegate.appSourceFocus.accepts(waiting, pid: 7))
    // An app's source is chosen among Korean and English, or with the sources managed, among the ones left on.
    let korean = InputSourceIdentity(id: "com.apple.inputmethod.Korean.2SetKorean", language: "ko"),
        abc = InputSourceIdentity(id: "com.apple.keylayout.ABC", language: "en"),
        japanese = InputSourceIdentity(id: "com.apple.inputmethod.Kotoeri.RomajiTyping.Japanese", language: "ja")
    delegate.sourceCache = (list: [korean, abc, japanese], layouts: [abc.id])
    precondition(delegate.appSourceChoices.map(\.id) == [korean.id, abc.id])
    let alfred = AlfredForcedKeyboard.bundleID
    delegate.alfredLocale = { abc.id }
    delegate.alfredLocaleCache = nil
    rules.enabled = false
    precondition(delegate.overlayTarget(bundle: alfred)?.id == abc.id && delegate.overlayTarget(bundle: "com.apple.Terminal") == nil,
        "With the per-app list off, only Alfred's Force Keyboard is followed")
    rules.enabled = true
    rules.set(AppSourceRule(bundleID: alfred, name: "Alfred", sourceID: korean.id))
    delegate.alfredLocaleCache = nil
    precondition(delegate.overlayTarget(bundle: alfred)?.id == korean.id, "An app's own rule wins over Alfred's Force Keyboard")
    rules.set(AppSourceRule(bundleID: alfred, name: "Alfred", sourceID: japanese.id))
    delegate.alfredLocaleCache = nil
    precondition(delegate.overlayTarget(bundle: alfred) == nil, "A rule whose source is not in use does not fall through to Alfred")
    rules.enabled = false
    delegate.alfredLocale = { "com.example.NotEnabled" }
    delegate.alfredLocaleCache = nil
    precondition(delegate.overlayTarget(bundle: alfred) == nil)
    rules.remove(alfred)
    defaults.set(true, forKey: "addedSources"); engine.disabledSources = [abc.id]
    precondition(delegate.appSourceChoices.map(\.id) == [korean.id, japanese.id])
    let shown = delegate.appSourceFocus.note(focused: 9, frontmost: 7, source: korean.id)
    precondition(shown == .entered(9))
    let shownToken = delegate.appSourceFocus.overlayGeneration
    delegate.rememberCapsBeforeSwitch()
    precondition(delegate.appSourceFocus.acceptsOverlay(shownToken, pid: 9))
    delegate.stopKeyTap()
    precondition(!delegate.appSourceFocus.acceptsOverlay(shownToken, pid: 9) && delegate.appSourceFocus.overlay == nil,
        "Stopping the tap drops the overlay without switching")
    print("PASS: app source rule persistence, replacement and removal, unavailable sources, focus reentry, stale activation cancellation, the lock screen, pause/permission/session guards, the sources offered, overlay focus, Alfred's forced keyboard")
}
#endif
