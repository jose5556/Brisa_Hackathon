from sqlalchemy import create_engine, text

# A tua string de conexão exata com base no teu docker-compose
DATABASE_URL = "postgresql://parking_user:parking_password@localhost:5432/parking_db"

try:
    # 1. Criar o motor de conexão
    engine = create_engine(DATABASE_URL)
    
    # 2. Tentar abrir uma conexão e rodar uma query simples
    with engine.connect() as conexao:
        # Vamos perguntar ao PostGIS a versão dele para garantir que a extensão está ativa!
        resultado = conexao.execute(text("SELECT postgis_full_version();"))
        versao_postgis = resultado.scalar()
        
        print("\n✅ Conexão ao Docker estabelecida com sucesso!")
        print(f"🚀 Versão do PostGIS detetada: {versao_postgis}\n")
        
        # Opcional: Validar se as tuas tabelas do schema foram criadas
        tabelas = conexao.execute(text(
            "SELECT table_name FROM information_schema.tables WHERE table_schema='public';"
        ))
        print("Tabelas encontradas no banco de dados:")
        for t in tabelas:
            print(f" - {t[0]}")

except Exception as e:
    print("\n❌ Erro ao ligar ao banco de dados no Docker:")
    print(e, "\n")