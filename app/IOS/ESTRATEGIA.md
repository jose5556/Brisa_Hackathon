# Estratégia de Deteção — Nível de Estacionamento

Como a app deteta se o veículo estacionou ao **nível do solo**, em **subsolo** ou
**acima do solo**.

A ideia central: **encontrar a última leitura de "rua calma"** antes de o carro
entrar na estrutura, **cortar o buffer a partir desse ponto**, e classificar o
nível a partir dos **deltas e dados** dessa janela (a transição inteira, não a
foto do carro já parado).

---

## 1. Ciclo de vida (consumo de bateria)

Os sensores pesados só ligam **durante a condução**. Fora disso, só corre a
deteção de atividade, que é de baixo consumo.

```
   ┌─────────────┐   deteta "em veículo"    ┌──────────────────┐
   │   PARADO    │ ───────────────────────▶ │   A CONDUZIR     │
   │ (a pé/idle) │   (Activity Recognition) │ recolha completa │
   │             │ ◀─────────────────────── │  GPS+Baró+Magn   │
   └─────────────┘   deteta "parou"          └──────────────────┘
       baixo consumo                              │ parou
                                                  ▼
                                         ┌──────────────────┐
                                         │  ANALISA EVENTO  │
                                         │ âncora → features │
                                         └──────────────────┘
```

| Fase | O que corre | Bateria |
|---|---|---|
| Parado / a pé | Só deteção de atividade | mínimo |
| A conduzir | GPS + barómetro + magnetómetro | alto (só enquanto conduz) |
| Estacionou | Acha âncora → corta → classifica → desliga | volta ao mínimo |

---

## 2. A ideia central — cortar na última "rua calma"

A app guarda um **buffer contínuo** das leituras cruas. Quando o carro **pára**
(ou o utilizador carrega no botão), recua-se no buffer **de trás para a frente**
até encontrar a **última leitura de rua calma** — e corta-se aí.

```
   buffer ───────────────────────────────────────────────▶ paragem
   │  rua  rua  rua  [transição: rampa + garagem]  PAROU ✋
   │                ▲
   │                └── ÂNCORA = última leitura CALMA, achada a recuar
   │
   │◀──── JANELA = âncora … paragem = a transição inteira ────▶│
```

- **Porque a transição e não a foto do fim?** Um piso -2 e a rua têm pressões
  absolutas parecidas (a pressão muda com a meteorologia). O que distingue é
  **como** lá chegaste: a descida + o GPS a colapsar. Isso só se vê na transição.

---

## 3. O que é uma leitura "calma"?

Rua aberta = os três sinais em baseline **ao mesmo tempo**:

```
   CALMA  =  magVariance < X     (magnetómetro estável, sem metal à volta)
        AND  speed       > Y     (a andar a sério)
        AND  gps.acc     < Z     (GPS com bom sinal)
```

As três juntas **só acontecem em rua aberta** — debaixo de um teto de betão é
fisicamente impossível ter GPS bom. É isso que torna o ponto de corte nítido.

---

## 4. Como se mede a variância do magnetómetro

A peça menos óbvia. **Variância ≠ diferença entre leituras consecutivas** (essa é
minúscula e ruidosa). Variância = **quão espalhados estão os valores dentro de
uma janela de tempo** (~2 s).

```
   ┌─────────── janela de 2 s ───────────┐
   │ ● ● ● ● ● ● ● ● ● ● ● ● ● ● ● ● ● ●  │  ← ~20 leituras (magnetómetro a 10 Hz)
   └──────────────────────────────────────┘
            calcula 1 variância destas ~20
```

Exemplo (magnitude do campo, µT):

```
   RUA      [48.1, 48.3, 49.0, 48.5, 49.2, ...]  → variância ≈ 0.3   (apertado)
   GARAGEM  [48, 55, 42, 63, 38, 70, 45, ...]    → variância ≈ 95    (espalhado)
```

Cada passo individual muda pouco, mas o **espalhamento do conjunto** separa
0.3 de 95. A janela transforma muitos passos pequenos num número grande e claro.

> Variância = média dos `(valor − média)²`. Pequena = tudo junto (rua);
> grande = tudo disperso (garagem com pilares/vigas/carros).

---

## 5. Sincronizar os sinais

`speed` e `gps.acc` **já vêm juntos** no mesmo `GpsReading` → já sincronizados.
Só o magnetómetro (stream separado, 10 Hz) precisa de alinhamento.

**Técnica: o GPS é o relógio.** Para cada leitura GPS no instante `t`, a variância
do magnetómetro é calculada sobre a **janela que termina em `t`**.

```
   GPS  │   ●          ●          ●          ●        (relógio, ~1 Hz)
        │   t0         t1         t2         t3
   Mag  │●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●         (10 Hz, à boleia)
        │   └─janela 2s─┘        └─janela 2s─┘
```

Em cada batida do GPS: `(speed, acc)` vêm com ele; `magVar = variância da janela
[t−2s, t]`. Os três ficam no mesmo instante, sem reamostragem.

---

## 6. Os valores de comparação (X, Y, Z)

Dois são físicos e fixos; o do magnetómetro é relativo.

| Threshold | Tipo | Valor | Porquê |
|---|---|---|---|
| **Z** — `gps.acc < 15 m` | fixo físico | 15 m | a conduzir a accuracy é 3–15 m; acima é obstruído |
| **Y** — `speed > 2.5 m/s` | fixo físico | ~9 km/h | acima disto é "a andar"; abaixo o Doppler fica ruidoso |
| **X** — `magVar < k·base` | **relativo** | k ≈ 2.5 | a escala da variância muda com dispositivo/carro/região |

**Porque X é relativo:** o campo absoluto varia por região (25–65 µT) e a escala
da variância depende do sensor e do próprio carro (caixa de aço). Um `X` fixo
funciona num carro e falha no seguinte.

**O baseline (`base`)** = mediana da variância durante **condução limpa recente**
(últimos ~30 s com `acc<15` e `speed>2.5`). Mantém-se a rolar enquanto conduzes —
quando paras, já está pronto. Sem condução limpa suficiente → defaults +
**baixa confiança**.

---

## 7. O corte e as redes de segurança

```
   âncora = última leitura calma (a recuar da paragem)
   (opcional: âncora −= N segundos de margem)

   janela = buffer[ âncora … paragem ]

   redes de segurança:
     • duração mínima ~15 s   (se a âncora ficar perto demais)
     • duração máxima ~90 s   (teto, evita janelas gigantes)
```

---

## 8. Classificar o nível — ladeira vs garagem

Achada e cortada a janela, calculam-se os **deltas/features**. A distinção
crítica (sobretudo no Porto/Lisboa): **descer uma ladeira e descer para uma
garagem dão o mesmo sinal no barómetro.** O que os separa é o **GPS**.

```
                  A pressão SOBE (desceu)?
                          │
              ┌───────────┴───────────┐
              ▼                        ▼
       GPS continua BOM?         GPS COLAPSOU?
              │                        │
              ▼                        ▼
        ┌──────────┐            ┌──────────────┐
        │  LADEIRA │            │   GARAGEM    │
        │ (= solo) │            │ (= subsolo)  │
        └──────────┘            └──────────────┘
   + magnetómetro normal    + magnetómetro turbulento
```

- **Pressão SOBE + GPS cego** → desceu coberto → **underground**
- **Pressão DESCE + GPS cego** → subiu coberto → **above** (silo)
- **Pressão muda + GPS nunca cegou** → **street level** (ladeira/rua)

> **Regra de ouro:** a pressão diz **que houve descida/subida**; o GPS diz **se
> foi ao ar livre ou debaixo de um teto**.

---

## 9. Pipeline completo

```
 [Activity Recognition]  ──▶  deteta condução
          │
          ▼
 [SensorCollector]  ──▶  buffer contínuo (GPS, barómetro, magnetómetro)
          │              + baseline rolling da "rua calma"
          ▼
 [Paragem / botão]  ──▶  marca o FIM da janela
          │
          ▼
 [AnchorDetector]  ──▶  recua no buffer até à última leitura CALMA
          │              (magVar<X E speed>Y E acc<Z) → corta
          ▼
 [Feature Extractor]  ──▶  deltas da janela cortada:
          │                 - pressure_delta / slope (subiu? desceu?)
          │                 - gps_lost_ratio (GPS colapsou?)
          │                 - magnetic_field_variance ...
          ▼
 [API /predict]  ──▶  modelo (RandomForest)
          │
          ▼
   { "classification": "underground", "confidence": 0.92 }
```

---

## 10. Algoritmo (pseudo-código)

```swift
// Dispara na paragem (botão ou speed≈0 sustentado).
func findAnchorAndCut(stopMs: Int64) -> SensorWindow {

    let base = currentBaseline()          // mediana da condução limpa recente
    let X = 2.5 * base.magVar             // relativo
    let Y = 2.5                           // m/s   (fixo)
    let Z = 15.0                          // m     (fixo)

    // GPS é o relógio; recua da paragem
    var anchorMs = stopMs
    for gps in allGpsReadings.reversed() where gps.timestampMs <= stopMs {
        let t      = gps.timestampMs
        let magVar = magVariance(endingAt: t, readings: allMagneticReadings)

        let éCalma = magVar < X
                  && gps.speedMps > Y
                  && Double(gps.accuracyMeters) < Z

        if éCalma { anchorMs = t; break }    // última rua calma → âncora
    }

    anchorMs -= N_BACKOFF                     // margem de segurança
    anchorMs = clampDuration(anchorMs, stopMs, min: 15_000, max: 90_000)

    return SensorWindow(
        gpsReadings:      allGpsReadings.filter      { $0.timestampMs >= anchorMs && $0.timestampMs <= stopMs },
        pressureReadings: allPressureReadings.filter { $0.timestampMs >= anchorMs && $0.timestampMs <= stopMs },
        magneticReadings: allMagneticReadings.filter { $0.timestampMs >= anchorMs && $0.timestampMs <= stopMs }
    )
}
```

---

## 11. Recolha em background (iOS vs Android)

| | iOS | Android |
|---|---|---|
| Permissão | Localização **"Always"** | `ACCESS_BACKGROUND_LOCATION` |
| Mecanismo | Background Mode "Location updates" | **Foreground Service** + notificação |
| Deteção de condução | `CMMotionActivityManager` (automotive) | Activity Recognition (`IN_VEHICLE`) |

> Ligar os sensores pesados só durante a condução é o que mantém a bateria sob
> controlo.

---

## Resumo numa frase

> **Mantém o baseline da rua enquanto conduz, recua no buffer até à última leitura
> calma (magnetómetro estável + a andar + GPS bom), corta aí, e usa o colapso do
> GPS para separar uma ladeira de uma garagem.**
