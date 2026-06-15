PYTHON ?= python3
VENV ?= venv
PYTHON_VENV := $(VENV)/bin/python
PIP_VENV := $(VENV)/bin/python -m pip

.PHONY: venv install test up down api train db-test help

help:
	@echo "Available targets:"
	@echo "  make venv        - create the backend virtual environment"
	@echo "  make install     - install Python dependencies"
	@echo "  make train       - train the ML model"
	@echo "  make api         - run the FastAPI server"
	@echo "  make up       - start the PostgreSQL container"
	@echo "  make down     - stop the PostgreSQL container"
	@echo "  make db-test     - test the DB connection"
	@echo "  make test        - run the prediction tests"

venv:
	$(PYTHON) -m venv $(VENV)

install: venv
	. $(VENV)/bin/activate && $(PIP_VENV) install --upgrade pip && $(PIP_VENV) install -r requirements.txt

train:
	. $(VENV)/bin/activate && $(PYTHON_VENV) scripts/train_model.py

api:
	. $(VENV)/bin/activate && $(PYTHON_VENV) -m uvicorn src.main:app --host 0.0.0.0 --port 8000 --reload

up:
	docker compose up -d

down:
	docker compose down

db-test:
	. $(VENV)/bin/activate && $(PYTHON_VENV) scripts/test_db_connection.py

test:
	. $(VENV)/bin/activate && $(PYTHON_VENV) -m pytest ../tests/test_vertical_ml_predict.py
