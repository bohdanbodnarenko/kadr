//
//  AppDelegate.swift
//  Kadr
//
//  Created by Bohdan Bodnarenko on 27.08.2026.
//

import AppKit

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// NSApplication.delegate is *unretained* — keep a strong reference
    private static let shared = AppDelegate()

    @MainActor
    static func main() {
        let app = NSApplication.shared
        app.delegate = shared
        app.run()
    }

    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem?.button?.image = NSImage(
            systemSymbolName: "camera.viewfinder",
            accessibilityDescription: "Kadr"
        )
    }
}
