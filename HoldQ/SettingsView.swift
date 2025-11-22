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
    @State private var launchAtLogin: Bool = false
    
    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    // Hold Duration Slider
                    HStack {
                        Text("Hold Duration:")
                            .frame(width: 100, alignment: .trailing)
                        
                        Slider(value: $holdDuration, in: 0.1...2.0, step: 0.1)
                            .frame(width: 200)
                        
                        Text(String(format: "%.1f s", holdDuration))
                            .monospacedDigit()
                            .foregroundColor(.secondary)
                            .frame(width: 40, alignment: .leading)
                    }
                    
                    // Alert Text Input
                    HStack {
                        Text("Alert Text:")
                            .frame(width: 100, alignment: .trailing)
                        
                        TextField("", text: $customQuitText)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 240) // Match slider width + text width approx
                    }
                }
                .padding(.vertical, 8)
            }
            
            Divider()
                .padding(.vertical, 8)
            
            Section {
                HStack {
                    Text("System:")
                        .frame(width: 100, alignment: .trailing)
                        .hidden() // Placeholder for alignment
                    
                    Toggle("Launch at Login", isOn: $launchAtLogin)
                        .toggleStyle(.checkbox)
                        .onChange(of: launchAtLogin) { newValue in
                            toggleLaunchAtLogin(enabled: newValue)
                        }
                    
                    Spacer()
                }
            }
            
            Spacer()
            
            HStack {
                Spacer()
                Button("Done") {
                    NSApp.keyWindow?.close()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 10)
        }
        .padding(20)
        .frame(width: 450, height: 200)
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
