import os
import glob
from datetime import datetime
import geopandas as gpd
from sqlalchemy import create_engine

# Remote server configuration
DATABASE_URL = "postgresql://parking_user:parking_password@localhost:5432/parking_db"
engine = create_engine(DATABASE_URL)

# Path to the 'valid' directory containing the map files
maps_dir = os.path.join(os.path.dirname(__file__), "..", "maps", "valid")

# Look for all .geojson files inside the valid folder
geojson_files = glob.glob(os.path.join(maps_dir, "*.geojson"))

if not geojson_files:
    print(f"Error: No .geojson files found at {os.path.abspath(maps_dir)}")
    exit()

print(f"Found {len(geojson_files)} files to process.\n")

# Dynamically get the current date in DD_MM_YYYY format
current_date_tag = datetime.now().strftime("%d_%m_%Y")

# Dictionary to cleanly map file names to the exact text expected by your custom city_code type
CITY_SCHEMA_MAP = {
    "Porto": "Porto",
    "Oeiras": "Oeiras",
    "Espinho": "Espinho",
    "Matosinhos": "Matosinhos",
    "Maia": "Maia",
    "Vila_nova_de_Gaia": "Vila nova de Gaia",
    "Arouca"
}

for file_path in geojson_files:
    file_name = os.path.basename(file_path)
    file_base = os.path.splitext(file_name)[0]
    
    # Match the database string expectation
    db_city_value = CITY_SCHEMA_MAP.get(file_base, file_base)
    
    print(f"Processing {file_base} as schema value '{db_city_value}' ({file_name})...")
    
    try:
        from shapely.geometry import MultiLineString, LineString

        # Read the GeoJSON map file
        gdf_roads = gpd.read_file(file_path)
        
        # Ensure data uses SRID 4326 (WGS84)
        if gdf_roads.crs != "EPSG:4326":
            print(f"  -> Converting coordinate system for {file_base} to EPSG:4326...")
            gdf_roads = gdf_roads.to_crs(epsg=4326)

        # Convert Polygons into LineStrings
        if any(geom.geom_type in ['Polygon', 'MultiPolygon'] for geom in gdf_roads.geometry if geom):
            print(f"  -> Detected Polygon data. Extracting boundaries...")
            gdf_roads.geometry = gdf_roads.geometry.boundary
            
        # Safe MultiLineString wrapping across all variants
        def ensure_multilinestring(geom):
            if geom is None:
                return None
            if isinstance(geom, LineString):
                return MultiLineString([geom])
            if isinstance(geom, MultiLineString):
                return geom
            if hasattr(geom, "geoms"):
                lines = [g for g in geom.geoms if isinstance(g, LineString)]
                return MultiLineString(lines) if lines else geom
            return geom

        gdf_roads.geometry = gdf_roads.geometry.apply(ensure_multilinestring)

        # Set dynamic metadata
        gdf_roads['city'] = db_city_value  
        gdf_roads['source'] = 'BrisaHackathon'
        gdf_roads['source_version'] = current_date_tag
        
        # Rename geometry column to 'geom'
        gdf_roads = gdf_roads.rename_geometry('geom')
        
        # Filter target schema columns
        colunas_schema = ['city', 'geom', 'source', 'source_version']
        gdf_roads = gdf_roads[colunas_schema]
        
        # Append data directly into the remote database
        gdf_roads.to_postgis(name="paid_zones", con=engine, if_exists="append", index=False)
        print(f"  -> {file_base} imported successfully!")
        
    except Exception as e:
        print(f"  [ERROR] Failed to process {file_base}: {e}")

print("\nAll available maps have been processed!")