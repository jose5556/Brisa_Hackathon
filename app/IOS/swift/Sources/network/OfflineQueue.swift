import Foundation

// ── OfflineQueue ──────────────────────────────────────
// Fila de payloads que falharam o envio por falta de rede.
//
// Comportamento:
//   • Persiste em disco (sobrevive a fechar/reabrir a app).
//   • TTL: payloads mais velhos que `ttl` são descartados (20 min).
//   • Tentativas ILIMITADAS até expirar o TTL.
//   • Reenvio por TIMER periódico (`flushInterval`) enquanto houver itens.
//
// O payload é construído UMA vez (com a meteorologia e features daquele
// momento) e reenviado tal-e-qual mais tarde — os timestamps da janela
// permanecem os originais.
actor OfflineQueue {

    static let shared = OfflineQueue()

    // ── Configuração ──────────────────────────────────
    private let ttl: TimeInterval           = 20 * 60   // 20 minutos
    private let flushInterval: TimeInterval = 30         // tenta reenviar a cada 30s

    // ── Item da fila ──────────────────────────────────
    private struct QueuedPayload: Codable {
        let id: UUID
        let payload: SensorPayload
        let enqueuedAt: Date
    }

    private let fileURL: URL
    private var items: [QueuedPayload] = []
    private var autoFlushTask: Task<Void, Never>?

    private init() {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("offline_payload_queue.json")
        load()
    }

    // ── API pública ───────────────────────────────────

    /// Guarda um payload que não conseguiu ser enviado.
    func enqueue(_ payload: SensorPayload) {
        purgeExpired()
        items.append(QueuedPayload(id: UUID(), payload: payload, enqueuedAt: Date()))
        save()
        print("[OfflineQueue] Payload guardado para reenvio — \(items.count) na fila")
    }

    /// Nº de payloads atualmente na fila (após descartar expirados).
    func pendingCount() -> Int {
        purgeExpired()
        return items.count
    }

    /// Arranca o timer de reenvio (idempotente).
    /// Chamar no arranque da app para recuperar itens de sessões anteriores.
    func startAutoFlush() {
        guard autoFlushTask == nil else { return }
        autoFlushTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64((self?.flushInterval ?? 30) * 1_000_000_000))
                await self?.flush()
            }
        }
    }

    func stopAutoFlush() {
        autoFlushTask?.cancel()
        autoFlushTask = nil
    }

    /// Tenta reenviar todos os payloads pendentes. Os que falharem ficam na
    /// fila (tentativas ilimitadas); os expirados são descartados.
    func flush() async {
        purgeExpired()
        let snapshot = items
        guard !snapshot.isEmpty else { return }

        print("[OfflineQueue] A tentar reenviar \(snapshot.count) payload(s)…")
        var sentIds = Set<UUID>()

        for item in snapshot {
            do {
                _ = try await SensorApiClient.shared.predictVerticalContext(payload: item.payload)
                sentIds.insert(item.id)
                print("[OfflineQueue] ✓ Reenviado \(item.id)")
            } catch {
                // Mantém na fila — volta a tentar no próximo ciclo.
                print("[OfflineQueue] ✗ Falhou \(item.id): \(error.localizedDescription)")
            }
        }

        // Remove os enviados (sem perder itens enfileirados durante o flush).
        items.removeAll { sentIds.contains($0.id) }
        purgeExpired()
        save()
    }

    // ── Internos ──────────────────────────────────────

    private func purgeExpired() {
        let cutoff = Date().addingTimeInterval(-ttl)
        let before = items.count
        items.removeAll { $0.enqueuedAt < cutoff }
        if items.count != before {
            print("[OfflineQueue] \(before - items.count) payload(s) expirado(s) descartado(s)")
            save()
        }
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(items)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            print("[OfflineQueue] save falhou: \(error.localizedDescription)")
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        items = (try? JSONDecoder().decode([QueuedPayload].self, from: data)) ?? []
        if !items.isEmpty {
            print("[OfflineQueue] \(items.count) payload(s) carregado(s) do disco")
        }
    }
}
