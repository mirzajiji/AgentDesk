//
//  AgentDeskApp.swift
//  AgentDesk
//
//  Created by Mirza on 09/09/2026.
//

import SwiftUI

@main
struct AgentDeskApp: App {
    #if os(macOS)
    @StateObject private var runs = NativeRunRegistry.shared
    @StateObject private var codex = CodexSettingsModel()
    #endif
    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
        }
        #if os(macOS)
        .defaultLaunchBehavior(.presented)
        .commands { NativePaletteCommands() }
        #endif
        #if os(macOS)
        MenuBarExtra {
            NativeRunMenu(registry: runs)
        } label: {
            Image(systemName: "play.rectangle")
                .accessibilityLabel("AgentDesk run status")
        }
        Settings {
            CodexSettingsView(model: codex)
        }
        #endif
    }
}
