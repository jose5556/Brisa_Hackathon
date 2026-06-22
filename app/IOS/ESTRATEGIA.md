# Estratégia de Deteção — Nível de Estacionamento

Como a app deteta se o veículo estacionou ao **nível do solo**, em **subsolo** ou
**acima do solo**, recolhendo dados durante a condução e analisando a **transição**
(a entrada/descida), não apenas o instante parado.

---

## 1. Ciclo de vida (consumo de bateria)

Os sensores pesados só ligam **durante a condução**. Fora disso, só corre a
deteção de atividade, que é de baixo consumo.

```
   ┌─────────────┐   deteta "em veículo"   ┌──────────────────┐
   │   PARADO    │ ──────────────────────▶ │   A CONDUZIR     │
   │ (a pé/idle) │   (Activity Recognition) │ recolha completa │
   │             │ ◀────────────────────── │  GPS+Baró+Magn   │
   └─────────────┘   deteta "parou"         └──────────────────┘
       baixo consumo                              │ estabilizou
                                                  ▼
                                         ┌──────────────────┐
                                         │  ANALISA EVENTO  │
                                         │ features → modelo│
                                         └──────────────────┘
```

| Fase | O que corre | Bateria |
|---|---|---|
| Parado / a pé | Só deteção de atividade | mínimo |
| A conduzir | GPS + barómetro + magnetómetro | alto (só enquanto conduz) |
| Estacionou | Captura transição → analisa → desliga | volta ao mínimo |

---

## 2. A janela do "evento" — início e fim

A app guarda um **buffer contínuo (~3 min)**. O **fim** marca-se em tempo real
(quando o sinal estabiliza); o **início** marca-se a posteriori, recuando no
buffer até ao último "ponto limpo de rua".

```
  pressão
    │                                   ┌──────── estabilizou (FIM) ✂️
    │                              ┌────┘   variância↓ e velocidade≈0
    │                         ┌────┘
    │                    ┌────┘   ← a descer a rampa (transição)
    │   ─────────────────┘
    │   rua normal       ▲
    │                    │
    └────────────────────┼──────────────────────────────▶ tempo
                         INÍCIO (baseline)
                  último ponto com GPS bom + a andar,
                  antes de algo começar a mudar

   │◀───────── JANELA DO EVENTO = a transição inteira ──────────▶│
```

- **Início (baseline):** último instante com GPS bom, em movimento, pressão plana.
- **Fim:** pressão estável + velocidade ≈ 0 durante ~5s seguidos.
- **Redes de segurança:** duração mínima (~15s) e timeout máximo (~90s).

---

## 3. O problema das ladeiras (Porto/Lisboa)

Descer uma ladeira e descer para uma garagem **dão o mesmo sinal no barómetro**.
O que os distingue é o **GPS**: ao ar livre mantém-se; debaixo de um teto, morre.

```
                  A pressão SOBE (desceu)?
                          │
              ┌───────────┴───────────┐
              ▼                        ▼
       GPS continua BOM?         GPS COLAPSOU?
       altitude GPS              barómetro mexe,
       acompanha                 GPS não confirma
              │                        │
              ▼                        ▼
        ┌──────────┐            ┌──────────────┐
        │  LADEIRA │            │   GARAGEM    │
        │ (= solo) │            │ (= subsolo)  │
        └──────────┘            └──────────────┘
   + magnetómetro normal    + magnetómetro distorcido
                            + rampa em espiral (bússola gira)
```

> **Regra de ouro:** a pressão diz **que houve descida**; o GPS diz **se foi ao ar
> livre ou debaixo de um teto**. Só conta como "descida coberta" a variação de
> pressão que acontece **depois de o GPS ficar cego**.

---

## 4. Pipeline completo

```
 [Activity Recognition]  ──▶  deteta condução
          │
          ▼
 [SensorCollector]  ──▶  buffer contínuo (GPS, barómetro, magnetómetro)
          │                 - GPS sem distanceFilter (leituras contínuas)
          │                 - fecho por estabilização
          ▼
 [Deteção de evento]  ──▶  marca INÍCIO (recua no buffer) e FIM (estabiliza)
          │
          ▼
 [Feature Extractor]  ──▶  calcula features da TRANSIÇÃO:
          │                 - pressure_change_after_gps_loss
          │                 - gps_baro_altitude_agreement
          │                 - gps_quality_degradation
          │                 - magnetic_field_variance ...
          ▼
 [API /predict]  ──▶  modelo (gradient-boosted trees)
          │
          ▼
   { "classification": "underground",
     "confidence": 0.92 }
```

---

## 5. Recolha em background (iOS vs Android)

Para recolher enquanto o utilizador conduz, é a **localização** que mantém a app
viva; os outros sensores vão à boleia.

| | iOS | Android |
|---|---|---|
| Permissão | Localização **"Always"** | `ACCESS_BACKGROUND_LOCATION` |
| Mecanismo | Background Mode "Location updates" + `allowsBackgroundLocationUpdates` | **Foreground Service** + notificação persistente |
| Sinal visível | Barra/seta azul | Notificação persistente |
| Deteção de condução | `CMMotionActivityManager` (automotive) | Activity Recognition API (`IN_VEHICLE`) |

> Possível em ambos, mas exige **permissão especial** (recusável pelo utilizador) e
> **indicador visível**. Ligar os sensores pesados só durante a condução é o que
> mantém a bateria sob controlo.

---

## Resumo numa frase

> **Liga os sensores só ao conduzir, filma a transição (não a foto do fim),
> ancora a pressão à última leitura de rua, e usa o colapso do GPS para separar
> uma ladeira de uma garagem.**
