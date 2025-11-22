//
//  SettingsView.swift
//  HoldQ
//
//  Created by Dian Jin on 22/11/2025.
//

import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @AppStorage("holdDuration") private var holdDuration: Double = 0.5
    @AppStorage("customQuitText") private var customQuitText: String = "Keep Holding to Quit"
    @AppStorage("hideMenuBarIcon") private var hideMenuBarIcon: Bool = false
    @State private var launchAtLogin: Bool = false
    
    var body: some View {
        VStack(spacing: 20) {
            GroupBox(label: Text("Behavior").bold()) {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text("Hold Duration:")
                            .frame(width: 100, alignment: .trailing)
                        
                        Slider(value: $holdDuration, in: 0.1...2.0, step: 0.1)
                        
                        Text(String(format: "%.1f s", holdDuration))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 40, alignment: .trailing)
                    }
                    
                    HStack {
                        Text("Alert Text:")
                            .frame(width: 100, alignment: .trailing)
                        
                        TextField("Text to display", text: $customQuitText)
                            .textFieldStyle(.roundedBorder)
                    }
                }
                .padding(10)
            }
            
            GroupBox(label: Text("System").bold()) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("") // Spacer for alignment
                            .frame(width: 100)
                        Toggle("Launch at Login", isOn: $launchAtLogin)
                            .toggleStyle(.checkbox)
                            .onChange(of: launchAtLogin) { newValue in
                                toggleLaunchAtLogin(enabled: newValue)
                            }
                    }
                    
                    HStack(alignment: .top) {
                        Text("") // Spacer for alignment
                            .frame(width: 100)
                        VStack(alignment: .leading, spacing: 4) {
                            Toggle("Hide Menu Bar Icon", isOn: $hideMenuBarIcon)
                                .toggleStyle(.checkbox)
                            
                            Text("If hidden, relaunch the app to open Settings.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(10)
            }
            
            Spacer()
            
            HStack {
                Button(role: .destructive) {
                    NSApp.terminate(nil)
                } label: {
                    Text("Quit HoldQ")
                        .foregroundStyle(.red)
                }
                .keyboardShortcut("q", modifiers: .command)
                
                Spacer()
                
                Button("Done") {
                    NSApp.keyWindow?.close()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 450)
        .fixedSize(horizontal: true, vertical: false) // Ensure width is respected
        .onAppear {
            checkLaunchAtLogin()
        }
    }
    
    private func checkLaunchAtLogin() {
        let service = SMAppService.mainApp
        launchAtLogin = (service.status == .enabled)
    }
    
    private func toggleLaunchAtLogin(enabled: Bool) {
        let service = SMAppService.mainApp
        do {
            if enabled {
                if service.status != .enabled {
                    try service.register()
                }
            } else {
                if service.status == .enabled {
                    try service.unregister()
                }
            }
        } catch {
            print("Failed to toggle launch at login: \(error)")
            checkLaunchAtLogin()
        }
    }
}

#Preview {
    SettingsView()
}
