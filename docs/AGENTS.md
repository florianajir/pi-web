# Pi Web

Pi Web is a self-hosted web application stack designed for Raspberry Pi devices. It includes a variety of services for personal cloud such as Nextcloud, Immich, n8n, and monitoring solutions, all orchestrated using Docker Compose. The stack is secured with Tailscale and managed through Headscale for private networking.

## Guidelines

- Use docker compose for execution and management of services.
- Systemd service is provided for ease of use, but it should not be modified directly. Instead, any changes should be made in the docker compose file or the service configurations and init scripts provided in the repository to ensure idempotency and functionality on fresh installs.
- Makefile is provided for convenience to manage the stack and perform common tasks, but it should not be the primary interface for configuration or management of the services.
