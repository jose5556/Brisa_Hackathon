# Score de Transição — Como Funciona

Este documento explica, passo a passo, a lógica atual do **score por tick** usado para
detetar o início da janela de recolha de sensores (o momento em que o veículo estava
ainda em rua válida mas os sensores mais variaram — tipicamente a transição
rua → estacionamento).

> Implementação: [SensorScore.swift](app/IOS/swift/Sources/sensor/SensorScore.swift)
> Uso: [SensorViewModel.swift](app/IOS/swift/Sources/ui/SensorViewModel.swift#L48-L78)

---

## Ideia geral

Enquanto a app recolhe sensores, mantém um **buffer** das leituras dos últimos ~180 s
(GPS, barómetro, magnetómetro). Quando é feita uma análise:

1. Percorremos o buffer e damos a cada **tick** (~1 Hz, uma leitura GPS) um **score de
   transição** que mede o quanto os sensores variaram nesse instante.
2. O tick de **maior score** marca o **início da janela** de captura.
3. A janela vai desse pico até à última leitura (o instante do "Analisar").
4. Se nenhum tick for válido, cai-se numa janela fixa de 30 s (fallback).

A grelha de ticks são as **leituras GPS**, porque já trazem velocidade e estado do sinal.

---

## Os 4 sinais usados (fusão de sensores)

| Sinal | Unidade | O que mede |
|-------|---------|------------|
| **GPS accuracy** (`dAcc`) | metros (m) | quão instável ficou a precisão do GPS |
| **GPS speed** (`dSpeed`) | m/s | variação de velocidade (travagem, paragem) |
| **Magnetómetro** (`dMag`) | µT | variação do campo magnético (metal/betão) |
| **Pressão** (`dPress`) | hPa | variação de pressão (mudança de altitude/piso) |

- GPS accuracy e speed são **obrigatórios** — sem uma âncora GPS a ~5 s atrás, o tick
  é ignorado.
- Magnetómetro e pressão são **opcionais**: se o dispositivo não tiver essas leituras,
  o seu Δ vale `0` e não anula o tick.

---

## Passo a passo do cálculo

### Passo 1 — Δ bruto de cada sensor
Para cada tick no instante `t`, olhamos para a leitura de há **`rateMs` (5 s)** atrás
(`target = t − 5000ms`) e calculamos a variação absoluta:

```
dAcc   = | accuracy(t)  − accuracy(target)  |
dSpeed = | speed(t)     − speed(target)     |
dMag   = | magnitude(t) − magnitude(target) |   (0 se sem leituras)
dPress = | pressão(t)   − pressão(target)   |   (0 se sem leituras)
```

A "leitura de há 5 s atrás" é a amostra cujo timestamp está **mais próximo** de `target`.

### Passo 2 — Gate de rua
Um tick só pontua se estiver claramente **em movimento na rua**:

```
gated = temSinalGPS  E  speed(t) > minSpeedMps (2.5 m/s ≈ 9 km/h)
```

Se falhar o gate, o score do tick é `0` (mas o Δ continua a ser guardado para inspeção).

### Passo 3 — Normalização (σ)
Cada sensor tem escalas diferentes (metros vs m/s vs µT vs hPa), por isso normalizamos
cada Δ pela sua **variação típica** — o desvio-padrão (σ) desse sensor, medido **apenas
sobre os ticks que passaram o gate**:

```
n = delta / σ_do_sensor
```

Assim `n` fica adimensional: "quantos desvios-padrão este tick varia acima do normal".
(Se `σ ≈ 0`, o contributo é `0` — o sensor não teve variação nenhuma na janela.)

### Passo 4 — Deadband e tecto (cap)
Sobre o valor normalizado `n`:

- **Deadband** (`deadband = 0.5σ`): variações ínfimas → `0` (ruído irrelevante).
- **Tecto/cap** (`cap = 3.0σ`): variações enormes não podem dominar → limitadas a 3σ.

```
se n < 0.5  →  contributo = 0
senão       →  contributo = peso × min(n, 3.0)
```

### Passo 5 — Peso de cada sensor
Cada contributo é multiplicado pelo peso do respetivo sensor (atualmente todos `1.0`):

```
sAcc, sSpeed, sMag, sPress
```

### Passo 6 — Score bruto do tick
Soma dos 4 contributos:

```
rawScore = sAcc + sSpeed + sMag + sPress
```

### Passo 7 — Suavização (EMA)
Para o score não saltar de tick para tick, aplica-se uma média móvel exponencial
(`emaAlpha = 0.5`):

```
score(tick) = α × rawScore + (1 − α) × score(tick anterior)
            = (rawScore + score_anterior) / 2      (com α = 0.5)
```

### Passo 8 — Escolha do início da janela
Percorridos todos os ticks, o **tick com maior `score`** (e que passou o gate) torna-se
o **início da janela**. A janela final é `[esse tick → última leitura]`.

---

## ⚠️ Constantes a calibrar

Todos os parâmetros vivem em `SensorWindow.ScoreParams`
([SensorScore.swift:51-62](app/IOS/swift/Sources/sensor/SensorScore.swift#L51-L62)).
Os valores atuais são **iniciais** e **serão recalibrados com dados de campo**:

| Parâmetro | Valor atual | Papel | Nota de calibração |
|-----------|-------------|-------|--------------------|
| `rateMs` | `5000` ms | janela de variação do Δ (Passo 1) | quão "para trás" olhamos |
| `minSpeedMps` | `2.5` m/s | gate de rua (Passo 2) | limiar rua vs parado |
| `deadband` | `0.5` σ | corta ruído (Passo 4) | subir → mais rigoroso |
| `cap` | `3.0` σ | tecto por sensor (Passo 4) | evita outliers dominarem |
| `weightAcc` | `1.0` | peso GPS accuracy (Passo 5) | **a calibrar por importância** |
| `weightSpeed` | `1.0` | peso GPS speed (Passo 5) | **a calibrar por importância** |
| `weightMag` | `1.0` | peso magnetómetro (Passo 5) | **a calibrar por importância** |
| `weightPressure` | `1.0` | peso pressão (Passo 5) | **a calibrar por importância** |
| `emaAlpha` | `0.5` | suavização EMA (Passo 7) | maior → reage mais rápido |

> **Nota sobre os pesos:** hoje todos os sensores contam igual (`1.0`). Quando houver
> dados de teste suficientes, os pesos devem refletir quais sinais melhor distinguem a
> transição rua → estacionamento (ex.: magnetómetro pode merecer mais peso em garagens).

> **Nota sobre os deltas:** o Δ de cada sensor é comparado sempre com a leitura de há
> `rateMs` atrás e normalizado pelo σ do próprio buffer — por isso a escala é relativa à
> janela e não depende de valores absolutos calibrados. O que fica por afinar são os
> limiares (`deadband`, `cap`) e os pesos.

---

## Estruturas de saída

- **`ScoredTick`** — um tick com os Δ brutos, os contributos por sensor, `rawScore` e
  `score` (EMA). Serve para logging e calibração.
- **`WindowScore`** — resultado final: `bestTimestampMs` (início da janela, ou `nil`),
  `bestScore` e a série completa de `ticks`.

---

## Fluxo resumido

```
buffer (≤180s)
   │
   ├─ Passo 1: Δ de cada sensor vs 5s atrás
   ├─ Passo 2: gate (GPS + velocidade > 2.5 m/s)
   ├─ Passo 3: normaliza pelo σ (só ticks gated)
   ├─ Passo 4: deadband (<0.5σ→0) + cap (>3σ→3σ)
   ├─ Passo 5: aplica peso por sensor
   ├─ Passo 6: soma → rawScore
   ├─ Passo 7: EMA → score
   └─ Passo 8: tick de maior score = início da janela
   │
   ▼
janela [pico → agora] → payload → envio
```
