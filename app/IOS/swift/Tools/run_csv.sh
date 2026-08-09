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
#     ./Tools/run_csv.sh --all                 # corre TODOS os CSVs de Tools/data
#                                              # com --api (payload + resposta ml1),
#                                              # 1 s de intervalo entre envios
#
#   Flags (passadas ao runner):
#     --api            envia o payload da janela recortada à API e imprime a resposta
#     --ip <x.x.x.x>   IP do servidor da API (por omissão o de ServerConfig)
#
#   Ex.:  ./Tools/run_csv.sh Tools/data/underground.csv --api --ip 100.121.113.91
#   Ex.:  ./Tools/run_csv.sh --all --ip 100.121.113.91
set -euo pipefail
cd "$(dirname "$0")/.."

# Modo --all: corre todos os CSVs de Tools/data com --api.
ALL=0
if [[ $# -ge 1 && "$1" == "--all" ]]; then
    ALL=1
    shift
fi

# 1.º argumento é o CSV se não começar por "-"; o resto são flags do runner.
CSV="Tools/data/above.csv"
if [[ $ALL -eq 0 && $# -ge 1 && "${1:0:1}" != "-" ]]; then
    CSV="$1"
    shift
fi

if [[ $ALL -eq 0 && ! -f "$CSV" ]]; then
    echo "⚠ CSV não encontrado: $CSV" >&2
    exit 1
fi

OUT="$(mktemp -d)/brisa-csv"

# ScoreCsvRunner.swift usa @main, por isso compila diretamente em conjunto com o
# código de produção (não precisa do truque de renomear para main.swift).
swiftc Tools/ScoreCsvRunner.swift \
       Sources/data/SensorData.swift \
       Sources/sensor/SensorScore.swift \
       Sources/network/SensorApiClient.swift \
       -o "$OUT"

if [[ $ALL -eq 1 ]]; then
    # Corre cada CSV com --api e mostra só o payload enviado e a resposta do
    # modelo (ml1). Espera 1 s entre envios para não sobrecarregar o servidor.
    FIRST=1
    for csv in Tools/data/*.csv; do
        [[ $FIRST -eq 1 ]] || sleep 1
        FIRST=0
        echo
        echo "═══════════════════════════════════════════════════════════════"
        echo "  $csv"
        echo "═══════════════════════════════════════════════════════════════"
        "$OUT" "$csv" --api "$@" | sed -n '/── Payload enviado à API ──\|⚠ Sem payload/,$p' \
            || echo "  ⚠ falha ao correr $csv"
    done
else
    "$OUT" "$CSV" "$@"
fi
