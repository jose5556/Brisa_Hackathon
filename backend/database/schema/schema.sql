CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS postgis_topology;
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

--============================================================
-- ENUM TYPES
--============================================================

CREATE TYPE location_type AS ENUM (
    'street_paid',        -- public street with parking fee → charge
    'street_free',        -- public street without parking fee → do not charge
    'garage_open',        -- private above-ground garage
    'garage_underground', -- underground or covered garage
    'unknown'             -- not classified
);

CREATE TYPE session_status AS ENUM (
    'detecting',          -- 10-second window in progress (!!! to decide that timeframe, how that will work !!!)
    'pending_confirm',    -- push sent
    'confirmed',          -- user confirmed (positive label)
    'cancelled'          -- user cancelled (negative label)
);

CREATE TYPE model_decision AS ENUM (
    'charge',             -- system decided to charge
    'uncertain'           -- score below the minimum threshold
);

CREATE TYPE city_code AS ENUM (
    'OPO',                -- Porto
    'LIS'                 -- Lisbon
);

--============================================================
--  1. USERS
--  Users of the DEVELOPER app
-- ============================================================

CREATE TABLE users (
    id                  UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    city                city_code NOT NULL,
    device_platform     TEXT NOT NULL DEFAULT 'ios',   -- ios | android
    rgpd_consent_at     TIMESTAMPTZ,                   -- NULL = no consent
    rgpd_consent_version TEXT,                         -- consent text version
    is_active           BOOLEAN NOT NULL DEFAULT TRUE,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

--============================================================
--  2. PAID_ZONES
--  Paid parking zones
-- ============================================================

CREATE TABLE paid_zones (
    id                  UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    city                city_code NOT NULL,
    geom                GEOMETRY(Geometry, 4326) NOT NULL,  -- PostGIS
    source              TEXT NOT NULL DEFAULT 'manual',   -- 'osm' | 'brisa' | 'manual' | 'portoDigital'
    source_version      TEXT NOT NULL,               -- e.g.: version or date of the source published
    is_active           BOOLEAN NOT NULL DEFAULT TRUE,
    loaded_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_paid_zones_geom    ON paid_zones USING GIST(geom);
CREATE INDEX idx_paid_zones_city    ON paid_zones(city);

--============================================================
--  3. PARKING_SESSIONS
--  A session = one stop event detected by the system.
--  The center of everything, all other tables reference this.
-- ============================================================

CREATE TABLE parking_sessions (
    id                      UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id                 UUID NOT NULL REFERENCES users(id),
    city                    city_code NOT NULL,
    status                  session_status NOT NULL DEFAULT 'detecting',

    -- PostGIS geometry - detected stop point
    -- SRID 4326 (WGS84) - phone coordinates
    detected_location       GEOMETRY(POINT, 4326),
    location_accuracy_m     NUMERIC(6,2),              -- GPS accuracy in meters

    -- Matching paid zone (if found)
    paid_zone_id            UUID REFERENCES paid_zones(id),

    -- Timing
    detected_at             TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    push_sent_at            TIMESTAMPTZ,
    user_responded_at       TIMESTAMPTZ,
    session_ended_at        TIMESTAMPTZ,

    -- Shadow mode - manual user label
    user_label              BOOLEAN,                   -- TRUE=confirmed, FALSE=cancelled

    -- Device metadata
    device_os_version       TEXT,
    app_version             TEXT,

    created_at              TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at              TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_parking_sessions_geom ON parking_sessions USING GIST(detected_location);
CREATE INDEX idx_parking_sessions_user ON parking_sessions(user_id);
CREATE INDEX idx_parking_sessions_paid_zone ON parking_sessions(paid_zone_id);

--============================================================
--  4. SENSOR_PAYLOADS
--  Raw features sent by the device to FastAPI.
--  Separated from parking_sessions to avoid inflating the main table
--  and to allow re-processing with new models without losing data.
-- ============================================================

CREATE TABLE sensor_payloads (
    id                      UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    session_id              UUID NOT NULL REFERENCES parking_sessions(id) ON DELETE CASCADE,

    -- Observation window
    window_start_at         TIMESTAMPTZ NOT NULL,
    window_end_at           TIMESTAMPTZ NOT NULL,
    window_duration_s       NUMERIC(5,2) NOT NULL DEFAULT 10.0,

    -- Barometer
    pressure_hpa            NUMERIC(8,3),     -- absolute pressure
    pressure_delta_hpa      NUMERIC(7,4),     -- variation vs baseline
    pressure_variance       NUMERIC(10,6),    -- variance during window
    altitude_change_m       NUMERIC(7,3),     -- estimated altitude change
    city_baseline_pressure  NUMERIC(8,3),

    -- Magnetometer
    mag_x                   NUMERIC(10,4),
    mag_y                   NUMERIC(10,4),
    mag_z                   NUMERIC(10,4),
    mag_variance_total      NUMERIC(10,6),    -- total 3-axis variance
    mag_distortion_score    NUMERIC(5,4),     -- 0=clean, 1=highly disturbed

    -- GNSS quality
    gnss_accuracy_m         NUMERIC(6,2),
    hdop                    NUMERIC(5,2),    -- horizontal precision
    satellite_count         INTEGER,         -- number of visible satellites   
    gnss_signal_drop        BOOLEAN,         -- degradation during the window

    -- Meteorological and urban conditions (for model error analysis)
    weather_condition   TEXT,            -- 'clear' | 'rain' | 'overcast'
    time_of_day         TEXT,            -- 'morning' | 'afternoon' | 'evening' | 'night'

    -- Full JSON payload (to re-process with future features)
    raw_payload             JSONB,

    received_at             TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_sensor_payloads_session ON sensor_payloads(session_id);

--===============================================================
--  5. INFERENCE_LOGS
--  Output of each ML pipeline call.
--  One per session, but there may be re-inferences with a new model.
-- ===============================================================

CREATE TABLE inference_logs (
    id                          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    session_id                  UUID NOT NULL REFERENCES parking_sessions(id),
    payload_id                  UUID REFERENCES sensor_payloads(id),
    model_version_id            UUID,          -- FK to model_versions (below)

    -- Model 1 — Vertical Context Classifier
    ml1_street_prob              NUMERIC(5,4),  -- P(street_level)
    ml1_underground_prob         NUMERIC(5,4),  -- P(underground)
    ml1_above_prob               NUMERIC(5,4),  -- P(above_ground)
    ml1_non_street_confidence    NUMERIC(5,4),  -- composite score "not a street"
    ml1_decision                 model_decision,

    -- Spatial Context Service
    spatial_in_paid_zone        BOOLEAN,
    spatial_zone_id             UUID REFERENCES paid_zones(id),
    spatial_dist_to_road_m      NUMERIC(8,2),
    spatial_road_type           TEXT,          -- OSM highway tag
    spatial_score               NUMERIC(5,4),

    -- Model 2 — Spatial Decision Classifier (when implemented)
    ml2_charge_confidence        NUMERIC(5,4),
    ml2_garage_surface_prob      NUMERIC(5,4),
    ml2_decision                 model_decision,

    -- Final pipeline decision
    final_decision              model_decision NOT NULL DEFAULT 'uncertain',
    final_confidence            NUMERIC(5,4)
);

CREATE INDEX idx_inference_logs_session ON inference_logs(session_id);
CREATE INDEX idx_inference_logs_model ON inference_logs(model_version_id);

--==============================================================
--  6. TRAINING_LABELS
--  Ground truth for training - separated from inference_logs
--  so we can have multiple label sources (user, manual, auto)
-- ==============================================================

CREATE TABLE training_labels (
    id                  UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    session_id          UUID NOT NULL REFERENCES parking_sessions(id),
    inference_log_id    UUID REFERENCES inference_logs(id),

    -- Label
    location_type       location_type NOT NULL,
    label_confidence    NUMERIC(5,4) NOT NULL DEFAULT 1.0,  -- 1.0 = full certainty
    label_source        TEXT NOT NULL,   -- 'user_confirm' | 'user_cancel' | 'manual' | 'auto'
    labelled_by         UUID REFERENCES users(id),          -- NULL if automatic

    -- Confirmed geometry (may differ slightly from GPS)
    confirmed_location  GEOMETRY(POINT, 4326),

    -- For model error analysis
    model_was_correct   BOOLEAN,        -- comparison with final_decision
    error_type          TEXT,           -- 'false_positive' | 'false_negative' | NULL

    -- Quality flags for filtering during training
    is_valid            BOOLEAN NOT NULL DEFAULT TRUE,
    exclusion_reason    TEXT,           -- reason if is_valid = FALSE

    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_training_labels_geom ON training_labels USING GIST(confirmed_location);
CREATE INDEX idx_training_labels_session ON training_labels(session_id);

--============================================================
--  7. MODEL_VERSIONS
--  Registry of model versions - Model 1 and Model 2
-- ============================================================

CREATE TABLE model_versions (
    id                  UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    model_name          TEXT NOT NULL,       -- 'vertical_classifier' | 'spatial_classifier'
    version_tag         TEXT NOT NULL,       -- ex: 'v1.0.0', 'v1.2.3'
    description         TEXT,

    -- Artifact
    artifact_path       TEXT NOT NULL,      -- trained model path

    -- Training metrics
    train_accuracy      NUMERIC(5,4),
    train_f1_score      NUMERIC(5,4),
    val_accuracy        NUMERIC(5,4),
    val_f1_score        NUMERIC(5,4),
    val_precision       NUMERIC(5,4),
    val_recall          NUMERIC(5,4),
    train_sample_count  INTEGER,
    val_sample_count    INTEGER,

    -- Deployment
    is_active           BOOLEAN NOT NULL DEFAULT FALSE,  -- only one active per model_name
    deployed_at         TIMESTAMPTZ,
    retired_at          TIMESTAMPTZ,
    deployed_by         UUID REFERENCES users(id),

    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Ensure only one active version per model
CREATE UNIQUE INDEX idx_model_versions_active
    ON model_versions(model_name)
    WHERE is_active = TRUE;

--============================================================
--  USEFUL VIEWS FOR THE DEVELOPER DASHBOARD
-- ============================================================

-- View: model performance by session
CREATE OR REPLACE VIEW v_model_performance AS
SELECT
    il.final_decision,
    tl.location_type                            AS true_label,
    (il.final_decision = 'charge' AND tl.location_type IN ('street_paid')) AS model_was_correct,
    COUNT(*)                                    AS count,
    AVG(il.final_confidence)                    AS avg_confidence
FROM inference_logs il
LEFT JOIN training_labels tl ON tl.session_id = il.session_id
GROUP BY 1, 2, 3;

-- View: session distribution by type and city
CREATE OR REPLACE VIEW v_session_summary AS
SELECT
    ps.city,
    tl.location_type,
    tl.label_source,
    COUNT(*)                                    AS total,
    COUNT(*) FILTER (WHERE tl.model_was_correct = TRUE)  AS correct,
    COUNT(*) FILTER (WHERE tl.model_was_correct = FALSE) AS incorrect,
    ROUND(
        COUNT(*) FILTER (WHERE tl.model_was_correct = TRUE)::NUMERIC
        / NULLIF(COUNT(*), 0) * 100, 2
    )                                           AS accuracy_pct
FROM parking_sessions ps
JOIN training_labels tl ON tl.session_id = ps.id
WHERE tl.is_valid = TRUE
GROUP BY 1, 2, 3;

-- View: errors by paid zone (to identify problematic zones)
CREATE OR REPLACE VIEW v_zone_error_rate AS
SELECT
    pz.id                                       AS paid_zone_id,
    pz.city,
    COUNT(il.id)                                AS total_inferences,
    COUNT(*) FILTER (WHERE tl.model_was_correct = FALSE) AS errors,
    ROUND(
        COUNT(*) FILTER (WHERE tl.model_was_correct = FALSE)::NUMERIC
        / NULLIF(COUNT(il.id), 0) * 100, 2
    )                                           AS error_rate_pct
FROM paid_zones pz
LEFT JOIN inference_logs il ON il.spatial_zone_id = pz.id
LEFT JOIN training_labels tl ON tl.session_id = il.session_id
GROUP BY pz.id, pz.city
ORDER BY error_rate_pct DESC NULLS LAST;