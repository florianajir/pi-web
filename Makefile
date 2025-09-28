################################################################################
# Minimal Makefile for pi-web
# Keeps only essential operational commands.
################################################################################

.PHONY: help install start stop restart update status logs preflight

PROJECT_PATH := $(shell pwd)
UNIT         := pi-web.service
COMPOSE      := docker compose

help:
	@echo "Commands:"
	@echo "  install   Install & enable systemd unit"
	@echo "  start     Start stack"
	@echo "  stop      Stop stack"
	@echo "  restart   Restart stack"
	@echo "  status    Show systemd status"
	@echo "  logs      Follow compose logs"
	@echo "  update    Git pull + restart"
	@echo "  preflight Quick env readiness check"
	@echo "  help      This help"

preflight:
	@echo "🔍 Preflight...";
	@if ! docker info >/dev/null 2>&1; then echo "❌ Docker not reachable"; exit 1; fi
	@echo "✔ Docker OK"
	@if mount | grep -q ' type cgroup2 '; then echo "✔ cgroup v2"; else echo "ℹ legacy cgroup"; fi
	@if docker run --rm -m 32m busybox sh -c 'cat /sys/fs/cgroup/memory.max 2>/dev/null || cat /sys/fs/cgroup/memory/memory.limit_in_bytes 2>/dev/null' | grep -qE '33554432|32'; then echo "✔ memory limits enforced"; else echo "⚠ memory limits NOT enforced"; fi
	@echo "Done"

install:
	@echo "📦 Installing..."
	@if [ ! -f .env ]; then echo "❌ .env missing (copy .env.dist)"; exit 1; fi
	sed 's|__PROJECT_PATH__|$(PROJECT_PATH)|g' config/systemd/system/pi-web.service > /tmp/$(UNIT)
	sudo cp /tmp/$(UNIT) /etc/systemd/system/
	sudo cp config/systemd/system/pi-web-restart.service /etc/systemd/system/
	sudo cp config/systemd/system/pi-web-restart.timer /etc/systemd/system/
	sudo systemctl daemon-reload
	sudo systemctl enable $(UNIT)
	@echo "✅ Installed"

start:
	@echo "🚀 Start"
	sudo systemctl start $(UNIT)
	@echo "✅ Started"

stop:
	@echo "🛑 Stop"
	sudo systemctl stop $(UNIT)
	@echo "✅ Stopped"

restart:
	@echo "🔄 Restart"
	sudo systemctl restart $(UNIT)
	@echo "✅ Restarted"

update:
	@echo "🔄 Update (git pull + restart)"
	@git pull --ff-only
	$(MAKE) restart
	@echo "✅ Update complete"

status:
	@echo "📊 Status"
	sudo systemctl status $(UNIT) --no-pager -l

logs:
	@echo "📝 Logs (Ctrl+C to exit)"
	$(COMPOSE) logs -f --tail=100

