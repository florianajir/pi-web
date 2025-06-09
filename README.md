# pi-web

Raspberry pi docker compose stack

Exposed: 
- monitoring: grafana.pi-a11r
- proxy: pi-a11r:8080

Stacks docker compose:
- proxy: Traeffik
- monitoring
  - grafana (:3000)
  - cadvisor 
  - node-exporter
  - prometheus

## Environment Variables

Create a `.env` file in the root directory with the following variables:

```bash
HOSTNAME=pi-a11r.local
USER=admin
EMAIL=admin@example.com
PASSWORD=your_secure_password
```

## SOPS Encryption/Decryption

This project uses [SOPS](https://github.com/mozilla/sops) for secure environment variable management.

### Prerequisites

1. Install SOPS and age:
   ```bash
   # Install age
   sudo apt install age  # or use your package manager
   ```

2. Configure age key file:
   ```bash
   export SOPS_AGE_KEY_FILE=~/.config/sops/age/age.key
   ```

### Usage

**Decrypt environment file:**
```bash
sops -d .env.enc > .env
```

**Encrypt environment file:**
```bash
sops -e .env > .env.enc
```

**Edit encrypted file directly:**
```bash
sops .env.enc
```

### Configuration

The `.sops.yaml` file contains the age public key for encryption:
```yaml
creation_rules:
  - age: age1ngwx8qf0lw93dqgcth5zfef8w7ppqc3wlyq0hx75rl4k27umwy9qtmcxzj
```
