# Fluxo da App — do arranque ao resultado

Diagrama simples do percurso completo: arranque → recolha de sensores →
envio para o backend de ML → classificação → resultado no ecrã.

---

## Visão geral (ASCII)

```
┌──────────────────────────────────────────────────────────────────────┐
│ 1. ARRANQUE                                                            │
│    BrisaApp (@main) ──▶ ContentView aparece (.onAppear)                │
└───────────────────────────────┬──────────────────────────────────────┘
                                 │ viewModel.startCollecting()
                                 ▼
┌──────────────────────────────────────────────────────────────────────┐
│ 2. RECOLHA CONTÍNUA  ·  SensorCollector.startContinuous()            │
│    Buffers em background num BUFFER DINÂMICO (histórico rolling de    │
│    ~minutos, NSLock) — a janela de análise é recortada depois:       │
│      • GPS         CLLocationManager   (~1 Hz, sem distanceFilter)    │
│      • Barómetro   CMAltimeter         (~1 Hz)                        │
│      • Magnetómetro CMMotionManager    (10 Hz)                        │
│      • Trim timer  mantém só o histórico necessário                  │
└───────────────────────────────┬──────────────────────────────────────┘
                                 │  (corre antes de qualquer clique)
                                 ▼
┌──────────────────────────────────────────────────────────────────────┐
│ 3. 🔘 BOTÃO  "▶ Analisar ambiente"  ·  ContentView                   │
│    O utilizador carrega ──▶ marca o instante de referência (paragem) │
│    viewModel.sendCurrentWindow()  →  estado = .loading (spinner)      │
└───────────────────────────────┬──────────────────────────────────────┘
                                 ▼
┌──────────────────────────────────────────────────────────────────────┐
│ 3b. RECORTE DINÂMICO DA JANELA  ·  (estratégia de âncora)            │
│    Recua no buffer a partir da paragem e corta a janela:             │
│      âncora ──────────────────────▶ paragem                          │
│    Âncora achada por um SCORE DE VARIAÇÃO                            │
│    (magnetómetro + redução de velocidade + perda de GPS).            │
│    → duração da janela é DINÂMICA, não fixa.  [detalhe à parte]      │
└───────────────────────────────┬──────────────────────────────────────┘
                                 │ janela recortada (âncora → paragem)
                                 ▼
┌──────────────────────────────────────────────────────────────────────┐
│ 4. ORQUESTRAÇÃO  ·  SensorRepository.processAndSend(window)          │
│                                                                       │
│   a) última coord GPS ── sem sinal? ──▶ erro "Sem sinal GPS" ✋       │
│   b) WeatherService.fetch(lat,lon)  ── Open-Meteo                     │
│         └─ falha? usa defaults (1013.25 hPa, "clear") e continua      │
│   c) window.toPayload(baseline, weather)  ── calcula FEATURES         │
│         └─ sem dados? ──▶ erro "Dados insuficientes" ✋               │
└───────────────────────────────┬──────────────────────────────────────┘
                                 │ SensorPayload (JSON, snake_case)
                                 ▼
┌──────────────────────────────────────────────────────────────────────┐
│ 5. ENVIO  ·  SensorApiClient.predictVerticalContext(payload)        │
│    POST {baseURL}/predict   ───────────────────────────────────▶ ╮   │
└──────────────────────────────────────────────────────────────────┼───┘
                                                                    │
              ═══════════════ rede ═══════════════                  │
                                                                    ▼
┌──────────────────────────────────────────────────────────────────────┐
│ 6. BACKEND  ·  FastAPI  /predict  (ml-backend/src/api.py)            │
│    payload ──▶ predict_vertical_context()                            │
│            ──▶ modelo RandomForest (vertical_context_rf.joblib)      │
│    devolve { classification, non_street_confidence }                 │
└───────────────────────────────┬──────────────────────────────────────┘
                                 │ HTTP 200 + JSON
              ═══════════════ rede ═══════════════
                                 ▼
┌──────────────────────────────────────────────────────────────────────┐
│ 7. RECEBIMENTO  ·  SensorApiClient descodifica PredictionResponse   │
│    ── erro? ──▶ networkError / httpError / decodingFailed ✋         │
└───────────────────────────────┬──────────────────────────────────────┘
                                 │
                                 ▼
┌──────────────────────────────────────────────────────────────────────┐
│ 8. RESULTADO NO ECRÃ  ·  SensorViewModel ──▶ ContentView            │
│    sucesso → uploadResult = .success  → ResultCard (classe + conf%)  │
│    erro    → uploadResult = .error    → ErrorCard                    │
│    (@Published → a UI re-renderiza automaticamente)                  │
└──────────────────────────────────────────────────────────────────────┘
                                 │
                                 ▼  (ao sair do ecrã: .onDisappear)
                          stopCollecting()
```

---

## Versão Mermaid (renderiza no GitHub / VS Code)

```mermaid
flowchart TD
    A["BrisaApp @main"] --> B["ContentView .onAppear"]
    B -->|startCollecting| C["SensorCollector\nGPS + Barómetro + Magnetómetro\nbuffer dinâmico"]
    C -.->|buffers em background| C
    B --> BTN(["🔘 Botão: ▶ Analisar ambiente"])
    BTN -->|sendCurrentWindow\nmarca paragem| D{"Recorte dinâmico da janela\nâncora → paragem\n(score: mag + velocidade + GPS)"}
    D -->|getCurrentWindow| E["Janela recortada\n(duração dinâmica)"]
    E --> F["SensorRepository\nprocessAndSend"]
    F --> G{"GPS tem sinal?"}
    G -->|não| ERR1["Erro: Sem sinal GPS"]
    G -->|sim| H["WeatherService\nOpen-Meteo (baseline + tempo)"]
    H --> I["toPayload()\ncalcula features"]
    I --> J{"Dados suficientes?"}
    J -->|não| ERR2["Erro: Dados insuficientes"]
    J -->|sim| K["SensorApiClient\nPOST /predict (JSON)"]
    K -->|rede| L["FastAPI /predict\nRandomForest model"]
    L -->|"{classification,\nnon_street_confidence}"| M["Descodifica\nPredictionResponse"]
    M -->|sucesso| N["ResultCard\nclasse + confiança %"]
    M -->|erro| ERR3["ErrorCard\nnetwork/http/decoding"]
    N --> O["onDisappear → stopCollecting"]
```

---

## Notas

- **A recolha começa no `.onAppear`**, antes de qualquer clique — o buffer vai
  acumulando histórico para haver passado suficiente onde recortar.
- **A janela já não é fixa (30s):** é um **buffer dinâmico**. O clique no botão
  marca o instante de **paragem**; a janela de análise é recortada recuando no
  buffer até à **âncora** (início da transição), achada por um **score de
  variação** (magnetómetro + redução de velocidade + perda de GPS). _A estratégia
  da âncora está definida à parte — aqui só entra como passo do fluxo._
- **A meteorologia nunca bloqueia**: se a Open-Meteo falhar, usa defaults e segue.
- **Pontos de paragem (erro)**: sem sinal GPS, dados insuficientes, falha de
  rede/HTTP, ou descodificação inválida — cada um vira uma mensagem na UI.

> ⚠️ **Desalinhamento de contrato (a confirmar):** o backend
> [`api.py`](../../ml-backend/src/api.py) declara o `SensorWindow` com campos
> `wifi_*`, `ble_*`, `pressure_slope`, `stationary_ratio` — mas o
> [`SensorPayload`](swift/Sources/data/SensorData.swift) do iOS envia
> `gps_speed_*`, `pressure_hpa`, `magnetic_field_*`, etc. Os nomes **não batem
> certo**. Vale a pena alinhar o payload do iOS com o esquema do backend (ou
> vice-versa) antes de testar o envio ponta a ponta.
