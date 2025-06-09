.PHONY: help dependencies decrypt install_systemd install enable start stop restart update status

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
