import SwiftUI
import UIKit

// ── SensorTick ────────────────────────────────────────
struct SensorTick: Identifiable {
    let id = UUID()
    let elapsedS:     Int
    let timestamp:    String
    let pressureHpa:  Double
    let gpsAccuracyM: Double
    let gpsSpeedMps:  Double
    let magUt:        Double
}

// ── DataCollectionView ────────────────────────────────
struct DataCollectionView: View {

    @ObservedObject var viewModel: SensorViewModel
    @State private var shareURL: URL? = nil
    @State private var showShare = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {

                // ── Cabeçalho das colunas ─────────────
                HStack(spacing: 0) {
                    ColHeader("time",     width: 44)
                    ColHeader("hPa",      width: 68)
                    ColHeader("acc(m)",   width: 60)
                    ColHeader("spd(m/s)", width: 68)
                    ColHeader("mag(µT)",  width: 68)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color(white: 0.07))
                .overlay(Divider().background(Color(white: 0.12)), alignment: .bottom)

                // ── Lista de ticks ────────────────────
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(viewModel.dataTicks) { tick in
                                TickRow(tick: tick)
                                    .id(tick.id)
                            }
                        }
                    }
                    .onChange(of: viewModel.dataTicks.count) { _ in
                        if let last = viewModel.dataTicks.last {
                            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    }
                }

                // ── Rodapé com botões ─────────────────
                VStack(spacing: 0) {
                    Divider().background(Color(white: 0.12))
                    HStack(spacing: 10) {

                        // REC / PARAR
                        Button(action: {
                            if viewModel.isDataRecording { viewModel.stopDataRecording() }
                            else { viewModel.startDataRecording() }
                        }) {
                            Text(viewModel.isDataRecording
                                 ? "■  PARAR  (\(viewModel.dataTicks.count) ticks)"
                                 : "●  INICIAR")
                                .font(.system(size: 13, weight: .bold, design: .monospaced))
                                .foregroundColor(viewModel.isDataRecording ? .white : .vvGreen)
                                .frame(maxWidth: .infinity)
                                .frame(height: 44)
                                .background(viewModel.isDataRecording
                                            ? Color(white: 0.14)
                                            : Color(white: 0.08))
                                .cornerRadius(10)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10)
                                        .stroke(viewModel.isDataRecording ? Color.vvGreen : Color(white: 0.2), lineWidth: 1)
                                )
                        }

                        // EXPORTAR
                        Button(action: {
                            shareURL = viewModel.exportDataCSV()
                            if shareURL != nil { showShare = true }
                        }) {
                            Text("EXPORTAR")
                                .font(.system(size: 13, weight: .bold, design: .monospaced))
                                .foregroundColor(canExport ? .white : Color(white: 0.3))
                                .frame(width: 110)
                                .frame(height: 44)
                                .background(canExport ? Color.vvGreenDark : Color(white: 0.06))
                                .cornerRadius(10)
                        }
                        .disabled(!canExport)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(Color.black)
                }
            }
        }
        .navigationTitle("DATA COLLECTION")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbarBackground(Color.black, for: .navigationBar)
        .sheet(isPresented: $showShare) {
            if let url = shareURL {
                ShareSheet(items: [url])
            }
        }
    }

    private var canExport: Bool {
        !viewModel.isDataRecording && !viewModel.dataTicks.isEmpty
    }
}

// ── TickRow ───────────────────────────────────────────
private struct TickRow: View {
    let tick: SensorTick

    var body: some View {
        HStack(spacing: 0) {
            ColCell(String(format: "%02d:%02d", tick.elapsedS / 60, tick.elapsedS % 60), width: 44)
            ColCell(String(format: "%.2f", tick.pressureHpa),  width: 68)
            ColCell(String(format: "%.1f",  tick.gpsAccuracyM), width: 60)
            ColCell(String(format: "%.2f", tick.gpsSpeedMps),  width: 68)
            ColCell(String(format: "%.1f",  tick.magUt),        width: 68)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
        .background(Color.black)
        .overlay(Divider().background(Color(white: 0.06)), alignment: .bottom)
    }
}

// ── ColHeader / ColCell ───────────────────────────────
private struct ColHeader: View {
    let text: String
    let width: CGFloat
    init(_ text: String, width: CGFloat) { self.text = text; self.width = width }

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundColor(Color(white: 0.35))
            .kerning(0.5)
            .frame(width: width, alignment: .trailing)
    }
}

private struct ColCell: View {
    let text: String
    let width: CGFloat
    init(_ text: String, width: CGFloat) { self.text = text; self.width = width }

    var body: some View {
        Text(text)
            .font(.system(size: 10, design: .monospaced))
            .foregroundColor(Color(white: 0.82))
            .frame(width: width, alignment: .trailing)
    }
}

// ── ShareSheet (UIKit wrapper) ────────────────────────
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
