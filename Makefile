.PHONY: help install_systemd install start stop restart update status logs

help:
	@echo "Available commands:"
	@echo "  install            - Install and enable systemd service"
	@echo "  update             - Update the repository and restart service"
	@echo "  start              - Start service"
	@echo "  stop               - Stop service"
	@echo "  restart            - Restart service"
	@echo "  status             - Show the status of service"
	@echo "  logs               - Show docker stack logs"
	@echo "  help               - Show this help message"

install:
	@echo "📦 Installing Pi-Web service..."
	@if [ ! -f .env ]; then echo "❌ .env file missing"; exit 1; fi
	@echo "Current directory: $(shell pwd)"
	# Install systemd unit files
	sed 's|__PROJECT_PATH__|$(shell pwd)|g' config/systemd/system/pi-web.service > /tmp/pi-web.service
	sudo cp /tmp/pi-web.service /etc/systemd/system/
	sudo cp config/systemd/system/pi-web-restart.service /etc/systemd/system/
	sudo cp config/systemd/system/pi-web-restart.timer /etc/systemd/system/
	sudo systemctl daemon-reload
	sudo systemctl enable pi-web.service
	@echo "✅ Pi-Web service enabled"

start:
	@echo "🚀 Starting..."
	sudo systemctl start pi-web.service
	@echo "✅ Pi-Web service started"

stop:
	@echo "🛑 Stopping..."
	sudo systemctl stop pi-web.service
	@echo "✅ Pi-Web service stopped"

restart:
	@echo "🔄 Restarting..."
	sudo systemctl restart pi-web.service
	@echo "✅ Pi-Web service restarted"

update:
	@echo "🔄 Updating..."
	sudo apt update && sudo apt upgrade -y
	git pull
	sed 's|__PROJECT_PATH__|$(shell pwd)|g' config/systemd/system/pi-web.service > /tmp/pi-web.service
	sudo cp -f /tmp/pi-web.service /etc/systemd/system/
	sudo systemctl daemon-reload
	make restart
	@echo "✅ Services updated and restarted"

status:
	@echo "📊 Status:"
	sudo systemctl status pi-web.service --no-pager -l

logs:
	@echo "📝 Showing logs for all services..."
	docker compose logs
