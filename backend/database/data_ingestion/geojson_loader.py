import os # to check if the file exists
import glob # to find the GeoJSON file
import geopandas as gpd
from sqlalchemy import create_engine
from datetime import datetime

# Remote server configuration
DATABASE_URL = "postgresql://parking_user:parking_password@100.121.113.91:5432/parking_db"
engine = create_engine(DATABASE_URL)

# Path to the 'valid' directory containing the map files
maps_dir = os.path.join(os.path.dirname(__file__), "..", "maps", "valid")

# Look for all .geojson files inside the valid folder
geojson_files = glob.glob(os.path.join(maps_dir, "*.geojson"))

if not geojson_files:
    print(f"Error: No .geojson files found at {os.path.abspath(maps_dir)}")
    exit()

print(f"Found {len(geojson_files)} files to process.\n")

current_date_tag = datetime.now().strftime("%d_%m_%Y")

for file_path in geojson_files:
    # Dynamically extract the city name from the file name (e.g., "Vila_nova_de_Gaia")
    file_name = os.path.basename(file_path)
    city_name = os.path.splitext(file_name)[0]
    
    print(f"Processing {city_name} ({file_name})...")
    
    try:
        # Read the GeoJSON map file
        gdf_roads = gpd.read_file(file_path)
        
        # Ensure data uses SRID 4326 (WGS84)
        if gdf_roads.crs != "EPSG:4326":
            print(f"  -> Converting coordinate system for {city_name} to EPSG:4326...")
            gdf_roads = gdf_roads.to_crs(epsg=4326)
        
        # Set dynamic metadata
        gdf_roads['city'] = city_name
        gdf_roads['source'] = 'BrisaHackathon'
        gdf_roads['source_version'] = current_date_tag
        
        # Rename geometry column to 'geom'
        gdf_roads = gdf_roads.rename_geometry('geom')
        
        # Filter target schema columns
        colunas_schema = ['city', 'geom', 'source', 'source_version']
        gdf_roads = gdf_roads[colunas_schema]
        
        # Append data directly into the remote database
        gdf_roads.to_postgis(name="paid_zones", con=engine, if_exists="append", index=False)
        print(f"  -> {city_name} imported successfully!")
        
    except Exception as e:
        print(f"  [ERROR] Failed to process {city_name}: {e}")

print("\nAll available maps have been processed!")

'''
for testing in terminal:
psql -h 100.121.113.91 -U parking_user -d parking_db -c "SELECT city, source, source_version, COUNT(*) FROM paid_zones GROUP BY city, source, source_version;"
'''
