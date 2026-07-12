import Cocoa
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    let popover = NSPopover()
    let telemetryManager = TelemetryManager()
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Configure popover content view
        let contentView = DashboardView(manager: telemetryManager)
        
        popover.contentSize = NSSize(width: 380, height: 500)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: contentView)
        
        // Setup menu bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem?.button {
            // Use the standard terminal icon from SF Symbols
            if let image = NSImage(systemSymbolName: "terminal", accessibilityDescription: "Claude Telemetry") {
                image.isTemplate = true // Ensures light/dark mode compliance in menubar
                button.image = image
            } else {
                // Fallback to monospace prompt characters if SF Symbols fail
                button.title = ">_"
                button.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .bold)
            }
            
            button.action = #selector(togglePopover(_:))
            button.target = self
        }
        
        // Add listener to refresh telemetry whenever user opens the popover
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(popoverWillShow),
            name: NSPopover.willShowNotification,
            object: popover
        )
    }
    
    @objc func popoverWillShow() {
        telemetryManager.refresh()
    }
    
    @objc func togglePopover(_ sender: AnyObject?) {
        guard let button = statusItem?.button else { return }
        
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            // Make the popover window key to ensure it is focused
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}
