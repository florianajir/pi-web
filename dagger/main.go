// Dagger CI pipeline for pi-web.
//
// Provides two callable functions mirroring the GitHub Actions CI pipeline:
//   - validate: lints YAML files (no Docker daemon needed)
//   - smoke-test: starts the full compose stack via host Docker socket and checks service health
//
// Example usage:
//
//	dagger call validate --src .
//	dagger call smoke-test --src . --docker-sock /var/run/docker.sock

package main

import (
	"context"
	"fmt"
	"strings"

	"dagger/pi-web/internal/dagger"
)

const (
	// hostProjectDir is the absolute path of the project on the host.
	// Generated config files are exported back here so docker compose bind-mounts can find them.
	hostProjectDir = "/opt/pi-web"

	// ciDataDir is a temporary, writable directory on the host used for all CI bind-mount data.
	// Using a path outside of hostProjectDir avoids conflicts with production data that may
	// be owned by root or initialised with a different password.
	ciDataDir = "/tmp/pi-web-ci-data"

	// ciEnvBase contains shared CI environment variables used by both pre-start scripts and docker compose.
	ciEnvBase = `HOST_NAME=test.local
USER=testuser
EMAIL=test@example.com
PASSWORD=testpassword123
HOST_LAN_IP=192.168.1.100
TIMEZONE=UTC
CLOUDFLARE_ZONE_ID=ci-zone-placeholder
CLOUDFLARE_DNS_API_TOKEN=ci-token-placeholder
`

	// ciEnvContent is used by docker compose: adds DATA_LOCATION so all bind-mount paths resolve
	// to ciDataDir on the host, avoiding conflicts with root-owned production bind-mount data.
	ciEnvContent = ciEnvBase + "DATA_LOCATION=" + ciDataDir + "\n"
)

// PiWeb is the Dagger CI module for pi-web.
type PiWeb struct{}

// Validate lints all YAML files using yamllint.
// No Docker daemon is required.
//
//	dagger call validate --src .
func (m *PiWeb) Validate(ctx context.Context, src *dagger.Directory) (string, error) {
	out, err := dag.Container().
		From("python:3.12-alpine").
		WithExec([]string{"pip", "install", "--quiet", "yamllint"}).
		WithMountedDirectory("/workspace", src.WithNewFile(".env", ciEnvContent)).
		WithWorkdir("/workspace").
		WithExec([]string{"yamllint", "-c", ".yamllint", "."}).
		Stdout(ctx)
	if err != nil {
		return out, fmt.Errorf("yamllint: %w", err)
	}
	return "✔ YAML lint passed\n" + out, nil
}

// SmokeTest starts the full Docker Compose stack and verifies service health.
// It mirrors the GitHub Actions smoke-test job exactly.
//
//	dagger call smoke-test --src . --docker-sock /var/run/docker.sock
func (m *PiWeb) SmokeTest(ctx context.Context, src *dagger.Directory, dockerSock *dagger.Socket) (string, error) {
	var sb strings.Builder

	// Phase 1 — run pre-start scripts via the host Docker daemon.
	// This writes generated files (authelia secrets, lldap JWT, rendered configs) directly to
	// ciDataDir on the HOST filesystem where docker compose bind-mounts can find them.
	if err := m.generateAndExportConfigs(ctx, src, dockerSock); err != nil {
		return "", fmt.Errorf("pre-start config generation: %w", err)
	}
	sb.WriteString("✔ Pre-start scripts complete\n")

	// Phase 2 — bring up the stack (compose reads HOST filesystem for bind-mounts).
	if err := m.composeUp(ctx, src, dockerSock); err != nil {
		logs, _ := m.composeLogs(ctx, src, dockerSock)
		sb.WriteString("\n=== COMPOSE LOGS ===\n" + logs)
		_ = m.composeDown(ctx, src, dockerSock)
		return sb.String(), fmt.Errorf("stack startup: %w", err)
	}
	sb.WriteString("✔ Stack started and healthy\n")

	// Phase 3 — run health checks identical to CI.
	if err := m.runHealthChecks(ctx, src, dockerSock, &sb); err != nil {
		logs, _ := m.composeLogs(ctx, src, dockerSock)
		sb.WriteString("\n=== COMPOSE LOGS ===\n" + logs)
		_ = m.composeDown(ctx, src, dockerSock)
		return sb.String(), err
	}

	// Phase 4 — tear down (always).
	_ = m.composeDown(ctx, src, dockerSock)
	sb.WriteString("✔ Stack torn down\n")

	return sb.String(), nil
}

// generateAndExportConfigs runs authelia-pre-start.sh via the HOST Docker daemon.
// A helper Alpine container is launched with the project source mounted read-only and
// ciDataDir mounted as the writable data directory.  Generated files (Authelia secrets,
// rendered configuration.yml, lldap JWT secret) are written directly to ciDataDir on the
// HOST filesystem — no Dagger Directory.Export needed, avoiding SDK export issues.
func (m *PiWeb) generateAndExportConfigs(ctx context.Context, src *dagger.Directory, sock *dagger.Socket) error {
	// Build the shell command: install deps, run authelia-pre-start.sh.
	// DATA_LOCATION is passed as an env var (absolute path) so the script writes to
	// /ci-data inside the helper container = ciDataDir on the host.
	// chmod a+rX makes all generated files world-readable so docker compose (running as the
	// non-root CI user) can open env_files that the root container just created.
	script := "apk add -q bash openssl python3 && bash ./scripts/authelia-pre-start.sh && chmod -R a+rX /ci-data"

	_, err := m.dockerCLI(src, sock).
		WithExec([]string{
			"docker", "run", "--rm",
			"-e", "HOST_NAME=test.local",
			"-e", "USER=testuser",
			"-e", "EMAIL=test@example.com",
			"-e", "PASSWORD=testpassword123",
			"-e", "TIMEZONE=UTC",
			"-e", "DATA_LOCATION=/ci-data",
			"-v", hostProjectDir + ":/workspace:ro",
			"-v", ciDataDir + ":/ci-data",
			"-w", "/workspace",
			"alpine:3.21",
			"sh", "-c", script,
		}).Stdout(ctx)
	return err
}

// dockerCLI returns a container wired with the host Docker socket and the
// project directory mounted at the same host path so compose bind-mounts resolve correctly.
// ciDataDir is also mounted so docker compose can read env_files (e.g. lldap.env) that
// generateAndExportConfigs wrote there via the host Docker daemon.
func (m *PiWeb) dockerCLI(src *dagger.Directory, dockerSock *dagger.Socket) *dagger.Container {
	return dag.Container().
		From("docker:cli").
		WithUnixSocket("/var/run/docker.sock", dockerSock).
		// Mount project at the SAME path as on the host so --project-directory resolves correctly.
		WithMountedDirectory(hostProjectDir, src.WithNewFile(".env", ciEnvContent)).
		// Mount CI data so docker compose can read env_files (DATA_LOCATION=/tmp/pi-web-ci-data).
		WithMountedDirectory(ciDataDir, dag.Host().Directory(ciDataDir)).
		WithWorkdir(hostProjectDir).
		WithEnvVariable("COMPOSE_ANSI", "never").
		WithEnvVariable("COMPOSE_REMOVE_ORPHANS", "1").
		WithEnvVariable("COMPOSE_PROGRESS", "quiet")
}

// composeArgs builds a docker compose command with the CI compose file pair.
// Uses project name "pi-web-ci" to avoid conflicting with any production "pi-web" stack.
func composeArgs(args ...string) []string {
	return append([]string{
		"docker", "compose",
		"-f", hostProjectDir + "/compose.yaml",
		"-f", hostProjectDir + "/compose.test.yaml",
		"--project-directory", hostProjectDir,
		"--project-name", "pi-web-ci",
	}, args...)
}

func (m *PiWeb) composeUp(ctx context.Context, src *dagger.Directory, sock *dagger.Socket) error {
	_, err := m.dockerCLI(src, sock).
		WithExec(composeArgs("up", "-d", "--wait", "--wait-timeout", "360", "--pull", "missing", "--yes")).
		Stdout(ctx)
	return err
}

func (m *PiWeb) composeLogs(ctx context.Context, src *dagger.Directory, sock *dagger.Socket) (string, error) {
	return m.dockerCLI(src, sock).
		WithExec(composeArgs("logs", "--timestamps")).
		Stdout(ctx)
}

func (m *PiWeb) composeDown(ctx context.Context, src *dagger.Directory, sock *dagger.Socket) error {
	_, err := m.dockerCLI(src, sock).
		WithExec(composeArgs("down", "-v")).
		Stdout(ctx)
	return err
}

func (m *PiWeb) runHealthChecks(ctx context.Context, src *dagger.Directory, sock *dagger.Socket, sb *strings.Builder) error {
	cli := m.dockerCLI(src, sock)

	// check runs a command inside a compose service container and records the result.
	check := func(label, service string, cmd ...string) error {
		args := append([]string{"exec", "-T", service}, cmd...)
		if _, err := cli.WithExec(composeArgs(args...)).Stdout(ctx); err != nil {
			return fmt.Errorf("%s: %w", label, err)
		}
		sb.WriteString("✔ " + label + "\n")
		return nil
	}

	// --- Infrastructure ---

	if err := check("traefik ping", "traefik",
		"traefik", "healthcheck", "--ping"); err != nil {
		return err
	}
	// Confirm postgres is accepting connections AND all four application databases
	// were created by config/postgres/init-databases.sh.
	if err := check("postgres ready + databases", "postgres",
		"sh", "-c", "pg_isready -U postgres && psql -U postgres -lqt | grep -qE 'authelia|immich|lldap|nextcloud'"); err != nil {
		return err
	}
	if err := check("redis ping", "redis",
		"redis-cli", "ping"); err != nil {
		return err
	}

	// --- DNS stack ---

	if err := check("unbound DNS resolution", "unbound",
		"unbound-host", "-r", "-t", "A", "cloudflare.com"); err != nil {
		return err
	}
	if err := check("pihole DNS resolution", "pihole",
		"nslookup", "cloudflare.com", "127.0.0.1"); err != nil {
		return err
	}

	// --- Auth stack ---

	if err := check("lldap web UI", "lldap",
		"wget", "-qO", "/dev/null", "http://127.0.0.1:17170/"); err != nil {
		return err
	}
	if err := check("authelia health API", "authelia",
		"wget", "-qO", "/dev/null", "http://127.0.0.1:9091/api/health"); err != nil {
		return err
	}

	// --- Application services ---

	if err := check("ntfy health", "ntfy",
		"wget", "-qO", "/dev/null", "http://127.0.0.1/v1/health"); err != nil {
		return err
	}
	if err := check("n8n health", "n8n",
		"wget", "-qO", "/dev/null", "http://127.0.0.1:5678/healthz"); err != nil {
		return err
	}
	if err := check("homepage", "homepage",
		"wget", "-qO", "/dev/null", "http://127.0.0.1:3000/"); err != nil {
		return err
	}
	if err := check("beszel health", "beszel",
		"/beszel", "health", "--url", "http://localhost:8090"); err != nil {
		return err
	}
	if err := check("uptime-kuma health", "uptime-kuma",
		"/extra/healthcheck"); err != nil {
		return err
	}
	if err := check("portainer", "portainer",
		"/portainer", "--version"); err != nil {
		return err
	}

	// --- Storage services ---

	// Nextcloud /status.php — accept 200 (ready) or 503 (still initialising DB), retry up to 12×.
	ncScript := `code=""
for i in $(seq 1 12); do
  code=$(curl -sS -o /dev/null -w '%{http_code}' http://localhost/status.php | tr -d '\r\n')
  if [ "$code" = "200" ] || [ "$code" = "503" ]; then break; fi
  sleep 5
done
if [ "$code" != "200" ] && [ "$code" != "503" ]; then
  echo "Unexpected Nextcloud status.php HTTP code: $code" >&2
  exit 1
fi
echo "$code"`
	ncOut, err := cli.WithExec(composeArgs(
		"exec", "-T", "nextcloud",
		"sh", "-c", ncScript,
	)).Stdout(ctx)
	if err != nil {
		return fmt.Errorf("nextcloud: %w", err)
	}
	sb.WriteString("✔ nextcloud status.php: " + strings.TrimSpace(ncOut) + "\n")

	if err := check("immich API ping", "immich-server",
		"curl", "-fsS", "http://localhost:2283/api/server/ping"); err != nil {
		return err
	}

	return nil
}
