#!/usr/bin/env bash
# Corre o ScoreCsvRunner standalone (fora do iOS), reutilizando o código de
# produção do score (SensorScore.swift) e do payload (SensorData.swift).
#
# Calcula o score por segundo sobre um CSV de leituras REAIS e mostra onde o
# algoritmo colocaria o baseline/pico, comparando com o EXPECTED do ficheiro.
#
#   Uso:
#     ./Tools/run_csv.sh                       # usa o CSV por omissão em Tools/data
#     ./Tools/run_csv.sh Tools/data/xpto.csv   # usa o CSV indicado
set -euo pipefail
cd "$(dirname "$0")/.."

CSV="${1:-Tools/data/street.csv}"

if [[ ! -f "$CSV" ]]; then
    echo "⚠ CSV não encontrado: $CSV" >&2
    exit 1
fi

OUT="$(mktemp -d)/brisa-csv"

# ScoreCsvRunner.swift usa @main, por isso compila diretamente em conjunto com o
# código de produção (não precisa do truque de renomear para main.swift).
swiftc Tools/ScoreCsvRunner.swift \
       Sources/data/SensorData.swift \
       Sources/sensor/SensorScore.swift \
       -o "$OUT"

"$OUT" "$CSV"
