# Custo-Benefício Energético — Recolha de Sensores iOS

Análise do que está implementado hoje e o que não faz sentido do ponto de vista energético, dado o objectivo do modelo: **classificar o nível vertical do veículo** (street level / underground / above).

---

## O que o modelo realmente precisa

| Sensor | Para que serve no modelo | Importância |
|--------|--------------------------|-------------|
| Barómetro | Pressão absoluta e variação — sinal directo de altitude. 1 piso ≈ 1.2 hPa | Alta |
| Magnetómetro | Assinatura magnética de estruturas de betão armado e metal (parques subterrâneos perturbam o campo) | Alta |
| GPS | Coordenadas para buscar `cityBaselinePressure` via Open-Meteo; features de suporte (`gps_lost_ratio`, velocidade) | Baixa |

---

## O que não faz sentido hoje

### 1. GPS com `kCLLocationAccuracyBest`

```swift
locationManager.desiredAccuracy = kCLLocationAccuracyBest
```

**Custo:** modo de maior consumo do GPS — radio activo continuamente, tri-lateration de alta frequência.

**Benefício real para o modelo 1 (nível vertical):** baixo. As features GPS do modelo 1 (`gps_accuracy_mean`, `gps_speed_mean`, `gps_lost_ratio`) não ficam mais ricas com precisão de 3 m vs. 10 m. O veículo está estacionado e o barómetro é o sinal dominante.

**Benefício real para o modelo 2 (zona tarifada):** alto. Detectar se o veículo está dentro de um polígono de zona paga de estacionamento requer geofencing com precisão de metros. A fronteira entre zona tarifada e não tarifada pode ser uma rua — `kCLLocationAccuracyBest` é a escolha correcta para este caso.

**Conclusão:** manter `kCLLocationAccuracyBest`. O custo energético justifica-se pelo modelo 2, e recolher dados de alta precisão desde o início garante que o dataset de treino é válido para ambos os modelos.

---

### 2. GPS com `distanceFilter = kCLDistanceFilterNone`

```swift
locationManager.distanceFilter = kCLDistanceFilterNone
```

**Custo:** o sistema reporta cada actualização GPS independentemente do deslocamento, mesmo que o carro não se tenha movido 1 cm.

**Benefício real para o modelo 1 (nível vertical):** nenhum. O veículo está estacionado. O resample timer a 1 Hz já garante que a janela deslizante fica populada.

**Benefício real para o modelo 2 (zona tarifada):** potencialmente relevante para confirmar que o veículo não se deslocou durante a janela de recolha. No entanto, o resample timer existente já cobre este caso — `kCLDistanceFilterNone` continua a ser redundante.

**O que precisamos de facto:** o resample timer a 1 Hz é a abordagem mais eficiente. Um `distanceFilter` de 5–10 m seria suficiente para detectar qualquer micro-deslocamento relevante, deixando o timer tratar do caso estático.

---

### 3. Magnetómetro via `DeviceMotion` em vez de sensor directo

```swift
motionManager.startDeviceMotionUpdates(using: .xMagneticNorthZVertical)
```

**Custo:** `DeviceMotion` activa internamente o pipeline de fusão sensorial da Apple — acelerómetro + giroscópio + magnetómetro a correr em conjunto, mesmo com o acelerómetro desativado no nosso código. O iOS usa os três para produzir o campo magnético calibrado.

**Benefício real para o modelo:** o campo magnético calibrado (sem bias) é genuinamente mais valioso para treino — a assinatura de um parque subterrâneo é mais consistente e reproduzível com dados limpos. Este é o único caso onde o custo extra **se justifica**.

**Conclusão:** manter `DeviceMotion` é a decisão correcta para a qualidade do modelo. O custo energético é um trade-off consciente em favor de dados melhores.

---

### 4. Frequência do magnetómetro a 10 Hz

```swift
motionManager.deviceMotionUpdateInterval = 0.1   // 10 Hz
```

**Custo:** 10 amostras por segundo durante 30 segundos = 300 amostras de magnetómetro por janela.

**Benefício real para o modelo:** a assinatura magnética de um ambiente (subterrâneo vs. superfície) é estável — não muda a 10 Hz. As features calculadas (`magnetic_field_mean`, `magnetic_field_variance`, etc.) sobre 300 amostras vs. 30 amostras têm diferença estatística mínima para um campo que varia lentamente.

**O que precisamos de facto:** 1 Hz seria suficiente para capturar a assinatura magnética do ambiente com boa representatividade estatística, com 10× menos custo energético no pipeline de fusão.

---

## Resumo

| Item | Custo energético | Benefício para o modelo | Decisão recomendada |
|------|-----------------|------------------------|---------------------|
| `kCLLocationAccuracyBest` | Alto | Alto para modelo 2 (geofencing zona tarifada) | Manter |
| `distanceFilter = None` | Médio | Baixo (resample timer já cobre) | Usar 5–10 m |
| `DeviceMotion` (sensor fusion) | Médio | Alto — dados magnéticos calibrados | Manter |
| Magnetómetro a 10 Hz | Médio | Baixo — campo magnético varia lentamente | Baixar para 1 Hz |

---

## Conclusão

A configuração de recolha de sensores — frequência de amostragem, duração da janela, sensores activos — tem que ser **idêntica entre a fase de recolha de dados para treino e a inferência em produção**. Se os parâmetros variarem, as features agregadas sobre a janela (médias, variâncias, deltas) terão distribuições diferentes, e o modelo aprenderá a classificar dados que nunca verá em produção, tornando-o impreciso.

Por isso, qualquer decisão sobre frequência ou duração não é uma optimização isolada — é uma escolha de arquitectura que se fixa uma vez e se mantém consistente em ambos os contextos.

Dentro dessa restrição, as únicas optimizações válidas são:

- **`distanceFilter` de `None` para 5–10 m** — não afecta as features, o resample timer já cobre o veículo estático.
- **`kCLLocationAccuracyBest` e `DeviceMotion`** — manter, pois a qualidade dos dados tem impacto directo nos dois modelos.
- **Frequência do magnetómetro** — a decisão (10 Hz ou 1 Hz) deve ser tomada uma vez, implementada, e igual em treino e produção. Mudar só em produção invalida o modelo treinado.

