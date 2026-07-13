#!/usr/bin/env bash
# Corre o TrajectorySimulator standalone (fora do iOS), reutilizando o código
# de produção do score (SensorScore.swift) e do payload (SensorData.swift).
#
# Escreve o report em app/IOS/swift/trajectory_report.md e imprime só o
# resumo no terminal.
#
#   Uso:  ./Tools/run_trajectory_sim.sh [flags]      (a partir de qualquer lado)
#
#   Flags (passadas ao simulador):
#     --api              envia o payload de cada janela à API e regista a resposta
#     --scenario <A..N>  corre só esse cenário
#     --seed <1..5>      corre só essa repetição (1 = primeiro seed)
#     --ip <x.x.x.x>     IP do servidor da API (por omissão o de ServerConfig)
#
#   Ex. de UM só envio:  ./Tools/run_trajectory_sim.sh --api --scenario A --seed 1
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="$(mktemp -d)/brisa-sim"

# TrajectorySimulator.swift usa @main, por isso compila diretamente em conjunto
# com o código de produção (não precisa do truque de renomear para main.swift).
swiftc Tools/TrajectorySimulator.swift \
       Sources/data/SensorData.swift \
       Sources/sensor/SensorScore.swift \
       Sources/network/SensorApiClient.swift \
       -o "$OUT"

"$OUT" "$@"
