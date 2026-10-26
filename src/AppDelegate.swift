import Cocoa
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    let popover = NSPopover()
    let telemetryManager = TelemetryManager()
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Configure popover content view
        let contentView = DashboardView(manager: telemetryManager)
        let hostingController = NSHostingController(rootView: contentView)

        // El popover toma el alto natural de la vista (sin hueco abajo) y lo
        // sigue al abrir o cerrar MODELOS y CONFIG, manteniendo la flecha
        // pegada al icono. En macOS 12 no existe esta opción: alto fijo.
        if #available(macOS 13.0, *) {
            hostingController.sizingOptions = [.preferredContentSize]
        } else {
            popover.contentSize = NSSize(width: 380, height: 600)
        }

        // Sin apariencia fija: el panel es opaco y sigue el modo claro u oscuro
        // del sistema (ver Theme).
        popover.behavior = .transient
        popover.contentViewController = hostingController
        
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
