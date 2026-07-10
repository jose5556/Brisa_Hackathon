#!/usr/bin/env bash
# Corre o TrajectorySimulator standalone (fora do iOS), reutilizando o código
# de produção do score (SensorScore.swift) e do payload (SensorData.swift).
#
# Escreve o report em app/IOS/swift/trajectory_report.md e imprime só o
# resumo no terminal.
#
#   Uso:  ./Tools/run_simulator.sh      (a partir de app/IOS/swift ou de qualquer lado)
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="$(mktemp -d)/brisa-sim"

# TrajectorySimulator.swift usa @main, por isso compila diretamente em conjunto
# com o código de produção (não precisa do truque de renomear para main.swift).
swiftc Tools/TrajectorySimulator.swift \
       Sources/data/SensorData.swift \
       Sources/sensor/SensorScore.swift \
       -o "$OUT"

"$OUT"
