# Repository Guidelines

## Project Structure & Module Organization

- `compose.yaml` runs the production stack; extend with `compose.test.yaml` for CI-safe overrides.
- `config/` stores service configs: `pihole/` dnsmasq, `systemd/` templates.
- `data/` keeps persistent volumes such as `data/n8n/`; avoid committing large exports or secrets.
- `etc/systemd/` mirrors units already installed on hosts; edit sources under `config/systemd/` instead.
- `.env.dist` lists required variables; copy to `.env` before invoking any Make target.

## Build, Test, and Development Commands

- `make install` renders systemd units with the repository path, installs them under `/etc/systemd/system`, and enables the service.
- `make start|stop|restart|status|logs` wrap systemd and Docker Compose operations; prefer them so team logs stay consistent.
- Validate Compose syntax with `docker compose -f compose.yaml config` after editing stack files.
- Use `docker compose -f compose.yaml -f compose.test.yaml up -d` to boot the stack with CI-friendly port bindings.

## Coding Style & Naming Conventions

- YAML files use two-space indentation; keep keys lowercase unless vendor docs require uppercase.
- Environment files stay in `KEY=value` form without quotes; document unusual keys inline in `.env.dist`.
- Systemd units follow the `pi-web*.service` pattern; use the same naming for new timers or oneshots.
- Run `yamllint .` (configured via `.yamllint`) before pushing and resolve warnings or justify them in commits.

## Testing Guidelines

- Smoke-test with `docker compose ps` and targeted `docker compose logs <service>`; confirm every healthcheck reaches `healthy`.
- For DNS or proxy changes, validate locally using `nslookup nextcloud.$HOST_NAME` and `curl -Ik https://traefik.$HOST_NAME`.
- After Nextcloud updates, confirm the UI through Traefik with `curl -Ik https://nextcloud.$HOST_NAME` and complete the first-run wizard if admin credentials changed.
- For WireGuard, confirm the tunnel and DNS path with `docker exec pi-wireguard wg show` and, from a connected client, `nslookup nextcloud.$HOST_NAME 10.13.13.1` (or the assigned VPN gateway).
- For Netdata, verify metrics collection with `curl -sf http://localhost:19999/api/v1/info`.
- For Portainer, confirm the UI through Traefik with `curl -Ik https://portainer.$HOST_NAME`.

## Configuration & Secrets

- Keep `.env` and service credentials out of Git; share them through the team vault and rotate when roles change.
- Store n8n exports outside `data/` to avoid credential leakage.
- Rotate the default Nextcloud admin and database secrets immediately after bootstrapping; document updated values in the vault.
  * Admin login reuses the global `USER` / `PASSWORD` pair—update them before exposing the stack.
- Treat WireGuard peer configs as secrets—export them from the container and store in the vault rather than the repo.
- Netdata Cloud tokens (`NETDATA_CLAIM_TOKEN`) are optional; if used, treat them as secrets.

## Commit & Pull Request Guidelines

- Follow the conventional prefixes already in history (`fix:`, `refactor:`, `chore:`); keep subjects ≤ 72 chars and mention the service touched (e.g., `fix: tighten traefik hsts policy`).
- PRs must link issues, summarize stack impact, and attach evidence (`docker compose config`, screenshots of dashboards, or log snippets).
- Replace TODOs with issue references; document remaining risks in the PR body.
- Request review when the stack runs via `make status` and `docker compose ps` without errors.
- Do NOT add inline “explanatory” comments whose only purpose is to restate what the diff already shows (e.g. `# updated memory limit`). Only keep comments that provide enduring operational or configuration context.
