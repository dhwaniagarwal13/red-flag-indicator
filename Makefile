PY := .venv/Scripts/python.exe
DBT := ../.venv/Scripts/dbt.exe
UNIVERSE ?= pilot

# Absolute repo root. dbt models resolve raw Parquet paths against it (see
# stg_facts.sql) so the warehouse can be queried from any working directory,
# not just from inside dbt/.
export REDFLAG_ROOT := $(CURDIR)

.PHONY: help install fetch-sp500 ingest ingest-prices seeds build test all sloan-test clean

help:
	@echo "make install           create venv and install deps"
	@echo "make fetch-sp500       fetch current S&P 500 constituents (one-time / refresh)"
	@echo "make ingest            fetch filings  (UNIVERSE=pilot; UNIVERSE=full for S&P 500)"
	@echo "make ingest-prices     fetch price history for Z-Score (UNIVERSE=pilot)"
	@echo "make seeds             export concepts.py metadata to dbt/seeds/"
	@echo "make build             seeds + run dbt models"
	@echo "make test              run dbt tests + pytest"
	@echo "make sloan-test        print the Sloan (1996) accrual anomaly report (Phase 4)"
	@echo "make all               ingest + ingest-prices + build + test"
	@echo "make clean             drop generated data (keeps the raw cache)"

install:
	python -m venv .venv
	$(PY) -m pip install --upgrade pip
	$(PY) -m pip install -e ".[dev]"

fetch-sp500:
	PYTHONPATH=src $(PY) -m redflag.fetch_sp500

ingest:
	PYTHONPATH=src $(PY) -m redflag.ingest --universe $(UNIVERSE)

ingest-prices:
	PYTHONPATH=src $(PY) -m redflag.ingest_prices --universe $(UNIVERSE)

seeds:
	PYTHONPATH=src $(PY) -m redflag.export_seeds

build: seeds
	# --full-refresh: concepts.csv's columns change often enough during
	# development that dbt's incremental seed-load can't sniff a schema
	# change reliably (it errors trying to match the CSV against the old
	# table shape). The seed is 23 rows — a full reload costs nothing.
	cd dbt && DBT_PROFILES_DIR=. $(DBT) seed --full-refresh
	cd dbt && DBT_PROFILES_DIR=. $(DBT) run

test:
	cd dbt && DBT_PROFILES_DIR=. $(DBT) test
	PYTHONPATH=src $(PY) -m pytest -q

sloan-test:
	PYTHONPATH=src $(PY) -m redflag.sloan_test

all: ingest ingest-prices build test

# Deliberately spares data/raw — refetching from the SEC (and re-fetching
# price history) is slow and impolite.
clean:
	rm -f data/redflag.duckdb data/staging/*.parquet
	rm -rf dbt/target dbt/logs
