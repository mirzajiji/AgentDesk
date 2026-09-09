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
    @StateObject private var codex = CodexSettingsModel()
    #endif
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        #if os(macOS)
        Settings {
            CodexSettingsView(model: codex)
        }
        #endif
    }
}
