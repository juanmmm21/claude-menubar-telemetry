import Foundation
import ServiceManagement

// Envoltorio fino sobre SMAppService (macOS 13+) para registrar esta app como
// elemento de inicio de sesión. Usa SMAppService.mainApp: pensado exactamente
// para apps que se registran a sí mismas, sin necesitar un helper bundle ni
// LaunchAgent propios. En macOS < 13 la API no existe, así que la funcionalidad
// se desactiva por completo (isSupported = false) en vez de intentar un
// mecanismo legado.
enum LaunchAtLoginService {
    static var isSupported: Bool {
        if #available(macOS 13.0, *) { return true }
        return false
    }

    static var isEnabled: Bool {
        guard #available(macOS 13.0, *) else { return false }
        return SMAppService.mainApp.status == .enabled
    }

    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        guard #available(macOS 13.0, *) else { return false }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return true
        } catch {
            NSLog("LaunchAtLoginService: no se pudo \(enabled ? "registrar" : "desregistrar") la app: \(error.localizedDescription)")
            return false
        }
    }
}
