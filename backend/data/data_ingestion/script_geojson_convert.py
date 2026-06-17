import geopandas as gpd
from sqlalchemy import create_engine

engine = create_engine("postgresql://parking_user:parking_password@localhost:5432/parking_db")

# Read the city road segments GeoJSON file
# GeoPandas will read the file and create a GeoDataFrame automatically
gdf_vias = gpd.read_file("../maps/OPO_paidzones.geojson")

# Ensure the data uses SRID 4326 (WGS84)
gdf_vias = gdf_vias.to_crs(epsg=4326)
gdf_vias['source'] = 'PortoDigital'
gdf_vias['source_version'] = '13_03_2026'  # date or tag version

# Inject directly into the database
# Note: This creates/replaces a table named 'name_of_the_table'
gdf_vias.to_postgis("OPO_paidzones", con=engine, if_exists="replace", index=False)
print("Porto road segments imported successfully!")

