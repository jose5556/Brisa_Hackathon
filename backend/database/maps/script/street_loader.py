import os
import geopandas as gpd
import osmnx as ox
import pandas as pd

script_dir = os.path.dirname(os.path.abspath(__file__))
geojson_path = os.path.join(script_dir, '../brisa/Porto.geojson') 

zones_gdf = gpd.read_file(geojson_path)

def extrair_apenas_poligonos(geom):
    if geom is None:
        return None
    if geom.geom_type in ['Polygon', 'MultiPolygon']:
        return geom
    if geom.geom_type == 'GeometryCollection':
        poligonos_internos = [g for g in geom.geoms if g.geom_type in ['Polygon', 'MultiPolygon']]
        if not poligonos_internos:
            return None
        if len(poligonos_internos) == 1:
            return poligonos_internos[0]
        else:
            return unary_union(poligonos_internos)
    return None

zones_gdf['geometry'] = zones_gdf['geometry'].make_valid()
zones_gdf['geometry'] = zones_gdf['geometry'].apply(extrair_apenas_poligonos)
zones_gdf = zones_gdf[zones_gdf['geometry'].notnull()]

if zones_gdf.crs != "EPSG:4326":
    zones_gdf = zones_gdf.to_crs(epsg=4326)

all_streets = []

print(f"Starting processing of {len(zones_gdf)} zones with edge verification...\n")

for idx, row in zones_gdf.iterrows():
    zone_name = row.get('name', f"Zona {idx}")
    polygon_id = row.get('polygonId', 'N/A')
    polygon = row['geometry']
    
    print(f"-> Processing: {zone_name} (ID: {polygon_id})...")
    
    graph = None
    used_buffer = False
    
    try:
        # Try with the original polygon
        graph = ox.graph_from_polygon(polygon, network_type='drive', retain_all=True)
        
        # If the graph was created but has no streets (edges), force an exception to fall into the buffer
        if graph is None or len(graph.edges) == 0:
            raise ValueError("Graph contains no edges")
            
    except Exception as e:
        error_msg = str(e)
        
        # If no nodes/edges found or the graph came empty, apply the protective buffer
        if "no edges" in error_msg.lower() or "no graph nodes" in error_msg.lower():
            try:
                buffered_polygon = polygon.buffer(0.00015) 
                graph = ox.graph_from_polygon(buffered_polygon, network_type='drive', retain_all=True)
                used_buffer = True
                
                if graph is None or len(graph.edges) == 0:
                    print(f"   [WARNING] none streets found even after safety buffer expansion.")
                    continue
            except Exception as inner_e:
                print(f"   [ERROR] Failure in safety buffer: {inner_e}")
                continue
        else:
            print(f"   [ERROR] Critical failure in request: {e}")
            continue
            
    # Processing the Graph and converting to GeoDataFrame
    if graph is not None:
        try:
            _, streets_gdf = ox.graph_to_gdfs(graph)
            streets_gdf = streets_gdf.reset_index()
            
            # If used the buffer, cut the excesses to maintain the original shape of the zone
            if used_buffer:
                streets_gdf = gpd.clip(streets_gdf, polygon)
                if streets_gdf.empty:
                    print(f"   [WARNING] Adjacent streets fell outside the strict limit of the zone after clipping.")
                    continue
            
            streets_gdf['zona_nome'] = zone_name
            streets_gdf['zona_polygon_id'] = polygon_id
            
            all_streets.append(streets_gdf)
            
        except Exception as e:
            print(f"   [ERROR] Unexpected error while converting road network: {e}")

if all_streets:
    combined_streets_df = pd.concat(all_streets, ignore_index=True)
    final_streets_gdf = gpd.GeoDataFrame(combined_streets_df, crs="EPSG:4326")
    
    columns_to_keep = ['name', 'highway', 'oneway', 'zona_nome', 'zona_polygon_id', 'geometry']
    available_columns = [col for col in columns_to_keep if col in final_streets_gdf.columns]
    final_streets_gdf = final_streets_gdf[available_columns]
    
    output_file = os.path.join(script_dir, '../brisa/modified/Porto_ruas.geojson')
    final_streets_gdf.to_file(output_file, driver='GeoJSON')
    
    print(f"\n Success! {len(final_streets_gdf)} street segments cleaned and mapped.")
    print(f"Final robust file generated at: '{output_file}'")
else:
    print("\n[ERROR] No streets could be extracted from the batch.")