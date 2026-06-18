
PYTHON ?= python3
VENV ?= venv
PYTHON_VENV := $(VENV)/bin/python
PIP_VENV := $(VENV)/bin/python -m pip
CERT_DIR ?= certs
SSL_CERT_FILE ?= $(CERT_DIR)/dev-cert.pem
SSL_KEY_FILE ?= $(CERT_DIR)/dev-key.pem
HOST ?= 0.0.0.0
PORT ?= 8000

.PHONY: venv install test up down api api-http cert train data db-test db-init db-reset db-shell help

help:
	@echo "Available targets:"
	@echo "  make venv        - create the backend virtual environment"
	@echo "  make install     - install Python dependencies"
	@echo "  make train       - train the ML model"
	@echo "  make cert        - create a self-signed development SSL certificate"
	@echo "  make api         - run the FastAPI server over HTTPS (default)"
	@echo "  make api-http    - run the FastAPI server over HTTP for local mobile development"
	@echo "  make up          - start the PostgreSQL container"
	@echo "  make down        - stop the PostgreSQL container"
	@echo "  make data        - generate synthetic training data"
	@echo "  make db-init     - load database/schema.sql into PostgreSQL"
	@echo "  make db-reset    - recreate the database and reload the schema"
	@echo "  make db-shell    - open a psql shell in the database container"
	@echo "  make db-test     - test the DB connection"
	@echo "  make test        - run the prediction tests"

venv:
	$(PYTHON) -m venv $(VENV)

install: venv
	. $(VENV)/bin/activate && $(PIP_VENV) install --upgrade pip && $(PIP_VENV) install -r requirements.txt

train: data
	. $(VENV)/bin/activate && $(PYTHON_VENV) scripts/train_model.py

cert:
	@mkdir -p $(CERT_DIR)
	@if [ ! -f "$(SSL_CERT_FILE)" ] || [ ! -f "$(SSL_KEY_FILE)" ]; then \
		openssl req -x509 -nodes -newkey rsa:2048 -days 365 \
			-keyout "$(SSL_KEY_FILE)" \
			-out "$(SSL_CERT_FILE)" \
			-subj "/C=PT/ST=Lisbon/L=Lisbon/O=Brisa/OU=Dev/CN=localhost"; \
	fi

api: cert
	. $(VENV)/bin/activate && $(PYTHON_VENV) -m uvicorn src.main:app --host $(HOST) --port $(PORT) --reload --ssl-keyfile $(SSL_KEY_FILE) --ssl-certfile $(SSL_CERT_FILE)

api-http:
	. $(VENV)/bin/activate && $(PYTHON_VENV) -m uvicorn src.main:app --host $(HOST) --port $(PORT) --reload

up:
	docker compose up -d

down:
	docker compose down

data:
	. $(VENV)/bin/activate && $(PYTHON_VENV) scripts/generate_synthetic_data.py

db-test:
	. $(VENV)/bin/activate && $(PYTHON_VENV) ../tests/back/test_db_connection.py

db-init:
	docker compose exec -T db psql -U parking_user -d parking_db < database/schema.sql

db-reset:
	docker compose down -v
	docker compose up -d
	@until docker compose exec -T db pg_isready -U parking_user -d parking_db >/dev/null 2>&1; do \
		sleep 1; \
	done
	docker compose exec -T db psql -U parking_user -d parking_db < database/schema.sql

db-shell:
	docker compose exec db psql -U parking_user -d parking_db

test:
	. $(VENV)/bin/activate && $(PYTHON_VENV) -m pytest ../tests/ml/test_vertical_ml_predict.py
