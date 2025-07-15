# pi-web

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Docker](https://img.shields.io/badge/Docker-Compose-blue.svg)](https://docker.com/)
[![Raspberry Pi](https://img.shields.io/badge/Raspberry%20Pi-Compatible-red.svg)](https://www.raspberrypi.org/)

Turn your Raspberry Pi into a self-hosted infrastructure with vpn, ad-blocker dns, monitoring, automation.

## 🏗️ Architecture

### Stack Components

- **VPN**: Home vpn using WireGuard
- **DNS + Ad-blocker**: Pi-Hole
- **Reverse Proxy**: Traefik handles routing, SSL certificates, and service discovery
- **Monitoring**: Complete observability with Grafana dashboards, Prometheus metrics, and system monitoring
- **Automation**: n8n provides visual workflow automation for connecting various services

### Services Included

| Service | Purpose | Access |
|---------|---------|--------|
| **Traefik** | Reverse proxy with SSL termination | `traefik.pi.web` |
| **n8n** | Workflow automation platform | `n8n.pi.web` |
| **Grafana** | Analytics and monitoring dashboards | `grafana.pi.web` |
| **Prometheus** | Metrics collection and storage | `prometheus.pi.web` |
| **cAdvisor** | Container resource monitoring | Internal |
| **Node Exporter** | System metrics collection | Internal |
| **WireGuard** | VPN server | `pi.web:51820` |
| **Pi Hole** | DNS server + Ad-Blocker | `pihole.pi.web` (dashboard), `pi.web:53` (DNS) |

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

The stack uses encrypted environment variables for security. Basic configuration:

```bash
HOSTNAME=pi.web
USER=admin
EMAIL=admin@example.com
PASSWORD=your_secure_password
```

### Advanced Configuration

- **Grafana**: Dashboards in `monitoring/grafana/provisioning/`
- **Prometheus**: Configuration in `monitoring/prometheus/prometheus.yml`
- **Traefik**: Auto-configuration via Docker labels
- **n8n**: Workflow data persisted in `n8n/files/`

### Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Test on a Raspberry Pi
5. Submit a pull request

## 🐛 Troubleshooting

### Common Issues

**Services won't start:**

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
