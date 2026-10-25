import Cocoa
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    let popover = NSPopover()
    let telemetryManager = TelemetryManager()
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Configure popover content view
        var contentView = DashboardView(manager: telemetryManager)
        // El popover toma el alto que mide la vista, así no queda hueco abajo
        // y crece al abrir MODELOS o CONFIG.
        contentView.onHeightChange = { [weak self] height in
            guard height > 0 else { return }
            // Fuera del pase de layout en curso de SwiftUI.
            DispatchQueue.main.async {
                guard let self = self else { return }
                let size = NSSize(width: 380, height: ceil(height))
                if self.popover.contentSize != size {
                    self.popover.contentSize = size
                }
            }
        }

        popover.contentSize = NSSize(width: 380, height: 560)
        popover.behavior = .transient
        // Apariencia oscura fija para que el cristal del panel (y la flecha del
        // popover) se vea igual con el modo claro del sistema.
        popover.appearance = NSAppearance(named: .darkAqua)
        popover.contentViewController = NSHostingController(rootView: contentView)
        
        // Setup menu bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem?.button {
            // Use the standard terminal icon from SF Symbols
            if let image = NSImage(systemSymbolName: "terminal", accessibilityDescription: "AI Telemetry") {
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
            // Sin esto macOS enfoca el primer botón y le pinta el anillo azul.
            // Va en diferido porque SwiftUI asigna ese foco al terminar de mostrarse.
            DispatchQueue.main.async { [weak self] in
                self?.popover.contentViewController?.view.window?.makeFirstResponder(nil)
            }
        }
    }
}
