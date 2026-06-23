# Dataset com CARLA — Estudo e Considerações

## Contexto

O objetivo é gerar um dataset sintético usando o simulador CARLA para treinar o classificador de contexto vertical de estacionamento do projeto Brisa. Os três cenários alvo são:

- **Subterrâneo** — estacionamento abaixo do nível da rua
- **Nível 0** — estacionamento na rua, a céu aberto
- **Elevado** — estacionamento em estrutura multi-piso acima do solo

---

## Comparativo: O que dá e o que não dá para capturar no CARLA

| Dado / Fenômeno | O que DÁ para pegar (fácil e imediato) | O que NÃO DÁ para pegar (limitações do simulador) |
|---|---|---|
| **Acelerômetro e Giroscópio (IMU)** | A inclinação exata do carro ao subir/descer rampas. Perfeito para o modelo aprender que "carro inclinado por X segundos = mudança de nível". | O padrão de vibração específico de pisos de concreto de garagem, lombadas de borracha ou juntas de dilatação metálicas. |
| **Orientação (Magnetômetro / Bússola)** | O movimento espiral contínuo (curvas fechadas sequenciais) típico de estruturas de estacionamento vertical. | **Distorção magnética real.** Garagens são gaiolas de metal e concreto armado. No mundo real, o magnetômetro enlouquece. No CARLA, ele será perfeito demais. |
| **Pressão Barométrica** | Uma transição perfeita e contínua de elevação usando a coordenada Z como *ground truth* para calcular a pressão teórica. | Flutuações reais de pressão causadas por ventilação artificial forte (exaustores de subsolo) ou mudanças climáticas dinâmicas durante a coleta. |
| **Sinal de GPS (Nível 0 e Elevado)** | Coordenadas precisas e velocidade enquanto o carro estiver sob céu aberto em rodovias ou viadutos. | O erro de *multipath* (sinal rebatendo em pilares/prédios próximos). O GPS do CARLA é nativamente limpo e exato, a menos que ruído artificial seja injetado. |
| **Sinal de GPS (Subterrâneo)** | Um corte brusco e total do sinal, desde que o script Python desligue o sensor ou zere os dados artificialmente. | A transição de degradação suave. Na vida real, o GPS perde precisão aos poucos na rampa de acesso antes de sumir. No script simples, o corte costuma ser binário (ligado/desligado). |
| **Velocidade e Trajetória** | Comportamento natural de aceleração e frenagem gerado pelo Autopilot do CARLA. | A velocidade extremamente lenta e as manobras de "para e avança" típicas de quem está procurando vaga em um subsolo apertado. |

---

## Cruzamento com os sensores ativos no app Brisa

O app iOS coleta GPS, barômetro e magnetômetro. O acelerômetro está **desativado** no `SensorCollector.swift`. O comparativo real para o projeto é:

| Sensor | Usado no app? | Qualidade no CARLA | Risco para o modelo |
|---|---|---|---|
| GPS (posição, precisão, velocidade) | ✅ | Limpo demais — sem multipath | Médio |
| GPS (perda de sinal / `gps_lost_ratio`) | ✅ | Corte binário, não gradual | **Alto** |
| Barômetro | ✅ | Perfeito — sem ruído de ventilação | Baixo |
| Magnetômetro | ✅ | Sem distorção real de garagem | **Alto** |
| Acelerômetro / IMU | ❌ desativado | — | — |

---

## Riscos críticos para o modelo

### 1. Perda de GPS binária vs. gradual

O feature `gps_lost_ratio` vai aprender que subterrâneo = 100% de sinal perdido. Na vida real, a rampa de descida produz valores entre 0.3 e 0.7, que é justamente a zona de decisão mais difícil para o classificador.

### 2. Magnetômetro "perfeito demais"

Os features `magnetic_field_variance` e `magnetic_field_delta` são os que mais distinguem garagem subterrânea no mundo real. No CARLA, esses valores serão baixos e estáveis — o modelo não aprenderá a distorção causada por concreto armado e estruturas metálicas.

### 3. Velocidade irreal no cenário elevado

Usar viadutos ou rodovias do CARLA para simular estacionamento elevado faz o modelo associar "elevado" com alta velocidade em linha reta. Na vida real, estacionamentos elevados têm movimentação lenta e muitas curvas.

---

## Impacto no modelo de ML

**Positivo:** O dataset sintético é suficiente para um *Proof of Concept*. O modelo aprende as "regras de ouro" rapidamente:

- Pressão aumenta + GPS some + altitude desce → **Subterrâneo**
- GPS perfeito + pressão estável + carro reto → **Nível da Rua**
- Pressão diminui + altitude sobe → **Elevado**

**Ponto de atenção:** O modelo treinado só no CARLA terá dificuldade em generalizar para dados reais nas zonas de transição (rampa de entrada/saída), onde os sinais são ambíguos e graduais.

---

## Mitigação recomendada

Para tornar o dataset mais realista sem alterar a simulação, aplicar **ruído sintético pós-coleta** antes do treino:

- `gps_lost_ratio` no cenário subterrâneo: substituir corte binário por distribuição Beta assimétrica (0.3–1.0) para simular degradação gradual na rampa.
- `magnetic_field_variance` e `magnetic_field_delta` no cenário subterrâneo: multiplicar por fator aleatório (3×–8×) para simular distorção de garagem.
- Velocidade no cenário elevado: limitar o Autopilot do CARLA a ≤ 15 km/h com curvas frequentes para imitar movimentação interna de garagem.

---

## Conclusão

O CARLA com mapas prontos é uma abordagem viável e rápida para gerar um dataset de prova de conceito. Os cenários de nível 0 e subterrâneo são bem representados. O cenário elevado exige mais cuidado na configuração da simulação. A maior fragilidade é a perfeição do sinal GPS e a ausência de distorção magnética — ambas mitigáveis com injeção de ruído controlado no pós-processamento.

---

## Configuração no CARLA — Como Seria Implementado

### Pré-requisitos

- CARLA 0.9.13+ instalado e rodando
- Python 3.8+ com os pacotes `carla`, `pandas` e `numpy`
- Conexão via cliente Python na porta padrão 2000

---

### 1. Seleção de mapas por cenário

| Cenário | Mapa recomendado | Justificativa |
|---|---|---|
| **Nível 0** | `Town01`, `Town02`, `Town03` | Ruas urbanas a céu aberto, GPS limpo |
| **Elevado** | `Town04` | Possui viaduto / overpass com estrutura elevada utilizável |
| **Subterrâneo** | Mapa customizado via OpenDRIVE | Nenhum mapa padrão do CARLA tem túnel subterrâneo nativo |

O script de coleta precisa de uma etapa de inicialização que conecta ao servidor CARLA, carrega o mapa do cenário desejado e spawna o veículo em um ponto de partida adequado.

---

### 2. Sensores disponíveis no CARLA

O CARLA **não possui barômetro nem magnetômetro nativos**. Esses dados precisam ser derivados.

| Sensor do app Brisa | Equivalente no CARLA | Método |
|---|---|---|
| GPS (`CLLocationManager`) | `sensor.other.gnss` | Nativo — attach direto ao veículo |
| Barômetro (`CMAltimeter`) | ❌ não existe | Calcular a partir da coordenada Z do veículo |
| Magnetômetro (`CMMotionManager`) | ❌ não existe | Simular com ruído baseado no cenário |
| Acelerômetro (desativado no app) | `sensor.other.imu` | Nativo, mas não necessário para este projeto |

---

### 3. Sensor GNSS (GPS)

**Onde implementar:** etapa de setup, antes do loop de coleta.

**Lógica:**
- Criar o sensor GNSS e attachá-lo ao veículo
- Configurar parâmetros de ruído (desvio padrão de latitude, longitude e altitude) para simular a imprecisão real de multipath urbano
- Registrar um callback que salva cada leitura (latitude, longitude, altitude, timestamp) em um buffer

---

### 4. Barômetro simulado

**Onde implementar:** dentro do loop de coleta, a cada amostra.

**Lógica:**
- Ler a coordenada Z do veículo (em metros, onde Z=0 é o nível do solo do mapa e valores negativos indicam subterrâneo)
- Aplicar a fórmula barométrica padrão para converter altitude em pressão (hPa). Aproximação: cada metro de altitude corresponde a ~0.12 hPa de variação
- Usar como `city_baseline_pressure` um valor fixo representando a pressão ao nível da rua, para que o `pressure_delta_hpa` seja calculável

---

### 5. Perda de GPS no subterrâneo

**Onde implementar:** pós-processamento de cada leitura do GNSS, dentro do loop.

**Lógica:**
- Ler a coordenada Z do veículo a cada amostra
- Se Z estiver acima do threshold (ex: -1m), manter a leitura GPS normal
- Se Z estiver abaixo do threshold, calcular um ratio de perda proporcional à profundidade (ex: perda total aos 10m)
- Abaixo do ratio crítico: marcar a leitura como sem sinal e degradar a precisão para um valor alto (999m)
- Na zona intermediária (rampa): degradar a precisão gradualmente e sortear aleatoriamente se o sinal existe ou não, para simular a transição suave

Isso resolve o problema do corte binário e gera `gps_lost_ratio` realista para as amostras de transição.

---

### 6. Magnetômetro simulado

**Onde implementar:** dentro do loop de coleta, a cada amostra.

**Lógica:**
- Definir um valor base de campo magnético típico da região (em µT, em torno de 48 µT para Europa)
- Adicionar ruído gaussiano com escala variável por cenário:
  - **Subterrâneo:** escala alta (3×–8× o ruído base) — simula distorção de concreto armado e estruturas metálicas
  - **Elevado:** escala média (1×–3×) — alguma interferência de estrutura metálica
  - **Nível 0:** escala baixa (ruído mínimo) — campo estável a céu aberto
- Registrar a magnitude resultante como `magnetic_field_ut` para cada timestamp

---

### 7. Controle de velocidade por cenário

**Onde implementar:** etapa de setup de cada cenário, após o spawn do veículo.

**Lógica:**
- Ativar o Autopilot do CARLA com o Traffic Manager
- Configurar a velocidade máxima desejada por cenário:
  - Nível 0: ~30 km/h (tráfego urbano normal)
  - Elevado: ~15 km/h (movimentação lenta de garagem)
  - Subterrâneo: ~10 km/h (manobras lentas em espaço confinado)
- Isso garante que o modelo não aprenda que "elevado = alta velocidade"

---

### 8. Loop de coleta e geração do CSV

**Onde implementar:** script principal.

**Lógica geral do loop:**
1. Para cada cenário (nível 0 / elevado / subterrâneo):
   - Carregar o mapa, spawnar o veículo, iniciar sensores e Autopilot
   - Repetir N vezes (ex: 200 amostras por cenário):
     - Aguardar a janela de coleta (30 segundos, igual ao app iOS)
     - Agregar as leituras do buffer GPS (mean, max, delta, lost ratio, speed)
     - Calcular barômetro e magnetômetro simulados
     - Registrar a linha com o label do cenário (`street_level`, `elevated`, `underground`)
   - Destruir o veículo e limpar os sensores
2. Salvar todas as linhas em `carla_dataset.csv` com os mesmos nomes de features do `SensorPayload` do app iOS

Manter os nomes de features idênticos ao `SensorPayload` é crítico para que o modelo treinado no dataset CARLA seja compatível com os dados reais do app sem nenhuma transformação adicional.

---

### 9. O que ainda precisa de pesquisa


> 1. **Mapas underground nativos:** existe algum mapa ou asset oficial do CARLA (ou do `carla-simulator/scenario_runner`) com túnel subterrâneo ou geometria abaixo do nível Z=0? Ou a única opção é criar um mapa customizado com o RoadRunner / OpenDRIVE?
>
> 2. **Magnetômetro no CARLA:** o CARLA 0.9.14+ adicionou algum sensor de campo magnético nativo? Ou continua sendo necessário simulá-lo manualmente com base na posição do veículo?
>
> 3. **Perda de sinal GNSS por geometria:** existe alguma forma nativa de configurar o `sensor.other.gnss` para perder sinal automaticamente ao entrar em um tunnel (baseado na geometria do mapa)? Ou isso precisa ser tratado manualmente verificando a coordenada Z no script Python?
>
> 4. **Scenario Runner:** existe algum cenário pronto no `carla-simulator/scenario_runner` que simule entrada e saída de garagem subterrânea que possa ser reutilizado?
