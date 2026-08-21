.PHONY: help install install-system uninstall start stop restart update status logs doctor preflight check-env print-required-vars test services enable disable config headscale-register headscale-reset rotate-password rotate-password-full

REQUIRED_ENV_VARS := HOST_NAME TIMEZONE EMAIL ADMIN_USER PASSWORD HOST_LAN_IP CLOUDFLARE_DNS_API_TOKEN CLOUDFLARE_ZONE_ID

MAKEFLAGS += --no-print-directory

PROJECT_PATH := $(shell pwd)
UNIT         := pi-pcloud.service
WATCH_UNIT   := pi-pcloud-authelia-ntfy.service
COMPOSE      := docker compose
# The pi-pcloud command and its completions. /usr/local/bin is on PATH for both
# users and sudo; the completion directories are Debian's own.
BIN_LINK        := /usr/local/bin/pi-pcloud
BASH_COMPLETION := /usr/share/bash-completion/completions/pi-pcloud
ZSH_COMPLETION  := /usr/share/zsh/vendor-completions/_pi-pcloud
# Empty when make already runs as root: root-only images often ship without a
# sudo binary at all (install.sh applies the same rule to its own commands).
SUDO         := $(if $(filter 0,$(shell id -u)),,sudo)
# Resolved by path, not by name: sysctl lives in /usr/sbin, which a root shell
# entered with `su` (no dash) does not have on its PATH — and $(SUDO) is empty
# there, so sudo's secure_path no longer covers it either.
SYSCTL       := $(firstword $(wildcard /usr/sbin/sysctl /sbin/sysctl) sysctl)

# A second word on the command line is an argument, not a target: `make enable
# stremio` reads better than `make enable s=stremio`, and the pi-pcloud command
# can then pass its own arguments straight through. The stub rule keeps make
# from trying to build that word as a goal; s=<service> still works.
ifneq (,$(filter enable disable headscale-register,$(firstword $(MAKECMDGOALS))))
GOAL_ARG := $(word 2,$(MAKECMDGOALS))
ifneq (,$(GOAL_ARG))
$(eval $(GOAL_ARG):;@:)
endif
endif
SERVICE       := $(if $(s),$(s),$(GOAL_ARG))
HEADSCALE_KEY := $(GOAL_ARG)

help:
	@echo "Commands:"
	@echo "  install          Install & enable systemd unit, start stack and initialize"
	@echo "  install-system   Re-apply the host files only (sysctl, /etc/hosts, units, command)"
	@echo "  uninstall        Stop stack, remove all data/volumes and uninstall systemd units"
	@echo "  start            Start stack"
	@echo "  stop             Stop stack"
	@echo "  restart          Restart stack"
	@echo "  update           Pull the repository and updated images, rebuild, restart"
	@echo "  status           Show systemd status"
	@echo "  logs             Follow compose logs"
	@echo "  services         List optional services and whether each is enabled"
	@echo "  enable <name>    Enable an optional service (updates COMPOSE_PROFILES, starts it, runs its init hooks)"
	@echo "  disable <name>   Disable an optional service (updates COMPOSE_PROFILES, stops it)"
	@echo "  config           Interactive checklist to choose which services run"
	@echo "  doctor           Report anything outside its threshold (disk, RAM, temp, containers, backups)"
	@echo "  preflight        Quick env readiness check"
	@echo "  headscale-register <key> Register a headscale node"
	@echo "  headscale-reset  Reset all Headscale nodes, preauth keys, and IP allocations"
	@echo "  check-env        Validate required .env variables"
	@echo "  test             Run the installer and check-env test suites (no host changes)"
	@echo "  rotate-password       Rotate PASSWORD after a leak (LLDAP admin + Authelia only, no Postgres)"
	@echo "  rotate-password-full  Same, plus every Postgres role and every other service using PASSWORD"
	@echo "  help             This help"

# Both the reader and the safety rule come from scripts/lib.sh, which install.sh
# also calls: a second copy of the rule here would let the installer and this
# check disagree the moment either is tightened.
check-env:
	@if [ ! -f .env ]; then echo "❌ .env missing (copy .env.dist)"; exit 1; fi
	@echo "🔍 Checking required .env variables..."; \
	if [ ! -r scripts/lib.sh ]; then echo "❌ scripts/lib.sh is missing or unreadable"; exit 1; fi; \
	. scripts/lib.sh >/dev/null 2>&1; \
	command -v env_value_is_safe >/dev/null 2>&1 || { echo "❌ scripts/lib.sh did not define env_value_is_safe"; exit 1; }; \
	missing=0; \
	for var in $(REQUIRED_ENV_VARS); do \
		val=$$(read_env_value_from_file .env "$$var"); \
		if [ -z "$$val" ]; then echo "  ❌ $$var is not set or empty"; missing=1; \
		elif ! env_value_is_safe "$$val"; then \
			echo "  ❌ $$var $$ENV_VALUE_RULES"; missing=1; \
		fi; \
	done; \
	if [ $$missing -eq 1 ]; then exit 1; fi
	@echo "✔ Required .env variables OK"

# Read by install.sh so it prompts for exactly this list: make expands `+=`
# appends and line continuations that a text scrape of this file would miss.
print-required-vars:
	@echo "$(REQUIRED_ENV_VARS)"

# Same suites CI runs. Every test works on a temporary copy, so this touches
# neither .env nor the host.
test:
	@sh tests/install-test.sh
	@sh tests/check-env-test.sh
	@sh tests/cli-test.sh

preflight: check-env
	@echo "🔍 Preflight...";
	@if ! docker info >/dev/null 2>&1; then echo "❌ Docker not reachable"; exit 1; fi
	@echo "✔ Docker OK"
	@if mount | grep -q ' type cgroup2 '; then echo "✔ cgroup v2"; else echo "ℹ legacy cgroup"; fi
	@if docker run --rm -m 32m busybox sh -c 'cat /sys/fs/cgroup/memory.max 2>/dev/null || cat /sys/fs/cgroup/memory/memory.limit_in_bytes 2>/dev/null' | grep -qE '33554432|32'; then echo "✔ memory limits enforced"; else echo "⚠ memory limits NOT enforced"; fi
	@echo "Done"

install: check-env install-system
	@if [ "$(SKIP_START)" = "1" ]; then \
		echo "⏭️  SKIP_START=1 set; not starting stack"; \
	else \
		echo "🚀 Starting stack..."; \
		$(SUDO) systemctl start $(UNIT); \
		$(MAKE) start; \
	fi
	@echo "✅ Installation complete"

# Everything this repository installs outside itself: sysctl, the /etc/hosts
# records, the systemd units (rendered with this checkout's path) and the
# pi-pcloud command. Split out of `install` so `update` can re-apply it after
# a pull: these are copies, so a unit or a completion changed upstream would
# otherwise sit stale on the host until the next install. Every step is
# idempotent. The command itself is a symlink into the checkout and needs no
# refresh, unlike the completions beside it.
install-system:
	@echo "📦 Installing system files..."
	@echo "🧰 Applying host sysctl settings..."
	$(SUDO) cp config/sysctl.d/pi-pcloud.conf /etc/sysctl.d/99-pi-pcloud.conf
	$(SUDO) $(SYSCTL) --system >/dev/null
	@echo "🌐 Adding local DNS overrides to /etc/hosts..."
	@HOST_NAME_VAL=$$(grep -E '^HOST_NAME=' .env | tail -n1 | cut -d= -f2-); \
	HOST_LAN_IP_VAL=$$(grep -E '^HOST_LAN_IP=' .env | tail -n1 | cut -d= -f2-); \
	if [ -n "$$HOST_NAME_VAL" ] && [ -n "$$HOST_LAN_IP_VAL" ]; then \
		$(SUDO) sed -i "/# pi-pcloud local overrides/,/# end pi-pcloud local overrides/d" /etc/hosts; \
		printf "# pi-pcloud local overrides\n$$HOST_LAN_IP_VAL\theadscale.$$HOST_NAME_VAL\n# end pi-pcloud local overrides\n" | $(SUDO) tee -a /etc/hosts >/dev/null; \
		echo "  ✔ headscale.$$HOST_NAME_VAL -> $$HOST_LAN_IP_VAL"; \
	else \
		echo "  ⚠ HOST_NAME or HOST_LAN_IP not set, skipping"; \
	fi
	sed 's|__PROJECT_PATH__|$(PROJECT_PATH)|g' config/systemd/system/pi-pcloud.service > /tmp/$(UNIT)
	$(SUDO) cp /tmp/$(UNIT) /etc/systemd/system/
	sed 's|__PROJECT_PATH__|$(PROJECT_PATH)|g' config/systemd/system/$(WATCH_UNIT) > /tmp/$(WATCH_UNIT)
	$(SUDO) cp /tmp/$(WATCH_UNIT) /etc/systemd/system/
	sed 's|__PROJECT_PATH__|$(PROJECT_PATH)|g' config/systemd/system/nextcloud-cron.service > /tmp/nextcloud-cron.service
	$(SUDO) cp /tmp/nextcloud-cron.service /etc/systemd/system/
	$(SUDO) cp config/systemd/system/nextcloud-cron.timer /etc/systemd/system/
	$(SUDO) systemctl daemon-reload
	$(SUDO) systemctl enable $(UNIT) $(WATCH_UNIT) nextcloud-cron.timer
	@echo "✅ Systemd units installed"
	@echo "🔗 Installing the pi-pcloud command..."
# A symlink, not a copy: the command follows this checkout, so a git pull
# updates it and there is no rendered duplicate to drift.
	$(SUDO) ln -sfn $(PROJECT_PATH)/scripts/pi-pcloud $(BIN_LINK)
	$(SUDO) mkdir -p $(dir $(BASH_COMPLETION)) $(dir $(ZSH_COMPLETION))
	$(SUDO) cp config/completion/pi-pcloud.bash $(BASH_COMPLETION)
	$(SUDO) cp config/completion/_pi-pcloud $(ZSH_COMPLETION)
	@echo "✅ pi-pcloud available on PATH (new shells get completion)"

uninstall:
	@echo "🗑️  Uninstalling pi-pcloud..."
	@echo ""
	@echo "⚠️  WARNING: This will remove ALL data including:"
	@echo "   - Docker volumes (pi-hole, headscale, etc.)"
	@echo "   - Bind-mount data dirs: ./data/nextcloud, ./data/postgres, ./data/n8n, ./data/immich"
	@echo "   - Generated config: ./data/authelia-config/configuration.yml"
	@echo "   - Generated config: ./config/headplane/config.yaml" 
	@echo "   - Generated config: ./config/headscale/config.yaml"
	@echo "   - Generated config: ./config/headscale/policy.hujson"
	@echo "   - Generated config: ./config/ntfy/ntfy.env"
	@echo "   - Generated config: ./config/beszel-agent/agent.env"
	@echo "   - Systemd service units"
	@echo ""
	@read -p "Are you sure? Type 'yes' to confirm: " confirm && [ "$$confirm" = "yes" ] || (echo "Aborted"; exit 1)
	@echo ""
	@echo "🛑 Stopping services..."
	-$(SUDO) systemctl stop $(WATCH_UNIT) 2>/dev/null || true
	-$(SUDO) systemctl stop $(UNIT) 2>/dev/null || true
	@echo "🐳 Removing containers and volumes..."
	-$(COMPOSE) down -v --remove-orphans 2>/dev/null || true
	@echo "🧹 Removing bind-mount data directories..."
	-$(SUDO) rm -rf ./data/nextcloud ./data/postgres ./data/n8n ./data/immich ./data/lldap ./data/authelia-config
	@echo "🧹 Removing generated config files..."
	-rm -f ./config/headplane/config.yaml
	-rm -f ./config/headscale/config.yaml
	-rm -f ./config/headscale/policy.hujson
	-rm -f ./config/ntfy/ntfy.env
	-rm -f ./config/beszel-agent/agent.env
	@echo "🧰 Removing host sysctl settings..."
	-$(SUDO) rm -f /etc/sysctl.d/99-pi-pcloud.conf
	-$(SUDO) $(SYSCTL) --system >/dev/null
	@echo "🌐 Removing local DNS overrides from /etc/hosts..."
	-$(SUDO) sed -i "/# pi-pcloud local overrides/,/# end pi-pcloud local overrides/d" /etc/hosts
	@echo "🧹 Removing the pi-pcloud command..."
	-$(SUDO) rm -f $(BIN_LINK) $(BASH_COMPLETION) $(ZSH_COMPLETION)
	@echo "🧹 Removing systemd units..."
	-$(SUDO) systemctl disable $(UNIT) $(WATCH_UNIT) nextcloud-cron.timer 2>/dev/null || true
	-$(SUDO) rm -f /etc/systemd/system/$(UNIT)
	-$(SUDO) rm -f /etc/systemd/system/$(WATCH_UNIT)
	-$(SUDO) rm -f /etc/systemd/system/nextcloud-cron.service
	-$(SUDO) rm -f /etc/systemd/system/nextcloud-cron.timer
	-$(SUDO) systemctl daemon-reload
	@echo "✅ Uninstall complete"
	@echo ""
	@echo "ℹ️  Note: .env file preserved. Remove manually if needed."

start:
	@echo "🚀 Starting pi-pcloud stack..."
	$(SUDO) systemctl start $(UNIT)
	@echo "✅ Stack started"

stop:
	@echo "🛑 Stopping pi-pcloud stack..."
	$(COMPOSE) down --remove-orphans
	$(SUDO) systemctl stop $(UNIT) 2>/dev/null || true
	@echo "✅ Stack stopped"

restart: stop start

# Images are refreshed while the stack is still running, so the interruption is
# one restart instead of a download. `pull` only covers the services the
# current COMPOSE_PROFILES selects, and skips the five images built here, which
# `build --pull` rebuilds against their updated bases. Pruning at the end
# reclaims the layers the recreated containers just released — dangling images
# only, so nothing a container still references is touched.
update:
	@echo "🔄 Updating pi-pcloud..."
	@branch=$$(git rev-parse --abbrev-ref HEAD); 	if [ "$$branch" != "main" ]; then echo "  ⚠ on branch $$branch, not main"; fi
	@echo "📥 Repository..."
	@git pull --ff-only
	$(MAKE) check-env
	@echo "📦 Images (the stack keeps running)..."
	@$(COMPOSE) pull --ignore-buildable
	@echo "🔨 Locally built images..."
	@$(COMPOSE) build --pull
	$(MAKE) install-system
	$(MAKE) restart
	@echo "🧹 Reclaiming space from the replaced images..."
	@docker image prune -f | tail -n1
	@echo "✅ Update complete"

status:
	@echo "📊 Status"
	$(SUDO) systemctl status $(UNIT) --no-pager -l
	-$(SUDO) systemctl status $(WATCH_UNIT) --no-pager -l

logs:
	@echo "📝 Logs (Ctrl+C to exit)"
	$(COMPOSE) logs -f --tail=100

# Optional services are toggled through Docker Compose profiles: every optional
# service carries a profile named after itself (plus the catch-all "all"), and
# COMPOSE_PROFILES in .env selects which run. All the logic (enabled-ness
# computation, .env rewriting, the per-service pre-start/bootstrap hooks and
# the interactive checklist) lives in scripts/services.sh — these targets are
# thin wrappers around it.
services:
	@/bin/sh scripts/services.sh list

enable:
	@/bin/sh scripts/services.sh enable "$(SERVICE)"

disable:
	@/bin/sh scripts/services.sh disable "$(SERVICE)"

config:
	@/bin/sh scripts/services.sh config

# The same endpoint the assistant calls for the `anomalies` topic, so the shell
# and the chat cannot disagree. Asked from inside the container because
# system-tools only exposes its port on the compose networks, and with python3
# because the image (python:3.12-slim) ships no curl - the same call its
# healthcheck makes.
doctor:
	@echo "🩺 Diagnostic"
	@$(COMPOSE) exec -T system-tools python3 -c \
		"import urllib.request as r; print(r.urlopen('http://localhost:8000/status/anomalies').read().decode())" \
		|| echo "❌ system-tools unreachable - check 'docker compose ps' and 'make logs'"

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

rotate-password:
	@if [ ! -f .env ]; then echo "❌ .env missing (copy .env.dist)"; exit 1; fi
	sh scripts/rotate-password.sh --skip-postgres

rotate-password-full:
	@if [ ! -f .env ]; then echo "❌ .env missing (copy .env.dist)"; exit 1; fi
	sh scripts/rotate-password.sh
