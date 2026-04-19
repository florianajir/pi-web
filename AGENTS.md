# Pi Pcloud

Pi Pcloud is a self-hosted web application stack designed for Raspberry Pi devices. It includes a variety of services for personal cloud such as Nextcloud, Immich, n8n, and monitoring solutions, all orchestrated using Docker Compose. The stack is secured with Tailscale and managed through Headscale for private networking.

## Guidelines

- Use docker compose for execution and management of services.
- Changes should be made in the docker compose file or the service configurations and scripts provided in the repository to ensure idempotency and functionality on fresh installs.
- Stack is run by systemd service, so the scripts in the scripts directory should be used for any pre-start, post-start, or pre-stop operations to ensure they run correctly in the service lifecycle.
- Makefile is provided for convenience.
- Never use make uninstall or any destructive operation on a path other than the project path.
- Avoid creating new env vars in .env and .env.dist, use the provided configuration files and scripts to manage environment variables. For authentication, use USER and PASSWORD env vars.
- Avoid adding new docker containers for running scripts that can be written in scripts directory and run in systemd service ExecStartPre and ExecStartPost
- Never print sensitive information like .env content, passwords, or tokens in logs or stdout, use environment variables for handling sensitive data but keep it hidden.
