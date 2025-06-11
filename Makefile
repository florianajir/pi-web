.PHONY: help dependencies decrypt install_systemd install enable start stop restart update status setup-lint lint lint-fix

# Default target
help:
	@echo "Available commands:"
	@echo "  dependencies       - Install required dependencies"
	@echo "  decrypt            - Decrypt environment variables from .env.enc"
	@echo "  install_systemd    - Install systemd service files"
	@echo "  install            - Install dependencies, decrypt env, and setup systemd services"
	@echo "  update             - Update the repository and restart services"
	@echo "  enable             - Enable systemd services"
	@echo "  start              - Start all systemd services"
	@echo "  stop               - Stop all systemd services"
	@echo "  restart            - Restart all systemd services"
	@echo "  status             - Show the status of all systemd services"
	@echo "  setup-lint         - Install yamllint for YAML validation"
	@echo "  lint               - Run YAML and Docker Compose validation"
	@echo "  lint-fix           - Auto-fix common YAML formatting issues"
	@echo "  help               - Show this help message"

dependencies:
	@echo "📦 Installing dependencies..."
	sudo apt-get update
	sudo apt-get install -y sops
	@echo "✅ Dependencies installed"

decrypt:
	@echo "🔐 Decrypting environment variables..."
	sops -d .env.enc > .env

install_systemd:
	@echo "📁 Installing system service..."
	sudo cp etc/systemd/system/*.service /etc/systemd/system/
	sudo systemctl daemon-reload
	@echo "✅ systemd service files installed and daemon reloaded"

install: dependencies decrypt install_systemd enable start

enable:
	@echo "🔧 Enabling..."
	sudo systemctl enable monitoring.service
	sudo systemctl enable n8n.service
	sudo systemctl enable proxy.service
	@echo "✅ All services enabled"

start:
	@echo "🚀 Starting..."
	sudo systemctl start proxy.service
	sudo systemctl start monitoring.service
	sudo systemctl start n8n.service
	@echo "✅ All services started"

stop:
	@echo "🛑 Stopping..."
	sudo systemctl stop n8n.service
	sudo systemctl stop monitoring.service
	sudo systemctl stop proxy.service
	@echo "✅ All services stopped"

restart:
	@echo "🔄 Restarting..."
	sudo systemctl restart proxy.service
	sudo systemctl restart monitoring.service
	sudo systemctl restart n8n.service
	@echo "✅ All services restarted"

update:
	@echo "🔄 Updating..."
	git pull
	make install_systemd
	make restart
	@echo "✅ Services updated and restarted"

status:
	@echo "📊 Status:"
	sudo systemctl status proxy.service --no-pager -l
	sudo systemctl status monitoring.service --no-pager -l
	sudo systemctl status n8n.service --no-pager -l

setup-lint:
	@echo "🔧 Installing YAML linting tools..."
	sudo apt update && sudo apt install -y yamllint
	@echo "✅ YAML linting tools installed successfully"

lint:
	@echo "🔍 Running validation checks..."
	@echo "Checking YAML files..."
	@if command -v yamllint >/dev/null 2>&1; then \
		yamllint -c .yamllint */compose.yaml .github/workflows/*.yml || true; \
	else \
		echo "installing yamllint..."; \
		sudo apt-get update \
		sudo apt-get install -y yamllint \
		yamllint -c .yamllint */compose.yaml .github/workflows/*.yml || true; \
	fi
	@echo "Checking Docker Compose files..."
	@for file in */compose.yaml; do \
		echo "Validating $$file..."; \
		docker compose -f "$$file" config >/dev/null 2>&1 && echo "✅ $$file is valid" || echo "❌ $$file has issues"; \
	done
	@echo "✅ Validation completed"

lint-fix:
	@echo "🔧 Fixing common YAML formatting issues..."
	@echo "Removing trailing spaces..."
	@sed -i 's/[[:space:]]*$$//' */compose.yaml 2>/dev/null || true
	@sed -i 's/[[:space:]]*$$//' .github/workflows/*.yml 2>/dev/null || true
	@echo "Fixing bracket spacing..."
	@sed -i 's/\[ */[/g; s/ *\]/]/g' .github/workflows/*.yml 2>/dev/null || true
	@echo "✅ YAML formatting fixes applied"
	@echo "Run 'make lint' to check for remaining issues"
