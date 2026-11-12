# ==============================================================================
# MORNYE NETWORK STORAGE — AUTOMATION MAKEFILE
# ==============================================================================

.PHONY: help setup start stop restart status doctor dashboard test docker-build docker-up docker-down docker-logs backup clean

help:
	@echo "Mornye Network Storage — Available Make Targets:"
	@echo "  make setup         - Run automated Linux system setup (setup.sh)"
	@echo "  make start         - Start native WebDAV service"
	@echo "  make stop          - Stop WebDAV service"
	@echo "  make restart       - Restart WebDAV service"
	@echo "  make status        - Display unified infrastructure status"
	@echo "  make doctor        - Run system dependency diagnostics"
	@echo "  make dashboard     - Launch real-time monitoring dashboard"
	@echo "  make test          - Run automated pytest test suite"
	@echo "  make docker-build  - Build production multi-stage Docker image"
	@echo "  make docker-up     - Start containerized WebDAV stack"
	@echo "  make docker-down   - Stop containerized WebDAV stack"
	@echo "  make docker-logs   - Tail container service logs"
	@echo "  make backup        - Create hot online SQLite database backup"
	@echo "  make clean         - Remove temporary files and test caches"

setup:
	@./setup.sh

start:
	@./mornye.sh start

stop:
	@./mornye.sh stop

restart:
	@./mornye.sh restart

status:
	@./mornye.sh status

doctor:
	@./mornye.sh doctor

dashboard:
	@./mornye.sh dashboard

test:
	@pytest tests/ -v

docker-build:
	@docker compose build

docker-up:
	@docker compose up -d

docker-down:
	@docker compose down

docker-logs:
	@docker compose logs -f

backup:
	@./mornye.sh backup create

clean:
	@find . -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
	@find . -type f -name "*.pyc" -delete 2>/dev/null || true
	@rm -rf .pytest_cache .coverage
	@echo "[✔] Cleanup complete."
