#!/usr/bin/env python3
# ─────────────────────────────────────────────────────────────────────────────
# generate_sim_data.py
# ─────────────────────────────────────────────────────────────────────────────
# Gera CSVs SINTÉTICOS calibrados nas capturas REAIS de Tools/data (alameda,
# hellom, silo_auto, underground, …), com o mesmo formato aceite pelo
# ScoreCsvRunner:
#
#   elapsed_s,timestamp,pressure_hpa,gps_accuracy_m,gps_speed_mps,mag_ut
#   ...
#   EXPECTED <segundo da transição>
#
# Realismo que o TrajectorySimulator NÃO tem (observado nos dados reais):
#   • Precisão GPS "pegajosa" e quantizada: fica presa em valores típicos do
#     iOS (14.25, 25.00, 48.01, …) durante dezenas de segundos e salta para
#     centenas (316.9 … 1219.41) dentro do parque.
#   • Fix stale: quando o sinal degrada, o iOS repete a última localização →
#     velocidade e precisão CONGELAM (ex.: alameda 940-975s, speed=0.82 fixo),
#     e só depois caem para 0 com precisão enorme.
#   • Pressão de rua NÃO plana: colinas reais (~±1-2 hPa em minutos) + deriva
#     meteorológica + ruído AR(1) quantizado a 0.01 hPa.
#   • Magnetómetro com deriva de baseline (OU process) e picos esporádicos
#     (passagem por carris/elétrico chega a 400-700 µT — ver street3).
#   • Artefactos do logger: linhas duplicadas ocasionais (mesmo elapsed_s).
#
# Uso:
#   python3 Tools/generate_sim_data.py            # escreve em Tools/data_sim/
#   python3 Tools/generate_sim_data.py --seed 7   # outra variação de ruído
#
# Correr o score de produção sobre um ficheiro gerado:
#   ./Tools/run_csv.sh Tools/data_sim/sim_desce_p1.csv
# ─────────────────────────────────────────────────────────────────────────────
import argparse
import math
import os
import random
from datetime import datetime, timedelta, timezone

HPA_PER_M = 0.12          # ~0.12 hPa por metro (8.3 m/hPa)
FLOOR_M = 3.0             # altura típica de um piso → ~0.36 hPa

# Valores de precisão GPS observados nos CSVs reais (iOS quantiza).
ACC_GOOD = [4.39, 4.75, 5.01, 5.35, 5.54, 8.00, 8.02, 9.43, 10.13, 11.08]
ACC_FAIR = [12.00, 14.25, 16.00, 19.73, 21.77, 25.00]
ACC_POOR = [28.91, 32.00, 35.94, 40.00, 40.81, 48.01, 56.42, 76.29, 92.54]
ACC_LOST = [316.90, 513.38, 903.44, 1219.41]


class Rng(random.Random):
    def jitter(self, amp):
        return self.uniform(-amp, amp)


# ── Uma fase da viagem ───────────────────────────────────────────────────────
# speed: alvo no fim da fase (interpolado a partir do estado atual).
# alt:   variação de altitude ao LONGO da fase, em metros (negativo = desce).
# env:   'street_good' | 'street_fair' | 'entry' | 'ramp' | 'garage' | 'lost'
#        controla precisão GPS, magnetómetro e o comportamento de fix stale.
# mag:   (baseline µT, desvio por segundo) — sobrepõe o default do env.
class Phase:
    def __init__(self, name, dur, speed, env, alt=0.0, mag=None):
        self.name, self.dur, self.speed, self.env, self.alt, self.mag = \
            name, dur, speed, env, alt, mag


ENV_DEFAULTS = {
    # env          precisões         mag_base  mag_sd  p(spike)
    'street_good': (ACC_GOOD,          30.0,     2.5,   0.015),
    'street_fair': (ACC_FAIR,          32.0,     3.0,   0.015),
    'entry':       (ACC_POOR,          45.0,     6.0,   0.02),
    'ramp':        (ACC_POOR,          38.0,    12.0,   0.05),
    'garage':      (ACC_POOR,          44.0,     1.5,   0.01),
    'lost':        (ACC_LOST,          28.0,     4.0,   0.01),
}


def gen_scenario(phases, rng, p0, hilliness=1.0, tram=False):
    """Gera as amostras 1 Hz de um cenário. Devolve lista de dicts por segundo."""
    total = sum(ph.dur for ph in phases)

    # Colinas de rua: soma de senos com fases aleatórias (só pesa nas fases de
    # rua; dentro do parque a altitude é a das rampas).
    f1, f2 = rng.uniform(0.004, 0.008), rng.uniform(0.012, 0.02)
    ph1, ph2 = rng.uniform(0, 2 * math.pi), rng.uniform(0, 2 * math.pi)
    a1, a2 = 5.0 * hilliness, 2.0 * hilliness

    def street_alt(t):
        return a1 * math.sin(2 * math.pi * f1 * t + ph1) \
             + a2 * math.sin(2 * math.pi * f2 * t + ph2)

    rows = []
    t = 0
    cur_speed = phases[0].speed
    ramp_alt = 0.0            # altitude acumulada das rampas (persiste)
    last_street_alt = street_alt(0)   # congela as colinas ao sair da rua
    weather = 0.0             # deriva meteorológica (random walk lento)
    p_noise = 0.0             # ruído AR(1) do barómetro

    # Estado do gerador de precisão GPS (valor pegajoso + tempo restante).
    acc_val, acc_hold = None, 0
    # Fix stale: (speed, acc) congelados durante a degradação do sinal.
    frozen, freeze_left = None, 0
    prev_env = None

    # Magnetómetro: baseline OU + picos com duração.
    mag_base = ENV_DEFAULTS[phases[0].env][1]
    spike_left, spike_amp = 0, 0.0

    for ph in phases:
        accs, mag_target, mag_sd, p_spike = ENV_DEFAULTS[ph.env]
        if ph.mag:
            mag_target, mag_sd = ph.mag
        from_speed = cur_speed
        on_street = ph.env in ('street_good', 'street_fair')

        # Ao entrar num env pior que a rua, simula fix stale: congela a última
        # leitura (speed+acc) durante uns segundos antes do GPS "assumir" a perda.
        if prev_env is not None and on_street != (prev_env in ('street_good', 'street_fair')) \
                and not on_street and rows:
            freeze_left = rng.randint(4, 12)
            frozen = (rows[-1]['speed'], rows[-1]['acc'])
            acc_hold = 0
        prev_env = ph.env

        for i in range(1, ph.dur + 1):
            f = i / ph.dur
            t += 1

            # ── Velocidade ──
            target = from_speed + (ph.speed - from_speed) * f
            if target < 0.05:
                speed = 0.0
            else:
                speed = max(0.0, target + rng.jitter(0.35))

            # ── Altitude / pressão ──
            ramp_alt += ph.alt / ph.dur
            if on_street:
                last_street_alt = street_alt(t)
            alt = last_street_alt + ramp_alt
            weather += rng.gauss(0, 0.004)          # ±0.3 hPa em ~10 min
            p_noise = 0.75 * p_noise + rng.gauss(0, 0.009)
            press = p0 + weather - alt * HPA_PER_M + p_noise
            # AR(1) + quantização a 0.01 → |Δp| típico ~0.01-0.03, picos 0.1

            # ── Precisão GPS (pegajosa) + fix stale ──
            if freeze_left > 0:
                speed, acc = frozen
                freeze_left -= 1
                if freeze_left == 0:
                    acc_hold = 0    # a seguir salta para o valor do novo env
            else:
                if acc_hold <= 0:
                    acc_val = rng.choice(accs)
                    # parado/indoor fica preso mais tempo; a andar muda mais
                    acc_hold = rng.randint(8, 45) if not on_street or speed < 0.5 \
                        else rng.randint(3, 15)
                acc_hold -= 1
                if ph.env == 'street_good':
                    acc = max(3.5, acc_val + rng.jitter(1.2))   # jitter contínuo
                else:
                    acc = acc_val
                if ph.env in ('lost',):
                    speed = 0.0

            # ── Magnetómetro: OU para o alvo + ruído + picos ──
            mag_base += 0.06 * (mag_target - mag_base) + rng.gauss(0, mag_sd * 0.4)
            if spike_left > 0:
                spike_left -= 1
            elif rng.random() < p_spike:
                spike_left = rng.randint(2, 7)
                spike_amp = rng.uniform(200, 650) if (tram and on_street) \
                    else rng.uniform(15, 55)
            mag = mag_base + rng.gauss(0, mag_sd)
            if spike_left > 0:
                mag += spike_amp * rng.uniform(0.5, 1.0)
            mag = max(2.0, mag)

            rows.append({'t': t, 'press': press, 'acc': acc,
                         'speed': speed, 'mag': mag})
        cur_speed = ph.speed

    assert len(rows) == total
    return rows


def write_csv(path, rows, expected_sec, start, rng):
    lines = ['elapsed_s,timestamp,pressure_hpa,gps_accuracy_m,gps_speed_mps,mag_ut']
    for r in rows:
        ts = (start + timedelta(seconds=r['t'])).strftime('%Y-%m-%dT%H:%M:%SZ')
        line = (f"{r['t']},{ts},{r['press']:.2f},{r['acc']:.2f},"
                f"{r['speed']:.2f},{r['mag']:.2f}")
        lines.append(line)
        if rng.random() < 0.006:      # artefacto do logger: linha duplicada
            lines.append(line)
    lines += ['', f'EXPECTED {expected_sec}']
    with open(path, 'w') as f:
        f.write('\n'.join(lines) + '\n')


# ── Blocos de condução em rua (reutilizáveis) ────────────────────────────────
def rua_urbana(seconds, env='street_fair'):
    """Ciclo urbano: cruzeiro, semáforos (velocidade 0), curvas."""
    cycle = [
        Phase('cruzeiro', 16, 12, env),
        Phase('trava semáforo', 6, 0, env),
        Phase('parado semáforo', 10, 0, env),
        Phase('arranca', 6, 13, env),
        Phase('curva', 5, 5, env),
        Phase('retoma', 11, 12, env),
    ]
    cyc_s = sum(p.dur for p in cycle)
    return cycle * max(1, seconds // cyc_s)


def transito(seconds, env='street_fair'):
    """Stop-and-go congestionado (muitas paragens que NÃO são estacionamento)."""
    cycle = [
        Phase('anda-para', 4, 4, env),
        Phase('parado fila', 8, 0, env),
        Phase('avança', 3, 3, env),
        Phase('parado semáforo', 9, 0, env),
        Phase('avanço', 5, 6, env),
    ]
    cyc_s = sum(p.dur for p in cycle)
    return cycle * max(1, seconds // cyc_s)


def build_scenarios(seed):
    """Cada cenário: (ficheiro, fases, p0, hilliness, tram)."""
    scenarios = []

    # 1 — Rua com colinas → DESCE ao piso -1 (rampa aberta, sinal degradado).
    street = rua_urbana(400)
    entry = sum(p.dur for p in street)
    scenarios.append(('sim_desce_p1.csv', street + [
        Phase('entrada parque', 8, 2.0, 'entry'),
        Phase('rampa desce -1', 20, 1.5, 'ramp', alt=-FLOOR_M),
        Phase('manobra', 12, 1.2, 'garage'),
        Phase('estacionado', 30, 0.0, 'garage'),
    ], 1003.2, 1.2, False, entry))

    # 2 — Avenida rápida (GPS bom, jitter contínuo) → SOBE ao piso +2.
    street = [Phase('cruzeiro rápido', 20, 20, 'street_good'),
              Phase('abranda rotunda', 5, 6, 'street_good'),
              Phase('rotunda', 6, 7, 'street_good'),
              Phase('retoma', 18, 22, 'street_good')] * 6
    entry = sum(p.dur for p in street)
    scenarios.append(('sim_avenida_sobe_p2.csv', street + [
        Phase('entrada parque', 12, 2.0, 'entry'),
        Phase('rampa sobe +1', 22, 1.5, 'ramp', alt=+FLOOR_M),
        Phase('meio-piso', 6, 2.5, 'ramp'),
        Phase('rampa sobe +2', 22, 1.5, 'ramp', alt=+FLOOR_M),
        Phase('estacionado', 35, 0.0, 'garage'),
    ], 1006.1, 0.6, False, entry))

    # 3 — Silo automático (como hellom_silo_auto): entra, fila parado, elevador
    #     desce -2, GPS morre de vez (precisão 900+, velocidade 0).
    street = rua_urbana(280)
    entry = sum(p.dur for p in street)
    scenarios.append(('sim_silo_auto.csv', street + [
        Phase('entrada silo', 10, 1.5, 'entry'),
        Phase('fila parado', 25, 0.0, 'garage', mag=(45.0, 0.6)),
        Phase('elevador desce -2', 30, 0.0, 'garage', alt=-2 * FLOOR_M, mag=(45.0, 0.6)),
        Phase('depositado', 15, 0.0, 'lost', mag=(22.0, 1.5)),
        Phase('sem sinal', 40, 0.0, 'lost', mag=(22.0, 1.5)),
    ], 1002.9, 1.0, False, entry))

    # 4 — Parque à SUPERFÍCIE (Δp ≈ 0): o GPS mantém-se bom, sem rampa.
    street = rua_urbana(200, env='street_good')
    entry = sum(p.dur for p in street)
    scenarios.append(('sim_superficie.csv', street + [
        Phase('entra no parque', 10, 2.0, 'street_good'),
        Phase('manobra lugar', 16, 1.2, 'street_good'),
        Phase('estacionado', 35, 0.0, 'street_good', mag=(42.0, 3.0)),
    ], 1004.4, 0.8, False, entry))

    # 5 — Trânsito congestionado → SUBTERRÂNEO -3 (rampa espiral caótica:
    #     mag violento, precisão aos saltos, sinal perde-se a meio).
    street = transito(360)
    entry = sum(p.dur for p in street)
    scenarios.append(('sim_subterraneo_p3.csv', street + [
        Phase('entrada parque', 8, 2.0, 'entry'),
        Phase('espiral desce -1', 22, 1.3, 'ramp', alt=-FLOOR_M, mag=(38.0, 18.0)),
        Phase('espiral desce -2', 22, 1.3, 'ramp', alt=-FLOOR_M, mag=(36.0, 18.0)),
        Phase('espiral desce -3', 22, 1.3, 'lost', alt=-FLOOR_M, mag=(34.0, 14.0)),
        Phase('estacionado -3', 40, 0.0, 'lost', mag=(33.0, 3.0)),
    ], 1001.8, 1.0, False, entry))

    # 6 — Rua junto a CARRIS de elétrico (picos de mag 200-650 µT como street3)
    #     e estacionamento à superfície: teste de falso positivo magnético.
    street = rua_urbana(240)
    entry = sum(p.dur for p in street)
    scenarios.append(('sim_rua_eletrico.csv', street + [
        Phase('encosta', 8, 1.5, 'street_fair'),
        Phase('estacionado rua', 40, 0.0, 'street_fair', mag=(55.0, 8.0)),
    ], 1000.2, 1.4, True, entry))

    return scenarios


def main():
    ap = argparse.ArgumentParser(description='Gera CSVs sintéticos realistas em Tools/data_sim/')
    ap.add_argument('--seed', type=int, default=1, help='seed do ruído (default 1)')
    ap.add_argument('--out', default=os.path.join(os.path.dirname(__file__), 'data_sim'),
                    help='diretório de saída')
    args = ap.parse_args()

    os.makedirs(args.out, exist_ok=True)
    start = datetime(2026, 7, 14, 10, 0, 0, tzinfo=timezone.utc)

    for i, (name, phases, p0, hill, tram, expected) in enumerate(build_scenarios(args.seed)):
        rng = Rng(args.seed * 1000 + i)
        rows = gen_scenario(phases, rng, p0, hilliness=hill, tram=tram)
        path = os.path.join(args.out, name)
        write_csv(path, rows, expected, start + timedelta(minutes=30 * i), rng)
        dur = rows[-1]['t']
        dp = rows[0]['press'] - rows[-1]['press']
        print(f'✔ {path}  ({dur}s, entrada @ {expected}s, Δp cenário {dp:+.2f} hPa)')


if __name__ == '__main__':
    main()
