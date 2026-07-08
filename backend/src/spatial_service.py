import logging
from typing import Optional

from sqlalchemy import text
from sqlalchemy.orm import Session

log = logging.getLogger(__name__)

SEARCH_RADIUS_M = 30.0

def get_spatial_context(
    db: Session,
    latitude: Optional[float],
    longitude: Optional[float],
    city: str,) -> dict:
    """
    Uses PostGIS to calculate the distance from the car to the nearest paid zone.
    Uses the generic GEOGRAPHY type so that the distance is in real meters.
    """

    if latitude is None or longitude is None:
        log.warning(
            "get_spatial_context called with missing coordinates "
            "(lat=%s, lon=%s) — returning no-zone result.",
            latitude, longitude,
        )
        return _no_zone_result(reason="missing_coordinates")

    if not city:
        log.warning("get_spatial_context called without city — returning no-zone result.")
        return _no_zone_result(reason="missing_city")
    
    if not (-90 <= latitude <= 90) or not (-180 <= longitude <= 180):
        log.warning(
            "Invalid coordinates (lat=%s, lon=%s) — returning no-zone result.",
            latitude, longitude,
        )
        return _no_zone_result(reason="invalid_coordinates")
    
    try:
        result = db.execute(
            text(
                """
                SELECT 
                    id AS zone_id,
                    ST_Within(
                        ST_SetSRID(ST_MakePoint(:lon, :lat), 4326),
                        geom
                    )                               AS inside_zone,
                    ST_Distance(
                        ST_SetSRID(ST_MakePoint(:lon, :lat), 4326)::geography,
                        geom::geography
                    ) AS distance_to_zone_m
                FROM paid_zones
                WHERE city = CAST(:city AS city_code) AND is_active = TRUE
                AND ST_DWithin(
                            ST_SetSRID(ST_MakePoint(:lon, :lat), 4326)::geography,
                            geom::geography,
                            :radius_m
                )
                ORDER BY distance_to_zone_m ASC
                LIMIT 1
                """
            ),
            {
                "lon": longitude,
                "lat": latitude,
                "city": city,
                "radius_m": SEARCH_RADIUS_M
            }
        ).mappings().first()

    except Exception:
        log.exception(
            "PostGIS query failed for (lat=%s, lon=%s, city=%s).",
            latitude, longitude, city,
        )
        return _no_zone_result(reason="db_error")
    
    if result is None:
        log.debug(
            "No paid zone within %.0f m of (lat=%s, lon=%s, city=%s).",
            SEARCH_RADIUS_M, latitude, longitude, city,
        )
        return _no_zone_result(reason="no_zone_nearby")
    
    inside_zone        = bool(result["inside_zone"])
    distance_to_zone_m = float(result["distance_to_zone_m"])
    zone_id            = str(result["zone_id"])

    log.debug(
        "Spatial result: zone_id=%s  inside=%s  distance=%.2f m",
        zone_id, inside_zone, distance_to_zone_m,
    )

    return {
        "in_paid_zone":        inside_zone,
        "zone_id":             zone_id,
        "distance_to_zone_m":  distance_to_zone_m,
        "reason":              None,
    }

def _no_zone_result(reason: str) -> dict:
    return {
        "in_paid_zone":        None,
        "zone_id":             None,
        "distance_to_zone_m":  None,
        "reason":              reason,
    }