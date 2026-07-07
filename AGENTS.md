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

## Adding OIDC (Authelia SSO) to a service

Authelia is the OIDC provider. `data/authelia-config/configuration.yml` is RENDERED from `config/authelia/configuration.yml.template` by `scripts/authelia-pre-start.sh` on every start — never edit the rendered file, it gets overwritten. Do NOT build a custom image / Dockerfile to inject OIDC config; use a bootstrap script (guideline above). Steps:

1. Declare the client in `config/authelia/configuration.yml.template` (copy an existing stanza; use `__HOST_NAME__`, `{{ secret "/config/secrets/oidc_<id>_secret_hash" }}`, and the service's real redirect URI).
2. Add the client id to the secret-generation loop in `scripts/authelia-pre-start.sh` (generates `.txt` plaintext + `_hash` PBKDF2 automatically on fresh installs).
3. Configure the service itself with `scripts/<service>-oidc-bootstrap.sh`, sourcing `scripts/lib.sh` (reuse `ensure_authelia_oidc_materials`, `get_oidc_secret`, `wait_for_container`, `wait_for_http_endpoint`, `log`/`die`). Make it idempotent: only write/restart when config actually changed. Prefer the service's API; fall back to its config file (`docker exec` + `jq`) or DB when there's no API.
4. Wire it as `ExecStartPost=-/bin/sh __PROJECT_PATH__/scripts/<service>-oidc-bootstrap.sh` in `config/systemd/system/pi-pcloud.service` (and mirror into the deployed unit, then `systemctl daemon-reload`).
5. If the service must reach Authelia's discovery endpoint from inside Docker, add `extra_hosts: ["auth.${HOST_NAME:-pi.lan}:172.30.11.250"]` to its compose service.
6. Traefik middleware: services with their own account system (Immich, Kavita) use `lan@docker` only — do NOT stack `authelia@docker` forward-auth on top.
