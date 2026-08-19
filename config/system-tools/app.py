"""Read-only system status, as an OpenAPI tool server for Open WebUI.

Open WebUI injects every operation of the spec into the prompt of every message,
and this Pi processes prompts at ~40 tok/s - so the schema is a latency budget,
and so are the replies, which are re-processed on the next turn. One operation
with an enum costs 170 tokens, about +14 per topic added, where one extra
operation costs +72 on its own. `df -h` alone would cost ~400 in padding.

/proc and /sys are host-wide inside a container already; statvfs is not, which is
the only reason / is bind-mounted at /hostfs.

No endpoint takes a command, a path or a pattern, so an injected prompt has
nothing to steer.
"""

from __future__ import annotations

import json
import os
import socket
import sqlite3
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Literal
from urllib.parse import quote
from urllib.request import Request, urlopen

from fastapi import FastAPI
from fastapi.responses import PlainTextResponse

HOSTFS = Path(os.environ.get("HOSTFS", "/hostfs"))
PROC = HOSTFS / "proc"
SYS = HOSTFS / "sys"
DOCKER_SOCK = os.environ.get("DOCKER_SOCK", "/var/run/docker.sock")
# The socket is the host's: unfiltered, the list covers containers that have
# nothing to do with this stack, and a stray Exited one reads as a fault.
COMPOSE_PROJECT = os.environ.get("COMPOSE_PROJECT", "pi-web")
# Backrest's data directory is bind-mounted straight in (see compose.yaml); this
# is not a host path resolved under HOSTFS, because DATA_LOCATION is relative to
# the project directory by default and would land somewhere else entirely.
OPLOG = Path(os.environ.get("BACKREST_OPLOG", "/run/backrest/oplog.sqlite"))

# From backrest's proto/v1/operations.proto. WARNING is declared before ERROR but
# numbered after the cancellations, so reading declaration order off the binary
# gets these backwards.
BACKUP_STATUS = {
    0: "state unknown",
    1: "scheduled",
    2: "running",
    3: "succeeded",
    4: "FAILED",
    5: "cancelled by the system",
    6: "cancelled",
    7: "succeeded with warnings",
}
FINISHED = (3, 4, 7)

# A container started this recently is worth mentioning even with no restart
# counted against it, because `docker compose up` resets the counter.
RECENT_START = 3600
LOG_LINES = 3
LOG_WIDTH = 120

HEADSCALE_URL = os.environ.get("HEADSCALE_URL", "")
HEADSCALE_KEY_FILE = Path(os.environ.get("HEADSCALE_KEY_FILE", "/run/secrets/headscale_api_key"))
# All of them fit in a digest at this size; past it, offline devices are trimmed
# oldest-first and the reply says how many it dropped.
DEVICE_LINES = 25

# Named rather than discovered: enumerating the host's mount table meant
# filtering two dozen pseudo-filesystems and container layers down to these.
# topic_overview reports the first line, so `/` stays first.
FILESYSTEMS = ("/", "/mnt/usbdrive", "/mnt/sdcard")

app = FastAPI(
    title="Pi system status",
    description="Read-only status of the server this assistant runs on.",
    version="1.0.0",
)


def read(path: Path, default: str = "") -> str:
    try:
        return path.read_text()
    except OSError:
        return default


def human_bytes(num: float) -> str:
    for unit in ("B", "K", "M", "G", "T"):
        if abs(num) < 1024 or unit == "T":
            return f"{num:.0f}{unit}" if unit in ("B", "K") else f"{num:.1f}{unit}"
        num /= 1024
    return f"{num:.1f}T"


def duration(seconds: float) -> str:
    days, rem = divmod(int(seconds), 86400)
    hours, rem = divmod(rem, 3600)
    minutes = rem // 60
    parts = []
    if days:
        parts.append(f"{days}d")
    if hours or days:
        parts.append(f"{hours}h")
    parts.append(f"{minutes}m")
    return " ".join(parts)


def topic_disk() -> str:
    lines = []
    for mount in FILESYSTEMS:
        path = HOSTFS / mount.lstrip("/")
        # An unmounted drive leaves an empty directory on the root filesystem,
        # for which statvfs answers with the root filesystem's own numbers.
        if not path.is_mount():
            continue
        try:
            st = os.statvfs(path)
        except OSError:
            continue
        total = st.f_blocks * st.f_frsize
        if not total:
            continue
        free = st.f_bavail * st.f_frsize
        used = total - st.f_bfree * st.f_frsize
        lines.append(f"{mount}: {human_bytes(free)} free of {human_bytes(total)} ({used * 100 // total}% used)")
    return "\n".join(lines) or "no filesystem readable"


def cpu_times() -> list[list[int]]:
    rows = []
    for entry in read(PROC / "stat").splitlines():
        if not entry.startswith("cpu"):
            break
        rows.append([int(v) for v in entry.split()[1:]])
    return rows


def topic_cpu() -> str:
    # Two samples 300ms apart: /proc/stat is cumulative since boot, so a single
    # read would report the average since power-on rather than "right now".
    first = cpu_times()
    time.sleep(0.3)
    second = cpu_times()
    if not first or not second:
        return "cpu unreadable"

    def busy(before: list[int], after: list[int]) -> float:
        total = sum(after) - sum(before)
        idle = (after[3] + after[4]) - (before[3] + before[4])
        return 100.0 * (total - idle) / total if total > 0 else 0.0

    cores = len(first) - 1
    lines = [f"usage: {busy(first[0], second[0]):.0f}% over {cores} cores"]
    per_core = ", ".join(f"{busy(first[i], second[i]):.0f}%" for i in range(1, len(first)))
    lines.append(f"per core: {per_core}")

    load = read(PROC / "loadavg").split()
    if len(load) >= 3:
        lines.append(f"load average: {load[0]} {load[1]} {load[2]} (1/5/15 min, saturated above {cores})")

    temp = read(SYS / "class/thermal/thermal_zone0/temp").strip()
    if temp.isdigit():
        lines.append(f"temperature: {int(temp) / 1000:.1f}C")

    freqs = sorted(SYS.glob("devices/system/cpu/cpu[0-9]*/cpufreq/scaling_cur_freq"))
    values = [int(read(f).strip() or 0) for f in freqs]
    if any(values):
        lines.append(f"clock: {max(values) // 1000} MHz")

    return "\n".join(lines)


def topic_memory() -> str:
    info = {}
    for entry in read(PROC / "meminfo").splitlines():
        key, _, value = entry.partition(":")
        info[key] = int(value.split()[0]) * 1024 if value.split() else 0
    total, available = info.get("MemTotal", 0), info.get("MemAvailable", 0)
    if not total:
        return "memory unreadable"
    lines = [f"RAM: {human_bytes(available)} available of {human_bytes(total)} ({(total - available) * 100 // total}% used)"]
    swap_total, swap_free = info.get("SwapTotal", 0), info.get("SwapFree", 0)
    if swap_total:
        lines.append(f"swap: {human_bytes(swap_total - swap_free)} used of {human_bytes(swap_total)}")
    return "\n".join(lines)


def topic_uptime() -> str:
    # split() rather than `or "0"`: a whitespace-only read is truthy.
    fields = read(PROC / "uptime").split()
    if not fields:
        return "uptime unreadable"
    up = float(fields[0])
    booted = time.strftime("%Y-%m-%d %H:%M", time.localtime(time.time() - up))
    return f"up {duration(up)} (booted {booted})\nhost time: {time.strftime('%Y-%m-%d %H:%M %Z')}"


def docker_raw(path: str) -> bytes:
    """No client library: this is a GET over a unix socket."""
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
            sock.settimeout(5)
            sock.connect(DOCKER_SOCK)
            sock.sendall(f"GET {path} HTTP/1.0\r\nHost: docker\r\n\r\n".encode())
            chunks = []
            while data := sock.recv(65536):
                chunks.append(data)
        return b"".join(chunks).split(b"\r\n\r\n", 1)[1]
    except (OSError, IndexError):
        return b""


def docker_get(path: str) -> object | None:
    try:
        return json.loads(docker_raw(path))
    except ValueError:
        return None


def project_containers() -> list[dict]:
    query = quote(json.dumps({"label": [f"com.docker.compose.project={COMPOSE_PROJECT}"]}))
    containers = docker_get(f"/containers/json?all=1&filters={query}")
    return containers if isinstance(containers, list) else []


def short_name(container: dict) -> str:
    return (container.get("Names") or ["?"])[0].lstrip("/").removeprefix("pi-")


def rfc3339(value: str) -> float | None:
    """Docker and headscale both carry nanoseconds, which %f cannot read; an event
    that never happened is reported as year 0001."""
    if not value or value.startswith("0001"):
        return None
    try:
        stamp = datetime.strptime(value.partition(".")[0], "%Y-%m-%dT%H:%M:%S")
    except ValueError:
        return None
    return stamp.replace(tzinfo=timezone.utc).timestamp()


def topic_services() -> str:
    containers = project_containers()
    if not containers:
        return "container list unavailable"
    healthy, degraded = [], []
    for container in containers:
        name = short_name(container)
        status = container.get("Status", "")
        state = container.get("State", "")
        if state == "running" and "unhealthy" not in status:
            healthy.append(name)
        else:
            degraded.append(f"{name} ({status or state})")
    lines = [f"{len(healthy)} of {len(containers)} containers running and healthy"]
    if degraded:
        lines.append("needs attention: " + ", ".join(sorted(degraded)))
    else:
        lines.append("nothing needs attention")
    return "\n".join(lines)


def topic_restarts() -> str:
    lines = []
    now = time.time()
    for container in project_containers():
        detail = docker_get(f"/containers/{container['Id']}/json")
        if not isinstance(detail, dict):
            continue
        state = detail.get("State") or {}
        count = detail.get("RestartCount") or 0
        started = rfc3339(state.get("StartedAt", ""))
        age = now - started if started else None
        if count:
            note = f"{short_name(container)}: {count} restart{'s' if count > 1 else ''}"
            stopped = rfc3339(state.get("FinishedAt", ""))
            if stopped:
                note += f", last exit code {state.get('ExitCode')} {duration(now - stopped)} ago"
            lines.append((age if age is not None else 0.0, note))
        elif age is not None and age < RECENT_START:
            lines.append((age, f"{short_name(container)}: started {duration(age)} ago"))
    if not lines:
        return "no container has restarted"
    lines.sort()
    return "\n".join(note for _, note in lines[:6])


def failing_containers() -> list[dict]:
    return [
        container
        for container in project_containers()
        if container.get("State") != "running" or "unhealthy" in container.get("Status", "")
    ]


def log_lines(body: bytes) -> list[str]:
    """Docker prefixes every chunk with an 8-byte frame header, unless the
    container was given a TTY, in which case the stream is verbatim."""
    chunks, offset = [], 0
    while offset + 8 <= len(body):
        if body[offset] not in (0, 1, 2) or body[offset + 1 : offset + 4] != b"\x00\x00\x00":
            break
        size = int.from_bytes(body[offset + 4 : offset + 8], "big")
        chunks.append(body[offset + 8 : offset + 8 + size])
        offset += 8 + size
    if not chunks:
        chunks = [body]
    text = b"".join(chunks).decode("utf-8", "replace")
    return [line.strip() for line in text.splitlines() if line.strip()]


def topic_errors() -> str:
    failing = failing_containers()
    if not failing:
        return "no container is failing, so there is nothing to quote"
    blocks = []
    # Only containers already known to be broken, and only their tail: the model
    # never names what gets read, and a reply is prompt tokens on every later turn.
    for container in failing[:3]:
        lines = log_lines(
            docker_raw(f"/containers/{container['Id']}/logs?stderr=1&stdout=1&tail={LOG_LINES}")
        )[-LOG_LINES:]
        header = f"{short_name(container)} ({container.get('Status') or container.get('State')}):"
        body = "\n".join(f"  {line[:LOG_WIDTH]}" for line in lines) or "  (no output)"
        blocks.append(f"{header}\n{body}")
    if len(failing) > 3:
        blocks.append(f"({len(failing) - 3} more failing, not quoted)")
    return "\n".join(blocks)


def topic_backups() -> str:
    """Read from backrest's operation log rather than its API: the repos live on a
    remote, and the log answers "did last night run" without a restic password."""
    try:
        with sqlite3.connect(f"file:{OPLOG}?mode=ro", uri=True) as log:
            rows = log.execute(
                "SELECT g.plan_id, g.repo_id, o.status, o.start_time_ms, o.snapshot_id "
                "FROM operations o JOIN operation_groups g ON g.ogid = o.ogid "
                "WHERE g.plan_id != '_system_' ORDER BY o.start_time_ms DESC"
            ).fetchall()
    except sqlite3.Error:
        return "backup log unreadable"
    if not rows:
        return "no backup recorded"

    now = time.time()
    latest, scheduled, failures = {}, {}, {}
    for plan, repo, status, start_ms, snapshot in rows:
        key = f"{plan} -> {repo}"
        when = start_ms / 1000
        if status in FINISHED:
            failures[key] = failures.get(key, 0) + (status == 4)
            latest.setdefault(key, (when, status, snapshot))
        elif status == 1 and when > now:
            scheduled[key] = when

    lines = []
    for key, (when, status, snapshot) in latest.items():
        line = f"{key}: {BACKUP_STATUS.get(status, status)} {duration(now - when)} ago"
        if snapshot:
            line += f" (snapshot {snapshot[:8]})"
        if failures.get(key):
            line += f", {failures[key]} failed run(s) on record"
        if key in scheduled:
            line += f"; next in {duration(scheduled[key] - now)}"
        lines.append(line)
    return "\n".join(lines)


def topic_devices() -> str:
    """The tailnet is served by headscale (config/headscale), so this reads its
    node API rather than tailscale's SaaS one. Every device is listed with when it
    was last seen, which is what makes "when was X last online" answerable without
    a parameter naming X - the model reads it off the list."""
    if not HEADSCALE_URL:
        return "tailnet not configured"
    key = read(HEADSCALE_KEY_FILE).strip()
    if not key:
        return "tailnet key unavailable"
    try:
        request = Request(f"{HEADSCALE_URL}/api/v1/node", headers={"Authorization": f"Bearer {key}"})
        with urlopen(request, timeout=5) as response:
            nodes = json.load(response).get("nodes") or []
    except (OSError, ValueError):
        return "tailnet unreachable"
    if not nodes:
        return "no device registered"

    now = time.time()
    online, offline = [], []
    for node in nodes:
        label = node.get("givenName") or node.get("name") or "?"
        owner = (node.get("user") or {}).get("name") or "?"
        if node.get("online"):
            online.append(f"online   {label} ({owner})")
        else:
            seen = rfc3339(node.get("lastSeen", ""))
            when = f"last seen {duration(now - seen)} ago" if seen else "never seen"
            offline.append((seen or 0.0, f"offline  {label} ({owner}), {when}"))

    offline.sort(reverse=True)
    users = sorted({(node.get("user") or {}).get("name") or "?" for node in nodes})
    header = f"{len(online)} of {len(nodes)} devices online, {len(users)} users: {', '.join(users)}"
    room = max(DEVICE_LINES - len(online), 0)
    lines = [header] + online + [line for _, line in offline[:room]]
    if len(offline) > room:
        lines.append(f"({len(offline) - room} more offline, not listed)")
    return "\n".join(lines)


def topic_overview() -> str:
    return "\n".join(
        [
            topic_uptime().splitlines()[0],
            topic_cpu().splitlines()[0],
            topic_memory().splitlines()[0],
            topic_disk().splitlines()[0],
            topic_services().splitlines()[0],
        ]
    )


TOPICS = {
    "overview": topic_overview,
    "disk": topic_disk,
    "cpu": topic_cpu,
    "memory": topic_memory,
    "uptime": topic_uptime,
    "services": topic_services,
    "restarts": topic_restarts,
    "errors": topic_errors,
    "backups": topic_backups,
    "devices": topic_devices,
}

Topic = Literal[
    "overview", "disk", "cpu", "memory", "uptime",
    "services", "restarts", "errors", "backups", "devices",
]


@app.get(
    "/status/{topic}",
    operation_id="get_system_status",
    summary="Live status of the server this assistant runs on",
    description=(
        "Returns current server measurements. Topics: overview (a summary of all of them), "
        "disk (free space per filesystem), cpu (usage, load, temperature), memory (RAM and swap), "
        "uptime, services (are the containers up), "
        "restarts (what restarted and why), errors (log tail of whatever is failing), "
        "backups (last backup and whether it worked), "
        "devices (tailnet devices, who owns them, which are online and when the "
        "offline ones were last seen). Call this instead of guessing."
    ),
    response_class=PlainTextResponse,
)
def get_system_status(topic: Topic) -> str:
    return TOPICS[topic]()


@app.get("/health", include_in_schema=False)
def health() -> dict[str, str]:
    return {"status": "ok"}
