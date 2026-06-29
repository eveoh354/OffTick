import AppKit
import Darwin
import IOKit
import ServiceManagement
import UniformTypeIdentifiers
import UserNotifications

final class OffTickApp: NSObject, NSApplicationDelegate {
    private let statusItemAutosaveName = "\(Bundle.main.bundleIdentifier ?? "online.eveoh.offtick").statusItem"
    private var statusItem: NSStatusItem!
    private var panel: NSPanel!
    private var stackView: NSStackView!
    private var timer: Timer?
    private var isShowingSettings = false
    private let timeProvider = NetworkTimeProvider()
    private weak var liveEarnedMenuItem: NSMenuItem?
    private weak var liveDailyMenuItem: NSMenuItem?
    private weak var liveTimeMenuItem: NSMenuItem?
    private weak var liveCountdownMenuItem: NSMenuItem?
    private var stackLeadingConstraint: NSLayoutConstraint?
    private var stackTrailingConstraint: NSLayoutConstraint?
    private var stackTopConstraint: NSLayoutConstraint?
    private var stackBottomConstraint: NSLayoutConstraint?
    private var instanceLockFileDescriptor: Int32 = -1
    private let notificationCoordinator = NotificationCoordinator()
    private var availableUpdate: GitHubRelease?
    private var isCheckingForUpdate = false
    private var previousClockOutState: Bool?
    private var panelContentInsets: NSEdgeInsets {
        settings.panelSize.contentInsets
    }

    private var settings = WorkSettings.load()

    private func t(_ key: String) -> String {
        L10n.text(key, language: settings.language)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard acquireSingleInstanceLock() else {
            NSApp.terminate(nil)
            return
        }

        NSApp.setActivationPolicy(.accessory)
        notificationCoordinator.requestAuthorization()
        setupStatusItem()
        setupPanel()
        timeProvider.sync { [weak self] in
            self?.recordUnlockIfNeeded()
            self?.updateContent()
            self?.showPanelOnCurrentScreen()
        }
        setupUnlockObservers()
        updateContent()
        checkForUpdatesIfNeeded()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.showPanelOnCurrentScreen()
        }

        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else {
                return
            }

            self.timeProvider.sync()

            if !self.isShowingSettings {
                self.updateContent()
            }

            self.updateLiveMenuItems()
            self.checkClockOutCelebration()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        DistributedNotificationCenter.default().removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        timer?.invalidate()
        if instanceLockFileDescriptor >= 0 {
            flock(instanceLockFileDescriptor, LOCK_UN)
            close(instanceLockFileDescriptor)
        }
    }

    private func acquireSingleInstanceLock() -> Bool {
        let lockPath = "/tmp/dev.local.OffTick.lock"
        let descriptor = open(lockPath, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            return true
        }

        if flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            close(descriptor)
            return false
        }

        instanceLockFileDescriptor = descriptor
        return true
    }

    private func setupUnlockObservers() {
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(screenDidUnlock),
            name: Notification.Name("com.apple.screenIsUnlocked"),
            object: nil
        )

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(screenDidUnlock),
            name: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil
        )
    }

    @objc private func screenDidUnlock() {
        timeProvider.sync { [weak self] in
            self?.recordUnlockIfNeeded()
            self?.updateContent()
        }
    }

    private func recordUnlockIfNeeded() {
        guard settings.mode == .unlockTimer else {
            return
        }

        guard timeProvider.isSynced else {
            return
        }

        WorkSessionClock.recordUnlockIfNeeded(now: timeProvider.now)
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.autosaveName = statusItemAutosaveName
        configureStatusItemButton(toolTip: "OffTick")

        rebuildStatusMenu(snapshot: nil)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.configureStatusItemButton(toolTip: "OffTick")
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.configureStatusItemButton(toolTip: "OffTick")
        }
    }

    private func configureStatusItemButton(toolTip: String) {
        statusItem.isVisible = true
        statusItem.length = NSStatusItem.squareLength

        guard let button = statusItem.button else {
            return
        }

        button.title = ""
        button.image = statusIcon()
        button.imagePosition = .imageOnly
        button.toolTip = toolTip
    }

    private func statusIcon() -> NSImage? {
        let image = NSImage(systemSymbolName: "clock", accessibilityDescription: "OffTick")
        image?.size = NSSize(width: 18, height: 18)
        image?.isTemplate = true
        return image
    }

    private func setupPanel() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 180),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "OffTick"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.hasShadow = true
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        applyPanelScreenshotSharing()

        stackView = NSStackView()
        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.spacing = settings.panelSize.stackSpacing
        stackView.translatesAutoresizingMaskIntoConstraints = false

        let container = makePanelBackgroundView()
        let contentContainer = panelContentContainer(for: container)
        container.menu = makePanelContextMenu()
        contentContainer.menu = container.menu
        contentContainer.addSubview(stackView)
        panel.contentView = container

        stackLeadingConstraint = stackView.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor, constant: panelContentInsets.left)
        stackTrailingConstraint = stackView.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor, constant: -panelContentInsets.right)
        stackTopConstraint = stackView.topAnchor.constraint(equalTo: contentContainer.topAnchor, constant: panelContentInsets.top)
        stackBottomConstraint = stackView.bottomAnchor.constraint(lessThanOrEqualTo: contentContainer.bottomAnchor, constant: -panelContentInsets.bottom)

        NSLayoutConstraint.activate([
            stackLeadingConstraint,
            stackTrailingConstraint,
            stackTopConstraint,
            stackBottomConstraint
        ].compactMap { $0 })
    }

    private func makePanelBackgroundView() -> NSView {
        if #available(macOS 26.0, *) {
            let glassView = NSGlassEffectView()
            glassView.cornerRadius = 18
            glassView.clipsToBounds = true
            glassView.tintColor = NSColor.white.withAlphaComponent(0.05)
            return glassView
        }

        let effectView = NSVisualEffectView()
        effectView.blendingMode = .behindWindow
        effectView.material = .popover
        effectView.state = .active
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = 18
        effectView.layer?.masksToBounds = true
        effectView.layer?.borderWidth = 0.5
        effectView.layer?.borderColor = NSColor.white.withAlphaComponent(0.22).cgColor
        return effectView
    }

    private func makePanelContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: t("hidePanel"), action: #selector(hidePanel), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: t("settings"), action: #selector(showSettingsFromMenu), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: t("quit"), action: #selector(quit), keyEquivalent: "q"))
        menu.items.forEach { $0.target = self }
        return menu
    }

    private func panelContentContainer(for backgroundView: NSView) -> NSView {
        if #available(macOS 26.0, *),
           let glassView = backgroundView as? NSGlassEffectView,
           let contentView = glassView.contentView {
            return contentView
        }

        return backgroundView
    }

    @objc private func togglePanel() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showStatusMenu()
            return
        }

        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            positionPanelNearStatusItem()
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func showStatusMenu() {
        let snapshot = OffTickSnapshot(settings: settings, now: timeProvider.now)
        let menu = makeStatusMenu(snapshot: snapshot)
        if let button = statusItem.button {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.maxY + 4), in: button)
        }
    }

    @objc private func togglePanelFromMenu() {
        togglePanel()
    }

    @objc private func showSettingsFromMenu() {
        isShowingSettings = true
        updateContent()
        if !panel.isVisible {
            positionPanelNearStatusItem()
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    @objc private func hidePanel() {
        panel.orderOut(nil)
    }

    private func refreshPanelContextMenu() {
        guard let contentView = panel.contentView else {
            return
        }

        let menu = makePanelContextMenu()
        contentView.menu = menu
        if #available(macOS 26.0, *),
           let glassView = contentView as? NSGlassEffectView,
           let glassContentView = glassView.contentView {
            glassContentView.menu = menu
        }
    }

    private func showPanelOnCurrentScreen() {
        guard !panel.isVisible else {
            return
        }

        if let screen = NSScreen.main {
            let visibleFrame = screen.visibleFrame
            let panelSize = panel.frame.size
            let x = visibleFrame.maxX - panelSize.width - 24
            let y = visibleFrame.maxY - panelSize.height - 24
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        } else {
            panel.center()
        }

        panel.makeKeyAndOrderFront(nil)
    }

    private func positionPanelNearStatusItem() {
        guard let button = statusItem.button, let screen = button.window?.screen ?? NSScreen.main else {
            panel.center()
            return
        }

        let buttonFrame = button.window?.convertToScreen(button.frame) ?? .zero
        let panelSize = panel.frame.size
        let visibleFrame = screen.visibleFrame
        let x = min(max(buttonFrame.midX - panelSize.width / 2, visibleFrame.minX + 12), visibleFrame.maxX - panelSize.width - 12)
        let y = visibleFrame.maxY - panelSize.height - 12
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func updateContent() {
        if isShowingSettings {
            renderSettings()
            return
        }

        guard timeProvider.isSynced else {
            renderSyncing()
            configureStatusItemButton(toolTip: "OffTick \(t("syncingTime"))")
            rebuildStatusMenu(snapshot: nil)
            return
        }

        let snapshot = OffTickSnapshot(settings: settings, now: timeProvider.now)
        renderOverview(snapshot: snapshot)
        configureStatusItemButton(toolTip: "OffTick \(snapshot.statusTitle())")
        rebuildStatusMenu(snapshot: snapshot)
    }

    @objc private func showSettings() {
        isShowingSettings = true
        updateContent()
    }

    @objc private func showOverview() {
        isShowingSettings = false
        updateContent()
    }

    private func renderSettings() {
        clearStack()
        panel.setContentSize(NSSize(width: 340, height: 718))

        let title = makeLabel(t("settings"), size: 18, weight: .semibold)
        stackView.addArrangedSubview(title)
        stackView.addArrangedSubview(makeSeparator())

        stackView.addArrangedSubview(makeSectionTitle(t("display")))
        let languagePopUp = makeLanguagePopUp()
        stackView.addArrangedSubview(makeRow(label: t("language"), control: languagePopUp, suffix: nil))

        let timeFormatControl = NSSegmentedControl(labels: [t("hour24"), t("hour12")], trackingMode: .selectOne, target: self, action: #selector(timeFormatChanged(_:)))
        timeFormatControl.selectedSegment = settings.timeFormat == .twentyFourHour ? 0 : 1
        timeFormatControl.translatesAutoresizingMaskIntoConstraints = false
        timeFormatControl.widthAnchor.constraint(equalToConstant: 170).isActive = true
        stackView.addArrangedSubview(makeRow(label: t("time"), control: timeFormatControl, suffix: nil))

        let calendarControl = NSSegmentedControl(labels: [t("gregorian"), t("lunar")], trackingMode: .selectOne, target: self, action: #selector(calendarModeChanged(_:)))
        calendarControl.selectedSegment = settings.calendarMode == .gregorian ? 0 : 1
        calendarControl.translatesAutoresizingMaskIntoConstraints = false
        calendarControl.widthAnchor.constraint(equalToConstant: 170).isActive = true
        stackView.addArrangedSubview(makeRow(label: t("date"), control: calendarControl, suffix: nil))

        let panelSizeControl = NSSegmentedControl(labels: PanelSizeMode.allCases.map { t($0.titleKey) }, trackingMode: .selectOne, target: self, action: #selector(panelSizeChanged(_:)))
        panelSizeControl.selectedSegment = PanelSizeMode.allCases.firstIndex(of: settings.panelSize) ?? 1
        panelSizeControl.translatesAutoresizingMaskIntoConstraints = false
        panelSizeControl.widthAnchor.constraint(equalToConstant: 170).isActive = true
        stackView.addArrangedSubview(makeRow(label: t("panelSize"), control: panelSizeControl, suffix: nil))

        stackView.addArrangedSubview(makeSectionTitle(t("panelContent")))
        stackView.addArrangedSubview(makeCheckbox(title: t("date"), isOn: settings.showDateInPanel, action: #selector(panelContentChanged(_:)), tag: PanelContentField.date.rawValue))
        stackView.addArrangedSubview(makeCheckbox(title: t("time"), isOn: settings.showTimeInPanel, action: #selector(panelContentChanged(_:)), tag: PanelContentField.time.rawValue))
        stackView.addArrangedSubview(makeCheckbox(title: t("countdown"), isOn: settings.showCountdownInPanel, action: #selector(panelContentChanged(_:)), tag: PanelContentField.countdown.rawValue))
        stackView.addArrangedSubview(makeCheckbox(title: t("earnedIncome"), isOn: settings.showEarnedIncomeInPanel, action: #selector(panelContentChanged(_:)), tag: PanelContentField.earnedIncome.rawValue))
        stackView.addArrangedSubview(makeCheckbox(title: t("dailyIncome"), isOn: settings.showDailyIncomeInPanel, action: #selector(panelContentChanged(_:)), tag: PanelContentField.dailyIncome.rawValue))

        stackView.addArrangedSubview(makeSeparator())
        stackView.addArrangedSubview(makeSectionTitle(t("options")))
        stackView.addArrangedSubview(makeCheckbox(title: t("includePanelInScreenshots"), isOn: settings.includePanelInScreenshots, action: #selector(screenshotSharingChanged(_:)), tag: 0))
        let launchAtLoginCheckbox = makeCheckbox(title: t("launchAtLogin"), isOn: LoginItemController.isEnabled, action: #selector(launchAtLoginChanged(_:)), tag: 0)
        launchAtLoginCheckbox.isEnabled = LoginItemController.isSupported
        stackView.addArrangedSubview(launchAtLoginCheckbox)

        stackView.addArrangedSubview(makeSeparator())
        stackView.addArrangedSubview(makeSectionTitle(t("watermarkFormat")))
        stackView.addArrangedSubview(makeCheckbox(title: t("watermarkIncludeDate"), isOn: settings.includeDateInExportWatermark, action: #selector(watermarkFormatChanged(_:)), tag: WatermarkField.date.rawValue))
        stackView.addArrangedSubview(makeCheckbox(title: t("watermarkIncludeDevice"), isOn: settings.includeDeviceInExportWatermark, action: #selector(watermarkFormatChanged(_:)), tag: WatermarkField.device.rawValue))

        stackView.addArrangedSubview(makeSeparator())
        stackView.addArrangedSubview(makeSectionTitle(t("income")))
        let monthlyIncomeField = makeNumberField(value: settings.monthlyIncome, tag: SettingField.monthlyIncome.rawValue)
        stackView.addArrangedSubview(makeRow(label: t("monthlyIncome"), control: monthlyIncomeField, suffix: t("yuan")))

        let workdaysField = makeNumberField(value: Double(settings.workdaysInMonth), tag: SettingField.workdaysInMonth.rawValue)
        stackView.addArrangedSubview(makeRow(label: t("workdaysInMonth"), control: workdaysField, suffix: t("days")))

        stackView.addArrangedSubview(makeSeparator())
        stackView.addArrangedSubview(makeSectionTitle(t("timer")))
        let modeControl = NSSegmentedControl(labels: [t("fixedClockOut"), t("unlockTimer")], trackingMode: .selectOne, target: self, action: #selector(modeChanged(_:)))
        modeControl.selectedSegment = settings.mode == .fixedTime ? 0 : 1
        modeControl.translatesAutoresizingMaskIntoConstraints = false
        modeControl.widthAnchor.constraint(equalToConstant: 170).isActive = true
        stackView.addArrangedSubview(makeRow(label: t("workMode"), control: modeControl, suffix: nil))

        switch settings.mode {
        case .fixedTime:
            let startTimeStack = NSStackView()
            startTimeStack.orientation = .horizontal
            startTimeStack.spacing = 6

            let startHourField = makeNumberField(value: Double(settings.fixedStartHour), tag: SettingField.fixedStartHour.rawValue)
            startHourField.widthAnchor.constraint(equalToConstant: 46).isActive = true
            let startMinuteField = makeNumberField(value: Double(settings.fixedStartMinute), tag: SettingField.fixedStartMinute.rawValue)
            startMinuteField.widthAnchor.constraint(equalToConstant: 46).isActive = true

            startTimeStack.addArrangedSubview(startHourField)
            startTimeStack.addArrangedSubview(NSTextField(labelWithString: ":"))
            startTimeStack.addArrangedSubview(startMinuteField)
            stackView.addArrangedSubview(makeRow(label: t("startTime"), control: startTimeStack, suffix: nil))

            let fixedTimeStack = NSStackView()
            fixedTimeStack.orientation = .horizontal
            fixedTimeStack.spacing = 6

            let hourField = makeNumberField(value: Double(settings.fixedClockOutHour), tag: SettingField.fixedClockOutHour.rawValue)
            hourField.widthAnchor.constraint(equalToConstant: 46).isActive = true
            let minuteField = makeNumberField(value: Double(settings.fixedClockOutMinute), tag: SettingField.fixedClockOutMinute.rawValue)
            minuteField.widthAnchor.constraint(equalToConstant: 46).isActive = true

            fixedTimeStack.addArrangedSubview(hourField)
            fixedTimeStack.addArrangedSubview(NSTextField(labelWithString: ":"))
            fixedTimeStack.addArrangedSubview(minuteField)
            stackView.addArrangedSubview(makeRow(label: t("clockOutTime"), control: fixedTimeStack, suffix: nil))
        case .unlockTimer:
            let dailyHoursField = makeNumberField(value: settings.dailyWorkHours, tag: SettingField.dailyWorkHours.rawValue)
            stackView.addArrangedSubview(makeRow(label: t("dailyHours"), control: dailyHoursField, suffix: t("hoursUnit")))

            let exportButton = NSButton(title: t("exportUnlockRecords"), target: self, action: #selector(exportUnlockRecords))
            exportButton.bezelStyle = .rounded
            stackView.addArrangedSubview(makeRow(label: t("unlockRecords"), control: exportButton, suffix: nil))
        }

        let footer = NSStackView()
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 8

        let doneButton = NSButton(title: t("done"), target: self, action: #selector(showOverview))
        doneButton.bezelStyle = .rounded
        doneButton.keyEquivalent = "\r"
        let resetButton = NSButton(title: t("resetDefault"), target: self, action: #selector(resetSettings))
        resetButton.bezelStyle = .rounded

        footer.addArrangedSubview(doneButton)
        footer.addArrangedSubview(resetButton)
        stackView.addArrangedSubview(footer)

        configureStatusItemButton(toolTip: "OffTick \(t("settings"))")
    }

    @objc private func exportUnlockRecords() {
        guard timeProvider.isSynced else {
            timeProvider.sync { [weak self] in
                guard let self else {
                    return
                }

                if self.timeProvider.isSynced {
                    self.exportUnlockRecords()
                } else {
                    self.showMessage(title: self.t("networkTimeUnavailable"), message: self.t("networkTimeUnavailableHint"))
                }
            }
            return
        }

        let now = timeProvider.now
        let calendar = Calendar.beijing
        let defaultStart = calendar.date(byAdding: .month, value: -1, to: now) ?? now
        let dateFormatter = Self.exportDateFormatter

        let startField = NSTextField(string: dateFormatter.string(from: defaultStart))
        let endField = NSTextField(string: dateFormatter.string(from: now))
        [startField, endField].forEach {
            $0.placeholderString = "yyyy-MM-dd"
            $0.bezelStyle = .roundedBezel
            $0.controlSize = .regular
            $0.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
            $0.frame.size = NSSize(width: 140, height: 24)
        }

        let accessoryView = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 70))
        addExportDateRow(to: accessoryView, label: t("exportStartDate"), field: startField, y: 40)
        addExportDateRow(to: accessoryView, label: t("exportEndDate"), field: endField, y: 6)

        let alert = NSAlert()
        alert.messageText = t("exportUnlockRecords")
        alert.informativeText = t("exportUnlockRecordsHint")
        alert.accessoryView = accessoryView
        alert.addButton(withTitle: t("export"))
        alert.addButton(withTitle: t("cancel"))

        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }

        guard let startDate = dateFormatter.date(from: startField.stringValue),
              let endDate = dateFormatter.date(from: endField.stringValue),
              startDate <= endDate else {
            showMessage(title: t("invalidDateRange"), message: t("dateRangeFormatHint"))
            return
        }

        let endOfDay = calendar.date(byAdding: DateComponents(day: 1, second: -1), to: calendar.startOfDay(for: endDate)) ?? endDate
        let records = WorkSessionClock.records(from: startDate, to: endOfDay)
        guard !records.isEmpty else {
            showMessage(title: t("noUnlockRecords"), message: t("noUnlockRecordsHint"))
            return
        }

        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.pdf]
        savePanel.canCreateDirectories = true
        savePanel.nameFieldStringValue = "OffTick-Unlock-Records-\(WorkSessionClock.dateKey(startDate))-\(WorkSessionClock.dateKey(endDate)).pdf"

        guard savePanel.runModal() == .OK, let url = savePanel.url else {
            return
        }

        do {
            try UnlockRecordsPDFExporter.write(records: records, from: startDate, to: endOfDay, settings: settings, generatedAt: timeProvider.now, to: url)
            showMessage(title: t("exportComplete"), message: url.path) {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        } catch {
            showMessage(title: t("exportFailed"), message: error.localizedDescription)
        }
    }

    private func addExportDateRow(to container: NSView, label: String, field: NSTextField, y: CGFloat) {
        let labelView = NSTextField(labelWithString: label)
        labelView.font = .systemFont(ofSize: 13)
        labelView.textColor = .secondaryLabelColor
        labelView.alignment = .right
        labelView.frame = NSRect(x: 0, y: y + 3, width: 82, height: 18)

        field.frame.origin = NSPoint(x: 96, y: y)
        container.addSubview(labelView)
        container.addSubview(field)
    }

    private func showMessage(title: String, message: String, completion: (() -> Void)? = nil) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
        completion?()
    }

    private static let exportDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar.beijing
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private func renderSyncing() {
        clearStack()
        let metrics = settings.panelSize
        applyPanelLayoutMetrics(metrics)
        panel.setContentSize(NSSize(width: metrics.panelWidth, height: metrics.syncingHeight))

        stackView.addArrangedSubview(makeLabel("OffTick", size: metrics.brandFontSize, weight: .semibold, color: .secondaryLabelColor))
        stackView.addArrangedSubview(makeLabel(t("syncingTime"), size: metrics.messageFontSize, weight: .semibold))
    }

    private func renderOverview(snapshot: OffTickSnapshot) {
        clearStack()
        let metrics = settings.panelSize
        applyPanelLayoutMetrics(metrics)
        let visibleItemCount = settings.panelVisibleItemCount
        let panelHeight = max(metrics.minimumPanelHeight, metrics.heightBase + CGFloat(visibleItemCount) * metrics.itemHeight)
        panel.setContentSize(NSSize(width: metrics.panelWidth, height: panelHeight))

        if visibleItemCount == 0 {
            stackView.addArrangedSubview(makeLabel("OffTick", size: metrics.brandFontSize, weight: .semibold, color: .secondaryLabelColor))
            stackView.addArrangedSubview(makeLabel(t("noPanelContent"), size: metrics.messageFontSize, weight: .semibold))
            return
        }

        var hasAddedPrimary = false

        if settings.showDateInPanel {
            let dateLabel = makeLabel(snapshot.dateText(), size: metrics.dateFontSize, weight: .medium, color: .secondaryLabelColor)
            stackView.addArrangedSubview(dateLabel)
        }

        if settings.showTimeInPanel {
            let timeLabel = makeLabel(snapshot.timeText(), size: metrics.timeFontSize, weight: .semibold)
            timeLabel.font = .monospacedDigitSystemFont(ofSize: metrics.timeFontSize, weight: .semibold)
            stackView.addArrangedSubview(timeLabel)
            hasAddedPrimary = true
        }

        if hasAddedPrimary && (settings.showCountdownInPanel || settings.showEarnedIncomeInPanel || settings.showDailyIncomeInPanel) {
            stackView.addArrangedSubview(makeSeparator())
        }

        if settings.showCountdownInPanel {
            stackView.addArrangedSubview(makeVerticalMetric(caption: t("countdown"), value: snapshot.countdownText(), color: .controlAccentColor))
        }

        if settings.showEarnedIncomeInPanel {
            stackView.addArrangedSubview(makeMetric(caption: t("earnedIncome"), value: String(format: "¥%.2f", snapshot.earnedToday()), color: .labelColor))
        }

        if settings.showDailyIncomeInPanel {
            stackView.addArrangedSubview(makeMetric(caption: t("dailyIncome"), value: String(format: "¥%.2f", settings.dailyIncome), color: .labelColor))
        }
    }

    private func clearStack() {
        stackView.arrangedSubviews.forEach {
            stackView.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
    }

    private func applyPanelLayoutMetrics(_ metrics: PanelSizeMode) {
        let insets = metrics.contentInsets
        stackView.spacing = metrics.stackSpacing
        stackLeadingConstraint?.constant = insets.left
        stackTrailingConstraint?.constant = -insets.right
        stackTopConstraint?.constant = insets.top
        stackBottomConstraint?.constant = -insets.bottom
    }

    private func makeLabel(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor = .labelColor) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = color
        label.lineBreakMode = .byTruncatingTail
        return label
    }

    private func makeSectionTitle(_ text: String) -> NSTextField {
        let label = makeLabel(text, size: 11, weight: .semibold, color: .secondaryLabelColor)
        label.stringValue = text.uppercased()
        return label
    }

    private func makeMetric(caption: String, value: String, color: NSColor) -> NSStackView {
        let metrics = settings.panelSize
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = metrics.metricSpacing
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: metrics.contentWidth).isActive = true

        let captionLabel = makeLabel(caption, size: metrics.captionFontSize, weight: .medium, color: .secondaryLabelColor)
        captionLabel.widthAnchor.constraint(equalToConstant: metrics.captionWidth).isActive = true

        let valueLabel = makeLabel(value, size: metrics.valueFontSize, weight: .semibold, color: color)
        valueLabel.font = .monospacedDigitSystemFont(ofSize: metrics.valueFontSize, weight: .semibold)

        row.addArrangedSubview(captionLabel)
        row.addArrangedSubview(valueLabel)
        return row
    }

    private func makeVerticalMetric(caption: String, value: String, color: NSColor) -> NSStackView {
        let metrics = settings.panelSize
        let group = NSStackView()
        group.orientation = .vertical
        group.alignment = .leading
        group.spacing = metrics.verticalMetricSpacing
        group.translatesAutoresizingMaskIntoConstraints = false
        group.widthAnchor.constraint(equalToConstant: metrics.contentWidth).isActive = true

        let captionLabel = makeLabel(caption, size: metrics.captionFontSize, weight: .medium, color: .secondaryLabelColor)
        let valueLabel = makeLabel(value, size: metrics.countdownFontSize, weight: .semibold, color: color)
        valueLabel.font = .monospacedDigitSystemFont(ofSize: metrics.countdownFontSize, weight: .semibold)

        group.addArrangedSubview(captionLabel)
        group.addArrangedSubview(valueLabel)
        return group
    }

    private func makeCheckbox(title: String, isOn: Bool, action: Selector, tag: Int) -> NSButton {
        let checkbox = NSButton(checkboxWithTitle: title, target: self, action: action)
        checkbox.state = isOn ? .on : .off
        checkbox.tag = tag
        checkbox.controlSize = .small
        checkbox.font = .systemFont(ofSize: 13)
        checkbox.translatesAutoresizingMaskIntoConstraints = false
        checkbox.widthAnchor.constraint(equalToConstant: 320).isActive = true
        return checkbox
    }

    private func makeLanguagePopUp() -> NSPopUpButton {
        let popUp = NSPopUpButton()
        popUp.controlSize = .small
        popUp.target = self
        popUp.action = #selector(languagePopUpChanged(_:))
        for language in AppLanguage.allCases {
            popUp.addItem(withTitle: language.displayName)
            popUp.lastItem?.tag = language.rawValue
        }
        popUp.selectItem(withTag: settings.language.rawValue)
        popUp.translatesAutoresizingMaskIntoConstraints = false
        popUp.widthAnchor.constraint(equalToConstant: 170).isActive = true
        return popUp
    }

    private func makeSeparator() -> NSBox {
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.widthAnchor.constraint(equalToConstant: isShowingSettings ? 246 : settings.panelSize.contentWidth).isActive = true
        return separator
    }

    private func rebuildStatusMenu(snapshot: OffTickSnapshot?) {
        statusItem.menu = makeStatusMenu(snapshot: snapshot)
    }

    private func makeStatusMenu(snapshot: OffTickSnapshot?) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: panel?.isVisible == true ? t("hidePanel") : t("showPanel"), action: #selector(togglePanelFromMenu), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: t("settings"), action: #selector(showSettingsFromMenu), keyEquivalent: ","))
        menu.addItem(makeLanguageMenuItem())
        menu.addItem(makeUpdateMenuItem())
        menu.addItem(NSMenuItem.separator())

        if let snapshot {
            let dateItem = NSMenuItem(title: snapshot.dateText(), action: nil, keyEquivalent: "")
            dateItem.isEnabled = false
            let timeItem = NSMenuItem(title: "\(t("currentTime"))：\(snapshot.timeText())", action: nil, keyEquivalent: "")
            timeItem.isEnabled = false
            let countdownItem = NSMenuItem(title: "\(t("countdown"))：\(snapshot.countdownText())", action: nil, keyEquivalent: "")
            countdownItem.isEnabled = false
            menu.addItem(dateItem)
            menu.addItem(timeItem)
            menu.addItem(countdownItem)
            menu.addItem(NSMenuItem.separator())

            let earnedItem = NSMenuItem(title: String(format: "\(t("earnedIncome"))：¥%.2f", snapshot.earnedToday()), action: nil, keyEquivalent: "")
            earnedItem.isEnabled = false
            let dailyItem = NSMenuItem(title: String(format: "\(t("dailyIncome"))：¥%.2f", settings.dailyIncome), action: nil, keyEquivalent: "")
            dailyItem.isEnabled = false
            menu.addItem(earnedItem)
            menu.addItem(dailyItem)
            liveTimeMenuItem = timeItem
            liveCountdownMenuItem = countdownItem
            liveEarnedMenuItem = earnedItem
            liveDailyMenuItem = dailyItem
        } else {
            let waitingItem = NSMenuItem(title: t("waitingIncome"), action: nil, keyEquivalent: "")
            waitingItem.isEnabled = false
            menu.addItem(waitingItem)
            liveTimeMenuItem = nil
            liveCountdownMenuItem = nil
            liveEarnedMenuItem = nil
            liveDailyMenuItem = nil
        }

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: t("quit"), action: #selector(quit), keyEquivalent: "q"))
        menu.items.forEach { $0.target = self }
        return menu
    }

    private func makeUpdateMenuItem() -> NSMenuItem {
        let submenu = NSMenu()

        if let availableUpdate {
            submenu.addItem(NSMenuItem(title: "\(t("updateAvailable")) \(availableUpdate.displayVersion)", action: #selector(openLatestRelease), keyEquivalent: ""))
        } else if isCheckingForUpdate {
            let checkingItem = NSMenuItem(title: t("checkingForUpdates"), action: nil, keyEquivalent: "")
            checkingItem.isEnabled = false
            submenu.addItem(checkingItem)
        } else {
            submenu.addItem(NSMenuItem(title: t("checkForUpdates"), action: #selector(checkForUpdatesFromMenu), keyEquivalent: ""))
        }

        submenu.addItem(NSMenuItem(title: t("openReleasesPage"), action: #selector(openReleasesPage), keyEquivalent: ""))

        let item = NSMenuItem(title: t("updates"), action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    private func makeLanguageMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: t("language"), action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for language in AppLanguage.allCases {
            let languageItem = NSMenuItem(title: language.displayName, action: #selector(languageMenuChanged(_:)), keyEquivalent: "")
            languageItem.target = self
            languageItem.tag = language.rawValue
            languageItem.state = language == settings.language ? .on : .off
            submenu.addItem(languageItem)
        }
        item.submenu = submenu
        return item
    }

    private func updateLiveMenuItems() {
        guard timeProvider.isSynced,
              liveTimeMenuItem != nil || liveCountdownMenuItem != nil || liveEarnedMenuItem != nil || liveDailyMenuItem != nil else {
            return
        }

        let snapshot = OffTickSnapshot(settings: settings, now: timeProvider.now)
        liveTimeMenuItem?.title = "\(t("currentTime"))：\(snapshot.timeText())"
        liveCountdownMenuItem?.title = "\(t("countdown"))：\(snapshot.countdownText())"
        liveEarnedMenuItem?.title = String(format: "\(t("earnedIncome"))：¥%.2f", snapshot.earnedToday())
        liveDailyMenuItem?.title = String(format: "\(t("dailyIncome"))：¥%.2f", settings.dailyIncome)
    }

    private func checkClockOutCelebration() {
        guard timeProvider.isSynced else {
            return
        }

        let now = timeProvider.now
        let snapshot = OffTickSnapshot(settings: settings, now: now)
        let hasClockedOut = snapshot.hasClockedOut

        defer {
            previousClockOutState = hasClockedOut
        }

        guard previousClockOutState != nil else {
            return
        }

        if !hasClockedOut {
            return
        }

        guard previousClockOutState == false else {
            return
        }

        if panel.isVisible {
            showFireworks()
        }

        notificationCoordinator.celebrateClockOut(language: settings.language)
    }

    @objc private func checkForUpdatesFromMenu() {
        checkForUpdates(silent: false, force: true)
    }

    @objc private func openLatestRelease() {
        let url = availableUpdate?.htmlURL ?? GitHubUpdateChecker.releasesURL
        NSWorkspace.shared.open(url)
    }

    @objc private func openReleasesPage() {
        NSWorkspace.shared.open(GitHubUpdateChecker.releasesURL)
    }

    private func checkForUpdatesIfNeeded() {
        let defaults = UserDefaults.standard
        let key = "lastGitHubUpdateCheckAt"
        if let lastCheck = defaults.object(forKey: key) as? Date,
           Date().timeIntervalSince(lastCheck) < 24 * 60 * 60 {
            return
        }

        defaults.set(Date(), forKey: key)
        checkForUpdates(silent: true, force: false)
    }

    private func checkForUpdates(silent: Bool, force: Bool) {
        guard !isCheckingForUpdate else {
            return
        }

        isCheckingForUpdate = true
        rebuildStatusMenu(snapshot: timeProvider.isSynced ? OffTickSnapshot(settings: settings, now: timeProvider.now) : nil)

        GitHubUpdateChecker.fetchLatestRelease { [weak self] result in
            DispatchQueue.main.async {
                guard let self else {
                    return
                }

                self.isCheckingForUpdate = false

                switch result {
                case .success(let release):
                    if GitHubUpdateChecker.isRelease(release, newerThan: Bundle.main.shortVersionString) {
                        self.availableUpdate = release
                        self.rebuildStatusMenu(snapshot: self.timeProvider.isSynced ? OffTickSnapshot(settings: self.settings, now: self.timeProvider.now) : nil)
                        self.showMessage(title: self.t("updateAvailable"), message: "\(release.displayVersion)\n\(release.summary)") {
                            NSWorkspace.shared.open(release.htmlURL)
                        }
                    } else if !silent || force {
                        self.availableUpdate = nil
                        self.rebuildStatusMenu(snapshot: self.timeProvider.isSynced ? OffTickSnapshot(settings: self.settings, now: self.timeProvider.now) : nil)
                        self.showMessage(title: self.t("noUpdateAvailable"), message: self.t("noUpdateAvailableHint"))
                    }
                case .failure(let error):
                    if !silent || force {
                        self.showMessage(title: self.t("updateCheckFailed"), message: "\(self.t("updateCheckFailedHint"))\n\n\(error.localizedDescription)")
                    }
                    self.rebuildStatusMenu(snapshot: self.timeProvider.isSynced ? OffTickSnapshot(settings: self.settings, now: self.timeProvider.now) : nil)
                }
            }
        }
    }

    private func showFireworks() {
        guard let contentView = panel.contentView else {
            return
        }

        let fireworksView = FireworksView(frame: contentView.bounds)
        fireworksView.autoresizingMask = [.width, .height]
        contentView.addSubview(fireworksView, positioned: .above, relativeTo: nil)
        fireworksView.start()
    }

    private func makeRow(label: String, control: NSView, suffix: String?) -> NSStackView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: 320).isActive = true

        let labelView = NSTextField(labelWithString: label)
        labelView.font = .systemFont(ofSize: 13)
        labelView.textColor = .secondaryLabelColor
        labelView.widthAnchor.constraint(equalToConstant: 88).isActive = true

        row.addArrangedSubview(labelView)
        row.addArrangedSubview(control)

        if let suffix {
            let suffixView = NSTextField(labelWithString: suffix)
            suffixView.font = .systemFont(ofSize: 12)
            suffixView.textColor = .secondaryLabelColor
            row.addArrangedSubview(suffixView)
        }

        return row
    }

    private func makeNumberField(value: Double, tag: Int) -> NSTextField {
        let field = NSTextField(string: SettingField(rawValue: tag)?.format(value: value) ?? "\(value)")
        field.bezelStyle = .roundedBezel
        field.controlSize = .small
        field.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        field.tag = tag
        field.target = self
        field.action = #selector(numberFieldChanged(_:))
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 96).isActive = true
        return field
    }

    @objc private func numberFieldChanged(_ sender: NSTextField) {
        updateSetting(from: sender)
    }

    @objc private func modeChanged(_ sender: NSSegmentedControl) {
        settings.mode = sender.selectedSegment == 0 ? .fixedTime : .unlockTimer
        settings.save()
        recordUnlockIfNeeded()
        renderSettings()
    }

    @objc private func timeFormatChanged(_ sender: NSSegmentedControl) {
        settings.timeFormat = sender.selectedSegment == 0 ? .twentyFourHour : .twelveHour
        settings.save()
    }

    @objc private func screenshotSharingChanged(_ sender: NSButton) {
        settings.includePanelInScreenshots = sender.state == .on
        settings.save()
        applyPanelScreenshotSharing()
    }

    private func applyPanelScreenshotSharing() {
        guard panel != nil else {
            return
        }

        panel.sharingType = settings.includePanelInScreenshots ? .readOnly : .none
    }

    @objc private func launchAtLoginChanged(_ sender: NSButton) {
        do {
            try LoginItemController.setEnabled(sender.state == .on)
            if LoginItemController.requiresApproval {
                showMessage(title: t("launchAtLoginApprovalRequired"), message: t("launchAtLoginApprovalRequiredHint"))
            }
        } catch {
            sender.state = LoginItemController.isEnabled ? .on : .off
            showMessage(title: t("launchAtLoginFailed"), message: error.localizedDescription)
        }

        renderSettings()
    }

    @objc private func watermarkFormatChanged(_ sender: NSButton) {
        guard let field = WatermarkField(rawValue: sender.tag) else {
            return
        }

        let isOn = sender.state == .on
        switch field {
        case .date:
            settings.includeDateInExportWatermark = isOn
        case .device:
            settings.includeDeviceInExportWatermark = isOn
        }

        settings.save()
    }

    @objc private func calendarModeChanged(_ sender: NSSegmentedControl) {
        settings.calendarMode = sender.selectedSegment == 0 ? .gregorian : .lunar
        settings.save()
    }

    @objc private func panelSizeChanged(_ sender: NSSegmentedControl) {
        guard PanelSizeMode.allCases.indices.contains(sender.selectedSegment) else {
            return
        }

        settings.panelSize = PanelSizeMode.allCases[sender.selectedSegment]
        settings.save()
        updateContent()
    }

    @objc private func languagePopUpChanged(_ sender: NSPopUpButton) {
        guard let language = AppLanguage(rawValue: sender.selectedItem?.tag ?? settings.language.rawValue) else {
            return
        }

        changeLanguage(to: language)
    }

    @objc private func languageMenuChanged(_ sender: NSMenuItem) {
        guard let language = AppLanguage(rawValue: sender.tag) else {
            return
        }

        changeLanguage(to: language)
    }

    private func changeLanguage(to language: AppLanguage) {
        settings.language = language
        settings.save()
        refreshPanelContextMenu()
        updateContent()
        rebuildStatusMenu(snapshot: timeProvider.isSynced ? OffTickSnapshot(settings: settings, now: timeProvider.now) : nil)
    }

    @objc private func panelContentChanged(_ sender: NSButton) {
        guard let field = PanelContentField(rawValue: sender.tag) else {
            return
        }

        let isOn = sender.state == .on
        switch field {
        case .date:
            settings.showDateInPanel = isOn
        case .time:
            settings.showTimeInPanel = isOn
        case .countdown:
            settings.showCountdownInPanel = isOn
        case .earnedIncome:
            settings.showEarnedIncomeInPanel = isOn
        case .dailyIncome:
            settings.showDailyIncomeInPanel = isOn
        }

        settings.save()
    }

    @objc private func resetSettings() {
        settings = .default
        settings.save()
        renderSettings()
    }

    private func updateSetting(from field: NSTextField) {
        guard let settingField = SettingField(rawValue: field.tag) else {
            return
        }

        let value = field.doubleValue
        switch settingField {
        case .monthlyIncome:
            settings.monthlyIncome = max(0, value)
            field.stringValue = settingField.format(value: settings.monthlyIncome)
        case .workdaysInMonth:
            settings.workdaysInMonth = max(1, Int(value))
            field.stringValue = settingField.format(value: Double(settings.workdaysInMonth))
        case .dailyWorkHours:
            settings.dailyWorkHours = min(max(0.5, value), 24)
            field.stringValue = settingField.format(value: settings.dailyWorkHours)
        case .fixedClockOutHour:
            settings.fixedClockOutHour = min(max(0, Int(value)), 23)
            field.stringValue = settingField.format(value: Double(settings.fixedClockOutHour))
        case .fixedClockOutMinute:
            settings.fixedClockOutMinute = min(max(0, Int(value)), 59)
            field.stringValue = settingField.format(value: Double(settings.fixedClockOutMinute))
        case .fixedStartHour:
            settings.fixedStartHour = min(max(0, Int(value)), 23)
            field.stringValue = settingField.format(value: Double(settings.fixedStartHour))
        case .fixedStartMinute:
            settings.fixedStartMinute = min(max(0, Int(value)), 59)
            field.stringValue = settingField.format(value: Double(settings.fixedStartMinute))
        }

        settings.save()
        configureStatusItemButton(toolTip: "OffTick \(t("settings"))")
    }
}

extension OffTickApp: NSTextFieldDelegate {
    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else {
            return
        }

        updateSetting(from: field)
    }
}

extension Bundle {
    var shortVersionString: String {
        object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }
}

let app = NSApplication.shared
let delegate = OffTickApp()
app.delegate = delegate
app.run()

enum ClockOutMode {
    static let storageKey = "clockOutMode"

    case fixedTime
    case unlockTimer

    var storageValue: String {
        switch self {
        case .fixedTime:
            return "fixedTime"
        case .unlockTimer:
            return "unlockTimer"
        }
    }

    init(storageValue: String) {
        switch storageValue {
        case "fixedTime":
            self = .fixedTime
        case "unlockTimer", "durationFromBoot":
            self = .unlockTimer
        default:
            self = .unlockTimer
        }
    }
}

enum TimeFormatMode {
    static let storageKey = "timeFormatMode"

    case twentyFourHour
    case twelveHour

    var storageValue: String {
        switch self {
        case .twentyFourHour:
            return "twentyFourHour"
        case .twelveHour:
            return "twelveHour"
        }
    }

    init(storageValue: String) {
        switch storageValue {
        case "twelveHour":
            self = .twelveHour
        default:
            self = .twentyFourHour
        }
    }
}

enum CalendarMode {
    static let storageKey = "calendarMode"

    case gregorian
    case lunar

    var storageValue: String {
        switch self {
        case .gregorian:
            return "gregorian"
        case .lunar:
            return "lunar"
        }
    }

    init(storageValue: String) {
        switch storageValue {
        case "lunar":
            self = .lunar
        default:
            self = .gregorian
        }
    }
}

enum PanelSizeMode: String, CaseIterable {
    static let storageKey = "panelSizeMode"

    case small
    case medium
    case large

    var storageValue: String {
        rawValue
    }

    var titleKey: String {
        switch self {
        case .small:
            return "panelSizeSmall"
        case .medium:
            return "panelSizeMedium"
        case .large:
            return "panelSizeLarge"
        }
    }

    var panelWidth: CGFloat {
        switch self {
        case .small:
            return 246
        case .medium:
            return 286
        case .large:
            return 342
        }
    }

    var contentInsets: NSEdgeInsets {
        switch self {
        case .small:
            return NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        case .medium:
            return NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
        case .large:
            return NSEdgeInsets(top: 22, left: 24, bottom: 22, right: 24)
        }
    }

    var contentWidth: CGFloat {
        panelWidth - contentInsets.left - contentInsets.right
    }

    var syncingHeight: CGFloat {
        switch self {
        case .small:
            return 88
        case .medium:
            return 104
        case .large:
            return 122
        }
    }

    var minimumPanelHeight: CGFloat {
        switch self {
        case .small:
            return 92
        case .medium:
            return 106
        case .large:
            return 128
        }
    }

    var heightBase: CGFloat {
        switch self {
        case .small:
            return 42
        case .medium:
            return 50
        case .large:
            return 60
        }
    }

    var itemHeight: CGFloat {
        switch self {
        case .small:
            return 31
        case .medium:
            return 36
        case .large:
            return 43
        }
    }

    var stackSpacing: CGFloat {
        switch self {
        case .small:
            return 8
        case .medium:
            return 10
        case .large:
            return 12
        }
    }

    var metricSpacing: CGFloat {
        switch self {
        case .small:
            return 8
        case .medium:
            return 10
        case .large:
            return 12
        }
    }

    var verticalMetricSpacing: CGFloat {
        switch self {
        case .small:
            return 3
        case .medium:
            return 4
        case .large:
            return 5
        }
    }

    var brandFontSize: CGFloat {
        switch self {
        case .small:
            return 12
        case .medium:
            return 13
        case .large:
            return 14
        }
    }

    var messageFontSize: CGFloat {
        switch self {
        case .small:
            return 16
        case .medium:
            return 18
        case .large:
            return 21
        }
    }

    var dateFontSize: CGFloat {
        switch self {
        case .small:
            return 11
        case .medium:
            return 12
        case .large:
            return 14
        }
    }

    var timeFontSize: CGFloat {
        switch self {
        case .small:
            return 24
        case .medium:
            return 28
        case .large:
            return 34
        }
    }

    var captionFontSize: CGFloat {
        switch self {
        case .small:
            return 10
        case .medium:
            return 11
        case .large:
            return 12
        }
    }

    var valueFontSize: CGFloat {
        switch self {
        case .small:
            return 16
        case .medium:
            return 18
        case .large:
            return 21
        }
    }

    var countdownFontSize: CGFloat {
        switch self {
        case .small:
            return 17
        case .medium:
            return 19
        case .large:
            return 23
        }
    }

    var captionWidth: CGFloat {
        switch self {
        case .small:
            return 68
        case .medium:
            return 78
        case .large:
            return 92
        }
    }

    init(storageValue: String) {
        self = PanelSizeMode(rawValue: storageValue) ?? .medium
    }
}

enum AppLanguage: Int, CaseIterable {
    static let storageKey = "appLanguage"

    case simplifiedChinese = 0
    case traditionalChinese
    case english
    case japanese
    case korean
    case spanish
    case french
    case german
    case portuguese
    case russian

    var storageValue: String {
        switch self {
        case .simplifiedChinese: return "zh-Hans"
        case .traditionalChinese: return "zh-Hant"
        case .english: return "en"
        case .japanese: return "ja"
        case .korean: return "ko"
        case .spanish: return "es"
        case .french: return "fr"
        case .german: return "de"
        case .portuguese: return "pt-BR"
        case .russian: return "ru"
        }
    }

    var displayName: String {
        switch self {
        case .simplifiedChinese: return "简体中文"
        case .traditionalChinese: return "繁體中文"
        case .english: return "English"
        case .japanese: return "日本語"
        case .korean: return "한국어"
        case .spanish: return "Español"
        case .french: return "Français"
        case .german: return "Deutsch"
        case .portuguese: return "Português"
        case .russian: return "Русский"
        }
    }

    var localeIdentifier: String {
        switch self {
        case .simplifiedChinese: return "zh_CN"
        case .traditionalChinese: return "zh_TW"
        case .english: return "en_US"
        case .japanese: return "ja_JP"
        case .korean: return "ko_KR"
        case .spanish: return "es_ES"
        case .french: return "fr_FR"
        case .german: return "de_DE"
        case .portuguese: return "pt_BR"
        case .russian: return "ru_RU"
        }
    }

    init(storageValue: String) {
        self = AppLanguage.allCases.first { $0.storageValue == storageValue } ?? .simplifiedChinese
    }
}

enum L10n {
    static func text(_ key: String, language: AppLanguage) -> String {
        translations[language]?[key] ?? translations[.simplifiedChinese]?[key] ?? key
    }

    private static let translations: [AppLanguage: [String: String]] = [
        .simplifiedChinese: [
            "settings": "设置",
            "hidePanel": "隐藏悬浮窗",
            "showPanel": "显示悬浮窗",
            "quit": "退出 OffTick",
            "display": "显示",
            "language": "语言",
            "time": "时间",
            "date": "日期",
            "hour24": "24小时",
            "hour12": "12小时",
            "gregorian": "国历",
            "lunar": "农历",
            "panelSize": "悬浮窗大小",
            "panelSizeSmall": "小",
            "panelSizeMedium": "中",
            "panelSizeLarge": "大",
            "panelContent": "悬浮窗内容",
            "options": "选项",
            "watermarkFormat": "水印格式",
            "countdown": "下班倒计时",
            "earnedIncome": "今日实时收入",
            "dailyIncome": "日均收入",
            "includePanelInScreenshots": "截图时包含悬浮窗",
            "launchAtLogin": "开机自启动",
            "watermarkIncludeDate": "水印包含导出时间",
            "watermarkIncludeDevice": "水印包含设备号",
            "updates": "更新",
            "checkForUpdates": "检查更新",
            "checkingForUpdates": "正在检查更新...",
            "openReleasesPage": "打开发布页面",
            "updateAvailable": "发现新版本",
            "noUpdateAvailable": "已是最新版本",
            "noUpdateAvailableHint": "当前版本已经是最新版本。",
            "updateCheckFailed": "检查更新失败",
            "updateCheckFailedHint": "暂时无法检查更新。你可以稍后再试，或从菜单里打开 GitHub 发布页面手动查看。",
            "income": "收入",
            "monthlyIncome": "月薪",
            "workdaysInMonth": "本月工作日",
            "timer": "计时",
            "workMode": "计算方式",
            "fixedClockOut": "固定下班",
            "unlockTimer": "解锁计时",
            "startTime": "上班时间",
            "clockOutTime": "下班时间",
            "dailyHours": "每日时长",
            "done": "完成",
            "resetDefault": "恢复默认",
            "syncingTime": "正在校准网络时间...",
            "noPanelContent": "未选择悬浮窗内容",
            "currentTime": "当前时间",
            "waitingIncome": "收入：等待网络时间",
            "waitingUnlock": "等待今日5点后首次解锁",
            "clockOutNotificationTitle": "下班啦",
            "clockOutNotificationBody": "今天辛苦了，OffTick 已经帮你数到下班时间。",
            "yuan": "元",
            "days": "天",
            "hoursUnit": "小时",
            "unlockRecords": "解锁记录",
            "exportUnlockRecords": "导出解锁记录",
            "exportUnlockRecordsHint": "请输入导出的日期范围，格式为 yyyy-MM-dd。",
            "exportStartDate": "开始日期",
            "exportEndDate": "结束日期",
            "export": "导出",
            "cancel": "取消",
            "invalidDateRange": "日期范围无效",
            "dateRangeFormatHint": "请使用 yyyy-MM-dd 格式，并确保开始日期不晚于结束日期。",
            "noUnlockRecords": "没有解锁记录",
            "noUnlockRecordsHint": "所选范围内没有记录到 5 点后的首次解锁时间。",
            "exportComplete": "导出完成",
            "exportFailed": "导出失败",
            "networkTimeUnavailable": "网络时间不可用",
            "networkTimeUnavailableHint": "OffTick 暂时无法校准网络时间，请联网后再导出。",
            "launchAtLoginFailed": "开机自启动设置失败",
            "launchAtLoginApprovalRequired": "需要系统确认",
            "launchAtLoginApprovalRequiredHint": "请在“系统设置 > 通用 > 登录项”里允许 OffTick 后，开机自启动才会生效。"
        ],
        .traditionalChinese: [
            "settings": "設定", "hidePanel": "隱藏懸浮窗", "showPanel": "顯示懸浮窗", "quit": "退出 OffTick", "display": "顯示", "language": "語言", "time": "時間", "date": "日期", "hour24": "24小時", "hour12": "12小時", "gregorian": "國曆", "lunar": "農曆", "panelSize": "懸浮窗大小", "panelSizeSmall": "小", "panelSizeMedium": "中", "panelSizeLarge": "大", "panelContent": "懸浮窗內容", "options": "選項", "watermarkFormat": "浮水印格式", "countdown": "下班倒數", "earnedIncome": "今日即時收入", "dailyIncome": "日均收入", "includePanelInScreenshots": "截圖時包含懸浮窗", "launchAtLogin": "開機自動啟動", "watermarkIncludeDate": "浮水印包含匯出時間", "watermarkIncludeDevice": "浮水印包含設備序號", "updates": "更新", "checkForUpdates": "檢查更新", "checkingForUpdates": "正在檢查更新...", "openReleasesPage": "開啟發布頁面", "updateAvailable": "發現新版本", "noUpdateAvailable": "已是最新版本", "noUpdateAvailableHint": "目前版本已經是最新版本。", "updateCheckFailed": "檢查更新失敗", "updateCheckFailedHint": "暫時無法檢查更新。你可以稍後再試，或從選單開啟 GitHub 發布頁面手動查看。", "income": "收入", "monthlyIncome": "月薪", "workdaysInMonth": "本月工作日", "timer": "計時", "workMode": "計算方式", "fixedClockOut": "固定下班", "unlockTimer": "解鎖計時", "startTime": "上班時間", "clockOutTime": "下班時間", "dailyHours": "每日時長", "done": "完成", "resetDefault": "恢復預設", "syncingTime": "正在校準網路時間...", "noPanelContent": "未選擇懸浮窗內容", "currentTime": "目前時間", "waitingIncome": "收入：等待網路時間", "waitingUnlock": "等待今日5點後首次解鎖", "clockOutNotificationTitle": "下班啦", "clockOutNotificationBody": "今天辛苦了，OffTick 已經幫你數到下班時間。", "yuan": "元", "days": "天", "hoursUnit": "小時", "unlockRecords": "解鎖記錄", "exportUnlockRecords": "匯出解鎖記錄", "exportUnlockRecordsHint": "請輸入匯出的日期範圍，格式為 yyyy-MM-dd。", "exportStartDate": "開始日期", "exportEndDate": "結束日期", "export": "匯出", "cancel": "取消", "invalidDateRange": "日期範圍無效", "dateRangeFormatHint": "請使用 yyyy-MM-dd 格式，並確保開始日期不晚於結束日期。", "noUnlockRecords": "沒有解鎖記錄", "noUnlockRecordsHint": "所選範圍內沒有記錄到 5 點後的首次解鎖時間。", "exportComplete": "匯出完成", "exportFailed": "匯出失敗", "networkTimeUnavailable": "網路時間不可用", "networkTimeUnavailableHint": "OffTick 暫時無法校準網路時間，請連網後再匯出。", "launchAtLoginFailed": "開機自動啟動設定失敗", "launchAtLoginApprovalRequired": "需要系統確認", "launchAtLoginApprovalRequiredHint": "請在「系統設定 > 一般 > 登入項目」允許 OffTick 後，開機自動啟動才會生效。"
        ],
        .english: [
            "settings": "Settings", "hidePanel": "Hide Floating Window", "showPanel": "Show Floating Window", "quit": "Quit OffTick", "display": "Display", "language": "Language", "time": "Time", "date": "Date", "hour24": "24-hour", "hour12": "12-hour", "gregorian": "Gregorian", "lunar": "Lunar", "panelSize": "Window Size", "panelSizeSmall": "Small", "panelSizeMedium": "Medium", "panelSizeLarge": "Large", "panelContent": "Floating Window", "options": "Options", "watermarkFormat": "Watermark", "countdown": "Clock-out Countdown", "earnedIncome": "Live Earnings", "dailyIncome": "Daily Income", "includePanelInScreenshots": "Include floating window in screenshots", "launchAtLogin": "Launch at login", "watermarkIncludeDate": "Include export time", "watermarkIncludeDevice": "Include device ID", "updates": "Updates", "checkForUpdates": "Check for Updates", "checkingForUpdates": "Checking for updates...", "openReleasesPage": "Open Releases Page", "updateAvailable": "Update Available", "noUpdateAvailable": "You are up to date", "noUpdateAvailableHint": "You are already using the latest version.", "updateCheckFailed": "Update Check Failed", "updateCheckFailedHint": "Unable to check for updates right now. Try again later, or open the GitHub Releases page from the menu.", "income": "Income", "monthlyIncome": "Monthly Income", "workdaysInMonth": "Workdays", "timer": "Timer", "workMode": "Mode", "fixedClockOut": "Fixed Clock-out", "unlockTimer": "Unlock Timer", "startTime": "Start Time", "clockOutTime": "Clock-out Time", "dailyHours": "Daily Hours", "done": "Done", "resetDefault": "Reset Defaults", "syncingTime": "Syncing network time...", "noPanelContent": "No floating content selected", "currentTime": "Current Time", "waitingIncome": "Income: waiting for network time", "waitingUnlock": "Waiting for first unlock after 5 AM", "clockOutNotificationTitle": "Time to clock out", "clockOutNotificationBody": "Nice work today. OffTick has counted down to your clock-out time.", "yuan": "CNY", "days": "days", "hoursUnit": "hours", "unlockRecords": "Unlock Records", "exportUnlockRecords": "Export Unlock Records", "exportUnlockRecordsHint": "Enter the export date range in yyyy-MM-dd format.", "exportStartDate": "Start Date", "exportEndDate": "End Date", "export": "Export", "cancel": "Cancel", "invalidDateRange": "Invalid Date Range", "dateRangeFormatHint": "Use yyyy-MM-dd and make sure the start date is not after the end date.", "noUnlockRecords": "No Unlock Records", "noUnlockRecordsHint": "No first unlock after 5 AM was recorded in the selected range.", "exportComplete": "Export Complete", "exportFailed": "Export Failed", "networkTimeUnavailable": "Network Time Unavailable", "networkTimeUnavailableHint": "OffTick could not sync network time. Connect to the internet and try exporting again.", "launchAtLoginFailed": "Could not update launch at login", "launchAtLoginApprovalRequired": "Approval Required", "launchAtLoginApprovalRequiredHint": "Allow OffTick in System Settings > General > Login Items before launch at login takes effect."
        ],
        .japanese: [
            "settings": "設定", "hidePanel": "フローティングウィンドウを隠す", "showPanel": "フローティングウィンドウを表示", "quit": "OffTick を終了", "display": "表示", "language": "言語", "time": "時刻", "date": "日付", "hour24": "24時間", "hour12": "12時間", "gregorian": "西暦", "lunar": "旧暦", "panelSize": "ウィンドウサイズ", "panelSizeSmall": "小", "panelSizeMedium": "中", "panelSizeLarge": "大", "panelContent": "表示内容", "options": "オプション", "watermarkFormat": "透かし形式", "countdown": "退勤カウントダウン", "earnedIncome": "本日のリアルタイム収入", "dailyIncome": "日収", "includePanelInScreenshots": "スクリーンショットに含める", "launchAtLogin": "ログイン時に起動", "watermarkIncludeDate": "透かしに書き出し時刻を含める", "watermarkIncludeDevice": "透かしにデバイスIDを含める", "updates": "アップデート", "checkForUpdates": "アップデートを確認", "checkingForUpdates": "アップデートを確認中...", "openReleasesPage": "リリースページを開く", "updateAvailable": "新しいバージョンがあります", "noUpdateAvailable": "最新版です", "noUpdateAvailableHint": "現在のバージョンは最新です。", "updateCheckFailed": "アップデート確認に失敗", "updateCheckFailedHint": "現在アップデートを確認できません。後でもう一度試すか、メニューから GitHub リリースページを開いて確認してください。", "income": "収入", "monthlyIncome": "月収", "workdaysInMonth": "今月の出勤日", "timer": "タイマー", "workMode": "計算方式", "fixedClockOut": "固定退勤", "unlockTimer": "ロック解除計時", "startTime": "始業時刻", "clockOutTime": "退勤時刻", "dailyHours": "1日の勤務時間", "done": "完了", "resetDefault": "初期値に戻す", "syncingTime": "ネットワーク時刻を同期中...", "noPanelContent": "表示内容が選択されていません", "currentTime": "現在時刻", "waitingIncome": "収入：時刻同期待ち", "waitingUnlock": "今日5時以降の初回ロック解除待ち", "clockOutNotificationTitle": "退勤時間です", "clockOutNotificationBody": "今日もお疲れさまでした。OffTick が退勤時間を知らせます。", "yuan": "元", "days": "日", "hoursUnit": "時間", "unlockRecords": "ロック解除記録", "exportUnlockRecords": "ロック解除記録を書き出す", "exportUnlockRecordsHint": "書き出す日付範囲を yyyy-MM-dd 形式で入力してください。", "exportStartDate": "開始日", "exportEndDate": "終了日", "export": "書き出す", "cancel": "キャンセル", "invalidDateRange": "日付範囲が無効です", "dateRangeFormatHint": "yyyy-MM-dd 形式を使用し、開始日が終了日より後にならないようにしてください。", "noUnlockRecords": "ロック解除記録がありません", "noUnlockRecordsHint": "選択した範囲に、5時以降の初回ロック解除記録はありません。", "exportComplete": "書き出し完了", "exportFailed": "書き出し失敗", "networkTimeUnavailable": "ネットワーク時刻を利用できません", "networkTimeUnavailableHint": "OffTick はネットワーク時刻を同期できませんでした。インターネットに接続してから再度書き出してください。", "launchAtLoginFailed": "ログイン時起動の設定に失敗しました", "launchAtLoginApprovalRequired": "システムの承認が必要です", "launchAtLoginApprovalRequiredHint": "「システム設定 > 一般 > ログイン項目」で OffTick を許可すると有効になります。"
        ],
        .korean: [
            "settings": "설정", "hidePanel": "플로팅 창 숨기기", "showPanel": "플로팅 창 보기", "quit": "OffTick 종료", "display": "표시", "language": "언어", "time": "시간", "date": "날짜", "hour24": "24시간", "hour12": "12시간", "gregorian": "양력", "lunar": "음력", "panelSize": "창 크기", "panelSizeSmall": "작게", "panelSizeMedium": "중간", "panelSizeLarge": "크게", "panelContent": "플로팅 창 내용", "options": "옵션", "watermarkFormat": "워터마크", "countdown": "퇴근 카운트다운", "earnedIncome": "오늘 실시간 수입", "dailyIncome": "일평균 수입", "includePanelInScreenshots": "스크린샷에 플로팅 창 포함", "launchAtLogin": "로그인 시 실행", "watermarkIncludeDate": "워터마크에 내보낸 시간 포함", "watermarkIncludeDevice": "워터마크에 기기 ID 포함", "updates": "업데이트", "checkForUpdates": "업데이트 확인", "checkingForUpdates": "업데이트 확인 중...", "openReleasesPage": "릴리스 페이지 열기", "updateAvailable": "새 버전 있음", "noUpdateAvailable": "최신 버전입니다", "noUpdateAvailableHint": "현재 최신 버전을 사용 중입니다.", "updateCheckFailed": "업데이트 확인 실패", "updateCheckFailedHint": "지금은 업데이트를 확인할 수 없습니다. 나중에 다시 시도하거나 메뉴에서 GitHub 릴리스 페이지를 열어 확인하세요.", "income": "수입", "monthlyIncome": "월급", "workdaysInMonth": "이번 달 근무일", "timer": "타이머", "workMode": "계산 방식", "fixedClockOut": "고정 퇴근", "unlockTimer": "잠금 해제 기준", "startTime": "출근 시간", "clockOutTime": "퇴근 시간", "dailyHours": "하루 근무시간", "done": "완료", "resetDefault": "기본값 복원", "syncingTime": "네트워크 시간 동기화 중...", "noPanelContent": "선택된 표시 항목 없음", "currentTime": "현재 시간", "waitingIncome": "수입: 네트워크 시간 대기", "waitingUnlock": "오늘 5시 이후 첫 잠금 해제 대기", "clockOutNotificationTitle": "퇴근 시간입니다", "clockOutNotificationBody": "오늘도 수고했어요. OffTick 이 퇴근 시간을 알려드려요.", "yuan": "위안", "days": "일", "hoursUnit": "시간", "unlockRecords": "잠금 해제 기록", "exportUnlockRecords": "잠금 해제 기록 내보내기", "exportUnlockRecordsHint": "내보낼 날짜 범위를 yyyy-MM-dd 형식으로 입력하세요.", "exportStartDate": "시작일", "exportEndDate": "종료일", "export": "내보내기", "cancel": "취소", "invalidDateRange": "날짜 범위가 올바르지 않습니다", "dateRangeFormatHint": "yyyy-MM-dd 형식을 사용하고 시작일이 종료일보다 늦지 않도록 하세요.", "noUnlockRecords": "잠금 해제 기록 없음", "noUnlockRecordsHint": "선택한 범위에 5시 이후 첫 잠금 해제 기록이 없습니다.", "exportComplete": "내보내기 완료", "exportFailed": "내보내기 실패", "networkTimeUnavailable": "네트워크 시간을 사용할 수 없음", "networkTimeUnavailableHint": "OffTick 이 네트워크 시간을 동기화하지 못했습니다. 인터넷에 연결한 뒤 다시 내보내세요.", "launchAtLoginFailed": "로그인 시 실행 설정 실패", "launchAtLoginApprovalRequired": "시스템 승인이 필요합니다", "launchAtLoginApprovalRequiredHint": "시스템 설정 > 일반 > 로그인 항목에서 OffTick 을 허용하면 적용됩니다."
        ],
        .spanish: [
            "settings": "Ajustes", "hidePanel": "Ocultar ventana flotante", "showPanel": "Mostrar ventana flotante", "quit": "Salir de OffTick", "display": "Visualización", "language": "Idioma", "time": "Hora", "date": "Fecha", "hour24": "24 h", "hour12": "12 h", "gregorian": "Gregoriano", "lunar": "Lunar", "panelSize": "Tamaño", "panelSizeSmall": "Pequeño", "panelSizeMedium": "Mediano", "panelSizeLarge": "Grande", "panelContent": "Contenido flotante", "options": "Opciones", "watermarkFormat": "Marca de agua", "countdown": "Cuenta atrás", "earnedIncome": "Ingresos en vivo", "dailyIncome": "Ingreso diario", "includePanelInScreenshots": "Incluir ventana flotante en capturas", "launchAtLogin": "Iniciar al acceder", "watermarkIncludeDate": "Incluir hora de exportación", "watermarkIncludeDevice": "Incluir ID del dispositivo", "updates": "Actualizaciones", "checkForUpdates": "Buscar actualizaciones", "checkingForUpdates": "Buscando actualizaciones...", "openReleasesPage": "Abrir página de lanzamientos", "updateAvailable": "Nueva versión disponible", "noUpdateAvailable": "Ya tienes la última versión", "noUpdateAvailableHint": "Ya estás usando la última versión.", "updateCheckFailed": "No se pudo buscar actualizaciones", "updateCheckFailedHint": "No se puede buscar actualizaciones ahora. Inténtalo más tarde o abre la página de lanzamientos de GitHub desde el menú.", "income": "Ingresos", "monthlyIncome": "Salario mensual", "workdaysInMonth": "Días laborables", "timer": "Temporizador", "workMode": "Modo", "fixedClockOut": "Salida fija", "unlockTimer": "Desde desbloqueo", "startTime": "Entrada", "clockOutTime": "Salida", "dailyHours": "Horas diarias", "done": "Listo", "resetDefault": "Restablecer", "syncingTime": "Sincronizando hora...", "noPanelContent": "Sin contenido seleccionado", "currentTime": "Hora actual", "waitingIncome": "Ingresos: esperando hora de red", "waitingUnlock": "Esperando el primer desbloqueo después de las 5", "clockOutNotificationTitle": "Hora de salir", "clockOutNotificationBody": "Buen trabajo hoy. OffTick llegó a tu hora de salida.", "yuan": "CNY", "days": "días", "hoursUnit": "horas", "unlockRecords": "Registros de desbloqueo", "exportUnlockRecords": "Exportar registros de desbloqueo", "exportUnlockRecordsHint": "Introduce el rango de fechas en formato yyyy-MM-dd.", "exportStartDate": "Fecha inicial", "exportEndDate": "Fecha final", "export": "Exportar", "cancel": "Cancelar", "invalidDateRange": "Rango de fechas no válido", "dateRangeFormatHint": "Usa yyyy-MM-dd y asegúrate de que la fecha inicial no sea posterior a la final.", "noUnlockRecords": "Sin registros de desbloqueo", "noUnlockRecordsHint": "No se registró ningún primer desbloqueo después de las 5 en el rango seleccionado.", "exportComplete": "Exportación completada", "exportFailed": "Error al exportar", "networkTimeUnavailable": "Hora de red no disponible", "networkTimeUnavailableHint": "OffTick no pudo sincronizar la hora de red. Conéctate a internet e intenta exportar de nuevo.", "launchAtLoginFailed": "No se pudo actualizar el inicio al acceder", "launchAtLoginApprovalRequired": "Se requiere aprobación", "launchAtLoginApprovalRequiredHint": "Permite OffTick en Ajustes del Sistema > General > Ítems de inicio para que surta efecto."
        ],
        .french: [
            "settings": "Réglages", "hidePanel": "Masquer la fenêtre flottante", "showPanel": "Afficher la fenêtre flottante", "quit": "Quitter OffTick", "display": "Affichage", "language": "Langue", "time": "Heure", "date": "Date", "hour24": "24 h", "hour12": "12 h", "gregorian": "Grégorien", "lunar": "Lunaire", "panelSize": "Taille", "panelSizeSmall": "Petit", "panelSizeMedium": "Moyen", "panelSizeLarge": "Grand", "panelContent": "Contenu flottant", "options": "Options", "watermarkFormat": "Filigrane", "countdown": "Compte à rebours", "earnedIncome": "Revenu en direct", "dailyIncome": "Revenu journalier", "includePanelInScreenshots": "Inclure la fenêtre flottante dans les captures", "launchAtLogin": "Lancer à l’ouverture de session", "watermarkIncludeDate": "Inclure l’heure d’export", "watermarkIncludeDevice": "Inclure l’ID de l’appareil", "updates": "Mises à jour", "checkForUpdates": "Rechercher des mises à jour", "checkingForUpdates": "Recherche de mises à jour...", "openReleasesPage": "Ouvrir la page des versions", "updateAvailable": "Nouvelle version disponible", "noUpdateAvailable": "Vous êtes à jour", "noUpdateAvailableHint": "Vous utilisez déjà la dernière version.", "updateCheckFailed": "Échec de la recherche", "updateCheckFailedHint": "Impossible de rechercher des mises à jour pour le moment. Réessayez plus tard ou ouvrez la page GitHub Releases depuis le menu.", "income": "Revenu", "monthlyIncome": "Salaire mensuel", "workdaysInMonth": "Jours ouvrés", "timer": "Minuteur", "workMode": "Mode", "fixedClockOut": "Fin fixe", "unlockTimer": "Depuis déverrouillage", "startTime": "Début", "clockOutTime": "Fin", "dailyHours": "Heures/jour", "done": "Terminé", "resetDefault": "Réinitialiser", "syncingTime": "Synchronisation de l’heure...", "noPanelContent": "Aucun contenu sélectionné", "currentTime": "Heure actuelle", "waitingIncome": "Revenu : attente de l’heure réseau", "waitingUnlock": "En attente du premier déverrouillage après 5 h", "clockOutNotificationTitle": "C’est l’heure de partir", "clockOutNotificationBody": "Beau travail aujourd’hui. OffTick a atteint l’heure de fin.", "yuan": "CNY", "days": "jours", "hoursUnit": "heures", "unlockRecords": "Historique de déverrouillage", "exportUnlockRecords": "Exporter l’historique", "exportUnlockRecordsHint": "Saisissez la plage de dates au format yyyy-MM-dd.", "exportStartDate": "Date de début", "exportEndDate": "Date de fin", "export": "Exporter", "cancel": "Annuler", "invalidDateRange": "Plage de dates non valide", "dateRangeFormatHint": "Utilisez yyyy-MM-dd et vérifiez que la date de début n’est pas après la date de fin.", "noUnlockRecords": "Aucun historique", "noUnlockRecordsHint": "Aucun premier déverrouillage après 5 h n’a été enregistré dans la plage sélectionnée.", "exportComplete": "Export terminé", "exportFailed": "Échec de l’export", "networkTimeUnavailable": "Heure réseau indisponible", "networkTimeUnavailableHint": "OffTick n’a pas pu synchroniser l’heure réseau. Connectez-vous à internet puis réessayez.", "launchAtLoginFailed": "Impossible de modifier le lancement à l’ouverture", "launchAtLoginApprovalRequired": "Autorisation requise", "launchAtLoginApprovalRequiredHint": "Autorisez OffTick dans Réglages Système > Général > Ouverture pour l’activer."
        ],
        .german: [
            "settings": "Einstellungen", "hidePanel": "Schwebefenster ausblenden", "showPanel": "Schwebefenster anzeigen", "quit": "OffTick beenden", "display": "Anzeige", "language": "Sprache", "time": "Zeit", "date": "Datum", "hour24": "24 Std.", "hour12": "12 Std.", "gregorian": "Gregorianisch", "lunar": "Mondkalender", "panelSize": "Fenstergröße", "panelSizeSmall": "Klein", "panelSizeMedium": "Mittel", "panelSizeLarge": "Groß", "panelContent": "Schwebefenster", "options": "Optionen", "watermarkFormat": "Wasserzeichen", "countdown": "Feierabend-Countdown", "earnedIncome": "Live-Einkommen", "dailyIncome": "Tageseinkommen", "includePanelInScreenshots": "Schwebefenster in Screenshots einschließen", "launchAtLogin": "Beim Anmelden starten", "watermarkIncludeDate": "Exportzeit einschließen", "watermarkIncludeDevice": "Geräte-ID einschließen", "updates": "Updates", "checkForUpdates": "Nach Updates suchen", "checkingForUpdates": "Suche nach Updates...", "openReleasesPage": "Release-Seite öffnen", "updateAvailable": "Neue Version verfügbar", "noUpdateAvailable": "Sie sind aktuell", "noUpdateAvailableHint": "Sie verwenden bereits die neueste Version.", "updateCheckFailed": "Update-Prüfung fehlgeschlagen", "updateCheckFailedHint": "Updates können derzeit nicht geprüft werden. Versuchen Sie es später erneut oder öffnen Sie die GitHub-Releases-Seite über das Menü.", "income": "Einkommen", "monthlyIncome": "Monatsgehalt", "workdaysInMonth": "Arbeitstage", "timer": "Timer", "workMode": "Modus", "fixedClockOut": "Feste Endzeit", "unlockTimer": "Ab Entsperren", "startTime": "Startzeit", "clockOutTime": "Endzeit", "dailyHours": "Stunden/Tag", "done": "Fertig", "resetDefault": "Zurücksetzen", "syncingTime": "Netzwerkzeit wird synchronisiert...", "noPanelContent": "Kein Inhalt ausgewählt", "currentTime": "Aktuelle Zeit", "waitingIncome": "Einkommen: warte auf Netzwerkzeit", "waitingUnlock": "Warte auf erstes Entsperren nach 5 Uhr", "clockOutNotificationTitle": "Feierabend", "clockOutNotificationBody": "Gute Arbeit heute. OffTick hat bis zum Feierabend gezählt.", "yuan": "CNY", "days": "Tage", "hoursUnit": "Stunden", "unlockRecords": "Entsperrverlauf", "exportUnlockRecords": "Entsperrverlauf exportieren", "exportUnlockRecordsHint": "Geben Sie den Datumsbereich im Format yyyy-MM-dd ein.", "exportStartDate": "Startdatum", "exportEndDate": "Enddatum", "export": "Exportieren", "cancel": "Abbrechen", "invalidDateRange": "Ungültiger Datumsbereich", "dateRangeFormatHint": "Verwenden Sie yyyy-MM-dd und stellen Sie sicher, dass das Startdatum nicht nach dem Enddatum liegt.", "noUnlockRecords": "Kein Entsperrverlauf", "noUnlockRecordsHint": "Im ausgewählten Bereich wurde keine erste Entsperrung nach 5 Uhr erfasst.", "exportComplete": "Export abgeschlossen", "exportFailed": "Export fehlgeschlagen", "networkTimeUnavailable": "Netzwerkzeit nicht verfügbar", "networkTimeUnavailableHint": "OffTick konnte die Netzwerkzeit nicht synchronisieren. Verbinden Sie sich mit dem Internet und exportieren Sie erneut.", "launchAtLoginFailed": "Start beim Anmelden konnte nicht geändert werden", "launchAtLoginApprovalRequired": "Genehmigung erforderlich", "launchAtLoginApprovalRequiredHint": "Erlauben Sie OffTick unter Systemeinstellungen > Allgemein > Anmeldeobjekte, damit es wirksam wird."
        ],
        .portuguese: [
            "settings": "Ajustes", "hidePanel": "Ocultar janela flutuante", "showPanel": "Mostrar janela flutuante", "quit": "Sair do OffTick", "display": "Exibição", "language": "Idioma", "time": "Hora", "date": "Data", "hour24": "24 h", "hour12": "12 h", "gregorian": "Gregoriano", "lunar": "Lunar", "panelSize": "Tamanho", "panelSizeSmall": "Pequeno", "panelSizeMedium": "Médio", "panelSizeLarge": "Grande", "panelContent": "Conteúdo flutuante", "options": "Opções", "watermarkFormat": "Marca d’água", "countdown": "Contagem para sair", "earnedIncome": "Ganhos ao vivo", "dailyIncome": "Renda diária", "includePanelInScreenshots": "Incluir janela flutuante nas capturas", "launchAtLogin": "Iniciar ao entrar", "watermarkIncludeDate": "Incluir hora da exportação", "watermarkIncludeDevice": "Incluir ID do dispositivo", "updates": "Atualizações", "checkForUpdates": "Verificar atualizações", "checkingForUpdates": "Verificando atualizações...", "openReleasesPage": "Abrir página de versões", "updateAvailable": "Nova versão disponível", "noUpdateAvailable": "Você está atualizado", "noUpdateAvailableHint": "Você já está usando a versão mais recente.", "updateCheckFailed": "Falha ao verificar atualizações", "updateCheckFailedHint": "Não foi possível verificar atualizações agora. Tente novamente mais tarde ou abra a página de versões do GitHub pelo menu.", "income": "Renda", "monthlyIncome": "Salário mensal", "workdaysInMonth": "Dias úteis", "timer": "Timer", "workMode": "Modo", "fixedClockOut": "Saída fixa", "unlockTimer": "Desde desbloqueio", "startTime": "Início", "clockOutTime": "Saída", "dailyHours": "Horas diárias", "done": "Concluir", "resetDefault": "Restaurar", "syncingTime": "Sincronizando horário...", "noPanelContent": "Nenhum conteúdo selecionado", "currentTime": "Hora atual", "waitingIncome": "Renda: aguardando horário de rede", "waitingUnlock": "Aguardando primeiro desbloqueio após 5h", "clockOutNotificationTitle": "Hora de sair", "clockOutNotificationBody": "Bom trabalho hoje. OffTick chegou ao horário de saída.", "yuan": "CNY", "days": "dias", "hoursUnit": "horas", "unlockRecords": "Registros de desbloqueio", "exportUnlockRecords": "Exportar registros de desbloqueio", "exportUnlockRecordsHint": "Informe o intervalo de datas no formato yyyy-MM-dd.", "exportStartDate": "Data inicial", "exportEndDate": "Data final", "export": "Exportar", "cancel": "Cancelar", "invalidDateRange": "Intervalo de datas inválido", "dateRangeFormatHint": "Use yyyy-MM-dd e verifique se a data inicial não é posterior à final.", "noUnlockRecords": "Sem registros de desbloqueio", "noUnlockRecordsHint": "Nenhum primeiro desbloqueio após 5h foi registrado no intervalo selecionado.", "exportComplete": "Exportação concluída", "exportFailed": "Falha ao exportar", "networkTimeUnavailable": "Horário de rede indisponível", "networkTimeUnavailableHint": "OffTick não conseguiu sincronizar o horário de rede. Conecte-se à internet e tente exportar novamente.", "launchAtLoginFailed": "Não foi possível atualizar o início ao entrar", "launchAtLoginApprovalRequired": "Aprovação necessária", "launchAtLoginApprovalRequiredHint": "Permita OffTick em Ajustes do Sistema > Geral > Itens de início para ativar."
        ],
        .russian: [
            "settings": "Настройки", "hidePanel": "Скрыть плавающее окно", "showPanel": "Показать плавающее окно", "quit": "Выйти из OffTick", "display": "Отображение", "language": "Язык", "time": "Время", "date": "Дата", "hour24": "24 часа", "hour12": "12 часов", "gregorian": "Григорианский", "lunar": "Лунный", "panelSize": "Размер окна", "panelSizeSmall": "Малый", "panelSizeMedium": "Средний", "panelSizeLarge": "Большой", "panelContent": "Содержимое окна", "options": "Параметры", "watermarkFormat": "Водяной знак", "countdown": "До конца работы", "earnedIncome": "Доход сейчас", "dailyIncome": "Доход в день", "includePanelInScreenshots": "Включать плавающее окно в снимки", "launchAtLogin": "Запускать при входе", "watermarkIncludeDate": "Добавлять время экспорта", "watermarkIncludeDevice": "Добавлять ID устройства", "updates": "Обновления", "checkForUpdates": "Проверить обновления", "checkingForUpdates": "Проверка обновлений...", "openReleasesPage": "Открыть страницу релизов", "updateAvailable": "Доступна новая версия", "noUpdateAvailable": "Установлена последняя версия", "noUpdateAvailableHint": "Вы уже используете последнюю версию.", "updateCheckFailed": "Не удалось проверить обновления", "updateCheckFailedHint": "Сейчас не удалось проверить обновления. Повторите позже или откройте страницу GitHub Releases из меню.", "income": "Доход", "monthlyIncome": "Месячный доход", "workdaysInMonth": "Рабочие дни", "timer": "Таймер", "workMode": "Режим", "fixedClockOut": "Фикс. конец", "unlockTimer": "От разблокировки", "startTime": "Начало", "clockOutTime": "Конец", "dailyHours": "Часов в день", "done": "Готово", "resetDefault": "Сбросить", "syncingTime": "Синхронизация времени...", "noPanelContent": "Ничего не выбрано", "currentTime": "Текущее время", "waitingIncome": "Доход: ожидание сетевого времени", "waitingUnlock": "Ожидание первой разблокировки после 5:00", "clockOutNotificationTitle": "Пора заканчивать", "clockOutNotificationBody": "Отличная работа сегодня. OffTick досчитал до конца рабочего дня.", "yuan": "CNY", "days": "дн.", "hoursUnit": "ч", "unlockRecords": "История разблокировок", "exportUnlockRecords": "Экспортировать историю", "exportUnlockRecordsHint": "Введите диапазон дат в формате yyyy-MM-dd.", "exportStartDate": "Дата начала", "exportEndDate": "Дата окончания", "export": "Экспорт", "cancel": "Отмена", "invalidDateRange": "Недопустимый диапазон дат", "dateRangeFormatHint": "Используйте yyyy-MM-dd и убедитесь, что дата начала не позже даты окончания.", "noUnlockRecords": "Нет записей", "noUnlockRecordsHint": "В выбранном диапазоне не найдено первой разблокировки после 5:00.", "exportComplete": "Экспорт завершён", "exportFailed": "Ошибка экспорта", "networkTimeUnavailable": "Сетевое время недоступно", "networkTimeUnavailableHint": "OffTick не удалось синхронизировать сетевое время. Подключитесь к интернету и повторите экспорт.", "launchAtLoginFailed": "Не удалось изменить запуск при входе", "launchAtLoginApprovalRequired": "Требуется подтверждение", "launchAtLoginApprovalRequiredHint": "Разрешите OffTick в Системные настройки > Основные > Объекты входа, чтобы включить."
        ]
    ]
}

private enum PanelContentField: Int {
    case date = 1
    case time
    case countdown
    case earnedIncome
    case dailyIncome
}

private enum WatermarkField: Int {
    case date = 1
    case device
}

final class NotificationCoordinator {
    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func celebrateClockOut(language: AppLanguage) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
                return
            }

            let content = UNMutableNotificationContent()
            content.title = L10n.text("clockOutNotificationTitle", language: language)
            content.body = L10n.text("clockOutNotificationBody", language: language)
            content.sound = .default

            let request = UNNotificationRequest(
                identifier: "offtick-clock-out-\(UUID().uuidString)",
                content: content,
                trigger: nil
            )
            UNUserNotificationCenter.current().add(request)

            DispatchQueue.main.async {
                NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
            }
        }
    }
}

struct GitHubRelease: Decodable {
    let tagName: String
    let name: String?
    let body: String?
    let htmlURL: URL
    let draft: Bool
    let prerelease: Bool

    var displayVersion: String {
        tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
    }

    var summary: String {
        let text = body?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else {
            return name ?? ""
        }

        return String(text.prefix(600))
    }

    private enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case body
        case htmlURL = "html_url"
        case draft
        case prerelease
    }
}

enum GitHubUpdateChecker {
    static let releasesURL = URL(string: "https://github.com/eveoh354/OffTick/releases")!
    private static let latestReleaseURL = URL(string: "https://api.github.com/repos/eveoh354/OffTick/releases/latest")!

    static func fetchLatestRelease(completion: @escaping (Result<GitHubRelease, Error>) -> Void) {
        var request = URLRequest(url: latestReleaseURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("OffTick", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 8

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                completion(.failure(error))
                return
            }

            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode),
                  let data else {
                completion(.failure(NSError(domain: "OffTick", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unable to fetch GitHub releases."])))
                return
            }

            do {
                completion(.success(try JSONDecoder().decode(GitHubRelease.self, from: data)))
            } catch {
                completion(.failure(error))
            }
        }.resume()
    }

    static func isRelease(_ release: GitHubRelease, newerThan currentVersion: String) -> Bool {
        guard !release.draft else {
            return false
        }

        return compareVersions(release.displayVersion, currentVersion) == .orderedDescending
    }

    private static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let leftParts = versionParts(lhs)
        let rightParts = versionParts(rhs)
        let count = max(leftParts.count, rightParts.count)

        for index in 0..<count {
            let left = index < leftParts.count ? leftParts[index] : 0
            let right = index < rightParts.count ? rightParts[index] : 0
            if left > right {
                return .orderedDescending
            }
            if left < right {
                return .orderedAscending
            }
        }

        return .orderedSame
    }

    private static func versionParts(_ version: String) -> [Int] {
        version
            .trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            .split(separator: ".")
            .map { part in
                Int(part.prefix { $0.isNumber }) ?? 0
            }
    }
}

enum LoginItemController {
    static var isSupported: Bool {
        if #available(macOS 13.0, *) {
            return true
        }

        return false
    }

    static var isEnabled: Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled || SMAppService.mainApp.status == .requiresApproval
        }

        return false
    }

    static var requiresApproval: Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .requiresApproval
        }

        return false
    }

    static func setEnabled(_ isEnabled: Bool) throws {
        guard #available(macOS 13.0, *) else {
            throw NSError(
                domain: "OffTick",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Launch at login requires macOS 13 or later."]
            )
        }

        if isEnabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}

final class FireworksView: NSView {
    private struct Particle {
        var position: CGPoint
        var velocity: CGVector
        var color: NSColor
        var radius: CGFloat
        var life: TimeInterval
        var maxLife: TimeInterval
    }

    private var particles: [Particle] = []
    private var timer: Timer?
    private var startDate = Date()
    private let colors: [NSColor] = [
        .systemRed,
        .systemOrange,
        .systemYellow,
        .systemGreen,
        .systemBlue,
        .systemPurple,
        .systemPink
    ]

    override var isOpaque: Bool {
        false
    }

    func start() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        startDate = Date()
        launchBurst(at: CGPoint(x: bounds.midX, y: bounds.midY))
        launchBurst(at: CGPoint(x: bounds.minX + bounds.width * 0.28, y: bounds.minY + bounds.height * 0.68))
        launchBurst(at: CGPoint(x: bounds.minX + bounds.width * 0.72, y: bounds.minY + bounds.height * 0.66))

        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    private func launchBurst(at origin: CGPoint) {
        for _ in 0..<46 {
            let angle = CGFloat.random(in: 0..<(CGFloat.pi * 2))
            let speed = CGFloat.random(in: 38...128)
            particles.append(
                Particle(
                    position: origin,
                    velocity: CGVector(dx: cos(angle) * speed, dy: sin(angle) * speed),
                    color: colors.randomElement() ?? .systemYellow,
                    radius: CGFloat.random(in: 2.0...4.6),
                    life: TimeInterval.random(in: 1.0...1.8),
                    maxLife: 1.8
                )
            )
        }
    }

    private func tick() {
        let delta: CGFloat = 1.0 / 60.0
        let elapsed = Date().timeIntervalSince(startDate)

        if elapsed > 0.7 && elapsed < 0.74 {
            launchBurst(at: CGPoint(x: bounds.midX, y: bounds.minY + bounds.height * 0.72))
        }

        particles = particles.compactMap { particle in
            var particle = particle
            particle.position.x += particle.velocity.dx * delta
            particle.position.y += particle.velocity.dy * delta
            particle.velocity.dy -= 88 * delta
            particle.velocity.dx *= 0.985
            particle.velocity.dy *= 0.985
            particle.life -= TimeInterval(delta)
            return particle.life > 0 ? particle : nil
        }

        needsDisplay = true

        if elapsed > 4.2 || particles.isEmpty && elapsed > 1.0 {
            timer?.invalidate()
            timer = nil
            removeFromSuperview()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        for particle in particles {
            let alpha = max(0, min(1, particle.life / particle.maxLife))
            particle.color.withAlphaComponent(alpha).setFill()
            let rect = CGRect(
                x: particle.position.x - particle.radius / 2,
                y: particle.position.y - particle.radius / 2,
                width: particle.radius,
                height: particle.radius
            )
            NSBezierPath(ovalIn: rect).fill()
        }
    }

    deinit {
        timer?.invalidate()
    }
}

final class NetworkTimeProvider {
    private let queue = DispatchQueue(label: "OffTick.NetworkTimeProvider")
    private var offset: TimeInterval = 0
    private var lastSyncDate: Date?

    var now: Date {
        queue.sync {
            Date().addingTimeInterval(offset)
        }
    }

    var isSynced: Bool {
        queue.sync {
            lastSyncDate != nil
        }
    }

    func sync(completion: (() -> Void)? = nil) {
        guard shouldSync else {
            completion?()
            return
        }

        var request = URLRequest(url: URL(string: "https://www.apple.com/")!)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 6

        URLSession.shared.dataTask(with: request) { [weak self] _, response, _ in
            defer {
                DispatchQueue.main.async {
                    completion?()
                }
            }

            guard let self,
                  let httpResponse = response as? HTTPURLResponse,
                  let dateText = httpResponse.value(forHTTPHeaderField: "Date"),
                  let serverDate = Self.httpDateFormatter.date(from: dateText) else {
                return
            }

            self.queue.sync {
                self.offset = serverDate.timeIntervalSince(Date())
                self.lastSyncDate = Date()
            }
        }.resume()
    }

    private var shouldSync: Bool {
        queue.sync {
            guard let lastSyncDate else {
                return true
            }

            return Date().timeIntervalSince(lastSyncDate) > 10 * 60
        }
    }

    private static let httpDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }()
}

struct WorkSettings {
    var monthlyIncome: Double
    var workdaysInMonth: Int
    var dailyWorkHours: Double
    var fixedStartHour: Int
    var fixedStartMinute: Int
    var fixedClockOutHour: Int
    var fixedClockOutMinute: Int
    var mode: ClockOutMode
    var timeFormat: TimeFormatMode
    var calendarMode: CalendarMode
    var panelSize: PanelSizeMode
    var language: AppLanguage
    var showDateInPanel: Bool
    var showTimeInPanel: Bool
    var showCountdownInPanel: Bool
    var showEarnedIncomeInPanel: Bool
    var showDailyIncomeInPanel: Bool
    var includePanelInScreenshots: Bool
    var includeDateInExportWatermark: Bool
    var includeDeviceInExportWatermark: Bool

    static var `default`: WorkSettings {
        defaultSettings(for: Date())
    }

    static func defaultSettings(for date: Date) -> WorkSettings {
        WorkSettings(
            monthlyIncome: 10_000,
            workdaysInMonth: ChinaWorkCalendar.workdaysInMonth(containing: date),
            dailyWorkHours: 8,
            fixedStartHour: 9,
            fixedStartMinute: 0,
            fixedClockOutHour: 18,
            fixedClockOutMinute: 0,
            mode: .unlockTimer,
            timeFormat: .twentyFourHour,
            calendarMode: .gregorian,
            panelSize: .medium,
            language: .simplifiedChinese,
            showDateInPanel: true,
            showTimeInPanel: true,
            showCountdownInPanel: true,
            showEarnedIncomeInPanel: false,
            showDailyIncomeInPanel: false,
            includePanelInScreenshots: false,
            includeDateInExportWatermark: true,
            includeDeviceInExportWatermark: true
        )
    }

    static func load() -> WorkSettings {
        migrateLegacyDefaultsIfNeeded()

        let defaults = UserDefaults.standard
        let fallback = WorkSettings.default
        let workdaysKey = "workdaysInMonth"
        let migrationKey = "didMigrateChinaWorkdaysDefault"

        if !defaults.bool(forKey: migrationKey) {
            if defaults.object(forKey: workdaysKey) == nil || defaults.integer(forKey: workdaysKey) == 22 {
                defaults.set(fallback.workdaysInMonth, forKey: workdaysKey)
            }

            defaults.set(true, forKey: migrationKey)
        }

        return WorkSettings(
            monthlyIncome: defaults.object(forKey: "monthlyIncome").map { _ in defaults.double(forKey: "monthlyIncome") } ?? fallback.monthlyIncome,
            workdaysInMonth: defaults.object(forKey: workdaysKey).map { _ in defaults.integer(forKey: workdaysKey) } ?? fallback.workdaysInMonth,
            dailyWorkHours: defaults.object(forKey: "dailyWorkHours").map { _ in defaults.double(forKey: "dailyWorkHours") } ?? fallback.dailyWorkHours,
            fixedStartHour: defaults.object(forKey: "fixedStartHour").map { _ in defaults.integer(forKey: "fixedStartHour") } ?? fallback.fixedStartHour,
            fixedStartMinute: defaults.object(forKey: "fixedStartMinute").map { _ in defaults.integer(forKey: "fixedStartMinute") } ?? fallback.fixedStartMinute,
            fixedClockOutHour: defaults.object(forKey: "fixedClockOutHour").map { _ in defaults.integer(forKey: "fixedClockOutHour") } ?? fallback.fixedClockOutHour,
            fixedClockOutMinute: defaults.object(forKey: "fixedClockOutMinute").map { _ in defaults.integer(forKey: "fixedClockOutMinute") } ?? fallback.fixedClockOutMinute,
            mode: ClockOutMode(storageValue: defaults.string(forKey: ClockOutMode.storageKey) ?? fallback.mode.storageValue),
            timeFormat: TimeFormatMode(storageValue: defaults.string(forKey: TimeFormatMode.storageKey) ?? fallback.timeFormat.storageValue),
            calendarMode: CalendarMode(storageValue: defaults.string(forKey: CalendarMode.storageKey) ?? fallback.calendarMode.storageValue),
            panelSize: PanelSizeMode(storageValue: defaults.string(forKey: PanelSizeMode.storageKey) ?? fallback.panelSize.storageValue),
            language: AppLanguage(storageValue: defaults.string(forKey: AppLanguage.storageKey) ?? fallback.language.storageValue),
            showDateInPanel: defaults.object(forKey: "showDateInPanel").map { _ in defaults.bool(forKey: "showDateInPanel") } ?? fallback.showDateInPanel,
            showTimeInPanel: defaults.object(forKey: "showTimeInPanel").map { _ in defaults.bool(forKey: "showTimeInPanel") } ?? fallback.showTimeInPanel,
            showCountdownInPanel: defaults.object(forKey: "showCountdownInPanel").map { _ in defaults.bool(forKey: "showCountdownInPanel") } ?? fallback.showCountdownInPanel,
            showEarnedIncomeInPanel: defaults.object(forKey: "showEarnedIncomeInPanel").map { _ in defaults.bool(forKey: "showEarnedIncomeInPanel") } ?? fallback.showEarnedIncomeInPanel,
            showDailyIncomeInPanel: defaults.object(forKey: "showDailyIncomeInPanel").map { _ in defaults.bool(forKey: "showDailyIncomeInPanel") } ?? fallback.showDailyIncomeInPanel,
            includePanelInScreenshots: defaults.object(forKey: "includePanelInScreenshots").map { _ in defaults.bool(forKey: "includePanelInScreenshots") } ?? fallback.includePanelInScreenshots,
            includeDateInExportWatermark: defaults.object(forKey: "includeDateInExportWatermark").map { _ in defaults.bool(forKey: "includeDateInExportWatermark") } ?? fallback.includeDateInExportWatermark,
            includeDeviceInExportWatermark: defaults.object(forKey: "includeDeviceInExportWatermark").map { _ in defaults.bool(forKey: "includeDeviceInExportWatermark") } ?? fallback.includeDeviceInExportWatermark
        ).sanitized()
    }

    private static func migrateLegacyDefaultsIfNeeded() {
        let markerKey = "didMigrateLegacyDefaultsToOnlineEveoh"
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: markerKey) else {
            return
        }

        let explicitKeys = [
            "monthlyIncome",
            "workdaysInMonth",
            "dailyWorkHours",
            "fixedStartHour",
            "fixedStartMinute",
            "fixedClockOutHour",
            "fixedClockOutMinute",
            ClockOutMode.storageKey,
            TimeFormatMode.storageKey,
            CalendarMode.storageKey,
            PanelSizeMode.storageKey,
            AppLanguage.storageKey,
            "showDateInPanel",
            "showTimeInPanel",
            "showCountdownInPanel",
            "showEarnedIncomeInPanel",
            "showDailyIncomeInPanel",
            "includePanelInScreenshots",
            "includeDateInExportWatermark",
            "includeDeviceInExportWatermark",
            "didMigrateChinaWorkdaysDefault"
        ]

        for domain in ["dev.local.OffTick", "OffTick"] {
            guard let legacyDefaults = UserDefaults(suiteName: domain) else {
                continue
            }

            let legacyValues = legacyDefaults.dictionaryRepresentation()
            for key in explicitKeys where defaults.object(forKey: key) == nil {
                if let value = legacyValues[key] {
                    defaults.set(value, forKey: key)
                }
            }

            for (key, value) in legacyValues where key.hasPrefix("firstUnlockAfterFive-") && defaults.object(forKey: key) == nil {
                defaults.set(value, forKey: key)
            }
        }

        defaults.set(true, forKey: markerKey)
    }

    func save() {
        let defaults = UserDefaults.standard
        let sanitized = self.sanitized()
        defaults.set(sanitized.monthlyIncome, forKey: "monthlyIncome")
        defaults.set(sanitized.workdaysInMonth, forKey: "workdaysInMonth")
        defaults.set(sanitized.dailyWorkHours, forKey: "dailyWorkHours")
        defaults.set(sanitized.fixedStartHour, forKey: "fixedStartHour")
        defaults.set(sanitized.fixedStartMinute, forKey: "fixedStartMinute")
        defaults.set(sanitized.fixedClockOutHour, forKey: "fixedClockOutHour")
        defaults.set(sanitized.fixedClockOutMinute, forKey: "fixedClockOutMinute")
        defaults.set(sanitized.mode.storageValue, forKey: ClockOutMode.storageKey)
        defaults.set(sanitized.timeFormat.storageValue, forKey: TimeFormatMode.storageKey)
        defaults.set(sanitized.calendarMode.storageValue, forKey: CalendarMode.storageKey)
        defaults.set(sanitized.panelSize.storageValue, forKey: PanelSizeMode.storageKey)
        defaults.set(sanitized.language.storageValue, forKey: AppLanguage.storageKey)
        defaults.set(sanitized.showDateInPanel, forKey: "showDateInPanel")
        defaults.set(sanitized.showTimeInPanel, forKey: "showTimeInPanel")
        defaults.set(sanitized.showCountdownInPanel, forKey: "showCountdownInPanel")
        defaults.set(sanitized.showEarnedIncomeInPanel, forKey: "showEarnedIncomeInPanel")
        defaults.set(sanitized.showDailyIncomeInPanel, forKey: "showDailyIncomeInPanel")
        defaults.set(sanitized.includePanelInScreenshots, forKey: "includePanelInScreenshots")
        defaults.set(sanitized.includeDateInExportWatermark, forKey: "includeDateInExportWatermark")
        defaults.set(sanitized.includeDeviceInExportWatermark, forKey: "includeDeviceInExportWatermark")
    }

    private func sanitized() -> WorkSettings {
        WorkSettings(
            monthlyIncome: max(0, monthlyIncome),
            workdaysInMonth: max(1, workdaysInMonth),
            dailyWorkHours: min(max(0.5, dailyWorkHours), 24),
            fixedStartHour: min(max(0, fixedStartHour), 23),
            fixedStartMinute: min(max(0, fixedStartMinute), 59),
            fixedClockOutHour: min(max(0, fixedClockOutHour), 23),
            fixedClockOutMinute: min(max(0, fixedClockOutMinute), 59),
            mode: mode,
            timeFormat: timeFormat,
            calendarMode: calendarMode,
            panelSize: panelSize,
            language: language,
            showDateInPanel: showDateInPanel,
            showTimeInPanel: showTimeInPanel,
            showCountdownInPanel: showCountdownInPanel,
            showEarnedIncomeInPanel: showEarnedIncomeInPanel,
            showDailyIncomeInPanel: showDailyIncomeInPanel,
            includePanelInScreenshots: includePanelInScreenshots,
            includeDateInExportWatermark: includeDateInExportWatermark,
            includeDeviceInExportWatermark: includeDeviceInExportWatermark
        )
    }

    var panelVisibleItemCount: Int {
        [
            showDateInPanel,
            showTimeInPanel,
            showCountdownInPanel,
            showEarnedIncomeInPanel,
            showDailyIncomeInPanel
        ].filter { $0 }.count
    }

    var dailyIncome: Double {
        monthlyIncome / Double(workdaysInMonth)
    }

    var workDuration: TimeInterval {
        dailyWorkHours * 60 * 60
    }

    func scheduledWorkDuration(on date: Date) -> TimeInterval {
        switch mode {
        case .fixedTime:
            let start = fixedStartDate(on: date)
            var end = fixedClockOutDate(on: date)
            if end <= start {
                end = Calendar.beijing.date(byAdding: .day, value: 1, to: end) ?? end
            }
            return max(60, end.timeIntervalSince(start))
        case .unlockTimer:
            return workDuration
        }
    }

    func fixedStartDate(on date: Date) -> Date {
        Calendar.beijing.date(
            bySettingHour: fixedStartHour,
            minute: fixedStartMinute,
            second: 0,
            of: date
        ) ?? date
    }

    func fixedClockOutDate(on date: Date) -> Date {
        Calendar.beijing.date(
            bySettingHour: fixedClockOutHour,
            minute: fixedClockOutMinute,
            second: 0,
            of: date
        ) ?? date
    }
}

extension Calendar {
    static var beijing: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        calendar.locale = Locale(identifier: "zh_CN")
        return calendar
    }
}

struct ChinaWorkCalendar {
    private static let calendar = Calendar(identifier: .gregorian)

    static func workdaysInMonth(containing date: Date) -> Int {
        let components = calendar.dateComponents([.year, .month], from: date)
        guard let year = components.year,
              let month = components.month,
              let firstDay = calendar.date(from: DateComponents(year: year, month: month, day: 1)),
              let dayRange = calendar.range(of: .day, in: .month, for: firstDay) else {
            return 22
        }

        return dayRange.reduce(0) { count, day in
            guard let current = calendar.date(from: DateComponents(year: year, month: month, day: day)) else {
                return count
            }

            return count + (isWorkday(current) ? 1 : 0)
        }
    }

    private static func isWorkday(_ date: Date) -> Bool {
        let key = dateKey(date)

        if adjustedWorkdays2026.contains(key) {
            return true
        }

        if holidays2026.contains(key) {
            return false
        }

        let weekday = calendar.component(.weekday, from: date)
        return weekday != 1 && weekday != 7
    }

    private static func dateKey(_ date: Date) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    private static let holidays2026: Set<String> = [
        "2026-01-01", "2026-01-02", "2026-01-03",
        "2026-02-15", "2026-02-16", "2026-02-17", "2026-02-18", "2026-02-19", "2026-02-20", "2026-02-21", "2026-02-22", "2026-02-23",
        "2026-04-04", "2026-04-05", "2026-04-06",
        "2026-05-01", "2026-05-02", "2026-05-03", "2026-05-04", "2026-05-05",
        "2026-06-19", "2026-06-20", "2026-06-21",
        "2026-09-25", "2026-09-26", "2026-09-27",
        "2026-10-01", "2026-10-02", "2026-10-03", "2026-10-04", "2026-10-05", "2026-10-06", "2026-10-07"
    ]

    private static let adjustedWorkdays2026: Set<String> = [
        "2026-01-04",
        "2026-02-14", "2026-02-28",
        "2026-05-09",
        "2026-09-20", "2026-10-10"
    ]
}

private enum SettingField: Int {
    case monthlyIncome = 1
    case workdaysInMonth
    case dailyWorkHours
    case fixedClockOutHour
    case fixedClockOutMinute
    case fixedStartHour
    case fixedStartMinute

    func format(value: Double) -> String {
        switch self {
        case .monthlyIncome:
            return String(format: "%.0f", value)
        case .workdaysInMonth, .fixedClockOutHour, .fixedClockOutMinute, .fixedStartHour, .fixedStartMinute:
            return String(format: "%.0f", value)
        case .dailyWorkHours:
            return String(format: "%.1f", value)
        }
    }
}

struct OffTickSnapshot {
    let settings: WorkSettings
    let now: Date

    func displayLines() -> [String] {
        [
            dateText(),
            timeText(),
            "\(L10n.text("countdown", language: settings.language))：\(countdownText())"
        ]
    }

    func statusTitle() -> String {
        countdownText(short: true)
    }

    func dateText() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: settings.language.localeIdentifier)
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        switch settings.calendarMode {
        case .gregorian:
            formatter.calendar = Calendar.beijing
            if settings.language == .simplifiedChinese || settings.language == .traditionalChinese {
                formatter.dateFormat = "yyyy年M月d日 EEEE"
            } else {
                formatter.dateStyle = .full
                formatter.timeStyle = .none
            }
            return formatter.string(from: now)
        case .lunar:
            var calendar = Calendar(identifier: .chinese)
            calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
            formatter.calendar = calendar
            formatter.dateFormat = "U年M月d日 EEEE"
            return "\(L10n.text("lunar", language: settings.language)) \(formatter.string(from: now))"
        }
    }

    func timeText() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: settings.language.localeIdentifier)
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = settings.timeFormat == .twentyFourHour ? "HH:mm:ss" : "a h:mm:ss"
        return formatter.string(from: now)
    }

    func countdownText(short: Bool = false) -> String {
        if settings.mode == .unlockTimer && WorkSessionClock.isWaitingForUnlock(now: now) {
            return short ? "--:--" : L10n.text("waitingUnlock", language: settings.language)
        }

        let remaining = max(0, clockOutDate().timeIntervalSince(now))
        let hours = Int(remaining) / 3600
        let minutes = (Int(remaining) % 3600) / 60
        let seconds = Int(remaining) % 60

        if short {
            return String(format: "%02d:%02d", hours, minutes)
        }

        switch settings.language {
        case .simplifiedChinese:
            return String(format: "%02d小时%02d分%02d秒", hours, minutes, seconds)
        case .traditionalChinese:
            return String(format: "%02d小時%02d分%02d秒", hours, minutes, seconds)
        case .japanese:
            return String(format: "%02d時間%02d分%02d秒", hours, minutes, seconds)
        case .korean:
            return String(format: "%02d시간 %02d분 %02d초", hours, minutes, seconds)
        default:
            return String(format: "%02dh %02dm %02ds", hours, minutes, seconds)
        }
    }

    func earnedToday() -> Double {
        if settings.mode == .unlockTimer && WorkSessionClock.isWaitingForUnlock(now: now) {
            return 0
        }

        let workDuration = settings.scheduledWorkDuration(on: now)
        let elapsed = min(max(0, now.timeIntervalSince(workStartDate())), workDuration)
        return settings.dailyIncome * elapsed / max(1, workDuration)
    }

    var hasClockedOut: Bool {
        clockOutDate() <= now
    }

    private func workStartDate() -> Date {
        switch settings.mode {
        case .fixedTime:
            return settings.fixedStartDate(on: now)
        case .unlockTimer:
            return WorkSessionClock.workStartDate(now: now) ?? now
        }
    }

    private func clockOutDate() -> Date {
        switch settings.mode {
        case .fixedTime:
            var end = settings.fixedClockOutDate(on: now)
            if end <= workStartDate() {
                end = Calendar.beijing.date(byAdding: .day, value: 1, to: end) ?? end
            }
            return end
        case .unlockTimer:
            guard let start = WorkSessionClock.workStartDate(now: now) else {
                return now
            }
            return start.addingTimeInterval(settings.workDuration)
        }
    }
}

struct WorkSessionClock {
    private static let unlockDatePrefix = "firstUnlockAfterFive"

    static func recordUnlockIfNeeded(now: Date) {
        guard isAfterFiveAM(now) else {
            return
        }

        let defaults = UserDefaults.standard
        let key = unlockKey(now)
        if defaults.object(forKey: key) == nil {
            defaults.set(now, forKey: key)
        }
    }

    static func records(from startDate: Date, to endDate: Date) -> [UnlockRecord] {
        let defaults = UserDefaults.standard
        let startDay = Calendar.beijing.startOfDay(for: startDate)
        let endDay = Calendar.beijing.startOfDay(for: endDate)

        return defaults.dictionaryRepresentation().compactMap { key, value in
            guard key.hasPrefix("\(unlockDatePrefix)-"),
                  let unlockDate = value as? Date else {
                return nil
            }

            let recordDay = Calendar.beijing.startOfDay(for: unlockDate)
            guard recordDay >= startDay && recordDay <= endDay else {
                return nil
            }

            return UnlockRecord(dateKey: dateKey(unlockDate), unlockDate: unlockDate)
        }
        .sorted { $0.unlockDate < $1.unlockDate }
    }

    static func workStartDate(now: Date) -> Date? {
        let defaults = UserDefaults.standard
        return defaults.object(forKey: unlockKey(now)) as? Date
    }

    static func isWaitingForUnlock(now: Date) -> Bool {
        workStartDate(now: now) == nil
    }

    private static func isAfterFiveAM(_ date: Date) -> Bool {
        let start = Calendar.beijing.date(bySettingHour: 5, minute: 0, second: 0, of: date) ?? date
        return date >= start
    }

    private static func unlockKey(_ date: Date) -> String {
        "\(unlockDatePrefix)-\(dateKey(date))"
    }

    static func dateKey(_ date: Date) -> String {
        let components = Calendar.beijing.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }
}

struct UnlockRecord {
    let dateKey: String
    let unlockDate: Date
}

struct PDFExportText {
    let title: String
    let range: String
    let generated: String
    let bundle: String
    let mode: String
    let dailyHours: String
    let date: String
    let firstUnlockTime: String
    let recordedAt: String
    let footer: String
    let page: String
    let deviceWarning: String

    init(language: AppLanguage) {
        switch language {
        case .simplifiedChinese:
            title = "OffTick 解锁记录"
            range = "范围"
            generated = "生成时间"
            bundle = "Bundle"
            mode = "模式"
            dailyHours = "每日时长"
            date = "日期"
            firstUnlockTime = "首次解锁时间"
            recordedAt = "记录时间"
            footer = "OffTick 本地导出"
            page = "页"
            deviceWarning = "本 PDF 水印包含设备序列号，请勿泄漏或转发给不可信对象。"
        case .traditionalChinese:
            title = "OffTick 解鎖記錄"
            range = "範圍"
            generated = "產生時間"
            bundle = "Bundle"
            mode = "模式"
            dailyHours = "每日時長"
            date = "日期"
            firstUnlockTime = "首次解鎖時間"
            recordedAt = "記錄時間"
            footer = "OffTick 本地匯出"
            page = "頁"
            deviceWarning = "本 PDF 浮水印包含設備序號，請勿洩漏或轉發給不可信對象。"
        default:
            title = "OffTick Unlock Records"
            range = "Range"
            generated = "Generated"
            bundle = "Bundle"
            mode = "Mode"
            dailyHours = "Daily Hours"
            date = "Date"
            firstUnlockTime = "First Unlock Time"
            recordedAt = "Recorded At"
            footer = "OffTick local export"
            page = "page"
            deviceWarning = "This PDF watermark includes the device serial number. Do not share it with untrusted recipients."
        }
    }
}

enum DeviceIdentifier {
    static func serialNumber() -> String? {
        let platformExpert = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard platformExpert != 0 else {
            return nil
        }

        defer {
            IOObjectRelease(platformExpert)
        }

        guard let serial = IORegistryEntryCreateCFProperty(platformExpert, "IOPlatformSerialNumber" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String else {
            return nil
        }

        return serial.isEmpty ? nil : serial
    }
}

enum UnlockRecordsPDFExporter {
    static func write(records: [UnlockRecord], from startDate: Date, to endDate: Date, settings: WorkSettings, generatedAt: Date, to url: URL) throws {
        let pageRect = CGRect(x: 0, y: 0, width: 595, height: 842)
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data),
              let context = CGContext(consumer: consumer, mediaBox: nil, nil) else {
            throw NSError(domain: "OffTick", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unable to create PDF context."])
        }

        let rowsPerPage = 28
        let pageCount = max(1, Int(ceil(Double(records.count) / Double(rowsPerPage))))
        let deviceSerialNumber = settings.includeDeviceInExportWatermark ? DeviceIdentifier.serialNumber() ?? "unknown" : nil
        for pageIndex in 0..<pageCount {
            var mediaBox = pageRect
            context.beginPDFPage([kCGPDFContextMediaBox as String: NSData(bytes: &mediaBox, length: MemoryLayout<CGRect>.size)] as CFDictionary)
            drawPage(
                context: context,
                rect: pageRect,
                records: records,
                pageIndex: pageIndex,
                pageCount: pageCount,
                rowsPerPage: rowsPerPage,
                from: startDate,
                to: endDate,
                settings: settings,
                generatedAt: generatedAt,
                deviceSerialNumber: deviceSerialNumber
            )
            context.endPDFPage()
        }

        context.closePDF()
        try data.write(to: url, options: .atomic)
    }

    private static func drawPage(
        context: CGContext,
        rect: CGRect,
        records: [UnlockRecord],
        pageIndex: Int,
        pageCount: Int,
        rowsPerPage: Int,
        from startDate: Date,
        to endDate: Date,
        settings: WorkSettings,
        generatedAt: Date,
        deviceSerialNumber: String?
    ) {
        NSGraphicsContext.saveGraphicsState()
        context.saveGState()
        context.translateBy(x: 0, y: rect.height)
        context.scaleBy(x: 1, y: -1)
        let graphicsContext = NSGraphicsContext(cgContext: context, flipped: true)
        NSGraphicsContext.current = graphicsContext

        NSColor.white.setFill()
        NSBezierPath(rect: rect).fill()

        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 22),
            .foregroundColor: NSColor.labelColor
        ]
        let subtitleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        let headerAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 12),
            .foregroundColor: NSColor.labelColor
        ]
        let bodyAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor.labelColor
        ]

        let margin: CGFloat = 54
        let startIndex = pageIndex * rowsPerPage
        let endIndex = min(records.count, startIndex + rowsPerPage)
        let pageRecords = records[startIndex..<endIndex]
        let contentBottom = CGFloat(178 + (max(1, pageRecords.count) * 22))
        let text = PDFExportText(language: settings.language)
        drawWatermarks(
            in: CGRect(x: margin, y: 168, width: rect.width - (margin * 2), height: min(contentBottom + 10, rect.height - 96) - 168),
            settings: settings,
            generatedAt: generatedAt,
            deviceSerialNumber: deviceSerialNumber
        )

        let rangeText = "\(dateString(startDate)) - \(dateString(endDate))"
        (text.title as NSString).draw(at: NSPoint(x: margin, y: 46), withAttributes: titleAttributes)
        ("\(text.range): \(rangeText)    \(text.generated): \(dateTimeString(generatedAt))    \(text.bundle): \(Bundle.main.bundleIdentifier ?? "unknown")" as NSString)
            .draw(at: NSPoint(x: margin, y: 76), withAttributes: subtitleAttributes)
        ("\(text.mode): \(settings.mode.storageValue)    \(text.dailyHours): \(String(format: "%.1f", settings.dailyWorkHours))" as NSString)
            .draw(at: NSPoint(x: margin, y: 94), withAttributes: subtitleAttributes)

        drawLine(from: CGPoint(x: margin, y: 122), to: CGPoint(x: rect.width - margin, y: 122))
        (text.date as NSString).draw(at: NSPoint(x: margin, y: 138), withAttributes: headerAttributes)
        (text.firstUnlockTime as NSString).draw(at: NSPoint(x: margin + 180, y: 138), withAttributes: headerAttributes)
        (text.recordedAt as NSString).draw(at: NSPoint(x: margin + 330, y: 138), withAttributes: headerAttributes)
        drawLine(from: CGPoint(x: margin, y: 160), to: CGPoint(x: rect.width - margin, y: 160))

        var y: CGFloat = 178
        for record in pageRecords {
            (record.dateKey as NSString).draw(at: NSPoint(x: margin, y: y), withAttributes: bodyAttributes)
            (timeString(record.unlockDate) as NSString).draw(at: NSPoint(x: margin + 180, y: y), withAttributes: bodyAttributes)
            (dateTimeString(record.unlockDate) as NSString).draw(at: NSPoint(x: margin + 330, y: y), withAttributes: bodyAttributes)
            y += 22
        }

        drawLine(from: CGPoint(x: margin, y: rect.height - 58), to: CGPoint(x: rect.width - margin, y: rect.height - 58))
        ("\(text.footer) - \(text.page) \(pageIndex + 1)/\(pageCount)" as NSString)
            .draw(at: NSPoint(x: margin, y: rect.height - 44), withAttributes: subtitleAttributes)
        if settings.includeDeviceInExportWatermark {
            (text.deviceWarning as NSString)
                .draw(at: NSPoint(x: margin, y: rect.height - 28), withAttributes: subtitleAttributes)
        }

        context.restoreGState()
        NSGraphicsContext.current = nil
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func drawWatermarks(in rect: CGRect, settings: WorkSettings, generatedAt: Date, deviceSerialNumber: String?) {
        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 14),
            .foregroundColor: NSColor.black.withAlphaComponent(0.055)
        ]
        let detailAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10.9, weight: .semibold),
            .foregroundColor: NSColor.black.withAlphaComponent(0.055)
        ]
        var lines = ["OffTick"]
        if let deviceSerialNumber {
            lines.append(deviceSerialNumber)
        }
        if settings.includeDateInExportWatermark {
            lines.append(dateTimeString(generatedAt))
        }

        let maxWidth = lines.map { line in
            (line as NSString).size(withAttributes: line == "OffTick" ? titleAttributes : detailAttributes).width
        }.max() ?? 0
        let lineHeight: CGFloat = 16
        let blockHeight = max(lineHeight, CGFloat(lines.count) * lineHeight)
        let xStep = min(max(maxWidth + 58, 92), 170)
        let yStep = min(max(blockHeight + 18, 38), 60)

        var y = rect.minY + 18
        while y < rect.maxY {
            var x = rect.minX + 34
            while x < rect.maxX {
                NSGraphicsContext.saveGraphicsState()
                let transform = NSAffineTransform()
                transform.translateX(by: x, yBy: y)
                transform.rotate(byDegrees: -20)
                transform.concat()
                for (index, line) in lines.enumerated() {
                    let attributes = line == "OffTick" ? titleAttributes : detailAttributes
                    (line as NSString).draw(at: NSPoint(x: -maxWidth / 2, y: -blockHeight / 2 + CGFloat(index) * lineHeight), withAttributes: attributes)
                }
                NSGraphicsContext.restoreGraphicsState()
                x += xStep
            }
            y += yStep
        }
    }

    private static func drawLine(from start: CGPoint, to end: CGPoint) {
        NSColor.separatorColor.setStroke()
        let path = NSBezierPath()
        path.move(to: start)
        path.line(to: end)
        path.lineWidth = 0.8
        path.stroke()
    }

    private static func dateString(_ date: Date) -> String {
        dateFormatter.dateFormat = "yyyy-MM-dd"
        return dateFormatter.string(from: date)
    }

    private static func timeString(_ date: Date) -> String {
        dateFormatter.dateFormat = "HH:mm:ss"
        return dateFormatter.string(from: date)
    }

    private static func dateTimeString(_ date: Date) -> String {
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return dateFormatter.string(from: date)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar.beijing
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        return formatter
    }()
}
