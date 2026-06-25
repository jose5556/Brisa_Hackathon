# Recolha de Dados por Snapshot Ponderado de Sensores

## Problema

O extractor actual (`SensorWindow.toPayload()`) calcula todos os deltas **dentro da janela de 30 s**. Quando o veículo está underground há mais de 5 minutos, a janela só contém leituras underground — os deltas internos são pequenos (ambiente estável) e o modelo não consegue "ver" que houve uma transição.

O que falta é uma referência ao estado anterior: **o que os sensores mediam quando o veículo ainda estava na rua**.

## Solução: Snapshot Triggered por Variação Ponderada

Quando o peso_sensor total dos sensores excede um limiar, guarda-se um snapshot do buffer **pré-evento** (o estado imediatamente anterior à mudança). Este snapshot serve dois propósitos:

1. **Input do extractor em inferência** — permite calcular deltas cross-contexto (rua→actual) que a janela de 30 s sozinha não consegue
2. **Amostra de treino** — preserva o estado de rua que o buffer deslizante teria descartado

### Fluxo

```
[buffer deslizante em memória]
        ↓
[calcular peso_sensor a cada tick]
        ↓
[peso_sensor > threshold?] → NÃO → continuar
        ↓ SIM
[peso_sensor_efectivo > snapshot_guardado.peso_sensor_efectivo?]
        │                             │
       SIM                           NÃO
        ↓                             ↓
[substituir snapshot]            [ignorar]
        │
        └── snapshot guardado é passado ao toPayload()
            para calcular deltas cross-contexto
```

### Regra de Substituição

Um novo snapshot substitui o anterior apenas se o seu `peso_sensor_efectivo` for maior. O decaimento exponencial garante que snapshots mais antigos enfraquecem continuamente — sem necessidade de cooldown. Uma transição legítima logo a seguir é automaticamente capturada se o seu peso_sensor_efectivo superar o do snapshot existente.

---

## Integração com o Extractor

O snapshot passa a ser um parâmetro opcional de `toPayload()`:

```swift
func toPayload(
    cityBaselinePressure: Double,
    weatherCondition: String,
    streetSnapshot: SensorWindow? = nil   // novo
) -> SensorPayload?
```

Quando `streetSnapshot` está disponível, o extractor calcula features cross-contexto adicionais:

| Feature | Fórmula | Significado |
|---------|---------|-------------|
| `pressureDeltaVsStreet` | `pressureHpa_actual - snapshotPressureHpa` | Queda de pressão desde a rua |
| `magneticDeltaVsStreet` | `magneticMean_actual - snapshotMagneticMean` | Variação do campo magnético desde a rua |
| `gpsAccuracyDeltaVsStreet` | `gpsAccuracyMean_actual - snapshotGpsAccuracyMean` | Degradação do sinal GPS desde a rua |

Quando `streetSnapshot` é `nil` (início de sessão, antes de qualquer transição), as features caem de volta a 0 — compatível com o comportamento actual.

O `SensorRepository` é responsável por passar o `best_snapshot` do `SensorCollector` ao chamar `toPayload()`.

---

## Hierarquia de Pesos (Fibonacci)

Os pesos seguem a sequência de Fibonacci para garantir dominância gradual sem esmagar os sensores secundários. A razão entre pesos consecutivos (~1.618) é mais equilibrada do que potências de 2.

| Rank | Sensor | Peso Fibonacci | Justificação |
|------|--------|---------------|--------------|
| 1 | Pressão barométrica | **8** | Transição rua→subterrâneo produz um delta de pressão físico e consistente (~2–5 hPa para cada 15–40 m de profundidade). É o sinal mais discriminativo e não depende de infraestrutura externa (satélites, rede). |
| 2 | Qualidade GPS / nº satélites | **5** | A perda de sinal GPS é quase imediata ao entrar num espaço fechado. Não requer calibração por local. A degradação do HDOP (horizontal dilution of precision) ou a queda de satélites visíveis é um proxy fiável de "tecto sobre a cabeça". |
| 3 | Velocidade GPS | **3** | O veículo desacelera consistentemente na entrada de um parque (rampa, cancela, curva fechada). Útil como confirmação de transição mas não discriminativo por si só — pode também ocorrer em semáforos ou cruzamentos. |
| 4 | Magnetómetro | **2** | Ambientes subterrâneos com estrutura de betão armado e cabos elétricos alteram o campo magnético. Sinal real mas com elevada variância entre locais diferentes. Usado como reforço secundário, não como gatilho primário. |

---

## Fórmula do Peso Sensor

Para garantir que as unidades físicas diferentes de cada sensor não distorcem os pesos Fibonacci, cada variação é normalizada ao seu range esperado antes de aplicar o peso:

```
peso_sensor = Σ ( peso_fibonacci_i × (Δsensor_i / range_esperado_i) )
```

O resultado é adimensional e os pesos Fibonacci fazem efetivamente o trabalho pretendido.

---

## Decaimento Temporal do Buffer

Um buffer guardado há muito tempo perde relevância como baseline — o contexto pode ter mudado. O score efectivo de um buffer decai exponencialmente com o tempo desde a sua captura:

```
peso_sensor_efectivo = peso_sensor × e^(-λ × t)
```

Onde:
- `t` = segundos desde a captura do snapshot
- `λ` = constante de decaimento (a calibrar)

### Comportamento do Decaimento

A exponencial é a escolha certa porque a perda de relevância é assimétrica: um buffer de 1 minuto atrás é muito mais confiável que um de 5 minutos, mas a diferença entre 8 e 10 minutos já é marginal. O decaimento mais agressivo no início reflecte isso naturalmente.

| λ | Peso a 1 min | Peso a 5 min | Peso a 10 min |
|---|-------------|--------------|---------------|
| 0.005 | 0.74 | 0.22 | 0.05 |
| 0.010 | 0.55 | 0.05 | ~0.00 |
| 0.002 | 0.89 | 0.55 | 0.30 |

> **λ a calibrar com dados de campo.** A questão é: quanto tempo um contexto de rua se mantém estável? Se o carro está parado, mais tempo. Se está em circulação, menos.

### Implicação na Regra de Empate

A regra de empate ("guardar o mais recente") passa a ser uma consequência natural do decaimento — não precisa de ser tratada como caso especial. Dois snapshots com o mesmo peso_sensor bruto terão automaticamente peso_sensor_efectivo diferentes pelo factor `e^(-λ × t)`.

---

## Calibração de Thresholds por Sensor

> **A preencher com dados reais de campo.**  
> Os valores abaixo são estimativas iniciais para arrancar a recolha. Devem ser revistos após as primeiras sessões de dados.

### Pressão Barométrica

| Parâmetro | Valor | Notas |
|-----------|-------|-------|
| Unidade | hPa |  |
| Range esperado (Δ) | `___` hPa | Delta típico rua→subterrâneo |
| Threshold de variação para acionar | `___` hPa | Variação mínima considerada significativa |
| Janela de cálculo do Δ | `___` s | Intervalo sobre o qual se mede a variação |

### Qualidade GPS / Nº Satélites

| Parâmetro | Valor | Notas |
|-----------|-------|-------|
| Unidade | nº satélites ou HDOP |  |
| Range esperado (Δ) | `___` satélites | Queda típica ao entrar em fechado |
| Threshold de variação para acionar | `___` satélites | Queda mínima considerada significativa |
| Janela de cálculo do Δ | `___` s |  |

### Velocidade GPS

| Parâmetro | Valor | Notas |
|-----------|-------|-------|
| Unidade | m/s |  |
| Range esperado (Δ) | `___` m/s | Desaceleração típica na entrada |
| Threshold de variação para acionar | `___` m/s |  |
| Janela de cálculo do Δ | `___` s |  |

### Magnetómetro

| Parâmetro | Valor | Notas |
|-----------|-------|-------|
| Unidade | µT (magnitude do vetor) |  |
| Range esperado (Δ) | `___` µT | Variação típica rua→subterrâneo |
| Threshold de variação para acionar | `___` µT |  |
| Janela de cálculo do Δ | `___` s |  |

---

## Parâmetros Globais do Sistema

| Parâmetro | Valor | Notas |
|-----------|-------|-------|
| peso_sensor mínimo para guardar snapshot | `___` | A calibrar |
| Tamanho do buffer pré-evento a guardar | 30 s | Alinhado com a janela de inferência atual |
| Constante de decaimento temporal λ | `___` | A calibrar com dados de campo |
| Política de substituição | peso_sensor_efectivo > snapshot_guardado | Substitui se o novo evento for mais relevante considerando o decaimento |

---

## Próximos Passos

1. Implementar `streetSnapshot: SensorWindow?` em `toPayload()` e as três features cross-contexto.
2. Expor `best_snapshot` no `SensorCollector` e passar ao `SensorRepository`.
3. Sessões de campo instrumentadas para registar os deltas reais por sensor em transições rua→subterrâneo conhecidas.
4. Preencher a tabela de calibração acima com percentis P10/P50/P90 dos deltas observados.
5. Definir o peso_sensor mínimo global com base nos dados recolhidos.
6. Calibrar λ observando quanto tempo o contexto de rua se mantém estável em diferentes cenários (parado, em circulação).
