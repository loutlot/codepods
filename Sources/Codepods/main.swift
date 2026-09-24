import AppKit
import ApplicationServices
import CoreImage
import IOKit.hid
import ServiceManagement

private let chatGPTBundleID = "com.openai.codex"

private func tr(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: NSLocalizedString(key, comment: ""), arguments: arguments)
}

private enum RemoteKey: Int {
    case volumeUp = 0
    case volumeDown = 1
    case playPause = 16
}

private struct AXNode {
    let element: AXUIElement
}

private enum AXUI {
    static func get(_ element: AXUIElement, _ name: String) -> Any? {
        var result: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success ? result : nil
    }

    static func string(_ element: AXUIElement, _ name: String) -> String {
        get(element, name) as? String ?? ""
    }

    static func press(_ element: AXUIElement) -> Bool {
        AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
    }

    static func key(_ code: CGKeyCode, down: Bool, flags: CGEventFlags = [], pid: pid_t? = nil) -> Bool {
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down) else { return false }
        event.flags = flags
        if let pid { event.postToPid(pid) } else { event.post(tap: .cgSessionEventTap) }
        return true
    }

    static func findControl(_ app: AXUIElement, role: String,
                            matchingTitle: (String) -> Bool) -> AXNode? {
        guard let focusedValue = get(app, kAXFocusedWindowAttribute) else { return nil }
        let focused = focusedValue as! AXUIElement
        var visited = 0
        func visit(_ element: AXUIElement, depth: Int) -> AXNode? {
            guard depth < 30, visited < 6000 else { return nil }
            visited += 1
            if string(element, kAXRoleAttribute) == role {
                let title = string(element, kAXTitleAttribute)
                if matchingTitle(title) {
                    return AXNode(element: element)
                }
            }
            for child in get(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
                if let match = visit(child, depth: depth + 1) { return match }
            }
            return nil
        }
        return visit(focused, depth: 0)
    }
}

private enum ControllerUpdate {
    case model(String)
    case dictation(Bool)
    case error(String)
}

private final class ChatGPTController {
    var onUpdate: ((ControllerUpdate) -> Void)?
    private let work = DispatchQueue(label: "Codepods.ChatGPT.UI", qos: .userInitiated)
    private var changingModel = false
    private var cachedPicker: AXNode?
    private var dictationHeld = false
    private var dictationPID: pid_t?

    private struct RecentModel {
        let number: Int
        let name: String
        let element: AXUIElement
    }

    private func appElement() -> AXUIElement? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier == chatGPTBundleID else { return nil }
        return AXUIElementCreateApplication(app.processIdentifier)
    }

    private func publish(_ update: ControllerUpdate) {
        DispatchQueue.main.async { [weak self] in self?.onUpdate?(update) }
    }

    func refreshModel() {
        work.async { [weak self] in
            guard let self else { return }
            guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == chatGPTBundleID }) else {
                self.cachedPicker = nil
                self.publish(.model(tr("ChatGPT is not running")))
                return
            }
            let element = AXUIElementCreateApplication(app.processIdentifier)
            let picker: AXNode?
            if let cached = self.cachedPicker,
               AXUI.string(cached.element, kAXTitleAttribute).lowercased().hasPrefix("gpt-") {
                picker = cached
            } else {
                picker = AXUI.findControl(element, role: kAXPopUpButtonRole as String,
                                         matchingTitle: { $0.lowercased().hasPrefix("gpt-") })
            }
            guard let picker else { self.publish(.model(tr("Unavailable"))); return }
            self.cachedPicker = picker
            let title = AXUI.string(picker.element, kAXTitleAttribute)
            if !title.isEmpty { self.publish(.model(title)) }
        }
    }

    func toggleDictation() {
        work.async { [weak self] in self?.toggleDictationNow() }
    }

    func releaseDictation() {
        work.sync { releaseDictationNow() }
    }

    private func toggleDictationNow() {
        if dictationHeld {
            releaseDictationNow()
            return
        }
        guard let app = appElement() else { return }
        var pid: pid_t = 0
        guard AXUIElementGetPid(app, &pid) == .success,
              AXUI.key(2, down: true, flags: [.maskControl, .maskShift]) else {
            publish(.error(tr("Could not start voice input")))
            return
        }
        dictationPID = pid
        dictationHeld = true
        publish(.dictation(true))
    }

    private func releaseDictationNow() {
        guard dictationHeld else { return }
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == chatGPTBundleID
        _ = AXUI.key(2, down: false, flags: [.maskControl, .maskShift],
                     pid: frontmost ? nil : dictationPID)
        dictationHeld = false
        dictationPID = nil
        publish(.dictation(false))
    }

    func changeModel(direction: Int) {
        work.async { [weak self] in self?.changeModelNow(direction: direction) }
    }

    private func changeModelNow(direction: Int) {
        guard !changingModel, let app = appElement() else { return }
        changingModel = true
        let picker: AXNode?
        if let cachedPicker,
           AXUI.string(cachedPicker.element, kAXTitleAttribute).lowercased().hasPrefix("gpt-") {
            picker = cachedPicker
        } else {
            picker = AXUI.findControl(app, role: kAXPopUpButtonRole as String,
                                      matchingTitle: { $0.lowercased().hasPrefix("gpt-") })
        }
        guard let picker else {
            changingModel = false
            publish(.error(tr("Model picker not found")))
            return
        }
        cachedPicker = picker
        let flags: CGEventFlags = [.maskControl, .maskShift]
        guard AXUI.key(46, down: true, flags: flags),
              AXUI.key(46, down: false, flags: flags) else {
            changingModel = false
            publish(.error(tr("Could not open recent models")))
            return
        }
        work.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            self?.selectRecentModel(in: app, picker: picker, direction: direction, attempt: 0)
        }
    }

    private func recentModels(near picker: AXUIElement) -> [RecentModel] {
        var child = picker
        for _ in 0..<5 {
            guard let value = AXUI.get(child, kAXParentAttribute) else { break }
            let parent = value as! AXUIElement
            for sibling in AXUI.get(parent, kAXChildrenAttribute) as? [AXUIElement] ?? []
                where !CFEqual(sibling, child) {
                var models: [RecentModel] = []
                var visited = 0
                func visit(_ element: AXUIElement, depth: Int) {
                    guard depth < 6, visited < 40 else { return }
                    visited += 1
                    if AXUI.string(element, kAXRoleAttribute) == kAXButtonRole as String {
                        let parts = AXUI.string(element, kAXTitleAttribute)
                            .split(separator: " ", maxSplits: 1)
                        if parts.count == 2, let number = Int(parts[0]), (1...3).contains(number),
                           parts[1].localizedCaseInsensitiveContains("gpt-") {
                            let words = parts[1].split(separator: " ")
                            let name = words.dropLast().joined(separator: " ")
                            models.append(RecentModel(number: number, name: name, element: element))
                        }
                    }
                    for nested in AXUI.get(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
                        visit(nested, depth: depth + 1)
                    }
                }
                visit(sibling, depth: 0)
                if !models.isEmpty { return models.sorted { $0.number < $1.number } }
            }
            child = parent
        }
        return []
    }

    private func selectRecentModel(in app: AXUIElement, picker: AXNode,
                                   direction: Int, attempt: Int) {
        guard appElement() != nil else { changingModel = false; return }
        let models = recentModels(near: picker.element)
        guard !models.isEmpty else {
            if attempt < 2 {
                work.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                    self?.selectRecentModel(in: app, picker: picker,
                                            direction: direction, attempt: attempt + 1)
                }
            } else {
                changingModel = false
                publish(.error(tr("Could not read recent models")))
            }
            return
        }
        let current = AXUI.string(picker.element, kAXTitleAttribute)
        let currentIndex = models.firstIndex { current.hasPrefix($0.name) }
        let targetIndex: Int
        if let currentIndex {
            targetIndex = (currentIndex + direction + models.count) % models.count
        } else {
            targetIndex = direction < 0 ? models.count - 1 : 0
        }
        let target = models[targetIndex]
        let keyCode: CGKeyCode = [18, 19, 20][target.number - 1]
        guard AXUI.key(keyCode, down: true), AXUI.key(keyCode, down: false) else {
            changingModel = false
            publish(.error(tr("Could not switch model")))
            return
        }
        work.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            self?.verifyRecentModel(in: app, picker: picker, target: target,
                                    direction: direction, attempt: 0, pressed: false)
        }
    }

    private func verifyRecentModel(in app: AXUIElement, picker: AXNode,
                                   target: RecentModel, direction: Int,
                                   attempt: Int, pressed: Bool) {
        guard appElement() != nil else { changingModel = false; return }
        let actual = AXUI.string(picker.element, kAXTitleAttribute)
        if actual.hasPrefix(target.name) {
            changingModel = false
            publish(.model(actual))
            return
        }
        if attempt < 2 {
            work.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                self?.verifyRecentModel(in: app, picker: picker, target: target,
                                        direction: direction, attempt: attempt + 1,
                                        pressed: pressed)
            }
        } else if !pressed, AXUI.press(target.element) {
            work.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                self?.verifyRecentModel(in: app, picker: picker, target: target,
                                        direction: direction, attempt: 0, pressed: true)
            }
        } else {
            changingModel = false
            publish(.error(tr("Could not confirm model change")))
        }
    }
}

private final class RemoteMonitor {
    private final class HIDEntry {
        let device: IOHIDDevice
        var opened = false
        var exclusive = false
        var attempted = false

        init(_ device: IOHIDDevice) { self.device = device }
    }

    private var tap: CFMachPort?
    private var tapKind = ""
    private var source: CFRunLoopSource?
    private var hidManager: IOHIDManager?
    private var hidEntries: [HIDEntry] = []
    private var targetFrontmost = false
    private var lastDeliveredKey: RemoteKey?
    private var lastDeliveryTime = 0.0
    private(set) var failed = false
    private(set) var lastFailure = ""
    var onKey: ((RemoteKey) -> Void)?

    private var hidExclusive: Bool { !hidEntries.isEmpty && hidEntries.allSatisfy(\.exclusive) }
    var headsetCount: Int { hidEntries.count }
    var isReady: Bool { (tap != nil && !failed) || hidExclusive }
    var canControlPlayback: Bool { hidExclusive }

    var captureStatus: String {
        if hidExclusive { return "HID Exclusive (\(hidEntries.count))" }
        if tap != nil && !failed {
            let device = hidEntries.isEmpty ? "Headset not found" : "HID Standby (\(hidEntries.count))"
            let detail = lastFailure.isEmpty ? "" : "; \(lastFailure)"
            return "\(tapKind) Event Tap; \(device)\(detail)"
        }
        if !hidEntries.isEmpty {
            return "HID Standby (\(hidEntries.count))"
        }
        return lastFailure.isEmpty ? "Unavailable" : lastFailure
    }

    private func deliver(_ key: RemoteKey) {
        let now = ProcessInfo.processInfo.systemUptime
        if lastDeliveredKey == key && now - lastDeliveryTime < 0.15 { return }
        lastDeliveredKey = key
        lastDeliveryTime = now
        onKey?(key)
    }

    func start() -> Bool {
        if tap != nil && hidManager != nil { return true }
        if tap != nil || hidManager != nil { reset() }
        lastFailure = ""
        let eventType = CGEventType(rawValue: 14)!
        let mask: CGEventMask = 1 << eventType.rawValue
        let callback: CGEventTapCallBack = { _, type, event, info in
            guard let info else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<RemoteMonitor>.fromOpaque(info).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                monitor.failed = true
                monitor.lastFailure = "Event tap disabled"
                return Unmanaged.passUnretained(event)
            }
            guard type.rawValue == 14, let native = NSEvent(cgEvent: event),
                  native.subtype.rawValue == 8 else {
                return Unmanaged.passUnretained(event)
            }
            guard monitor.targetFrontmost,
                  let key = RemoteKey(rawValue: (native.data1 & 0xFFFF0000) >> 16) else {
                return Unmanaged.passUnretained(event)
            }
            let isDown = ((native.data1 & 0xFFFF) >> 8) == 0xA
            let isRepeat = (native.data1 & 1) != 0
            if isDown && !isRepeat {
                DispatchQueue.main.async { monitor.deliver(key) }
            }
            return nil
        }
        let locations: [(CGEventTapLocation, String)] = [(.cghidEventTap, "HID"),
                                                         (.cgSessionEventTap, "Session")]
        for (location, kind) in locations {
            guard let tap = CGEvent.tapCreate(
                tap: location,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: mask,
                callback: callback,
                userInfo: Unmanaged.passUnretained(self).toOpaque()
            ) else { continue }
            self.tap = tap
            tapKind = kind
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            self.source = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            break
        }
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, 0)
        let match = [kIOHIDDeviceUsagePageKey as String: 12,
                     kIOHIDDeviceUsageKey as String: 1]
        IOHIDManagerSetDeviceMatching(manager, match as CFDictionary)
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, result, _, device in
            guard result == kIOReturnSuccess, let context else { return }
            let monitor = Unmanaged<RemoteMonitor>.fromOpaque(context).takeUnretainedValue()
            monitor.attach(device)
        }, Unmanaged.passUnretained(self).toOpaque())
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            guard let context else { return }
            let monitor = Unmanaged<RemoteMonitor>.fromOpaque(context).takeUnretainedValue()
            guard let index = monitor.hidEntries.firstIndex(where: { CFEqual($0.device, device) }) else { return }
            let entry = monitor.hidEntries.remove(at: index)
            if entry.opened { IOHIDDeviceClose(entry.device, 0) }
            if monitor.hidExclusive { monitor.lastFailure = "" }
        }, Unmanaged.passUnretained(self).toOpaque())
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        hidManager = manager
        for device in (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>) ?? [] {
            attach(device)
        }
        return tap != nil || !hidEntries.isEmpty
    }

    private func attach(_ device: IOHIDDevice) {
        guard !hidEntries.contains(where: { CFEqual($0.device, device) }) else { return }
        let product = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? ""
        let page = (IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsagePageKey as CFString) as? NSNumber)?.intValue
        let usage = (IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsageKey as CFString) as? NSNumber)?.intValue
        guard page == 12, usage == 1,
              product == "Headset" || product.localizedCaseInsensitiveContains("EarPods") else { return }
        IOHIDDeviceRegisterInputValueCallback(device, { context, result, _, value in
            guard result == kIOReturnSuccess, let context else { return }
            let monitor = Unmanaged<RemoteMonitor>.fromOpaque(context).takeUnretainedValue()
            let element = IOHIDValueGetElement(value)
            let page = IOHIDElementGetUsagePage(element)
            let usage = IOHIDElementGetUsage(element)
            let pressed = IOHIDValueGetIntegerValue(value)
            guard monitor.targetFrontmost, monitor.hidExclusive, pressed > 0,
                  page == UInt32(kHIDPage_Consumer) else { return }
            let key: RemoteKey?
            let code = usage == UInt32(kHIDUsage_Csmr_ConsumerControl) ? UInt32(pressed) : usage
            switch code {
            case UInt32(kHIDUsage_Csmr_VolumeIncrement): key = .volumeUp
            case UInt32(kHIDUsage_Csmr_VolumeDecrement): key = .volumeDown
            case UInt32(kHIDUsage_Csmr_PlayOrPause), UInt32(kHIDUsage_Csmr_Play),
                 UInt32(kHIDUsage_Csmr_Pause): key = .playPause
            default: key = nil
            }
            if let key { monitor.deliver(key) }
        }, Unmanaged.passUnretained(self).toOpaque())
        hidEntries.append(HIDEntry(device))
        if targetFrontmost { setActive(true) }
    }

    func setActive(_ active: Bool) {
        targetFrontmost = active
        if let tap, failed {
            CGEvent.tapEnable(tap: tap, enable: true)
            failed = !CGEvent.tapIsEnabled(tap: tap)
        }
        if active {
            for entry in hidEntries where !entry.attempted {
                entry.attempted = true
                let exclusive = IOHIDDeviceOpen(entry.device, 1)
                if exclusive == kIOReturnSuccess {
                    entry.opened = true
                    entry.exclusive = true
                } else {
                    let listen = IOHIDDeviceOpen(entry.device, 0)
                    entry.opened = listen == kIOReturnSuccess
                    lastFailure = exclusive == kIOReturnNotPermitted ? "HID permission required" : "HID seize \(exclusive)"
                }
            }
            if hidExclusive { lastFailure = "" }
        } else if !active {
            for entry in hidEntries {
                if entry.opened { IOHIDDeviceClose(entry.device, 0) }
                entry.opened = false
                entry.exclusive = false
                entry.attempted = false
            }
        }
    }

    func reset() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        for entry in hidEntries where entry.opened { IOHIDDeviceClose(entry.device, 0) }
        if let hidManager {
            IOHIDManagerUnscheduleFromRunLoop(hidManager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        }
        source = nil
        tap = nil
        tapKind = ""
        hidManager = nil
        hidEntries = []
        failed = false
    }
}

private final class AppDragView: NSImageView, NSDraggingSource {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        let item = NSDraggingItem(pasteboardWriter: Bundle.main.bundleURL as NSURL)
        item.setDraggingFrame(bounds, contents: image ?? NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath))
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }
}

private final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let monitor = RemoteMonitor()
    private let controller = ChatGPTController()
    private var statusItem: NSStatusItem!
    private var modelItem: NSMenuItem!
    private var dictationItem: NSMenuItem!
    private var errorItem: NSMenuItem!
    private var setupItem: NSMenuItem!
    private var setupWindow: NSWindow?
    private var accessibilityState: NSTextField?
    private var inputState: NSTextField?
    private var captureState: NSTextField?
    private var loginButton: NSButton?
    private var inputButton: NSButton?
    private var timer: Timer?
    private var captureAttempts = 0
    private var lastListenAccess = CGPreflightListenEventAccess()
    private var lastHIDAccess = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if let iconURL = Bundle.main.url(forResource: "Codepods", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = icon
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let url = Bundle.main.url(forResource: "remote", withExtension: "png"),
           let source = CIImage(contentsOf: url),
           let filter = CIFilter(name: "CIColorMatrix") {
            filter.setValue(source, forKey: kCIInputImageKey)
            filter.setValue(CIVector(x: 0, y: 0, z: 0, w: 0), forKey: "inputRVector")
            filter.setValue(CIVector(x: 0, y: 0, z: 0, w: 0), forKey: "inputGVector")
            filter.setValue(CIVector(x: 0, y: 0, z: 0, w: 0), forKey: "inputBVector")
            filter.setValue(CIVector(x: 1 / 3, y: 1 / 3, z: 1 / 3, w: 0), forKey: "inputAVector")
            filter.setValue(CIVector(x: 1, y: 1, z: 1, w: 0), forKey: "inputBiasVector")
            if let output = filter.outputImage,
               let bitmap = CIContext().createCGImage(output, from: source.extent) {
                let icon = NSImage(cgImage: bitmap, size: NSSize(width: 21, height: 20))
                icon.isTemplate = true
                statusItem.button?.image = icon
            }
        }
        let menu = NSMenu()
        modelItem = NSMenuItem(title: tr("Model: %@", "—"), action: nil, keyEquivalent: "")
        modelItem.isEnabled = false
        menu.addItem(modelItem)
        dictationItem = NSMenuItem(title: tr("Voice input: Off"), action: nil, keyEquivalent: "")
        dictationItem.isEnabled = false
        menu.addItem(dictationItem)
        errorItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        errorItem.isEnabled = false
        errorItem.isHidden = true
        menu.addItem(errorItem)
        menu.addItem(.separator())
        setupItem = NSMenuItem(title: tr("Settings & Permissions…"), action: #selector(showSetup), keyEquivalent: "")
        menu.addItem(setupItem)
        menu.addItem(NSMenuItem(title: tr("Quit Codepods"), action: #selector(quit), keyEquivalent: "q"))
        for item in menu.items { item.target = self }
        menu.delegate = self
        statusItem.menu = menu
        monitor.onKey = { [weak self] key in
            guard let self else { return }
            switch key {
            case .playPause:
                if self.monitor.canControlPlayback {
                    self.controller.toggleDictation()
                } else {
                    self.showError(tr("Input Monitoring permission required"))
                }
            case .volumeUp: self.controller.changeModel(direction: -1)
            case .volumeDown: self.controller.changeModel(direction: 1)
            }
        }
        controller.onUpdate = { [weak self] update in
            guard let self else { return }
            switch update {
            case .model(let name):
                self.modelItem.title = tr("Model: %@", name)
                self.errorItem.isHidden = true
            case .dictation(let active):
                self.dictationItem.title = tr(active ? "Voice input: On" : "Voice input: Off")
                self.statusItem.button?.title = active ? " ●" : ""
                self.errorItem.isHidden = true
            case .error(let message):
                self.showError(message)
            }
            self.updateTooltip()
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(frontmostAppChanged),
            name: NSWorkspace.didActivateApplicationNotification, object: nil
        )
        if SMAppService.mainApp.status != .enabled {
            try? SMAppService.mainApp.register()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
        refresh()
        controller.refreshModel()
        if !AXIsProcessTrusted() || !lastHIDAccess {
            showSetup()
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        controller.refreshModel()
    }

    private func showError(_ message: String) {
        errorItem.title = message
        errorItem.isHidden = false
    }

    private func updateTooltip() {
        statusItem.button?.toolTip = "Codepods\n\(modelItem.title)\n\(dictationItem.title)"
    }

    private func refresh() {
        let accessible = AXIsProcessTrusted()
        let listenAccess = CGPreflightListenEventAccess()
        let hidAccess = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
        if listenAccess != lastListenAccess || hidAccess != lastHIDAccess {
            lastListenAccess = listenAccess
            lastHIDAccess = hidAccess
            monitor.reset()
            captureAttempts = 0
        }
        if accessible && !monitor.isReady && captureAttempts < 5 {
            captureAttempts += 1
            _ = monitor.start()
        }
        monitor.setActive(NSWorkspace.shared.frontmostApplication?.bundleIdentifier == chatGPTBundleID)
        accessibilityState?.stringValue = tr(accessible ? "Granted" : "Not granted")
        accessibilityState?.textColor = accessible ? .systemGreen : .secondaryLabelColor
        inputState?.stringValue = tr(hidAccess ? "Granted" : "Not granted")
        inputState?.textColor = hidAccess ? .systemGreen : .secondaryLabelColor
        inputButton?.isEnabled = !hidAccess
        loginButton?.state = SMAppService.mainApp.status == .enabled ? .on : .off
        captureState?.stringValue = !accessible || !hidAccess ? tr("Grant the required permissions")
            : monitor.headsetCount > 0 ? tr("EarPods detected") : tr("Connect EarPods")
        setupItem.title = accessible && hidAccess ? tr("Settings & Permissions…")
            : tr("Settings & Permissions… (Action required)")
        updateTooltip()
    }

    @objc private func frontmostAppChanged(_ notification: Notification) {
        let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        monitor.setActive(app?.bundleIdentifier == chatGPTBundleID)
        if app?.bundleIdentifier == chatGPTBundleID { controller.refreshModel() }
        else { controller.releaseDictation() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.releaseDictation()
    }

    @objc private func showSetup() {
        if setupWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 390),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.title = tr("Codepods Settings")
            window.level = .floating
            window.hidesOnDeactivate = false
            window.center()
            guard let content = window.contentView else { return }

            let title = NSTextField(labelWithString: "Codepods")
            title.font = .boldSystemFont(ofSize: 22)
            title.frame = NSRect(x: 24, y: 345, width: 410, height: 30)
            content.addSubview(title)
            let subtitle = NSTextField(labelWithString: tr("Control ChatGPT with EarPods"))
            subtitle.textColor = .secondaryLabelColor
            subtitle.frame = NSRect(x: 24, y: 319, width: 410, height: 20)
            content.addSubview(subtitle)
            let instruction = NSTextField(wrappingLabelWithString:
                tr("Drag the icon below into the app list in System Settings, then turn on the switch."))
            instruction.frame = NSRect(x: 24, y: 270, width: 412, height: 42)
            content.addSubview(instruction)

            let dragBox = NSBox(frame: NSRect(x: 24, y: 170, width: 412, height: 88))
            dragBox.boxType = .custom
            dragBox.fillColor = .controlBackgroundColor
            dragBox.borderColor = .separatorColor
            dragBox.borderWidth = 1
            dragBox.cornerRadius = 10
            content.addSubview(dragBox)
            let dragIcon = AppDragView(frame: NSRect(x: 38, y: 183, width: 62, height: 62))
            dragIcon.image = Bundle.main.path(forResource: "Codepods", ofType: "icns")
                .flatMap(NSImage.init(contentsOfFile:))
                ?? NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
            dragIcon.imageScaling = .scaleProportionallyUpOrDown
            dragIcon.toolTip = tr("Drag Codepods.app into System Settings")
            dragIcon.setAccessibilityLabel(tr("Drag Codepods.app into System Settings"))
            content.addSubview(dragIcon)
            let dragTitle = NSTextField(labelWithString: tr("Drag Codepods.app"))
            dragTitle.font = .systemFont(ofSize: 14, weight: .semibold)
            dragTitle.frame = NSRect(x: 120, y: 218, width: 290, height: 22)
            content.addSubview(dragTitle)
            let dragHint = NSTextField(labelWithString: tr("Drop into the app list in System Settings"))
            dragHint.textColor = .secondaryLabelColor
            dragHint.frame = NSRect(x: 120, y: 193, width: 290, height: 20)
            content.addSubview(dragHint)

            let accessTitle = NSTextField(labelWithString: tr("Accessibility"))
            accessTitle.frame = NSRect(x: 24, y: 133, width: 155, height: 20)
            content.addSubview(accessTitle)
            let accessState = NSTextField(labelWithString: "")
            accessState.frame = NSRect(x: 180, y: 133, width: 120, height: 20)
            accessibilityState = accessState
            content.addSubview(accessState)
            let accessButton = NSButton(title: tr("Open Settings"), target: self,
                                        action: #selector(requestAccessibility))
            accessButton.frame = NSRect(x: 317, y: 125, width: 119, height: 32)
            content.addSubview(accessButton)

            let inputTitle = NSTextField(labelWithString: tr("Input Monitoring"))
            inputTitle.frame = NSRect(x: 24, y: 94, width: 155, height: 20)
            content.addSubview(inputTitle)
            let inputState = NSTextField(labelWithString: "")
            inputState.frame = NSRect(x: 180, y: 94, width: 120, height: 20)
            self.inputState = inputState
            content.addSubview(inputState)
            let inputButton = NSButton(title: tr("Open Settings"), target: self,
                                       action: #selector(requestInputMonitoring))
            inputButton.frame = NSRect(x: 317, y: 86, width: 119, height: 32)
            self.inputButton = inputButton
            content.addSubview(inputButton)

            let capture = NSTextField(labelWithString: "")
            capture.font = .systemFont(ofSize: 12)
            capture.textColor = .secondaryLabelColor
            capture.frame = NSRect(x: 24, y: 57, width: 412, height: 18)
            captureState = capture
            content.addSubview(capture)
            let login = NSButton(checkboxWithTitle: tr("Launch at Login"), target: self,
                                 action: #selector(toggleLogin))
            login.frame = NSRect(x: 24, y: 20, width: 220, height: 24)
            loginButton = login
            content.addSubview(login)
            setupWindow = window
        }
        refresh()
        setupWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        openPrivacySettings("Privacy_Accessibility")
        refresh()
    }

    @objc private func requestInputMonitoring() {
        _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        openPrivacySettings("Privacy_ListenEvent")
        refresh()
    }

    private func openPrivacySettings(_ section: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(section)"),
           NSWorkspace.shared.open(url) { return }
        _ = NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
    }

    @objc private func toggleLogin() {
        do {
            if loginButton?.state == .on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch { showError(tr("Could not change Launch at Login")) }
        refresh()
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

private let app = NSApplication.shared
private let delegate = AppDelegate()
app.delegate = delegate
app.run()
