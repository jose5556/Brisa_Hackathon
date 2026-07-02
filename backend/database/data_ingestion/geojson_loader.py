import os # to check if the file exists
import geopandas as gpd
from sqlalchemy import create_engine, text

DATABASE_URL = "postgresql://parking_user:parking_password@localhost:5432/parking_db"
engine = create_engine(DATABASE_URL)

geojson_path = "../maps/OPO_paidzones.geojson"

if not os.path.exists(geojson_path):
    print(f"Error: The file was not found at {geojson_path}")
    exit()

# Read the city road segments GeoJSON file
# GeoPandas will read the file and create a GeoDataFrame(gdf) automatically
gdf_roads = gpd.read_file(geojson_path)

# Ensure the data uses SRID 4326 (WGS84)
if gdf_roads.crs != "EPSG:4326":
        print("Converting coordinate system to EPSG:4326...")
        gdf_roads = gdf_roads.to_crs(epsg=4326)

gdf_roads['source'] = 'PortoDigital'
gdf_roads['source_version'] = '13_03_2026'  # date or tag version
gdf_roads['city'] = 'OPO'

gdf_roads = gdf_roads.rename_geometry('geom')

colunas_schema = ['city', 'geom', 'source', 'source_version']
gdf_roads = gdf_roads[colunas_schema]

# Inject directly into the database
gdf_roads.to_postgis(name="paid_zones", con=engine, if_exists="append", index=False)

print("Porto road segments imported successfully!")

'''
for testing in terminal:
docker exec -it parking-postgis psql -U parking_user -d parking_db -c "SELECT city, source, source_version, COUNT(*) FROM paid_zones GROUP BY city, source, source_version;"
'''
