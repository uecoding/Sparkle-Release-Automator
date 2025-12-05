//
//  Sparkle_Release_AutomatorApp.swift
//  Sparkle Release Automator
//
//  Created by Umut on 04/12/2025.
//

import SwiftUI
import Sparkle
import Combine

// This wrapper class holds the Sparkle Controller lifecycle
final class UpdaterController: ObservableObject {
    private let controller: SPUStandardUpdaterController
    
    init() {
        // SPUStandardUpdaterController handles the UI and logic automatically
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    }
    
    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}

@main
struct Sparkle_Release_AutomatorApp: App {
    // Initialize the updater when the app starts
    @StateObject var updater = UpdaterController()
    
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .commands {
            // Add the "Check for Updates..." item to the application menu
            CommandGroup(after: .appInfo) {
                Button("Check for Updates...") {
                    updater.checkForUpdates()
                }
            }
        }
    }
}
