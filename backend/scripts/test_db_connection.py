import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from sqlalchemy import text

from src.database import engine


def main():
    with engine.connect() as connection:
        result = connection.execute(text("SELECT version();"))
        print(result.scalar())


if __name__ == "__main__":
    main()
