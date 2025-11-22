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
    
    // 记录 Command+Q 的状态
    var isCommandQDown = false
    // 新增标志位：是否已经触发过退出（用于一次按住只触发一次）
    var hasTriggeredQuit = false
    var commandQStartTime: TimeInterval = 0
    var quitTimer: Timer?
    
    // 权限监控
    var lastPermissionState: Bool = false
    var permissionCheckTimer: Timer?
    
    // 设置窗口引用
    var settingsWindow: NSWindow?
    
    // 提示窗口
    var hudWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 请求通知权限（用于发送状态变更通知）
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        
        // 设置菜单栏图标
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "command.circle", accessibilityDescription: "HoldQ")
        }
        
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit HoldQ", action: #selector(quitApp), keyEquivalent: "q"))
        statusItem?.menu = menu
        
        // 申请辅助功能权限
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        let accessEnabled = AXIsProcessTrustedWithOptions(options as CFDictionary)
        
        lastPermissionState = accessEnabled
        
        if !accessEnabled {
            print("Accessibility access not granted. Please enable in System Settings.")
        } else {
            startEventTap()
        }
        
        // 启动定时检测权限变更
        permissionCheckTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.checkPermissionChange()
        }
    }
    
    func checkPermissionChange() {
        let current = AXIsProcessTrusted()
        if current != lastPermissionState {
            print("Permission changed from \(lastPermissionState) to \(current)")
            lastPermissionState = current
            
            if current {
                // 变成了有权限：尝试直接启动 Tap，或者重启 App
                print("Gained access, restarting event tap...")
                startEventTap()
                
                sendNotification(title: "Permission Granted", body: "HoldQ is now active.")
            } else {
                // 变成了没权限
                print("Lost access")
                // 停止 Tap
                if let tap = eventTap {
                    CGEvent.tapEnable(tap: tap, enable: false)
                }
                // 提示用户并退出
                sendNotification(title: "Permission Lost", body: "HoldQ requires Accessibility access. Quitting...")
                
                // 延迟退出，给用户一点时间看通知
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
                contentRect: NSRect(x: 0, y: 0, width: 450, height: 200),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.center()
            window.title = "HoldQ Settings"
            
            // 提升窗口层级，确保它浮在普通窗口之上
            window.level = .floating
            
            // 使用 NSHostingController 包装 View，更加规范
            let hostingController = NSHostingController(rootView: SettingsView())
            window.contentViewController = hostingController
            
            window.isReleasedWhenClosed = false
            settingsWindow = window
        }
        
        // 激活应用，确保能获得焦点
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
        // 12 是 Q 键
        let isQ = event.getIntegerValueField(.keyboardEventKeycode) == 12
        let flags = event.flags
        let isCommand = flags.contains(.maskCommand)
        
        // 处理 KeyDown
        if type == .keyDown {
            if isCommand && isQ {
                // 如果已经在等待释放状态，直接吞掉事件，不重复触发
                if hasTriggeredQuit {
                    return nil
                }
                
                if !isCommandQDown {
                    isCommandQDown = true
                    commandQStartTime = Date().timeIntervalSince1970
                    
                    // 显示提示
                    showHUD()
                    
                    // 获取设置中的持续时间 (default 0.5)
                    let duration = UserDefaults.standard.double(forKey: "holdDuration")
                    let actualDuration = duration > 0 ? duration : 0.5
                    
                    // 定时检查
                    quitTimer?.invalidate()
                    quitTimer = Timer.scheduledTimer(withTimeInterval: actualDuration, repeats: false) { [weak self] _ in
                        self?.triggerQuit()
                    }
                }
                return nil // 吞掉 Cmd+Q
            }
        }
        
        // 处理 KeyUp
        if type == .keyUp {
            if isQ {
                // 复位逻辑：只有当 Q 键真正抬起时，才允许下一次触发
                if isCommandQDown || hasTriggeredQuit {
                    isCommandQDown = false
                    hasTriggeredQuit = false
                    
                    quitTimer?.invalidate()
                    hideHUD()
                    return nil // 吞掉这个抬起事件，防止意外
                }
            }
        }
        
        // 处理 FlagsChanged (比如松开 Command 键)
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
        // 只有当 Command+Q 还在按下状态，且还没触发过时才执行
        guard isCommandQDown, !hasTriggeredQuit else { return }
        
        // 标记为已触发，防止连续退出
        hasTriggeredQuit = true
        
        // 震动反馈
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
        
        // 获取当前前台应用并退出它
        if let frontApp = NSWorkspace.shared.frontmostApplication {
            // 避免杀掉自己
            if frontApp.bundleIdentifier != Bundle.main.bundleIdentifier {
                // 使用 AppleScript 优雅退出，这样会触发保存提示
                let scriptSource = """
                tell application "\(frontApp.localizedName ?? frontApp.bundleIdentifier ?? "")" to quit
                """
                
                if let script = NSAppleScript(source: scriptSource) {
                    var error: NSDictionary?
                    script.executeAndReturnError(&error)
                    if let error = error {
                        print("AppleScript error: \(error)")
                        // 兜底：如果 AppleScript 失败（比如名字不对），再试一次普通 terminate
                        frontApp.terminate()
                    }
                } else {
                    frontApp.terminate()
                }
            }
        }
        
        // 触发后立刻隐藏 HUD，但保持 isCommandQDown 和 hasTriggeredQuit 为 true，直到物理松手
        hideHUD()
    }
    
    // MARK: - HUD UI
    
    func showHUD() {
        DispatchQueue.main.async {
            // 获取自定义文字
            let customText = UserDefaults.standard.string(forKey: "customQuitText") ?? "Keep Holding to Quit"
            
            if self.hudWindow == nil {
                let window = NSWindow(
                    contentRect: NSRect(x: 0, y: 0, width: 240, height: 60), // 略微加宽以适应较长文字
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
                
                // 给 label 设置一个 tag，方便后面更新文字
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
                // 更新文字（如果窗口已创建）
                if let visualEffect = self.hudWindow?.contentView as? NSVisualEffectView,
                   let label = visualEffect.viewWithTag(100) as? NSTextField {
                    label.stringValue = customText
                }
            }
            
            if let window = self.hudWindow, let screen = NSScreen.main {
                // 动态调整窗口宽度以适应文字
                let textWidth = (customText as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 16, weight: .bold)]).width
                let newWidth = max(200, textWidth + 40)
                var frame = window.frame
                frame.size.width = newWidth
                window.setFrame(frame, display: true)
                
                let screenRect = screen.visibleFrame
                let windowRect = window.frame
                let x = (screenRect.width - windowRect.width) / 2 + screenRect.minX
                let y = (screenRect.height - windowRect.height) * 0.3 + screenRect.minY // 屏幕中下部
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
            // 动画结束后隐藏
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
