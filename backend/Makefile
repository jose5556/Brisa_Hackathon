PYTHON ?= python3
VENV ?= venv

PYTHON_VENV := $(VENV)/bin/python
PIP_VENV := $(PYTHON_VENV) -m pip

CERT_DIR ?= certs
SSL_CERT_FILE ?= $(CERT_DIR)/dev-cert.pem
SSL_KEY_FILE ?= $(CERT_DIR)/dev-key.pem

HOST ?= 0.0.0.0
PORT ?= 8000
CERT_IP ?= 10.21.220.182

.PHONY: \
	help \
	venv \
	install \
	data \
	train \
	tests \
	up \
	down \
	api \
	api-http \
	cert \
	cert-mkcert \
	db-init \
	db-reset \
	db-shell \
	db-test \
	db-test-api

help:
	@echo "Available targets:"
	@echo "  make venv        - create the backend virtual environment"
	@echo "  make install     - install Python dependencies"
	@echo "  make data        - generate synthetic training data"
	@echo "  make train       - train the ML model"
	@echo "  make cert        - create a self-signed HTTPS certificate"
	@echo "  make cert-mkcert - create a trusted local HTTPS certificate"
	@echo "  make api         - run the FastAPI server over HTTPS"
	@echo "  make api-http    - run the FastAPI server over HTTP"
	@echo "  make up          - start the PostgreSQL container"
	@echo "  make down        - stop the PostgreSQL container and remove volumes"
	@echo "  make db-init     - load the database schema"
	@echo "  make db-reset    - recreate the database and reload the schema"
	@echo "  make db-shell    - open a PostgreSQL shell"
	@echo "  make db-test     - run the database connection test"
	@echo "  make db-test-api - run only API tests"
	@echo "  make tests       - run all tests"

venv:
	$(PYTHON) -m venv $(VENV)

install: venv
	$(PIP_VENV) install --upgrade pip
	$(PIP_VENV) install -r requirements.txt

data:
	$(PYTHON_VENV) scripts/generate_synthetic_data.py

train: data
	$(PYTHON_VENV) scripts/train_model.py

cert:
	@mkdir -p "$(CERT_DIR)"
	@if [ ! -f "$(SSL_CERT_FILE)" ] || [ ! -f "$(SSL_KEY_FILE)" ]; then \
		openssl req -x509 -nodes -newkey rsa:2048 -days 365 \
			-keyout "$(SSL_KEY_FILE)" \
			-out "$(SSL_CERT_FILE)" \
			-subj "/C=PT/ST=Lisbon/L=Lisbon/O=Brisa/OU=Dev/CN=localhost"; \
	fi

cert-mkcert:
	@mkdir -p "$(CERT_DIR)"
	@if ! command -v mkcert >/dev/null 2>&1; then \
		echo "mkcert was not found. Install it with: brew install mkcert"; \
		exit 1; \
	fi
	@mkcert -install
	@mkcert \
		-cert-file "$(SSL_CERT_FILE)" \
		-key-file "$(SSL_KEY_FILE)" \
		localhost \
		127.0.0.1 \
		::1 \
		"$(CERT_IP)"

api: cert
	$(PYTHON_VENV) -m uvicorn src.main:app \
		--host "$(HOST)" \
		--port "$(PORT)" \
		--reload \
		--ssl-keyfile "$(SSL_KEY_FILE)" \
		--ssl-certfile "$(SSL_CERT_FILE)"

api-http:
	$(PYTHON_VENV) -m uvicorn src.main:app \
		--host "$(HOST)" \
		--port "$(PORT)" \
		--reload

up:
	docker compose up -d

down:
	docker compose down -v

db-init:
	docker compose exec -T db \
		psql -v ON_ERROR_STOP=1 \
		-U parking_user \
		-d parking_db \
		< database/schema/schema.sql

# some update broke this, needs to be fixed :(
db-reset:
	docker compose down -v
	docker compose up -d
	@until docker compose exec -T db \
		pg_isready -U parking_user -d parking_db >/dev/null 2>&1; do \
		sleep 1; \
	done
	docker compose exec -T db \
		psql -v ON_ERROR_STOP=1 \
		-U parking_user \
		-d parking_db \
		< database/schema/schema.sql

db-shell:
	docker compose exec db psql -U parking_user -d parking_db

tests:
	$(PYTHON_VENV) -m pytest ../tests

db-test:
	$(PYTHON_VENV) ../tests/back/test_db_connection.py

test-api:
	$(PYTHON_VENV) -m pytest ../tests/back/test_api.py
