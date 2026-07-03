import SwiftUI

// ── ServerSettingsView ────────────────────────────────
// Ecrã de configuração do servidor:
//  • permite definir manualmente o IP usado por SensorApiClient
//    (persistido em ServerConfig / UserDefaults);
//  • testa a ligação ao endpoint GET /db/health e mostra o estado.
struct ServerSettingsView: View {

    @Environment(\.dismiss) private var dismiss

    @State private var ipText: String = ServerConfig.ip
    @State private var status: ConnStatus = .unknown
    @State private var checking = false

    enum ConnStatus {
        case unknown, ok, fail

        var color: Color {
            switch self {
            case .unknown: return .vvMuted
            case .ok:      return .vvGreen
            case .fail:    return Color(red: 0.690, green: 0, blue: 0.125)
            }
        }

        var label: String {
            switch self {
            case .unknown: return "Não testado"
            case .ok:      return "Ligação OK"
            case .fail:    return "Sem ligação"
            }
        }
    }

    private var trimmedIP: String {
        ipText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                // ── IP do servidor ──────────────────────
                Section {
                    TextField("IP do servidor", text: $ipText)
                        .keyboardType(.numbersAndPunctuation)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                        .onChange(of: ipText) { _ in status = .unknown }

                    HStack {
                        Text("Porta")
                        Spacer()
                        Text("\(ServerConfig.port)")
                            .foregroundColor(.vvMuted)
                    }
                } header: {
                    Text("Servidor")
                } footer: {
                    Text("Endereço usado por SensorApiClient: \(ServerConfig.baseURL(for: trimmedIP))")
                        .font(.footnote)
                }

                // ── Estado da ligação ───────────────────
                Section {
                    HStack(spacing: 10) {
                        Circle()
                            .fill(status.color)
                            .frame(width: 10, height: 10)
                        Text(status.label)
                            .foregroundColor(.vvText)
                        Spacer()
                        if checking {
                            ProgressView()
                        }
                    }

                    Button(action: testConnection) {
                        Text("Testar ligação")
                    }
                    .disabled(checking || trimmedIP.isEmpty)
                } header: {
                    Text("Ligação (GET /db/health)")
                }
            }
            .navigationTitle("Configuração")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Guardar") { save() }
                        .disabled(trimmedIP.isEmpty)
                }
            }
        }
    }

    // ── Ações ──────────────────────────────────────────
    private func testConnection() {
        let ip = trimmedIP
        checking = true
        status = .unknown
        Task {
            let ok = await SensorApiClient.shared.checkDbHealth(ipOverride: ip)
            await MainActor.run {
                status = ok ? .ok : .fail
                checking = false
            }
        }
    }

    private func save() {
        ServerConfig.ip = trimmedIP
        dismiss()
    }
}

// ── Preview ───────────────────────────────────────────
#Preview {
    ServerSettingsView()
}
