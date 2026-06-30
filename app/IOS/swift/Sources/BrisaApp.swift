import SwiftUI

// ── Entry point da app iOS ────────────────────────────
// Substitui os antigos main.swift / swift.swift (que eram targets de linha de comando).
// Em iOS, o ponto de entrada é um struct que adopta `App`.
@main
struct BrisaApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
