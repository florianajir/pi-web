# PI Web Docker Compose Stack

A personal self-hosted web stack for Raspberry Pi, built with Docker Compose. It includes a variety of services for personal cloud storage, media management, VPN connectivity, DNS filtering, monitoring, and more.

## Architecture

- **compose.yaml**: The main Docker Compose file that defines all the services and their configurations.
- **config/**: A directory containing configuration files for various services, such as Traefik, Nextcloud, and Immich.
- **data/**: A directory for persistent data storage used by services like Nextcloud and Immich.
- **scripts/**: A directory for custom scripts, such as initialization scripts for databases or automation scripts for maintenance tasks.
- **README.md**: Documentation for the project, including setup instructions and usage guidelines.
- **.env**: An environment file to store sensitive information and configuration variables for the docker services.
- **.env.dist**: A template for the `.env` file, listing required environment variables without actual values (to avoid committing secrets).
- **Makefile**: A file containing Make targets for common operations like starting, stopping, and managing the Docker Compose stack.


## Docker compose stack containers

- **Docker** for containerization and orchestration.
- **Portainer** for container management.
- **Beszel** for monitoring.
- **DDNS Updater** for dynamic DNS updates.
- **Traefik** for reverse proxy and TLS management.
- **Tailscale** for secure VPN connectivity.
- **Headscale** for managing Tailscale networks.
- **Headplane** for Headscale web interface.
- **N8n** for workflow automation.
- **Pihole** for personal DNS filtering.
- **Immich** for personal photo and video management.
- **Nextcloud** for personal cloud storage and collaboration.
- **Redis** for in-memory data storage.
- **Postgres** for relational database management (Immich and Nextcloud).
