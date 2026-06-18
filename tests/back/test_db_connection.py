from sqlalchemy import create_engine, text

DATABASE_URL = "postgresql://parking_user:parking_password@localhost:5432/parking_db"

try:
    engine = create_engine(DATABASE_URL)
    
    with engine.connect() as connection:
        result = connection.execute(text("SELECT postgis_full_version();"))
        postgis_version = result.scalar()
        
        print("\nConnection to Docker established successfully!")
        print(f"Detected PostGIS version: {postgis_version}\n")
        
        tables = connection.execute(text(
            "SELECT table_name FROM information_schema.tables WHERE table_schema='public';"
        ))
        print("Tables found in the database:")
        for t in tables:
            print(f" - {t[0]}")

except Exception as e:
    print("\nError connecting to the database in Docker:")
    print(e, "\n")