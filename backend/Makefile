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

MAKEFILE_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
COMPOSE_FILE := $(MAKEFILE_DIR)docker-compose.yml
SCHEMA_FILE := $(MAKEFILE_DIR)database/schema/schema.sql
DOCKER_COMPOSE := docker compose -f $(COMPOSE_FILE)

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
	test-api

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

train-vertical: 
	$(PYTHON_VENV) scripts/train_vertical_lgbm.py

train-spatial: 
	$(PYTHON_VENV) scripts/train_spatial_lgbm.py

cert:
	@mkdir -p $(CERT_DIR)
	@if [ ! -f "$(SSL_CERT_FILE)" ] || [ ! -f "$(SSL_KEY_FILE)" ]; then \
		openssl req -x509 -nodes -newkey rsa:2048 -days 365 \
			-keyout "$(SSL_KEY_FILE)" \
			-out "$(SSL_CERT_FILE)" \
			-subj "/C=PT/ST=Lisbon/L=Lisbon/O=Brisa/OU=Dev/CN=localhost" \
			-addext "subjectAltName=DNS:localhost,IP:127.0.0.1,IP:$(CERT_IP)"; \
	fi

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
	$(DOCKER_COMPOSE) up -d

down:
	$(DOCKER_COMPOSE) down -v

db-reset:
	$(DOCKER_COMPOSE) down -v
	$(DOCKER_COMPOSE) up -d
	@until $(DOCKER_COMPOSE) exec -T db pg_isready -U parking_user -d parking_db >/dev/null 2>&1; do sleep 1; done

db-shell:
	$(DOCKER_COMPOSE) exec db psql -U parking_user -d parking_db

db-load-maps:
	$(PYTHON_VENV) database/data_ingestion/geojson_loader.py

tests:
	$(PYTHON_VENV) -m pytest ../tests

db-test:
	$(PYTHON_VENV) ../tests/back/test_db_connection.py

test-api:
	$(PYTHON_VENV) -m pytest ../tests/back/test_api.py
