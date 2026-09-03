# Contributing

Thanks for taking the time. Bug reports, service additions and documentation fixes are all welcome.

## Reporting a bug

Open an issue with: what you ran, what happened, and the relevant output of `make doctor` and `docker compose logs <service>`. **Never paste your `.env`, tokens or passwords** — redact them first.

Found a security issue? Please report it privately through GitHub's [security advisories](https://github.com/florianajir/pi-pcloud/security/advisories/new) rather than a public issue.

## Making a change

```bash
git clone https://github.com/florianajir/pi-pcloud.git
cd pi-pcloud
make test          # installer, CLI, check-env, service-selection, start-sequence and compose-invariant suites; touches nothing on the host
make lint          # every static check CI runs: shell, YAML, Python, Dockerfiles, workflows, secrets
```

`make lint` runs `scripts/lint.sh`, which the CI workflow calls too, so a green
run locally means a green run there. A gate whose tool is missing is reported as
skipped rather than dropped — `LINT_STRICT=1`, which CI sets, makes a skip fail.

`shellcheck` comes from your package manager. `ruff` and `yamllint` are pinned in
`requirements-lint.txt`, and Raspberry Pi OS bookworm (like any PEP 668 distro)
refuses to install them system-wide, so use a virtualenv:

```bash
sudo apt-get install -y shellcheck
python3 -m venv .venv-lint && .venv-lint/bin/pip install -r requirements-lint.txt
PATH="$PWD/.venv-lint/bin:$PATH" make lint
```

`hadolint`, `actionlint` and `gitleaks` need nothing installed: `scripts/lint.sh`
runs them from pinned images whenever Docker is available.

Then open a pull request against `main`. CI runs those same gates, validates the
Compose file under four profile combinations, runs the test suites and boots the
stack.

### House rules

These are the ones that get changes sent back. [AGENTS.md](AGENTS.md) has the full set.

- **Everything through Docker Compose.** Change `compose.yaml`, `config/` or `scripts/` — never the state of a running container. A fresh install must reach the same result.
- **Scripts are POSIX `sh`**, run by dash with `set -eu`. No bashisms. `make lint` is the gate: `shellcheck -s dash` reports every bashism as an `SC3xxx` error over every tracked shell file, `config/**` and the extensionless `scripts/pi-pcloud` included.
- **Never source `.env`** — read keys through `scripts/lib.sh` `get_env_value`. Never log a secret.
- **Pin every image version** explicitly, after checking upstream for the newest stable release. No `latest`.
- **Documentation follows the change, in the same commit.** Verify every port, IP, variable and default against the actual file; use `<HOST_NAME>` placeholders, never a real domain.
- **Comments explain *why*, not *what*.** Self-explanatory code beats a comment restating it.

### Adding a service

Follow the [add-service checklist](.agents/skills/add-service/SKILL.md): Compose profile, Traefik labels, Authelia OIDC client, shared Postgres/Redis, ntfy, Uptime Kuma, Backrest, Homepage labels and the systemd bootstrap hook.

### Brand assets

Two files in `docs/assets/` are the only sources for the project's artwork:

| File | Used by |
|---|---|
| `banner.png` | the README header |
| `logo.png` | the mark — source for every homepage icon |

Everything in `config/homepage/icons/` is generated. After changing `logo.png`, re-render
the set (needs ImageMagick) and commit the result:

```bash
scripts/homepage-favicon.sh
```

`logo-mask.svg` is the exception: it is the hand-maintained monochrome silhouette Safari
needs for `rel="mask-icon"`, and the script only copies it into place.

Re-rendering an existing icon takes effect immediately — the bind mounts are per-file and
ImageMagick rewrites them in place. Adding a *new* filename needs `docker compose up -d
homepage`, because Next.js indexes `public/` once at boot and 404s anything that appeared
afterwards.
