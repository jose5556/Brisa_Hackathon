import SwiftUI
import Combine

// ── Cores ViaVerde ────────────────────────────────────
// Equivalente às val VV* do Kotlin
extension Color {
    static let vvGreen      = Color(red: 0.176, green: 0.690, blue: 0.133)  // #2DB022
    static let vvGreenDark  = Color(red: 0.122, green: 0.502, blue: 0.094)  // #1F8018
    static let vvGreenLight = Color(red: 0.910, green: 0.961, blue: 0.906)  // #E8F5E7
    static let vvBackground = Color(red: 0.969, green: 0.973, blue: 0.969)  // #F7F8F7
    static let vvCard       = Color.white
    static let vvBorder     = Color(red: 0.878, green: 0.929, blue: 0.878)  // #E0EDE0
    static let vvText       = Color(red: 0.102, green: 0.102, blue: 0.102)  // #1A1A1A
    static let vvMuted      = Color(red: 0.533, green: 0.533, blue: 0.533)  // #888888
}

// ── ContentView (equivalente a ViaVerdeScreen) ────────
struct ContentView: View {

    @StateObject private var viewModel = SensorViewModel()

    // Animação da barra de progresso (equivalente ao progressAnim do Kotlin)
    @State private var progressValue: Double = 0
    // Controla navegação para a tela de logs DEV
    @State private var showLogs = false
    private let progressTimer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    var isLoading: Bool { viewModel.uploadResult == .loading }

    var body: some View {
        NavigationStack {
        VStack(spacing: 0) {

            // ── Header verde ──────────────────────────
            headerView

            // ── Corpo ─────────────────────────────────
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {

                    // Card de estado
                    StatusCard(result: viewModel.uploadResult,
                               progress: isLoading ? progressValue : 0)

                    // Grid de sensores
                    Text("SENSORES ACTIVOS")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.vvMuted)
                        .kerning(1.5)

                    HStack(spacing: 10) {
                        SensorChip(name: "GPS",   label: "Localização")
                        SensorChip(name: "Bar.",  label: "Pressão")
                        SensorChip(name: "Acel.", label: "Movimento")
                        SensorChip(name: "Mag.",  label: "Campo")
                    }

                    // Resultado
                    if case .success(let classification, let confidence) = viewModel.uploadResult {
                        ResultCard(classification: classification, confidence: confidence)
                    }

                    // Erro
                    if case .error(let message) = viewModel.uploadResult {
                        ErrorCard(message: message)
                    }

                    Spacer(minLength: 20)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 20)
            }

            // ── Botão ───────────────────────
            VStack(spacing: 0) {
                Divider()
                VStack(spacing: 8) {

                    // ── Janela dinâmica: Iniciar / Analisar ───
                    HStack(spacing: 8) {
                        // Iniciar (ou parar contagem)
                        Button(action: {
                            if viewModel.isManualCapture { viewModel.cancelManualCapture() }
                            else { viewModel.startManualCapture() }
                        }) {
                            Text(viewModel.isManualCapture
                                 ? "■  \(viewModel.manualElapsedS)s"
                                 : "●  INICIAR")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundColor(viewModel.isManualCapture ? .white : .vvGreenDark)
                                .frame(maxWidth: .infinity)
                                .frame(height: 40)
                                .background(viewModel.isManualCapture ? Color.vvGreenDark : Color.vvGreenLight)
                                .cornerRadius(10)
                        }
                        .disabled(isLoading)

                        // Analisar ambiente (janela dinâmica)
                        Button(action: { viewModel.analyzeManualWindow() }) {
                            Text("ANALISAR AMBIENTE")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .frame(height: 40)
                                .background(viewModel.isManualCapture ? Color.vvGreen : Color.vvGreen.opacity(0.4))
                                .cornerRadius(10)
                        }
                        .disabled(!viewModel.isManualCapture || isLoading)
                    }

                    Button(action: {
                        viewModel.testDbConnection()   // teste rápido: imprime GET /db/health no console
                        if isLoading { viewModel.resetResult() }
                        else         { viewModel.sendCurrentWindow() }
                    }) {
                        HStack(spacing: 10) {
                            if isLoading {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                    .scaleEffect(0.85)
                                Text("Analisando… (score)")
                                    .font(.system(size: 15, weight: .bold))
                                    .foregroundColor(.white)
                                    .kerning(0.5)
                            } else {
                                Text("▶  ANALISAR (SCORE)")
                                    .font(.system(size: 15, weight: .bold))
                                    .foregroundColor(.white)
                                    .kerning(1)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 56)
                        .background(isLoading ? Color.vvGreen.opacity(0.6) : Color.vvGreen)
                        .cornerRadius(14)
                    }

                    if viewModel.uploadResult != .idle {
                        Button("Limpar resultado") {
                            viewModel.resetResult()
                        }
                        .font(.system(size: 13))
                        .foregroundColor(.vvMuted)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .background(Color.vvBackground)
            }
        }
        .background(Color.vvBackground.ignoresSafeArea())
        .onAppear  { viewModel.startCollecting() }
        .onDisappear { viewModel.stopCollecting() }
        .onReceive(progressTimer) { _ in
            guard isLoading else { progressValue = 0; return }
            progressValue = min(progressValue + (0.1 / 30.0), 1.0)
            if progressValue >= 1.0 { progressValue = 0 }
        }
        .navigationDestination(isPresented: $showLogs) {
            SensorLogsView(viewModel: viewModel)
        }
        } // NavigationStack
    }

    // ── Header ────────────────────────────────────────
    var headerView: some View {
        ZStack {
            LinearGradient(
                colors: [.vvGreenDark, .vvGreen],
                startPoint: .top, endPoint: .bottom
            )

            VStack(spacing: 10) {
                // Logo placeholder — substitui por Image("logo_viaverde")
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.white.opacity(0.15))
                    .frame(width: 56, height: 56)
                    .overlay(
                        Text("VV")
                            .font(.system(size: 20, weight: .black))
                            .foregroundColor(.white)
                    )

                Text("VIA VERDE")
                    .font(.system(size: 26, weight: .black))
                    .foregroundColor(.white)
                    .kerning(3)

                Text("CONTEXT DETECTION")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white.opacity(0.7))
                    .kerning(2)
            }
            .padding(.vertical, 28)

            // Botão DEV no canto superior direito — abre a tela de logs
            VStack {
                HStack {
                    Spacer()
                    Button("DEV") { showLogs = true }
                        .font(.system(size: 10, weight: .bold))
                        .kerning(1)
                        .foregroundColor(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color.white.opacity(0.15))
                        .cornerRadius(8)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.3), lineWidth: 1))
                        .padding(.trailing, 16)
                }
                Spacer()
            }
            .padding(.top, 56)
        }
        .ignoresSafeArea(edges: .top)
    }
}

// ── StatusCard ────────────────────────────────────────
struct StatusCard: View {

    let result: UploadResult
    let progress: Double

    private var content: (label: String, text: String, tagColor: Color, tagText: String) {
        switch result {
        case .idle:
            return ("ESTADO", "Pronto para recolher dados", .vvGreen, "Idle")
        case .loading:
            return ("A RECOLHER", "A capturar sensores…", Color(red: 0.902, green: 0.318, blue: 0), "Em curso")
        case .success:
            return ("CONCLUÍDO", "Dados enviados com sucesso", .vvGreen, "OK")
        case .error:
            return ("ERRO", "Falha no envio", Color(red: 0.690, green: 0, blue: 0.125), "Erro")
        }
    }

    var body: some View {
        let c = content
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(c.label)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.vvGreen)
                    .kerning(1.5)
                Spacer()
                Text(c.tagText)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(c.tagColor)
                    .kerning(0.5)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .background(c.tagColor.opacity(0.12))
                    .cornerRadius(20)
            }

            Text(c.text)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.vvText)

            if result == .loading {
                ProgressView(value: progress)
                    .progressViewStyle(LinearProgressViewStyle(tint: .vvGreen))
                    .padding(.top, 4)
            }
        }
        .padding(16)
        .background(Color.vvCard)
        .cornerRadius(14)
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.vvBorder, lineWidth: 1)
        )
    }
}

// ── SensorChip ────────────────────────────────────────
struct SensorChip: View {
    let name: String
    let label: String

    var body: some View {
        VStack(spacing: 6) {
            Circle()
                .fill(Color.vvGreen)
                .frame(width: 8, height: 8)
            Text(name)
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(.vvText)
                .multilineTextAlignment(.center)
            Text(label)
                .font(.system(size: 9))
                .foregroundColor(.vvMuted)
                .multilineTextAlignment(.center)
                .kerning(0.3)
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(Color.vvCard)
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.vvBorder, lineWidth: 1)
        )
    }
}

// ── ResultCard ────────────────────────────────────────
struct ResultCard: View {
    let classification: String
    let confidence: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ÚLTIMA CLASSIFICAÇÃO")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.vvMuted)
                .kerning(1.5)
            Text(classification)
                .font(.system(size: 22, weight: .black))
                .foregroundColor(.vvText)
            Text(String(format: "Confiança: %.0f%%", confidence * 100))
                .font(.system(size: 12))
                .foregroundColor(.vvMuted)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.vvCard)
        .cornerRadius(14)
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.vvBorder, lineWidth: 1)
        )
    }
}

// ── ErrorCard ─────────────────────────────────────────
struct ErrorCard: View {
    let message: String

    var body: some View {
        Text("⚠ \(message)")
            .font(.system(size: 13))
            .foregroundColor(Color(red: 0.690, green: 0, blue: 0.125))
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(red: 1, green: 0.941, blue: 0.941))
            .cornerRadius(14)
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color(red: 1, green: 0.804, blue: 0.820), lineWidth: 1)
            )
    }
}

// ── Preview ───────────────────────────────────────────
#Preview {
    ContentView()
}