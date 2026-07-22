PY := .venv/Scripts/python.exe
DBT := ../.venv/Scripts/dbt.exe
UNIVERSE ?= pilot

# Absolute repo root. dbt models resolve raw Parquet paths against it (see
# stg_facts.sql) so the warehouse can be queried from any working directory,
# not just from inside dbt/.
export REDFLAG_ROOT := $(CURDIR)

.PHONY: help install ingest seeds build test all clean

help:
	@echo "make install           create venv and install deps"
	@echo "make ingest            fetch filings  (UNIVERSE=pilot)"
	@echo "make seeds             export concepts.py metadata to dbt/seeds/"
	@echo "make build             seeds + run dbt models"
	@echo "make test              run dbt tests + pytest"
	@echo "make all               ingest + build + test"
	@echo "make clean             drop generated data (keeps the raw cache)"

install:
	python -m venv .venv
	$(PY) -m pip install --upgrade pip
	$(PY) -m pip install -e ".[dev]"

ingest:
	PYTHONPATH=src $(PY) -m redflag.ingest --universe $(UNIVERSE)

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

all: ingest build test

# Deliberately spares data/raw — refetching from the SEC is slow and impolite.
clean:
	rm -f data/redflag.duckdb data/staging/*.parquet
	rm -rf dbt/target dbt/logs
