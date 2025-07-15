# pi-web

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Docker](https://img.shields.io/badge/Docker-Compose-blue.svg)](https://docker.com/)
[![Raspberry Pi](https://img.shields.io/badge/Raspberry%20Pi-Compatible-red.svg)](https://www.raspberrypi.org/)

A comprehensive, production-ready Docker Compose stack for Raspberry Pi that provides monitoring, reverse proxy, and automation services. Turn your Raspberry Pi into a powerful self-hosted infrastructure with web-based dashboards and automated service management.

## ✨ Features

- 🚀 **One-command deployment** with automated Makefile setup
- 🔍 **Complete monitoring stack** with Grafana, Prometheus, and system metrics
- 🌐 **Smart reverse proxy** with Traefik for automatic service discovery
- 🤖 **Workflow automation** with n8n for connecting services and APIs
- 🔐 **Secure secrets management** with SOPS encryption
- ⚙️ **Systemd integration** for production-grade service management
- 🏠 **Local subdomain routing** for easy service access

## 🏗️ Architecture

### Services Included

| Service | Purpose | Access |
|---------|---------|--------|
| **Grafana** | Analytics and monitoring dashboards | `monitoring.pi.home` |
| **Prometheus** | Metrics collection and storage | Internal |
| **cAdvisor** | Container resource monitoring | Internal |
| **Node Exporter** | System metrics collection | Internal |
| **Traefik** | Reverse proxy with SSL termination | `proxy.pi.home` |
| **n8n** | Workflow automation platform | `n8n.pi.home` |

### Stack Components

- **🔍 Monitoring Stack**: Complete observability with Grafana dashboards, Prometheus metrics, and system monitoring
- **🌐 Reverse Proxy**: Traefik handles routing, SSL certificates, and service discovery
- **🤖 Automation**: n8n provides visual workflow automation for connecting various services

## 🚀 Quick Start

### Prerequisites

- Raspberry Pi with Raspbian/Ubuntu
- Docker and Docker Compose installed
- `sudo` access for systemd service management

### Installation

1. **Clone the repository**:

```bash
git clone https://github.com/yourusername/pi-web.git
make install
```

### Access Your Services

Configure your local machine's `/etc/hosts` file with your Pi's IP address:

```bash
# Add this line to /etc/hosts on your local machine
192.168.1.45    pi.home proxy.pi.home monitoring.pi.home n8n.pi.home
```

Then access:
- **Grafana Dashboard**: `http://monitoring.pi.home`
- **Traefik Dashboard**: `http://proxy.pi.home`
- **n8n Automation**: `http://n8n.pi.home`

## 📋 Management Commands

| Command | Description |
|---------|-------------|
| `make help` | Show all available commands |
| `make install` | Complete installation and setup |
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

# Start/stop individual components
sudo systemctl start monitoring.service
sudo systemctl stop n8n.service
```

## 🧪 Development Setup

For contributors and developers who want to maintain code quality:

### Linting Setup

Install linting tools for validation:

```bash
make setup-lint
```

This installs:
- ✅ yamllint for YAML syntax and formatting
- ✅ Git pre-commit hook for automatic validation

### Manual Linting

Run quality checks manually:

```bash
make lint
```

This checks:
- YAML syntax and formatting in compose files
- Dockerfile best practices (if present)
- Docker Compose configuration validation

## ⚙️ Configuration

### Environment Variables

The stack uses encrypted environment variables for security. Basic configuration:

```bash
HOSTNAME=pi.home
USER=admin
EMAIL=admin@example.com
PASSWORD=your_secure_password
```

### SOPS Encryption

This project uses [SOPS](https://github.com/mozilla/sops) for secure environment management:

```bash
# Decrypt environment file (automatically done by make install)
sops -d .env.enc > .env

# Encrypt new environment file
sops -e .env > .env.enc

# Edit encrypted file directly
sops .env.enc
```

### Advanced Configuration

- **Grafana**: Dashboards in `monitoring/grafana/provisioning/`
- **Prometheus**: Configuration in `monitoring/prometheus/prometheus.yml`
- **Traefik**: Auto-configuration via Docker labels
- **n8n**: Workflow data persisted in `n8n/files/`

## 🔧 Development

### Project Structure

```
pi-web/
├── Makefile              # Management commands
├── monitoring/           # Grafana, Prometheus, exporters
├── proxy/               # Traefik reverse proxy
├── n8n/                 # Workflow automation
└── etc/systemd/system/  # Service definitions
```

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
journalctl -u monitoring.service -f
```

**Can't access web interfaces:**
- Verify `/etc/hosts` configuration on your local machine
- Check that services are running: `make status`
- Ensure firewall allows access to ports 80, 443, 8080

**Environment decryption fails:**
- Ensure SOPS and age are installed: `make dependencies`
- Verify age key file exists and is configured

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## 🤝 Support

- 📖 [Wiki](../../wiki) for detailed documentation
- 🐛 [Issues](../../issues) for bug reports and feature requests
- 💬 [Discussions](../../discussions) for questions and community support

## ⭐ Acknowledgments

- [Grafana](https://grafana.com/) for monitoring dashboards
- [Prometheus](https://prometheus.io/) for metrics collection
- [Traefik](https://traefik.io/) for reverse proxy
- [n8n](https://n8n.io/) for workflow automation
