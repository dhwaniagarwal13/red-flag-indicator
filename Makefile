PY := .venv/Scripts/python.exe
DBT := ../.venv/Scripts/dbt.exe
UNIVERSE ?= pilot

.PHONY: help install ingest build test all clean

help:
	@echo "make install           create venv and install deps"
	@echo "make ingest            fetch filings  (UNIVERSE=pilot)"
	@echo "make build             run dbt models"
	@echo "make test              run dbt tests + pytest"
	@echo "make all               ingest + build + test"
	@echo "make clean             drop generated data (keeps the raw cache)"

install:
	python -m venv .venv
	$(PY) -m pip install --upgrade pip
	$(PY) -m pip install -e ".[dev]"

ingest:
	PYTHONPATH=src $(PY) -m redflag.ingest --universe $(UNIVERSE)

build:
	cd dbt && DBT_PROFILES_DIR=. $(DBT) run

test:
	cd dbt && DBT_PROFILES_DIR=. $(DBT) test
	PYTHONPATH=src $(PY) -m pytest -q

all: ingest build test

# Deliberately spares data/raw — refetching from the SEC is slow and impolite.
clean:
	rm -f data/redflag.duckdb data/staging/*.parquet
	rm -rf dbt/target dbt/logs
