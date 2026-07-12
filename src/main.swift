import Cocoa

// Setup shared NSApplication event loop and assign the custom delegate
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate

// Bootstrap and run the Cocoa Application loop
app.run()
