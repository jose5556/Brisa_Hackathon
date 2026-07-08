"""
generate_synthetic_data.py
==========================
Generates a realistic synthetic dataset for the Vertical Context Classifier
(Model 1: street_level | underground | above).

Usage
-----
    # 1. Generate data first (if not done yet)
    python generate_synthetic_data.py --n 5000

Design principles
-----------------
- Signal distributions are grounded in real-world physics for each location type:
    * Barometer: absolute pressure follows hypsometric formula; urban Porto/Lisbon
      topography spans ~0–165 m ASL, so baseline pressure varies ~1013–995 hPa.
      Underground garages are typically 3–8 m below surface, adding ~0.4–1 hPa.
      Above-ground (multi-storey) garages are 3–30 m above street.
    * Magnetometer: underground environments have severe ferromagnetic interference
      from rebar, metro rails, pipes; above-ground garages have moderate steel
      structure interference; streets are baseline urban.
- Real failure modes are injected:
    * Barometer drift (sensor warm-up)
    * GNSS multipath in dense urban canyons (Baixa do Porto, Av. Aliados)
    * Magnetometer saturation near metro lines (Porto Metro Linha D, E)
    * Missing/None values (device firmware issues, BLE sensor drops)
    * Mislabelled outliers (~3% noise)
- Class balance: deliberately imbalanced to reflect real-world distribution:
    street_level 55% | underground 30% | above 15%
  (underground is oversampled relative to reality to help minority-class learning)

Output
------
data/synthetic_vertical_dataset.csv   — full dataset
data/synthetic_vertical_train.csv     — 80% train split
data/synthetic_vertical_val.csv       — 20% val split
"""

import argparse
import json
import random
from pathlib import Path

import numpy as np
import pandas as pd
from sklearn.model_selection import train_test_split

# ── reproducibility ─────────────────────────────────────────────────────────
SEED = 42
rng = np.random.default_rng(SEED)
random.seed(SEED)

# ── output paths ─────────────────────────────────────────────────────────────
OUT_DIR = Path("data")
OUT_DIR.mkdir(exist_ok=True)

# ─────────────────────────────────────────────────────────────────────────────
# PHYSICS CONSTANTS
# ─────────────────────────────────────────────────────────────────────────────
# Hypsometric: ΔP ≈ -0.12 hPa/m at sea level, ~-0.115 hPa/m at 100 m ASL.
HPA_PER_METRE = 0.12          # hPa drop per metre of ascent
STANDARD_SLP  = 1013.25       # hPa at sea level, ISA

# Porto/Lisbon ground elevation envelope (OSM DEM data):
# * Porto city centre: 0–90 m ASL (river plain to Foz/Antas plateau)
# * Lisbon city centre: 0–100 m ASL (Baixa 5 m → Bairro Alto 80 m → Monsanto 230 m)
# We model ground elevation as a bimodal: flat zones + hilly zones.
CITY_ELEVATION = {
    "OPO": {"flat": (0, 40),  "hilly": (40, 165)},
    "LIS": {"flat": (0, 30),  "hilly": (30, 120)},
}

# ─────────────────────────────────────────────────────────────────────────────
# HELPER FUNCTIONS
# ─────────────────────────────────────────────────────────────────────────────

def ground_elevation_m(city: str) -> float:
    """Sample a realistic ground elevation for the city."""
    cfg = CITY_ELEVATION[city]
    # 60% flat / 40% hilly — reflects city footprint distribution
    if rng.random() < 0.60:
        return float(rng.uniform(*cfg["flat"]))
    return float(rng.uniform(*cfg["hilly"]))


def surface_pressure_hpa(elevation_m: float) -> float:
    """Approximate absolute barometric pressure at a given elevation."""
    # Barometric formula (simplified troposphere):
    # P = SLP * (1 - L*h/T0)^(g*M/R*L)  ≈ SLP * exp(-h/8500)
    p = STANDARD_SLP * np.exp(-elevation_m / 8500.0)
    return float(p)


def add_sensor_noise(value: float, sigma: float, missing_prob: float = 0.0) -> float | None:
    """Add Gaussian noise and optionally simulate a missing reading."""
    if rng.random() < missing_prob:
        return None
    return float(value + rng.normal(0, sigma))


def clamp(value: float, lo: float, hi: float) -> float:
    return max(lo, min(hi, value))

# ─────────────────────────────────────────────────────────────────────────────
# PER-CLASS SAMPLE GENERATORS
# ─────────────────────────────────────────────────────────────────────────────

def make_street_level(city: str) -> dict:
    """
    STREET LEVEL — public road surface.

    Signals:
    - Pressure: surface value ± weather variation ± urban heat island (~0.5 hPa)
    - Pressure_delta: small; driven by wind gusts and building downdraft (~±0.3 hPa)
    - Magnetometer: baseline urban: tram rails, subsurface pipes → moderate variance
    - GNSS: variable — open sky (accuracy 4–8 m) vs. urban canyon (8–25 m, loss 0–15%)
    """
    elev = ground_elevation_m(city)
    base_p = surface_pressure_hpa(elev)

    # Weather perturbation (±3 hPa realistic daily variation)
    weather_perturb = rng.normal(0, 1.2)
    p_abs = base_p + weather_perturb
    p_abs = add_sensor_noise(p_abs, sigma=0.08, missing_prob=0.005)

    p_delta = rng.normal(0, 0.15)          # small wind/gust effect
    p_delta = add_sensor_noise(p_delta, sigma=0.05, missing_prob=0.01)

    p_var = abs(rng.normal(0.02, 0.015))   # low variance on street
    alt_change = rng.normal(0, 1.5)        # slight slope changes

    # Magnetometer: urban baseline with occasional tram/metro proximity spikes
    near_metro = rng.random() < 0.20       # 20% chance near metro line (Porto Linha D/E/F)
    mag_base = rng.uniform(30, 55)         # µT — typical urban Europe
    if near_metro:
        mag_base += rng.uniform(10, 30)    # metro rail interference
    mag_var = abs(rng.normal(0.04, 0.03))
    mag_mean = add_sensor_noise(mag_base, sigma=2.0, missing_prob=0.02)
    mag_delta = rng.normal(0, 3.0)

    # GNSS: street can range from open sky to deep canyon
    canyon_effect = rng.random() < 0.35   # 35% in urban canyon (Aliados, Clérigos, etc.)
    if canyon_effect:
        gnss_acc = rng.uniform(8, 28)
        gnss_delta = rng.uniform(3, 15)
        gnss_lost = rng.uniform(0.0, 0.15)
    else:
        gnss_acc = rng.uniform(3, 10)
        gnss_delta = rng.uniform(0.5, 4)
        gnss_lost = rng.uniform(0.0, 0.04)

    gnss_acc = add_sensor_noise(gnss_acc, sigma=1.5, missing_prob=0.01)
    gnss_delta = add_sensor_noise(gnss_delta, sigma=0.5)
    gnss_lost = clamp(float(gnss_lost + rng.normal(0, 0.01)), 0.0, 1.0)

    return {
        "label": "street_level",
        "city": city,
        "ground_elevation_m": round(elev, 1),
        "pressure_hpa": round(p_abs, 3) if p_abs else None,
        "pressure_delta_hpa": round(p_delta, 4) if p_delta else None,
        "pressure_variance": round(p_var, 6),
        "altitude_change_m": round(alt_change, 3),
        "magnetic_variance_total": round(mag_var, 6),
        "magnetic_field_mean": round(mag_mean, 4) if mag_mean else None,
        "magnetic_field_delta": round(mag_delta, 4),
        "gnss_accuracy_m": round(gnss_acc, 2) if gnss_acc else None,
        "gnss_accuracy_delta": round(gnss_delta, 2) if gnss_delta else None,
        "gnss_lost_ratio": round(gnss_lost, 3),
    }


def make_underground(city: str) -> dict:
    """
    UNDERGROUND GARAGE — subsurface, enclosed.

    Key physics:
    - Depth typically 3–10 m below street (up to 20 m for 4-storey basements)
    - Pressure HIGHER than surface by ~0.4–2.5 hPa (descent effect)
    - Pressure_delta: shows a clear negative spike during descent (entry ramp
      is typically -6% grade → ~1.5 m depth per 25 m horizontal → ~0.18 hPa/s)
    - Magnetometer: extreme variance and high mean due to rebar grid, steel I-beams,
      drainage pipes, metal doors, vehicles — highly ferromagnetic environment
    - GNSS: total or near-total loss.
      gnss_accuracy degrades to last-fix coasting (25–200 m).
    - Altitude change: negative (descended)
    """
    elev = ground_elevation_m(city)
    depth_m = rng.uniform(3, 18)           # depth of parking level below surface
    actual_elev = elev - depth_m

    base_p = surface_pressure_hpa(actual_elev)  # higher pressure underground
    weather_perturb = rng.normal(0, 1.2)
    p_abs = base_p + weather_perturb

    # Pressure variance: enclosed space, HVAC cycling, vehicle exhaust
    p_var = abs(rng.normal(0.08, 0.04))
    p_abs = add_sensor_noise(p_abs, sigma=0.05, missing_prob=0.003)

    # Descent delta: negative (descending ramp → pressure increases rapidly)
    # Typical ramp: 6–8% grade, 10 s window, ~0.5–1.8 m descent → 0.06–0.22 hPa
    p_delta_raw = rng.uniform(0.04, 0.28) * rng.choice([-1, -1, -1, 1])  # mostly negative = descending
    p_delta = add_sensor_noise(p_delta_raw, sigma=0.03, missing_prob=0.01)

    alt_change = -depth_m * rng.uniform(0.1, 0.6)  # partial descent in window

    # Magnetometer: strong ferromagnetic environment
    mag_base = rng.uniform(55, 120)        # high mean field (µT)
    mag_var = abs(rng.normal(0.35, 0.15))  # very high variance — structural steel
    # Occasionally sensor saturates (near elevator shaft, large rebar section)
    if rng.random() < 0.15:
        mag_var = rng.uniform(0.6, 1.2)
        mag_base = rng.uniform(100, 180)
    mag_mean = add_sensor_noise(mag_base, sigma=5.0, missing_prob=0.02)
    mag_delta = rng.normal(0, 12.0)       # large swings as vehicle moves past structures

    # GNSS: almost total loss
    gnss_lost = clamp(rng.uniform(0.80, 1.0), 0.0, 1.0)
    gnss_acc = rng.uniform(25, 200)        # last-fix coasting, degraded fast
    gnss_delta = rng.uniform(10, 80)        # massive delta between first/last reading in window
    gnss_acc = add_sensor_noise(gnss_acc, sigma=8.0, missing_prob=0.05)
    gnss_delta = add_sensor_noise(gnss_delta, sigma=5.0, missing_prob=0.05)

    return {
        "label": "underground",
        "city": city,
        "ground_elevation_m": round(elev, 1),
        "pressure_hpa": round(p_abs, 3) if p_abs else None,
        "pressure_delta_hpa": round(p_delta, 4) if p_delta else None,
        "pressure_variance": round(p_var, 6),
        "altitude_change_m": round(alt_change, 3),
        "magnetic_variance_total": round(mag_var, 6),
        "magnetic_field_mean": round(mag_mean, 4) if mag_mean else None,
        "magnetic_field_delta": round(mag_delta, 4),
        "gnss_accuracy_m": round(gnss_acc, 2) if gnss_acc else None,
        "gnss_accuracy_delta": round(gnss_delta, 2) if gnss_delta else None,
        "gnss_lost_ratio": round(gnss_lost, 3),
    }


def make_above(city: str) -> dict:
    """
    ABOVE-GROUND MULTI-STOREY GARAGE — elevated, partially open.

    Key physics:
    - Altitude above street: 3–28 m (1–8 levels at ~3.2 m/level)
    - Pressure LOWER than surface: -0.4 to -3.4 hPa
    - Pressure_delta: positive spike during ascent (spiral ramp)
    - Magnetometer: moderate steel structure interference, less extreme than underground
    - GNSS: partial — open sides allow partial sky view, but concrete columns and
      roof cause multipath. Accuracy 8–40 m. Lost ratio 0.05–0.50.
    - Altitude change: positive (ascended)
    """
    elev = ground_elevation_m(city)
    floors = rng.integers(1, 9)            # parking on floor 1–8
    floor_height_m = float(floors) * rng.uniform(2.8, 3.5)
    actual_elev = elev + floor_height_m

    base_p = surface_pressure_hpa(actual_elev)   # lower pressure elevated
    weather_perturb = rng.normal(0, 1.2)
    p_abs = base_p + weather_perturb

    p_var = abs(rng.normal(0.05, 0.025))   # moderate — open sides, wind effects
    p_abs = add_sensor_noise(p_abs, sigma=0.06, missing_prob=0.004)

    # Ascent delta: positive (ascending ramp → pressure decreases)
    p_delta_raw = rng.uniform(0.03, 0.22) * rng.choice([1, 1, 1, -1])  # mostly positive = ascending
    p_delta = add_sensor_noise(p_delta_raw, sigma=0.03, missing_prob=0.01)

    alt_change = floor_height_m * rng.uniform(0.1, 0.5)  # partial ascent in window

    # Magnetometer: moderate structural steel (columns, beams, rebar in slab)
    mag_base = rng.uniform(35, 70)
    mag_var = abs(rng.normal(0.12, 0.07))
    mag_mean = add_sensor_noise(mag_base, sigma=3.0, missing_prob=0.02)
    mag_delta = rng.normal(0, 5.0)

    # GNSS: partial sky view — highly dependent on bay position (inner vs perimeter)
    inner_bay = rng.random() < 0.40        # inner bays have worse sky view
    if inner_bay:
        gnss_lost = clamp(rng.uniform(0.30, 0.70), 0.0, 1.0)
        gnss_acc = rng.uniform(15, 60)
        gnss_delta = rng.uniform(8, 35)
    else:
        gnss_lost = clamp(rng.uniform(0.05, 0.35), 0.0, 1.0)
        gnss_acc = rng.uniform(6, 25)
        gnss_delta = rng.uniform(3, 18)

    gnss_acc = add_sensor_noise(gnss_acc, sigma=3.0, missing_prob=0.03)
    gnss_delta = add_sensor_noise(gnss_delta, sigma=2.0, missing_prob=0.03)

    return {
        "label": "above",
        "city": city,
        "ground_elevation_m": round(elev, 1),
        "pressure_hpa": round(p_abs, 3) if p_abs else None,
        "pressure_delta_hpa": round(p_delta, 4) if p_delta else None,
        "pressure_variance": round(p_var, 6),
        "altitude_change_m": round(alt_change, 3),
        "magnetic_variance_total": round(mag_var, 6),
        "magnetic_field_mean": round(mag_mean, 4) if mag_mean else None,
        "magnetic_field_delta": round(mag_delta, 4),
        "gnss_accuracy_m": round(gnss_acc, 2) if gnss_acc else None,
        "gnss_accuracy_delta": round(gnss_delta, 2) if gnss_delta else None,
        "gnss_lost_ratio": round(gnss_lost, 3),
    }

# ─────────────────────────────────────────────────────────────────────────────
# LABEL NOISE — simulate real mislabelling (~3% of sessions)
# ─────────────────────────────────────────────────────────────────────────────

LABEL_NOISE_RATE = 0.03
ALL_LABELS = ["street_level", "underground", "above"] # fixed order for encoding

def inject_label_noise(row: dict) -> dict:
    if rng.random() < LABEL_NOISE_RATE:
        other_labels = [l for l in ALL_LABELS if l != row["label"]]
        row["label"] = rng.choice(other_labels)
        row["label_noisy"] = True
    else:
        row["label_noisy"] = False
    return row

# ─────────────────────────────────────────────────────────────────────────────
# MAIN GENERATOR
# ─────────────────────────────────────────────────────────────────────────────

def generate_dataset(n_total: int = 5000) -> pd.DataFrame:
    # Class distribution: intentionally imbalanced, reflects real-world + minority boost
    # street_level=55%, underground=30%, above=15%
    n_street      = int(n_total * 0.55)
    n_underground = int(n_total * 0.30)
    n_above       = n_total - n_street - n_underground

    print(f"Generating {n_total} samples:")
    print(f"  street_level  : {n_street}")
    print(f"  underground   : {n_underground}")
    print(f"  above  : {n_above}")

    cities = ["OPO", "LIS"]
    records = []

    generators = [
        (make_street_level,  n_street),
        (make_underground,   n_underground),
        (make_above,  n_above),
    ]

    for gen_fn, count in generators:
        for _ in range(count):
            city = rng.choice(cities)
            row = gen_fn(city)
            row = inject_label_noise(row)
            records.append(row)

    # Shuffle
    rng.shuffle(records)

    df = pd.DataFrame(records)

    # ── Derived / engineered feature that the model can also use ──────────────
    # pressure_relative_hpa: pressure delta from estimated surface for that elevation
    # This is a *very* discriminative feature: underground → positive, above → negative.
    df["pressure_relative_to_surface_hpa"] = df.apply(
        lambda r: (
            r["pressure_hpa"] - surface_pressure_hpa(r["ground_elevation_m"])
            if r["pressure_hpa"] is not None else None
        ),
        axis=1,
    )

    # ── Metadata columns ──────────────────────────────────────────────────────
    # time_of_day: affects GNSS (satellites), traffic magnetic noise, thermal drift
    time_buckets = ["morning", "afternoon", "evening", "night"]
    time_weights  = [0.25, 0.35, 0.25, 0.15]
    df["time_of_day"] = rng.choice(time_buckets, size=len(df), p=time_weights)

    weather_buckets  = ["clear", "overcast", "rain"]
    weather_weights  = [0.50, 0.30, 0.20]
    df["weather_condition"] = rng.choice(weather_buckets, size=len(df), p=weather_weights)

    # Reorder columns for readability
    col_order = [
        "label", "label_noisy", "city",
        "ground_elevation_m",
        "pressure_hpa", "pressure_delta_hpa", "pressure_variance", "altitude_change_m",
        "pressure_relative_to_surface_hpa",
        "magnetic_variance_total", "magnetic_field_mean", "magnetic_field_delta",
        "gnss_accuracy_m", "gnss_accuracy_delta", "gnss_lost_ratio",
        "time_of_day", "weather_condition",
    ]
    df = df[col_order]

    return df


def main(n_total: int = 5000):
    df = generate_dataset(n_total)

    # ── Save full dataset ─────────────────────────────────────────────────────
    full_path = OUT_DIR / "synthetic_vertical_dataset.csv"
    df.to_csv(full_path, index=False)
    print(f"\nFull dataset saved → {full_path}  ({len(df)} rows)")

    # ── Train / val split (stratified on label) ───────────────────────────────
    train_df, val_df = train_test_split(
        df, test_size=0.20, random_state=SEED, stratify=df["label"]
    )
    train_path = OUT_DIR / "synthetic_vertical_train.csv"
    val_path   = OUT_DIR / "synthetic_vertical_val.csv"
    train_df.to_csv(train_path, index=False)
    val_df.to_csv(val_path, index=False)
    print(f"Train split saved  → {train_path}  ({len(train_df)} rows)")
    print(f"Val split saved    → {val_path}  ({len(val_df)} rows)")

    # ── Quick sanity stats ────────────────────────────────────────────────────
    print("\n── Label distribution (full dataset) ──")
    print(df["label"].value_counts(normalize=True).round(3).to_string())

    print("\n── Pressure stats by label ──")
    print(
        df.groupby("label")[["pressure_hpa", "pressure_delta_hpa", "pressure_relative_to_surface_hpa"]]
        .agg(["mean", "std"])
        .round(3)
        .to_string()
    )

    print("\n── GNSS stats by label ──")
    print(
        df.groupby("label")[["gnss_accuracy_m", "gnss_lost_ratio"]]
        .agg(["mean", "std"])
        .round(3)
        .to_string()
    )

    print("\n── Magnetometer stats by label ──")
    print(
        df.groupby("label")[["magnetic_variance_total", "magnetic_field_mean"]]
        .agg(["mean", "std"])
        .round(3)
        .to_string()
    )

    print(f"\nMislabelled rows (noise): {df['label_noisy'].sum()} / {len(df)}")

    # ── Feature metadata (for schema validation) ──────────────────────────────
    feature_cols = [
        "pressure_hpa", "pressure_delta_hpa", "pressure_variance", "altitude_change_m",
        "pressure_relative_to_surface_hpa",
        "magnetic_variance_total", "magnetic_field_mean", "magnetic_field_delta",
        "gnss_accuracy_m", "gnss_accuracy_delta", "gnss_lost_ratio",
    ]
    missing_rates = (df[feature_cols].isna().mean() * 100).round(2)
    print("\n── Missing value rates (%) ──")
    print(missing_rates.to_string())

    meta = {
        "n_total": len(df),
        "feature_columns": feature_cols,
        "label_column": "label",
        "classes": ["street_level", "underground", "above"],
        "cities": ["OPO", "LIS"],
        "label_noise_rate": LABEL_NOISE_RATE,
        "seed": SEED,
    }
    meta_path = OUT_DIR / "dataset_meta.json"
    with open(meta_path, "w") as f:
        json.dump(meta, f, indent=2)
    print(f"\nDataset metadata → {meta_path}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Generate synthetic vertical context dataset")
    parser.add_argument(
        "--n", type=int, default=5000,
        help="Total number of samples to generate (default: 5000)"
    )
    args = parser.parse_args()
    main(n_total=args.n)