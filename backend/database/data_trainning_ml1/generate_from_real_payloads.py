"""
generate_from_real_payloads.py
==============================
Generates a synthetic labelled dataset anchored on REAL sensor payloads
captured by the iOS app (app/IOS/swift/Tools/payloads.txt).

Instead of sampling from purely physics-based distributions (see
generate_synthetic_data.py), each synthetic row is created by:
    1. Picking a random real payload of the target class as anchor.
    2. Jittering every feature with Gaussian noise scaled to the
       per-class spread observed in the real data (with a floor so
       classes with few samples still get meaningful variation).
    3. Clipping to physical bounds (ratios in [0,1], variances >= 0, ...).
    4. Assigning a city from the DB maps (backend/database/maps/valid/) and
       sampling latitude/longitude from that city's real road geometries.

Usage
-----
    python generate_from_real_payloads.py --n 1500

Output
------
data/synthetic_from_payloads.csv        — full dataset
data/synthetic_from_payloads_train.csv  — 80% train split
data/synthetic_from_payloads_val.csv    — 20% val split
"""

import argparse
import json
import re
from pathlib import Path

import numpy as np
import pandas as pd
from sklearn.model_selection import train_test_split

SEED = 42
rng = np.random.default_rng(SEED)

HERE = Path(__file__).resolve().parent
PAYLOADS_TXT = HERE / "../../../app/IOS/swift/Tools/payloads.txt"
MAPS_DIR = HERE / "../maps/valid"
OUT_DIR = HERE / "data"
OUT_DIR.mkdir(exist_ok=True)

# File base name -> value expected by the DB city_code type
# (mirrors CITY_SCHEMA_MAP in data_ingestion/geojson_loader.py)
CITY_SCHEMA_MAP = {
    "Porto": "Porto",
    "Oeiras": "Oeiras",
    "Espinho": "Espinho",
    "Matosinhos": "Matosinhos",
    "Maia": "Maia",
    "Vila_nova_de_Gaia": "Vila nova de Gaia",
    "Arouca": "Arouca",
}

# Class proportions kept consistent with generate_synthetic_data.py
CLASS_PROPORTIONS = {"street_level": 0.55, "underground": 0.30, "above": 0.15}

# Known typos in hand-written labels
LABEL_FIXES = {"undergorund": "underground"}

FEATURES = [
    "latitude",
    "longitude",
    "gnss_accuracy_mean",
    "gnss_accuracy_delta",
    "gnss_lost_ratio",
    "pressure_hpa",
    "pressure_delta",
    "pressure_variance",
    "altitude_delta",
    "magnetic_field_mean",
    "magnetic_field_delta",
    "magnetic_variance",
    "window_duration_s",
]

# (lower bound, upper bound) applied after jitter; None = unbounded
BOUNDS = {
    "gnss_accuracy_mean": (1.0, None),
    "gnss_accuracy_delta": (0.0, None),
    "gnss_lost_ratio": (0.0, 1.0),
    "pressure_hpa": (950.0, 1050.0),
    "pressure_variance": (0.0, None),
    "magnetic_field_mean": (5.0, None),
    "magnetic_variance": (0.0, None),
    "window_duration_s": (3.0, None),
}

# Minimum jitter std as a fraction of the feature's global spread, so that
# classes with 2-3 real samples don't collapse onto their anchors.
STD_FLOOR_FRACTION = 0.15


def load_city_coordinates(maps_dir: Path) -> dict[str, np.ndarray]:
    """Collect road-geometry vertices (lat, lon) per city from the DB maps."""
    coords_by_city = {}
    for geojson_path in sorted(maps_dir.glob("*.geojson")):
        city = CITY_SCHEMA_MAP.get(geojson_path.stem, geojson_path.stem)
        with open(geojson_path) as f:
            collection = json.load(f)
        points = []
        for feature in collection.get("features", []):
            geom = feature.get("geometry") or {}
            gtype = geom.get("type")
            coords = geom.get("coordinates", [])
            # Normalize every geometry to a list of vertex sequences
            if gtype == "LineString":
                lines = [coords]
            elif gtype in ("MultiLineString", "Polygon"):
                lines = coords
            elif gtype == "MultiPolygon":
                lines = [ring for poly in coords for ring in poly]
            else:
                continue
            for line in lines:
                points.extend((lat, lon) for lon, lat, *_ in line)
        if points:
            coords_by_city[city] = np.asarray(points)
    if not coords_by_city:
        raise ValueError(f"no road geometries found in {maps_dir}")
    return coords_by_city


def parse_payloads(path: Path) -> pd.DataFrame:
    """Parse the hand-written payloads.txt into a DataFrame."""
    text = path.read_text()
    rows = []
    # Each block: label="..." followed by { key : value ... }
    for m in re.finditer(r'label="(?P<label>\w+)"\s*\{(?P<body>.*?)\}', text, re.S):
        label = m.group("label")
        label = LABEL_FIXES.get(label, label)
        row = {"label": label}
        for line in m.group("body").splitlines():
            kv = re.match(r"\s*([\w() ]+?)\s*:\s*(.+)", line)
            if not kv:
                continue
            key, value = kv.group(1).strip(), kv.group(2).strip()
            if key == "pressure_hpa (final)":
                key = "pressure_hpa"
            if key == "city":
                row["city"] = value
                continue
            if key.startswith("window_start") or key.startswith("window_end"):
                continue
            num = re.match(r"-?\d+(?:\.\d+)?", value)
            if num:
                row[key] = float(num.group(0))
        rows.append(row)
    df = pd.DataFrame(rows)
    missing = [f for f in FEATURES if f not in df.columns]
    if missing:
        raise ValueError(f"payloads.txt missing expected fields: {missing}")
    return df


def synthesize(
    real: pd.DataFrame,
    n_total: int,
    coords_by_city: dict[str, np.ndarray],
) -> pd.DataFrame:
    """Generate n_total synthetic rows anchored on the real payloads."""
    global_std = real[FEATURES].std(ddof=0).replace(0, np.nan)
    cities = list(coords_by_city)
    out = []
    for label, prop in CLASS_PROPORTIONS.items():
        anchors = real[real["label"] == label][FEATURES]
        if anchors.empty:
            print(f"[warn] no real payloads for class '{label}', skipping")
            continue
        n = int(round(n_total * prop))
        class_std = anchors.std(ddof=0)
        floor = (global_std * STD_FLOOR_FRACTION).fillna(0.0)
        jitter_std = np.maximum(class_std.fillna(0.0), floor)

        idx = rng.integers(0, len(anchors), size=n)
        base = anchors.to_numpy()[idx]
        noise = rng.normal(0.0, jitter_std.to_numpy(), size=(n, len(FEATURES)))
        samples = base + noise

        df = pd.DataFrame(samples, columns=FEATURES)
        for col, (lo, hi) in BOUNDS.items():
            df[col] = df[col].clip(lower=lo, upper=hi)

        # City sampled uniformly from the DB maps; lat/lon drawn from that
        # city's real road vertices with a tiny (~±10 m) GPS-like jitter.
        df["city"] = rng.choice(cities, size=n)
        for city in cities:
            mask = df["city"] == city
            k = int(mask.sum())
            if k == 0:
                continue
            pts = coords_by_city[city]
            picks = pts[rng.integers(0, len(pts), size=k)]
            picks = picks + rng.normal(0.0, 1e-4, size=picks.shape)
            df.loc[mask, "latitude"] = picks[:, 0]
            df.loc[mask, "longitude"] = picks[:, 1]

        df["label"] = label
        out.append(df)

    result = pd.concat(out, ignore_index=True)
    result = result.sample(frac=1.0, random_state=SEED).reset_index(drop=True)
    return result[["label", "city"] + FEATURES].round(5)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--n", type=int, default=1500, help="total synthetic rows")
    args = ap.parse_args()

    real = parse_payloads(PAYLOADS_TXT)
    print(f"Parsed {len(real)} real payloads: "
          f"{real['label'].value_counts().to_dict()}")

    coords_by_city = load_city_coordinates(MAPS_DIR)
    print(f"Loaded road coordinates for {len(coords_by_city)} cities: "
          f"{ {c: len(p) for c, p in coords_by_city.items()} }")

    data = synthesize(real, args.n, coords_by_city)
    train, val = train_test_split(
        data, test_size=0.2, random_state=SEED, stratify=data["label"]
    )

    data.to_csv(OUT_DIR / "synthetic_from_payloads.csv", index=False)
    train.to_csv(OUT_DIR / "synthetic_from_payloads_train.csv", index=False)
    val.to_csv(OUT_DIR / "synthetic_from_payloads_val.csv", index=False)

    print(f"Wrote {len(data)} rows "
          f"({data['label'].value_counts().to_dict()}) to {OUT_DIR}/")


if __name__ == "__main__":
    main()
