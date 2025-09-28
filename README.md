# pi-web

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Docker](https://img.shields.io/badge/Docker-Compose-blue.svg)](https://docker.com/)
[![Raspberry Pi](https://img.shields.io/badge/Raspberry%20Pi-Compatible-red.svg)](https://www.raspberrypi.org/)

Turn your Raspberry Pi into a self-hosted infrastructure with vpn, ad-blocker dns, monitoring and workflow automation.

## 🏗️ Architecture

### Stack Components

- **VPN**: WireGuard routes remote clients through Pi-hole DNS for LAN-safe browsing
- **DNS + Ad-blocker**: Pi-Hole
- **Reverse Proxy**: Traefik handles routing, SSL certificates, and service discovery
- **Monitoring**: Complete observability with Grafana dashboards, Prometheus metrics, and system monitoring
- **Automation**: n8n provides visual workflow automation for connecting various services
- **Cloud Storage**: Nextcloud offers self-hosted file sync and sharing with calendar/contacts support

### Services Included

| Service | Purpose | Access |
|---------|---------|--------|
| **Traefik** | Reverse proxy with SSL termination | `traefik.pi.lan` |
| **n8n** | Workflow automation platform | `n8n.pi.lan` |
| **Grafana** | Analytics and monitoring dashboards | `grafana.pi.lan` |
| **Prometheus** | Metrics collection and storage | `prometheus.pi.lan` |
| **cAdvisor** | Container resource monitoring | Internal |
| **Node Exporter** | System metrics collection | Internal |
| **Nextcloud** | Private file sync and collaboration | `nextcloud.pi.lan` |
| **WireGuard** | VPN server | `pi.lan:51820` |
| **Pi Hole** | DNS server + Ad-Blocker | `pihole.pi.lan` (dashboard), `pi.lan:53` (DNS) |

## 🚀 Quick Start

### Prerequisites

- Docker and Docker Compose installed

### Installation

```bash
git clone https://github.com/florianajir/pi-web.git
make install
```

## 📋 Management Commands

| Command | Description |
|---------|-------------|
| `make help` | Show all available commands |
| `make install` | Complete installation |
| `make start` | Start all services |
| `make stop` | Stop all services |
| `make restart` | Restart all services |
| `make status` | Check service status |
| `make update` | Update from git and restart |

### Service Management Examples

```bash
# Check status of all services
make status

# Restart services after configuration changes
make restart

# Update to latest version
make update
```

## 🧪 Development Setup

For contributors and developers who want to maintain code quality:

## ⚙️ Configuration

### Environment Variables

The stack uses encrypted environment variables for security. Basic configuration can be found in `.env.dist` file, just copy the file to `.env` to quickstart.

By default domains use the pattern `<service>.pi.lan` because `HOST_NAME=pi.lan` in `.env.dist`. To use a different internal domain (e.g. `pi.web`), set `HOST_NAME=pi.web` (and ensure your LAN DNS or `/etc/hosts` resolves `*.pi.web` to your Raspberry Pi host IP) before running `make start`.

### Advanced Configuration

- **Grafana**: Dashboards in `config/grafana/provisioning/`
- **Prometheus**: Configuration in `config/prometheus/prometheus.yml`
- **Traefik**: Auto-configuration via Docker labels
- **n8n**: Workflow data persisted in `n8n/files/`
- **Nextcloud**: Persistent data stored in the `nextcloud_data` volume; admin user/password reuse the global `USER` / `PASSWORD` values while database credentials live under the Nextcloud section of `.env`
- **WireGuard**: Configuration persisted in the `wireguard_config` volume; VPN clients default to the Pi-hole DNS defined by `WIREGUARD_PEER_DNS`

### Contributing

Please review the [Repository Guidelines](AGENTS.md) before contributing.

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Submit a pull request

## 🐛 Troubleshooting

```bash
# Check service status
make status

# Check logs
journalctl -u pi-web.service -f
```

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## ⭐ Acknowledgments

- [Grafana](https://grafana.com/) Analytics & monitoring solution
- [Prometheus](https://prometheus.io/) Monitoring system & time series database
- [cAdvisor](https://github.com/google/cadvisor) resource usage and performance characteristics of running containers
- [Traefik](https://traefik.io/) Application Proxy
- [n8n](https://n8n.io/) Workflow Automation Software & Tools
- [WireGuard](https://www.wireguard.com/) Fast, modern, secure VPN tunnel
- [Pi-hole](https://pi-hole.net/) Network-wide Ad Blocking
