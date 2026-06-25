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

## 6. DADOS EXTRAIDOS

LATITUDE
LONGITUTE

## magnetometro

magnetic_field_mean (intensidade média)

Ao ar livre, longe de estruturas, o campo magnético terrestre é relativamente estável (varia por região, mas tipicamente ~25-65 µT, dependendo da latitude).
Dentro de uma garagem com pilares de betão armado, vigas metálicas, portões de aço, etc., essa intensidade tende a cair (o metal "absorve"/desvia linhas de campo) ou, em alguns pontos, a subir bruscamente (perto de uma viga de aço, por exemplo). Na prática, o efeito dominante observado é geralmente atenuação/queda quando comparado ao baseline de céu aberto.
Em street level, a leitura tende a ficar mais próxima do "ruído ambiente normal" (sem grandes desvios).

magnetic_field_variance (variância dentro da janela)

Isto é talvez o sinal mais útil do magnetómetro para o seu caso, porque não depende de saber o baseline absoluto (que varia por região/latitude e é difícil de calibrar globalmente).
Em ambiente aberto (rua), o campo é relativamente homogéneo → variância baixa.
Dentro de uma garagem, o carro se movendo entre pilares, perto de portões metálicos, outros carros estacionados ao lado (massas metálicas grandes) → o campo varia muito ponto a ponto → variância alta.
Ou seja: variância alta = "ambiente estruturalmente complexo/metálico", o que é um proxy razoável para "estou dentro de um parking", independente de ser underground ou above ground.

magnetic_field_delta (entre primeira e última leitura da janela)

Captura a transição: se o carro entrou na estrutura durante a janela, a leitura do início (ainda na rua) vai ser diferente da leitura do fim (já dentro). É mais um sinal de "evento de transição" do que de "estado estacionário".
Isto é mais relevante para a Camada 1 (detecção do momento) do que para a Camada 2 (classificação do nível já parado) — porque uma vez já estacionado e parado, início e fim da janela vão captar leituras parecidas (mesmo ambiente), então o delta tende a zero mesmo estando dentro da garagem.

## GPS/GNSS

## Resumo numa frase

> **Liga os sensores só ao conduzir, filma a transição (não a foto do fim),
> ancora a pressão à última leitura de rua, e usa o colapso do GPS para separar
> uma ladeira de uma garagem.**
