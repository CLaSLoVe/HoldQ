//
//  HoldQApp.swift
//  HoldQ
//
//  Created by Dian Jin on 22/11/2025.
//

import SwiftUI
import AppKit
import Combine
import UserNotifications

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    var eventTap: CFMachPort?
    var runLoopSource: CFRunLoopSource?
    
    var isCommandQDown = false
    // Prevent multiple triggers for a single press.
    var hasTriggeredQuit = false
    var commandQStartTime: TimeInterval = 0
    var quitTimer: Timer?
    
    // Permission monitoring.
    var lastPermissionState: Bool = false
    var permissionCheckTimer: Timer?
    
    var settingsWindow: NSWindow?
    var hudWindow: NSWindow?
    
    // Observation token
    var defaultsObserver: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Request notification permissions for status updates.
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        
        // Configure menu bar icon visibility based on settings.
        updateMenuBarIcon()
        
        // DEBUG SAFETY: If running in Xcode and icon is hidden, force open settings
        // so you aren't locked out (since Xcode kills the previous instance, preventing "reopen").
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "hideMenuBarIcon") {
            openSettings()
        }
        #endif
        
        // Observe UserDefaults for changes to "hideMenuBarIcon".
        // Using NotificationCenter for simplicity as KVO with UserDefaults in Swift can be verbose.
        defaultsObserver = NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .sink { [weak self] _ in
                self?.updateMenuBarIcon()
            }
        
        // Request accessibility permissions.
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        let accessEnabled = AXIsProcessTrustedWithOptions(options as CFDictionary)
        
        lastPermissionState = accessEnabled
        
        if !accessEnabled {
            print("Accessibility access not granted. Please enable in System Settings.")
        } else {
            startEventTap()
        }
        
        // Monitor permission changes.
        permissionCheckTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.checkPermissionChange()
        }
    }
    
    // Handle reopening (e.g. clicking the app icon in Finder/Launchpad).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return true
    }
    
    func updateMenuBarIcon() {
        let hideIcon = UserDefaults.standard.bool(forKey: "hideMenuBarIcon")
        
        if hideIcon {
            // Remove if exists
            if let item = statusItem {
                NSStatusBar.system.removeStatusItem(item)
                statusItem = nil
            }
        } else {
            // Create if missing
            if statusItem == nil {
                setupStatusItem()
            }
        }
    }
    
    func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "command.circle", accessibilityDescription: "HoldQ")
        }
        
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit HoldQ", action: #selector(quitApp), keyEquivalent: "q"))
        statusItem?.menu = menu
    }
    
    func checkPermissionChange() {
        let current = AXIsProcessTrusted()
        if current != lastPermissionState {
            print("Permission changed from \(lastPermissionState) to \(current)")
            lastPermissionState = current
            
            if current {
                // Access granted: restart event tap.
                print("Gained access, restarting event tap...")
                startEventTap()
                
                sendNotification(title: "Permission Granted", body: "HoldQ is now active.")
            } else {
                // Access lost.
                print("Lost access")
                // Stop event tap.
                if let tap = eventTap {
                    CGEvent.tapEnable(tap: tap, enable: false)
                }
                // Notify user and quit.
                sendNotification(title: "Permission Lost", body: "HoldQ requires Accessibility access. Quitting...")
                
                // Delay exit to let the user read the notification.
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                    NSApp.terminate(nil)
                }
            }
        }
    }
    
    func sendNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
    
    @objc func quitApp() {
        NSApp.terminate(nil)
    }
    
    @objc func openSettings() {
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 450, height: 380), // Increased height for GroupBox layout
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.center()
            window.title = "HoldQ Settings"
            
            // Float above other windows.
            window.level = .floating
            
            // Wrap the SwiftUI view.
            let hostingController = NSHostingController(rootView: SettingsView())
            
            window.contentViewController = hostingController
            
            window.isReleasedWhenClosed = false
            settingsWindow = window
        }
        
        // Activate app to ensure focus.
        NSApp.activate(ignoringOtherApps: true)
        
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
    
    func startEventTap() {
        let eventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        
        // Create the event tap
        let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
                if let refcon = refcon {
                    let delegate = Unmanaged<AppDelegate>.fromOpaque(refcon).takeUnretainedValue()
                    return delegate.handle(type: type, event: event)
                }
                return Unmanaged.passRetained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )
        
        if let tap = eventTap {
            self.eventTap = tap
            runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
        } else {
            print("Failed to create event tap")
        }
    }
    
    func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Handle system disabling the event tap (auto-recovery)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            print("Event tap disabled by system (type: \(type.rawValue)). Re-enabling...")
            if let tap = self.eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }
        
        // 12 corresponds to the 'Q' key.
        let isQ = event.getIntegerValueField(.keyboardEventKeycode) == 12
        let flags = event.flags
        
        // Strict modifier check: Only Command should be pressed.
        // We want to allow Cmd+Q, but NOT Ctrl+Cmd+Q (Lock Screen) or Shift+Cmd+Q (Logout).
        let isCommand = flags.contains(.maskCommand)
        let isControl = flags.contains(.maskControl)
        let isOption = flags.contains(.maskAlternate)
        let isShift = flags.contains(.maskShift)
        
        // Only intercept if Command is down, and NO other modifiers are down.
        let isPureCommandQ = isCommand && !isControl && !isOption && !isShift
        
        if type == .keyDown {
            if isPureCommandQ && isQ {
                // Swallow event if waiting for release.
                if hasTriggeredQuit {
                    return nil
                }
                
                if !isCommandQDown {
                    isCommandQDown = true
                    commandQStartTime = Date().timeIntervalSince1970
                    
                    // Show HUD.
                    showHUD()
                    
                    // Get hold duration (default: 0.5s).
                    let duration = UserDefaults.standard.double(forKey: "holdDuration")
                    let actualDuration = duration > 0 ? duration : 0.5
                    
                    // Start the timer.
                    quitTimer?.invalidate()
                    quitTimer = Timer.scheduledTimer(withTimeInterval: actualDuration, repeats: false) { [weak self] _ in
                        self?.triggerQuit()
                    }
                }
                return nil // Consume Cmd+Q.
            }
        }
        
        if type == .keyUp {
            if isQ {
                // Reset only when Q is released.
                if isCommandQDown || hasTriggeredQuit {
                    isCommandQDown = false
                    hasTriggeredQuit = false
                    
                    quitTimer?.invalidate()
                    hideHUD()
                    return nil // Consume key up to prevent accidental input.
                }
            }
        }
        
        if type == .flagsChanged {
            if !flags.contains(.maskCommand) {
                if isCommandQDown || hasTriggeredQuit {
                    isCommandQDown = false
                    hasTriggeredQuit = false
                    
                    quitTimer?.invalidate()
                    hideHUD()
                }
            }
        }
        
        return Unmanaged.passRetained(event)
    }
    
    func triggerQuit() {
        // Trigger only if held and not yet triggered.
        guard isCommandQDown, !hasTriggeredQuit else { return }
        
        // Prevent repeated triggers.
        hasTriggeredQuit = true
        
        // Haptic feedback.
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
        
        // Terminate the frontmost app.
        if let frontApp = NSWorkspace.shared.frontmostApplication {
            // Don't kill self.
            if frontApp.bundleIdentifier != Bundle.main.bundleIdentifier {
                // Use AppleScript for a graceful exit (triggers save prompt).
                // Prefer Bundle Identifier as it is unique and reliable.
                var scriptSource = ""
                if let bundleId = frontApp.bundleIdentifier {
                    scriptSource = "tell application id \"\(bundleId)\" to quit"
                } else {
                    let appName = frontApp.localizedName ?? ""
                    scriptSource = "tell application \"\(appName)\" to quit"
                }
                
                var scriptSuccess = false
                if !scriptSource.isEmpty, let script = NSAppleScript(source: scriptSource) {
                    var error: NSDictionary?
                    script.executeAndReturnError(&error)
                    if error == nil {
                        scriptSuccess = true
                    } else {
                        print("AppleScript error: \(String(describing: error))")
                    }
                }
                
                // Fallback to standard termination if AppleScript fails.
                if !scriptSuccess {
                    print("Falling back to standard terminate for \(frontApp.localizedName ?? "unknown app")")
                    frontApp.terminate()
                }
            }
        }
        
        // Hide HUD, but keep state flags until key release.
        hideHUD()
    }
    
    // MARK: - HUD UI
    
    func showHUD() {
        DispatchQueue.main.async {
            // Fetch custom text.
            let customText = UserDefaults.standard.string(forKey: "customQuitText") ?? "Keep Holding to Quit"
            
            if self.hudWindow == nil {
                let window = NSWindow(
                    contentRect: NSRect(x: 0, y: 0, width: 240, height: 60), // Slightly wider for long text.
                    styleMask: [.borderless],
                    backing: .buffered,
                    defer: false
                )
                window.level = .floating
                window.backgroundColor = .clear
                window.isOpaque = false
                window.ignoresMouseEvents = true
                
                let visualEffect = NSVisualEffectView()
                visualEffect.material = .hudWindow
                visualEffect.state = .active
                visualEffect.wantsLayer = true
                visualEffect.layer?.cornerRadius = 12
                
                let label = NSTextField(labelWithString: customText)
                label.font = .systemFont(ofSize: 16, weight: .bold)
                label.textColor = .labelColor
                label.alignment = .center
                label.translatesAutoresizingMaskIntoConstraints = false
                
                // Tag for future updates.
                label.tag = 100
                
                visualEffect.addSubview(label)
                NSLayoutConstraint.activate([
                    label.centerXAnchor.constraint(equalTo: visualEffect.centerXAnchor),
                    label.centerYAnchor.constraint(equalTo: visualEffect.centerYAnchor),
                    label.leadingAnchor.constraint(greaterThanOrEqualTo: visualEffect.leadingAnchor, constant: 10),
                    label.trailingAnchor.constraint(lessThanOrEqualTo: visualEffect.trailingAnchor, constant: -10)
                ])
                
                window.contentView = visualEffect
                self.hudWindow = window
            } else {
                // Update text if window exists.
                if let visualEffect = self.hudWindow?.contentView as? NSVisualEffectView,
                   let label = visualEffect.viewWithTag(100) as? NSTextField {
                    label.stringValue = customText
                }
            }
            
            if let window = self.hudWindow, let screen = NSScreen.main {
                // Adjust width to fit text.
                let textWidth = (customText as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 16, weight: .bold)]).width
                let newWidth = max(200, textWidth + 40)
                var frame = window.frame
                frame.size.width = newWidth
                window.setFrame(frame, display: true)
                
                let screenRect = screen.visibleFrame
                let windowRect = window.frame
                let x = (screenRect.width - windowRect.width) / 2 + screenRect.minX
                let y = (screenRect.height - windowRect.height) * 0.3 + screenRect.minY // Position in the lower-middle screen.
                window.setFrameOrigin(NSPoint(x: x, y: y))
                
                window.alphaValue = 0
                window.makeKeyAndOrderFront(nil)
                window.animator().alphaValue = 1.0
            }
        }
    }
    
    func hideHUD() {
        DispatchQueue.main.async {
            self.hudWindow?.animator().alphaValue = 0
            // Hide after animation.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                if self.hudWindow?.alphaValue == 0 {
                    self.hudWindow?.orderOut(nil)
                }
            }
        }
    }
}

@main
struct HoldQApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
