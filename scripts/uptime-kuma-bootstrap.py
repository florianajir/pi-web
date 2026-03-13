#!/usr/bin/env python3
"""Bootstrap Uptime Kuma 2.x: setup admin, disable built-in auth (Authelia handles it),
configure ntfy notification, docker host, and container monitors.

Uses direct Socket.IO calls for Uptime Kuma 2.x compatibility.
"""

import json
import os
import re
import sys
import time
import threading

import socketio

LOG_PREFIX = "[uptime-kuma-bootstrap]"


def log(msg):
    ts = time.strftime("%H:%M:%S")
    print(f"{LOG_PREFIX} {ts} {msg}", file=sys.stderr, flush=True)


def env(key, default=""):
    return os.environ.get(key, default).strip()


def read_env_file(path):
    """Read a dotenv-style file into a dict."""
    values = {}
    if not os.path.isfile(path):
        return values
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            if "=" in line:
                k, v = line.split("=", 1)
                values[k.strip()] = v.strip()
    return values


def get_container_names_from_compose(project_dir):
    """Extract container names from compose.yaml."""
    compose_path = os.path.join(project_dir, "compose.yaml")
    if not os.path.isfile(compose_path):
        log(f"ERROR: compose.yaml not found at {compose_path}")
        return []
    containers = []
    with open(compose_path) as f:
        for line in f:
            match = re.search(r"container_name:\s*(\S+)", line)
            if match:
                containers.append(match.group(1))
    return containers


class UptimeKumaBootstrap:
    """Socket.IO client for Uptime Kuma 2.x bootstrap operations."""

    def __init__(self, url, timeout=30):
        self.url = url
        self.timeout = timeout
        self.sio = socketio.Client(logger=False, engineio_logger=False)
        self._connected = threading.Event()
        self._auto_logged_in = threading.Event()
        self._need_setup = threading.Event()
        self._ready = threading.Event()

        # Data received via events after login
        self.docker_hosts = []
        self.notifications = []
        self.monitors = {}

        self.sio.on("connect", self._on_connect)
        self.sio.on("autoLogin", self._on_auto_login)
        self.sio.on("setup", self._on_setup)
        self.sio.on("dockerHostList", self._on_docker_host_list)
        self.sio.on("notificationList", self._on_notification_list)
        self.sio.on("monitorList", self._on_monitor_list)

    def _on_connect(self):
        self._connected.set()

    def _on_auto_login(self, *args):
        self._auto_logged_in.set()

    def _on_setup(self, *args):
        self._need_setup.set()

    def _on_docker_host_list(self, data):
        if isinstance(data, list):
            self.docker_hosts = data
        log(f"Received {len(self.docker_hosts)} docker host(s)")

    def _on_notification_list(self, data):
        if isinstance(data, list):
            self.notifications = data
        log(f"Received {len(self.notifications)} notification(s)")

    def _on_monitor_list(self, data):
        if isinstance(data, dict):
            self.monitors = {
                m["name"]: m for m in data.values()
                if isinstance(m, dict) and "name" in m
            }
        self._ready.set()
        log(f"Received {len(self.monitors)} monitor(s)")

    def connect(self):
        """Connect to Uptime Kuma Socket.IO server."""
        log(f"Connecting to {self.url}")
        deadline = time.time() + 180
        last_err = None
        while time.time() < deadline:
            try:
                self.sio.connect(self.url, transports=["websocket"], wait_timeout=self.timeout)
                self._connected.wait(timeout=self.timeout)
                # Wait for autoLogin or setup events
                time.sleep(2)
                return
            except Exception as e:
                last_err = e
                time.sleep(2)
        log(f"ERROR: Could not connect: {last_err}")
        sys.exit(1)

    def disconnect(self):
        try:
            self.sio.disconnect()
        except Exception:
            pass

    def wait_ready(self):
        """Wait for monitorList event (signals all data has been sent)."""
        if not self._ready.wait(timeout=self.timeout):
            log("WARNING: Timed out waiting for monitor list event")

    def _call(self, event, *args):
        """Emit a Socket.IO event and wait for the callback response.

        Multiple arguments are sent as a tuple (Socket.IO array).
        """
        result = {}
        done = threading.Event()

        def callback(*cb_args):
            if cb_args:
                result["data"] = cb_args[0] if len(cb_args) == 1 else cb_args
            done.set()

        # python-socketio sends multiple args via a tuple as the data param
        data = args[0] if len(args) == 1 else args if args else None
        self.sio.emit(event, data, callback=callback)
        if not done.wait(timeout=self.timeout):
            raise TimeoutError(f"Timeout waiting for {event} response")
        return result.get("data", {})

    def setup(self, username, password):
        """Create initial admin account.
        Server signature: setup(username, password, callback)
        """
        r = self._call("setup", username, password)
        if not r.get("ok"):
            raise Exception(r.get("msg", "Setup failed"))
        log(f"Created admin account: {username}")
        return r

    def login(self, username, password):
        """Login with username and password.
        Server signature: login(data, callback) where data={username, password}
        """
        r = self._call("login", {"username": username, "password": password})
        if not r.get("ok"):
            raise Exception(r.get("msg", "Login failed"))
        log(f"Logged in as {username}")
        return r

    def setup_or_login(self, username, password):
        """Setup initial account or login with existing credentials."""
        if self._auto_logged_in.is_set():
            log("Auto-logged in (auth disabled)")
            self.wait_ready()
            return

        if self._need_setup.is_set():
            log("Fresh instance detected, creating admin account")
            self.setup(username, password)
            # Reconnect after setup to get proper auth context
            self.disconnect()
            time.sleep(2)
            self._reset_state()
            self.connect()
            if not self._auto_logged_in.is_set():
                self.login(username, password)
            self.wait_ready()
            return

        # Try login (instance already set up, auth enabled)
        try:
            self.login(username, password)
            self.wait_ready()
        except Exception as e:
            log(f"Login failed: {e}")
            sys.exit(1)

    def _reset_state(self):
        """Reset all event flags and data for reconnection."""
        self._connected.clear()
        self._auto_logged_in.clear()
        self._need_setup.clear()
        self._ready.clear()
        self.docker_hosts = []
        self.notifications = []
        self.monitors = {}

    def disable_auth(self, password):
        """Disable built-in auth (Authelia handles authentication).
        Server signature: setSettings(data, currentPassword, callback)
        """
        r = self._call("setSettings", {"disableAuth": True}, password)
        if isinstance(r, dict) and r.get("ok"):
            log("Disabled built-in auth (Authelia handles it)")
        else:
            log(f"setSettings response: {r} (may already be disabled)")

    def add_docker_host(self, name, docker_type="socket", docker_daemon="/var/run/docker.sock"):
        """Add a Docker host.
        Server signature: addDockerHost(dockerHost, dockerHostID, callback)
        """
        r = self._call("addDockerHost", {
            "name": name,
            "dockerType": docker_type,
            "dockerDaemon": docker_daemon,
        }, None)
        if not r.get("ok"):
            raise Exception(r.get("msg", "Failed to add docker host"))
        log(f"Added Docker host '{name}' (id={r.get('id')})")
        return r.get("id")

    def ensure_docker_host(self):
        """Ensure local Docker socket host exists. Returns its ID."""
        for host in self.docker_hosts:
            dtype = host.get("dockerType", host.get("_dockerType", ""))
            if dtype in (1, "socket"):  # SOCKET
                log(f"Docker host exists (id={host['id']}, name={host['name']})")
                return host["id"]

        return self.add_docker_host("Local Docker")

    def add_notification(self, config):
        """Add a notification.
        Server signature: addNotification(notification, notificationID, callback)
        """
        r = self._call("addNotification", config, None)
        if not r.get("ok"):
            raise Exception(r.get("msg", "Failed to add notification"))
        log(f"Added notification '{config.get('name')}' (id={r.get('id')})")
        return r.get("id")

    def ensure_ntfy_notification(self, ntfy_url, topic, ntfy_username, ntfy_password):
        """Ensure ntfy notification exists with username/password auth. Returns its ID."""
        for notif in self.notifications:
            config = notif.get("config", {})
            if isinstance(config, str):
                try:
                    config = json.loads(config)
                except Exception:
                    config = {}
            if config.get("type") == "ntfy" and config.get("ntfyserverurl") == ntfy_url:
                log(f"ntfy notification exists (id={notif['id']}, name={notif.get('name', config.get('name'))})")
                return notif["id"]

        return self.add_notification({
            "name": "ntfy",
            "type": "ntfy",
            "isDefault": True,
            "applyExisting": True,
            "ntfyserverurl": ntfy_url,
            "ntfytopic": topic,
            "ntfyAuthenticationMethod": "usernamePassword",
            "ntfyusername": ntfy_username,
            "ntfypassword": ntfy_password,
            "ntfyPriority": 3,
        })

    def add_monitor(self, monitor_data):
        """Add a monitor.
        Server signature: add(monitor, callback)
        """
        r = self._call("add", monitor_data)
        if not r.get("ok"):
            raise Exception(r.get("msg", "Failed to add monitor"))
        return r

    def ensure_group_monitor(self, group_name, notification_id):
        """Ensure a group monitor exists. Returns its ID."""
        if group_name in self.monitors:
            return self.monitors[group_name].get("id")

        r = self.add_monitor({
            "type": "group",
            "name": group_name,
            "interval": 60,
            "retryInterval": 30,
            "maxretries": 3,
            "accepted_statuscodes": ["200-299"],
            "notificationIDList": {str(notification_id): True} if notification_id else {},
            "conditions": [],
        })
        monitor_id = r.get("monitorID")
        log(f"Added group '{group_name}' (id={monitor_id})")
        return monitor_id

    def ensure_container_monitor(self, container_name, docker_host_id, notification_id, parent_id=None):
        """Ensure a Docker container monitor exists."""
        display_name = container_name
        if display_name.startswith("pi-"):
            display_name = display_name[3:]

        if display_name in self.monitors:
            return self.monitors[display_name].get("id")

        monitor_data = {
            "type": "docker",
            "name": display_name,
            "docker_container": container_name,
            "docker_host": docker_host_id,
            "interval": 60,
            "retryInterval": 30,
            "maxretries": 3,
            "accepted_statuscodes": ["200-299"],
            "notificationIDList": {str(notification_id): True} if notification_id else {},
            "conditions": [],
        }
        if parent_id is not None:
            monitor_data["parent"] = parent_id

        r = self.add_monitor(monitor_data)
        log(f"Added monitor '{display_name}' (id={r.get('monitorID')})")
        return r.get("monitorID")


def main():
    project_dir = env("PROJECT_DIR", os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    env_file = os.path.join(project_dir, ".env")
    ntfy_env_file = os.path.join(project_dir, "config", "ntfy", "ntfy.env")

    log("=== Uptime Kuma Bootstrap ===")

    if not os.path.isfile(env_file):
        log(f"ERROR: .env not found at {env_file}")
        sys.exit(1)

    env_values = read_env_file(env_file)
    ntfy_env = read_env_file(ntfy_env_file)

    username = env_values.get("USER", "")
    password = ntfy_env.get("UPTIME_KUMA_ADMIN_PASSWORD", "")
    if not username:
        log("ERROR: USER must be set in .env")
        sys.exit(1)
    if not password:
        log("ERROR: UPTIME_KUMA_ADMIN_PASSWORD not found in ntfy.env; run ntfy-pre-start.sh first")
        sys.exit(1)

    ntfy_username = "uptime-kuma"
    ntfy_password = ntfy_env.get("NTFY_UPTIME_KUMA_PASSWORD", "")
    ntfy_topic = "pi"
    kuma_url = env("UPTIME_KUMA_URL", "http://pi-uptime-kuma:3001")

    api = UptimeKumaBootstrap(kuma_url)
    api.connect()

    try:
        # Setup or login
        api.setup_or_login(username, password)

        # Disable built-in auth (Authelia handles it via reverse proxy)
        api.disable_auth(password)

        # Ensure Docker host
        docker_host_id = api.ensure_docker_host()

        # Ensure ntfy notification (username/password auth)
        notification_id = None
        ntfy_url = "http://pi-ntfy"
        if ntfy_password:
            notification_id = api.ensure_ntfy_notification(
                ntfy_url, ntfy_topic, ntfy_username, ntfy_password,
            )
        else:
            log("WARNING: NTFY_UPTIME_KUMA_PASSWORD not found; skipping ntfy notification setup")

        # Ensure "pi-web" group monitor
        group_id = api.ensure_group_monitor("pi-web", notification_id)

        # Get container names from compose.yaml
        container_names = get_container_names_from_compose(project_dir)
        if not container_names:
            log("WARNING: No container names found in compose.yaml")
        else:
            log(f"Found {len(container_names)} containers to monitor")

        for container_name in container_names:
            if container_name == "pi-uptime-kuma":
                continue
            try:
                api.ensure_container_monitor(
                    container_name, docker_host_id, notification_id, parent_id=group_id,
                )
            except Exception as e:
                log(f"WARNING: Failed to add monitor for {container_name}: {e}")

        log("Bootstrap completed successfully")

    finally:
        api.disconnect()


if __name__ == "__main__":
    main()
