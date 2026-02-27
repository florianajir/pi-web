.PHONY: help install uninstall start stop restart status logs preflight headscale-register headscale-reset

PROJECT_PATH := $(shell pwd)
UNIT         := pi-web.service
COMPOSE      := docker compose

ifeq (headscale-register,$(firstword $(MAKECMDGOALS)))
HEADSCALE_KEY := $(word 2,$(MAKECMDGOALS))
$(eval $(HEADSCALE_KEY):;@:)
endif

help:
	@echo "Commands:"
	@echo "  install   Install & enable systemd unit, start stack and initialize"
	@echo "  uninstall Stop stack, remove all data/volumes and uninstall systemd units"
	@echo "  start     Start stack"
	@echo "  stop      Stop stack"
	@echo "  restart   Restart stack"
	@echo "  status    Show systemd status"
	@echo "  logs      Follow compose logs"
	@echo "  preflight Quick env readiness check"
	@echo "  headscale-register <key> Register a headscale node"
	@echo "  headscale-reset Reset all Headscale nodes, preauth keys, and IP allocations"
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
	@echo "🧰 Applying host sysctl settings..."
	sudo cp config/sysctl.d/pi-web.conf /etc/sysctl.d/99-pi-web.conf
	sudo sysctl --system >/dev/null
	sed 's|__PROJECT_PATH__|$(PROJECT_PATH)|g' config/systemd/system/pi-web.service > /tmp/$(UNIT)
	sudo cp /tmp/$(UNIT) /etc/systemd/system/
	sudo cp config/systemd/system/pi-web-restart.service /etc/systemd/system/
	sudo cp config/systemd/system/pi-web-restart.timer /etc/systemd/system/
	sudo systemctl daemon-reload
	sudo systemctl enable $(UNIT)
	@echo "✅ Systemd units installed"
	@if [ "$(SKIP_START)" = "1" ]; then \
		echo "⏭️  SKIP_START=1 set; not starting stack"; \
	else \
		echo "🚀 Starting stack..."; \
		sudo systemctl start $(UNIT); \
	fi
	@echo "✅ Installation complete"

uninstall:
	@echo "🗑️  Uninstalling Pi-Web..."
	@echo ""
	@echo "⚠️  WARNING: This will remove ALL data including:"
	@echo "   - Docker volumes (Pi-hole, Headscale, etc.)"
	@echo "   - Bind-mount data dirs: ./data/nextcloud, ./data/postgres, ./data/n8n, ./data/immich"
	@echo "   - Generated config: ./config/headplane/config.yaml" 
	@echo "   - Generated config: ./config/headscale/config.yaml"
	@echo "   - Generated config: ./config/headscale/policy.hujson"
	@echo "   - Systemd service units"
	@echo ""
	@read -p "Are you sure? Type 'yes' to confirm: " confirm && [ "$$confirm" = "yes" ] || (echo "Aborted"; exit 1)
	@echo ""
	@echo "🛑 Stopping services..."
	-sudo systemctl stop $(UNIT) 2>/dev/null || true
	-sudo systemctl stop pi-web-restart.timer 2>/dev/null || true
	@echo "🐳 Removing containers and volumes..."
	-$(COMPOSE) down -v --remove-orphans 2>/dev/null || true
	@echo "🧹 Removing bind-mount data directories..."
	-sudo rm -rf ./data/nextcloud ./data/postgres ./data/n8n ./data/immich
	@echo "🧹 Removing generated config files..."
	-rm -f ./config/headplane/config.yaml
	-rm -f ./config/headscale/config.yaml
	-rm -f ./config/headscale/policy.hujson
	@echo "🧰 Removing host sysctl settings..."
	-sudo rm -f /etc/sysctl.d/99-pi-web.conf
	-sudo sysctl --system >/dev/null
	@echo "🧹 Removing systemd units..."
	-sudo systemctl disable $(UNIT) 2>/dev/null || true
	-sudo systemctl disable pi-web-restart.timer 2>/dev/null || true
	-sudo rm -f /etc/systemd/system/$(UNIT)
	-sudo rm -f /etc/systemd/system/pi-web-restart.service
	-sudo rm -f /etc/systemd/system/pi-web-restart.timer
	-sudo systemctl daemon-reload
	@echo "✅ Uninstall complete"
	@echo ""
	@echo "ℹ️  Note: .env file preserved. Remove manually if needed."

start:
	@echo "🚀 Starting Pi-Web stack..."
	sudo systemctl start $(UNIT)
	@echo "✅ Stack started"

stop:
	@echo "🛑 Stop"
	-sudo systemctl stop $(UNIT)
	@echo "✅ Stopped"

restart:
	@echo "🔄 Restart"
	-sudo systemctl restart $(UNIT)
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

headscale-register:
	@echo "🔐 Registering headscale node..."
	@if [ ! -f .env ]; then echo "❌ .env missing (copy .env.dist)"; exit 1; fi
	@if [ -z "$(HEADSCALE_KEY)" ]; then echo "❌ Key missing (use: make headscale-register <key>)"; exit 1; fi
	@EMAIL_FROM_ENV="$${EMAIL:-$$(grep -E '^EMAIL=' .env | tail -n1 | cut -d= -f2-)}"; \
	if [ -z "$$EMAIL_FROM_ENV" ]; then echo "❌ EMAIL not set in .env"; exit 1; fi; \
	$(COMPOSE) run --rm headscale nodes register --key "$(HEADSCALE_KEY)" --user "$$EMAIL_FROM_ENV"

headscale-reset:
	@echo "⚠️  This will WIPE ALL Headscale nodes, preauth keys, and IP allocations!"
	@read -p "Are you sure? Type 'yes' to confirm: " confirm && [ "$$confirm" = "yes" ] || (echo "Aborted"; exit 1)
	@echo "🧹 Deleting all Headscale nodes..."
	-docker compose exec -T headscale headscale nodes list -o json | jq -r '.[].id' 2>/dev/null | xargs -r -I{} docker compose exec -T headscale headscale nodes delete --identifier {} --force
	@echo "🧹 Deleting all Headscale preauth keys..."
	-docker compose exec -T headscale headscale preauthkeys list -o json | jq -r '.[].id' 2>/dev/null | xargs -r -I{} docker compose exec -T headscale headscale preauthkeys expire --id {} --force
	@echo "🧹 Resetting Headscale IP allocations (restarting service)..."
	-docker compose restart headscale
	@echo "✅ Headscale reset complete"
