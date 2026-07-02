# SensorLogsView — Developer Logs Screen

Tela de debug acessível via botão **DEV** no header da app principal. Expõe o pipeline completo de recolha de sensores, extracção de features, envio do payload e resposta do modelo — tudo numa única vista em modo escuro.

---

## Motivação

Durante o desenvolvimento e testes de campo é essencial perceber o que o modelo "está a ver" antes de classificar. A `SensorLogsView` elimina a necessidade de ler logs no Xcode — tudo o que é enviado para a API e recebido como resposta fica visível directamente no dispositivo.

---

## Acesso

Header da app (verde) → botão **DEV** no canto superior direito → `NavigationStack` navega para `SensorLogsView`.

---

## Fluxo de dados na tela

```
SensorCollector (contínuo)
        │
        ├─── liveWindow (@Published, 1 Hz) ──→ Strip de sensores activos
        │
        └─── getCurrentWindow() (no tap ANALISAR)
                    │
                    ▼
             SensorRepository.processAndSend()
                    │
                    ├─── lastWindow   ──→ RAW SENSOR WINDOW
                    ├─── lastPayload  ──→ FEATURE EXTRACTOR + PAYLOAD SENT
                    └─── uploadResult ──→ MODEL RESPONSE
```

O strip do topo actualiza em tempo real (1 Hz via `Timer`). As quatro secções colapsáveis são snapshots do **último envio** — só aparecem depois de carregar em "ANALISAR AMBIENTE" na tela principal.

---

## Strip de sensores activos (LIVE 1 Hz)

Quatro chips horizontais, um por sensor. Cada chip mostra todos os campos brutos do último sample recebido. O indicador circular é verde quando o sensor tem sinal, vermelho caso contrário.

```
┌────────────────┬────────────────┬────────────────┬──────────────┐
│ • GPS          │ • BAROMETER    │ • MAGNETOMETER │ ✕ IMU        │
│ lat: 41.14961  │ hPa: 1013.25   │ x:  22.14 µT   │              │
│ lon: -8.61099  │                │ y: -14.31 µT   │    N/A       │
│ acc: 5.0 m     │                │ z:  38.52 µT   │              │
│ alt: 120.1 m   │                │                │              │
│ spd: 0.00 m/s  │                │                │              │
│ sig: true      │                │                │              │
└────────────────┴────────────────┴────────────────┴──────────────┘
```

| Chip | Campos | Fonte |
|------|--------|-------|
| GPS | latitude, longitude, accuracy (m), altitude (m), speed (m/s), has signal | `CLLocationManager` |
| BAROMETER | pressure (hPa) | `CMAltimeter` — valores em kPa convertidos para hPa (× 10) |
| MAGNETOMETER | x, y, z (µT) | `CMMotionManager.deviceMotion.magneticField` calibrado |
| IMU | N/A | Acelerómetro desativado no `SensorCollector` — código comentado |

---

## Secções colapsáveis

Todas as secções são colapsáveis com animação. Cada cabeçalho mostra um badge com o número de readings ou features.

### 1 — RAW SENSOR WINDOW

Mostra o **último sample** de cada sensor dentro da janela de tempo activa (por defeito 30 s). Também indica quantos readings estão no buffer dessa janela.

- **GPS** — latitude, longitude, accuracy (m), altitude (m), speed (m/s), has signal
- **BAROMETER** — pressure (hPa)
- **MAGNETOMETER** — x (µT), y (µT), z (µT)

> Os valores aqui são os dados brutos tal como chegam dos sensores, antes de qualquer agregação estatística.

### 2 — FEATURE EXTRACTOR

Mostra as **19 features** calculadas por `SensorWindow.toPayload()` sobre os buffers da janela de tempo. Estas são as features enviadas ao modelo de ML.

**GPS (6 features)**

| Feature | Descrição |
|---------|-----------|
| `gps_accuracy_mean` | Média da precisão horizontal ao longo da janela (m) |
| `gps_accuracy_max` | Pior precisão observada na janela (m) |
| `gps_accuracy_delta` | Diferença entre a pior e a melhor precisão (m) |
| `gps_lost_ratio` | Fracção de amostras sem sinal válido (0–1) |
| `gps_speed_mean` | Velocidade média durante a janela (m/s) |
| `gps_speed_max` | Velocidade máxima durante a janela (m/s) |

**Barometer (5 features)**

| Feature | Descrição |
|---------|-----------|
| `pressure_hpa` | Pressão média na janela (hPa) |
| `pressure_delta_hpa` | Variação de pressão do início ao fim da janela (hPa) |
| `pressure_variance` | Variância das amostras de pressão |
| `altitude_change_m` | Variação de altitude estimada pela pressão (m) |
| `city_baseline_pressure` | Pressão ao nível do mar para a cidade actual, via Open-Meteo (hPa) |

**Altitude (2 features)**

| Feature | Descrição |
|---------|-----------|
| `altitude_delta` | Diferença de altitude GPS entre início e fim da janela (m) |
| `vertical_change_abs` | Valor absoluto da variação vertical (m) |

**Magnetometer (4 features)**

| Feature | Descrição |
|---------|-----------|
| `magnetic_field_mean` | Magnitude média do campo magnético (µT) |
| `magnetic_field_max` | Magnitude máxima observada (µT) |
| `magnetic_field_delta` | Variação da magnitude ao longo da janela (µT) |
| `magnetic_field_variance` | Variância da magnitude |

**Context (2 features)**

| Feature | Descrição |
|---------|-----------|
| `weather_condition` | Condição meteorológica actual: `clear`, `rain`, etc. |
| `time_of_day` | Período do dia: `morning`, `afternoon`, `evening`, `night` |

### 3 — PAYLOAD SENT

JSON completo enviado via `POST /predict`. Inclui todas as 19 features mais metadados da janela:

- `latitude` / `longitude` — posição GPS no momento do envio
- `window_start_at` / `window_end_at` — timestamps ISO 8601 da janela
- `window_duration_s` — duração efectiva da janela em segundos

O cabeçalho da secção mostra o timestamp de início da janela como badge.

### 4 — MODEL RESPONSE

Resposta do backend (`POST /predict` → `200 OK`):

- `classification` — classe predita: `street_level`, `underground`, ou `above`
- `non_street_confidence` — probabilidade de não ser via pública (P(underground) + P(above))
- Barra de confiança visual: verde se abaixo de 50 %, laranja acima

---

## Comportamento quando não há dados

Se ainda não foi feito nenhum envio, as secções colapsáveis não aparecem e é mostrada a mensagem:

> "Sem dados ainda — Volta à tela principal e carrega em ANALISAR AMBIENTE"

---

## Componentes SwiftUI

| Componente | Responsabilidade |
|------------|-----------------|
| `RawSensorChip` | Chip genérico com nome do sensor, indicador de estado e conteúdo variável via `@ViewBuilder` |
| `RawRow` | Linha `chave: valor` dentro de um `RawSensorChip` |
| `LogSection` | Secção colapsável de nível superior (título verde, badge) |
| `LogSubSection` | Sub-secção colapsável aninhada dentro de `LogSection` (título cinzento) |
| `DataRow` | Linha `chave — valor` alinhada horizontalmente, com opção de destaque |
| `JsonBlock` | Bloco JSON com syntax highlighting básico (chaves azuis, valores brancos) |

---

## Ficheiros modificados / criados

| Ficheiro | Alteração |
|----------|-----------|
| `ui/SensorLogsView.swift` | Criado — view completa com strip live e secções colapsáveis |
| `ui/ContentView.swift` | Adicionado `NavigationStack`, botão DEV no header e `.navigationDestination` |
| `ui/SensorViewModel.swift` | Adicionados `lastPayload`, `lastWindow`, `liveWindow`, `startLiveUpdates()`, `stopLiveUpdates()` |
| `SensorRepository.swift` | `processAndSend` passa a retornar `(payload: SensorPayload, response: PredictionResponse)` |

---

## Correcções ao mockup original (`sensor-logs-screen.html`)

| Mockup | Implementação real | Motivo |
|--------|--------------------|--------|
| `pressure_delta` | `pressure_delta_hpa` | Nome correcto no `SensorPayload` |
| `pressure_slope` | `pressure_variance` | Variância é o que é calculado em `toPayload()` |
| `stationary_ratio` | Removido | Não existe no iOS — depende de acelerómetro |
| Secção MOTION / IMU | IMU → N/A | Acelerómetro comentado no `SensorCollector` |
| Strip com valor único por sensor | Strip com todos os campos brutos | Pedido de melhoria para visibilidade de debug |
| Campos em falta | Adicionados: `pressure_hpa`, `altitude_change_m`, `city_baseline_pressure`, `weather_condition`, `time_of_day`, `window_start_at`, `window_end_at`, `window_duration_s` | Features presentes no payload mas ausentes do mockup |
