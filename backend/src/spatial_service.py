from sqlalchemy import text
from sqlalchemy.orm import Session

def get_spatial_context(db: Session, latitude: float, longitude: float, city: str = 'OPO') -> dict:
    """
    Uses PostGIS to calculate the distance from the car to the nearest paid zone.
    Uses the generic GEOGRAPHY type so that the distance is in real meters.
    """
    result = db.execute(
        text(
            """
            SELECT 
                id AS zone_id,
                ST_Distance(
                    ST_SetSRID(ST_MakePoint(:lon, :lat), 4326)::geography,
                    geom::geography
                ) AS distance_to_zone_m
            FROM paid_zones
            WHERE city = CAST(:city AS city_code) AND is_active = TRUE
            ORDER BY distance_to_zone_m ASC
            LIMIT 1
            """
        ),
        {
            "lon": longitude,
            "lat": latitude,
            "city": city
        }
    ).mappings().first()

    if not result:
        # there are no paid zones in the database for this city, or the city code is invalid
        return {
            "in_paid_zone": False,
            "zone_id": None,
            "distance_to_zone_m": 9999.0
        }

    distance = float(result["distance_to_zone_m"])
    
    return {
        "in_paid_zone": distance <= 0.0,
        "zone_id": str(result["zone_id"]),
        "distance_to_zone_m": distance
    }