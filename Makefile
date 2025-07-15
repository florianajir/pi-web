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
	sudo cp etc/systemd/system/*.service /etc/systemd/system/
	sudo systemctl daemon-reload
	sudo systemctl enable pi-web.service
	@echo "✅ Pi-Web service enabled"
	make start

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
	sudo cp -f etc/systemd/system/pi-web.service /etc/systemd/system/
	make restart
	@echo "✅ Services updated and restarted"

status:
	@echo "📊 Status:"
	sudo systemctl status pi-web.service --no-pager -l

logs:
	@echo "📝 Showing logs for all services..."
	docker compose logs
