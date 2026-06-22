# Via Verde · Context Detection (iOS)

App iOS (SwiftUI) que deteta o **contexto vertical** de um veículo estacionado —
distinguir, por exemplo, se parou na **rua** ou dentro de um **parque/garagem** —
combinando sensores do iPhone (GPS, barómetro, magnetómetro) com dados
meteorológicos e um modelo de Machine Learning servido por um backend.

---

## 1. Visão geral

A app recolhe continuamente leituras de sensores numa **janela deslizante de 30
segundos**. Quando o utilizador carrega em **"Analisar ambiente"**, a app tira um
*snapshot* dessa janela, enriquece-o com dados de meteorologia, calcula um
conjunto de *features* estatísticas e envia tudo para um backend de ML, que
devolve uma **classificação** e um nível de **confiança**.

Arquitetura: **MVVM + Repository**

```
ContentView ──▶ SensorViewModel ──▶ SensorRepository
   ▲                  │                    │
   │ (@Published)     │                    ├─▶ SensorCollector  (GPS / barómetro / magnetómetro)
   └──────────────────┘                    ├─▶ WeatherService   (Open-Meteo)
                                           ├─▶ toPayload()      (features → SensorPayload)
                                           └─▶ SensorApiClient  (POST /predict → backend ML)
```

- A **View** só desenha.
- O **ViewModel** só gere estado.
- O **Repository** contém a lógica de negócio (orquestra tudo).

---

## 2. Estrutura de ficheiros

```
Sources/
├── BrisaApp.swift                 # Entry point da app (@main)
├── FeatureExtractor.swift         # Wrapper de conveniência sobre toPayload()
├── SensorRepository.swift         # Orquestração do pipeline (o "cérebro")
├── WeatherService.swift           # Cliente da API meteorológica (Open-Meteo)
├── data/
│   └── SensorData.swift           # Modelos de dados + cálculo de features
├── network/
│   └── SensorApiClient.swift      # Cliente HTTP do backend de ML (POST /predict)
├── sensor/
│   └── SensorCollector.swift      # Recolha dos sensores (janela deslizante)
└── ui/
    ├── ContentView.swift          # Todo o ecrã (SwiftUI)
    ├── SensorViewModel.swift      # Estado e ligação View ↔ lógica
    └── uploadResult.swift         # Enum de estado da UI
```

---

## 3. Responsabilidade de cada ficheiro

| Ficheiro | Camada | Responsabilidade |
|---|---|---|
| `BrisaApp.swift` | Entry point | Arranca a app e mostra a `ContentView`. |
| `ui/ContentView.swift` | UI | Desenha o ecrã: header, cards de estado/resultado/erro, chips de sensores, botão e barra de progresso. |
| `ui/SensorViewModel.swift` | UI / estado | Liga a View à lógica. Gere o ciclo de vida da recolha e o estado `uploadResult`. Não calcula nada — delega no repository. |
| `ui/uploadResult.swift` | Estado | Enum `idle / loading / success / error` que a View observa. |
| `sensor/SensorCollector.swift` | Sensores | Liga/desliga GPS, barómetro e magnetómetro; mantém a janela deslizante *thread-safe*. |
| `data/SensorData.swift` | Modelos + features | Define `SensorWindow`, `GpsReading`, `PressureReading`, `MagneticReading`, o `SensorPayload` (formato JSON) e calcula as *features* em `toPayload()`. **Fonte de verdade dos dados.** |
| `FeatureExtractor.swift` | Features | Wrapper fino sobre `toPayload()`. Não é usado no fluxo principal — existe para chamadas isoladas/testes. |
| `WeatherService.swift` | Rede | Vai à Open-Meteo buscar pressão de referência e condição do tempo. |
| `network/SensorApiClient.swift` | Rede | Faz o `POST /predict` ao backend de ML e descodifica a resposta. |
| `SensorRepository.swift` | Orquestração | Cola tudo: GPS → meteorologia → features → envio. |

---

## 4. Fluxo passo a passo (runtime)

### Passo 1 — Arranque · `BrisaApp.swift`
O `@main struct BrisaApp: App` cria a `WindowGroup` e mostra a `ContentView`.

### Passo 2 — View aparece · `ui/ContentView.swift`
No `.onAppear`, a View chama `viewModel.startCollecting()`. A partir daqui os
sensores começam a alimentar buffers em background — **antes** mesmo de qualquer
clique.

### Passo 3 — Recolha contínua de sensores · `sensor/SensorCollector.swift`
`startContinuous(windowSizeMs: 30_000)` liga três fontes em paralelo:

- **GPS** (`CLLocationManager`) — pede permissão e regista `GpsReading`.
  - `distanceFilter = kCLDistanceFilterNone`: reporta sempre, mesmo parado.
  - Um **timer a 1 Hz** re-amostra a última posição conhecida, garantindo que a
    janela nunca fica vazia quando o dispositivo está imóvel (ou com localização
    simulada estática).
- **Barómetro** (`CMAltimeter`) — regista `PressureReading` (converte kPa → hPa).
- **Magnetómetro** (`CMMotionManager.deviceMotion` @ 10 Hz) — regista `MagneticReading`.
- **Trim timer** (a cada 60 s) — descarta amostras com mais de 2× a janela, para
  a memória não crescer indefinidamente.

Todos os buffers são protegidos por `NSLock`, porque os callbacks chegam de
threads diferentes.

### Passo 4 — Utilizador carrega em "▶ Analisar ambiente" · `ui/ContentView.swift`
O botão chama `viewModel.sendCurrentWindow()`. O estado passa a `.loading`: o
botão mostra o spinner "Analisando… (30s)" e a barra de progresso anima.

### Passo 5 — ViewModel orquestra · `ui/SensorViewModel.swift`
1. Tira o *snapshot* da janela atual: `collector.getCurrentWindow()` (apenas os
   últimos 30 s).
2. Entrega tudo ao `repository.processAndSend(window:)`.

### Passo 6 — Repository monta e envia · `SensorRepository.swift`
1. Lê a **última coordenada GPS**. Se não houver sinal → lança `noGpsSignal`
   ("Sem sinal GPS — aguarda e tenta novamente").
2. Chama o **WeatherService** para obter `cityBaselinePressure` e
   `weatherCondition` dessas coordenadas. Se falhar, usa valores neutros
   (1013.25 hPa, `"clear"`) e continua — não bloqueia o envio por causa do tempo.
3. Calcula as *features* com `window.toPayload(...)`.
4. Envia o payload via `SensorApiClient`.

### Passo 7 — Cálculo das features · `data/SensorData.swift` (`toPayload`)
Transforma as amostras brutas em estatísticas (médias, máximos, variâncias,
deltas) e produz um `SensorPayload`. Se não houver nenhuma leitura GPS, devolve
`nil`. (Ver secção 5 para o detalhe de cada feature.)

### Passo 8 — Chamada HTTP · `network/SensorApiClient.swift`
`POST {baseURL}/predict` com o payload em JSON. Recebe e descodifica
`PredictionResponse` (`classification` + `non_street_confidence`). Erros são
mapeados para `networkError` / `httpError` / `decodingFailed`.

### Passo 9 — Resultado no ecrã · `ui/SensorViewModel.swift` → `ui/ContentView.swift`
- **Sucesso** → `uploadResult = .success(...)` → mostra o `ResultCard` com a
  classificação e a confiança em %.
- **Erro** → `uploadResult = .error(message:)` → mostra o `ErrorCard`.

Como `uploadResult` é `@Published`, a UI re-renderiza automaticamente.

### Passo 10 — View desaparece · `ui/ContentView.swift`
O `.onDisappear` chama `viewModel.stopCollecting()`.

---

## 5. O contrato de dados (`SensorPayload`)

Enviado como JSON (snake_case) para `POST /predict`. Definido em
`data/SensorData.swift`.

| Campo JSON | Significado |
|---|---|
| `latitude`, `longitude` | Coordenadas onde o veículo parou. |
| `gps_accuracy_mean` / `_max` / `_delta` | Precisão do GPS na janela (m). Valores altos/instáveis sugerem sinal obstruído (interior). |
| `gps_lost_ratio` | % de leituras sem sinal (0 = sempre com sinal). |
| `gps_speed_mean` / `_max` | Velocidade na janela (m/s). |
| `pressure_hpa` | Pressão atmosférica média (hPa). |
| `pressure_delta_hpa` | Pressão medida − baseline da cidade (deteta mudança de piso). |
| `pressure_variance` | Variância da pressão (alta = subida/descida de rampa). |
| `altitude_change_m` | Variação de altitude estimada pela fórmula barométrica. |
| `city_baseline_pressure` | Pressão de referência da cidade (via Open-Meteo). |
| `altitude_delta` | Diferença de altitude GPS entre início e fim da janela. |
| `vertical_change_abs` | Soma das variações verticais absolutas. |
| `magnetic_field_mean` / `_max` / `_delta` / `_variance` | Campo magnético (µT). Anomalias indicam estruturas metálicas (garagens). |
| `weather_condition` | `"clear"` \| `"rain"` \| `"overcast"`. |
| `time_of_day` | `"morning"` \| `"afternoon"` \| `"evening"` \| `"night"`. |
| `window_start_at` / `window_end_at` | Timestamps ISO 8601 da janela. |
| `window_duration_s` | Duração da janela em segundos. |

**Resposta esperada do backend** (`PredictionResponse`):

```json
{
  "classification": "street",
  "non_street_confidence": 0.12
}
```

---

## 6. Configuração

### Endpoint do backend
Em `network/SensorApiClient.swift`, ajusta o `baseURL`:

- **Simulador:** `http://127.0.0.1:8000/`
- **iPhone físico** (mesma Wi-Fi do PC): `http://<IP-do-PC>:8000/`

### Permissões (Info.plist)
Obrigatórias — sem elas a app crasha ao aceder aos sensores:

| Key | Descrição |
|---|---|
| `NSLocationWhenInUseUsageDescription` | Justificação do uso do GPS. |
| `NSMotionUsageDescription` | Justificação do uso do magnetómetro/barómetro. |

---

## 7. Como correr

1. Abrir o **Xcode** → criar um projeto **iOS > App** (SwiftUI) e adicionar os
   ficheiros de `Sources/`. *(O `Package.swift` não é usado — é scaffolding de
   linha de comando, não uma app iOS.)*
2. Definir **Minimum Deployment** = iOS 16.
3. Adicionar as permissões do Info.plist (ver acima).
4. Escolher o destino e **Run** (`Cmd + R`).

### Limitações do Simulador

| Sensor | No Simulador |
|---|---|
| GPS | ✅ Funciona, mas com localização **simulada** (`Features > Location`). Valores sem o "ruído" real. |
| Barómetro | ❌ Indisponível → leituras de pressão a zero. |
| Magnetómetro | ❌ Indisponível → campo magnético a zero. |

Para dados representativos (precisão a variar, perda de sinal, altitude, pressão,
magnetómetro) é necessário um **iPhone físico**.

---

## 8. Tratamento de erros

| Situação | Origem | Mensagem ao utilizador |
|---|---|---|
| Sem leitura GPS válida | `SensorRepository` | "Sem sinal GPS — aguarda e tenta novamente." |
| Dados insuficientes | `SensorRepository` | "Dados insuficientes para classificar…" |
| Backend inacessível | `SensorApiClient` | "Servidor inacessível: …" |
| Erro HTTP do backend | `SensorApiClient` | "Erro do servidor: HTTP \<code\>" |
| Meteorologia falha | `WeatherService` | *(não bloqueia — usa defaults)* |
