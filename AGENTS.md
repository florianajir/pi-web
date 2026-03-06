# Pi Web

Pi Web is a self-hosted web application stack designed for Raspberry Pi devices. It includes a variety of services for personal cloud such as Nextcloud, Immich, n8n, and monitoring solutions, all orchestrated using Docker Compose. The stack is secured with Tailscale and managed through Headscale for private networking.

## Guidelines

- Use docker compose for execution and management of services.
- Changes should be made in the docker compose file or the service configurations and scripts provided in the repository to ensure idempotency and functionality on fresh installs.
- Makefile is provided for convenience.
- Never use make uninstall or any destructive operation on a path other than the project path.
