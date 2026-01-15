//
//  AppleIconCreatorApp.swift
//  AppleIconCreator
//
//  Created by Apple Ecosystem Icon Creator
//

import SwiftUI

@main
struct AppleIconCreatorApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.automatic)
        .defaultSize(width: 900, height: 700)
        .commands {
            CommandGroup(replacing: .newItem) {
                // Remove default New command
            }
        }
    }
}
