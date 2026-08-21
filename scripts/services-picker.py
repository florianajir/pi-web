#!/usr/bin/env python3
"""Interactive picker for the optional services of the stack.

Usage: services-picker.py <rows-file> <out-file>

The rows file holds one service per line, "service:section:companion-of:needs:state",
as produced by scripts/services.sh (which owns everything else: reading
compose.yaml, writing .env, running the per-service hooks). This script only
lets the user choose, then writes the services that stay ticked to the out
file, one per line. Exit status is 0 on confirm, 1 on cancel.

Files rather than stdio: curses owns the terminal, so a captured stdout would
either swallow the UI or the result.

Two relations reach us, and they are deliberately different. `companion-of` is
"pointless on its own" -- comet only makes sense with stremio, n8n-runners with
n8n -- and is drawn as an indented row. `needs` is "cannot run without", which
crosses sections: qbittorrent is a download service listed under Download, but
it runs inside gluetun's network namespace. Toggling propagates along both,
transitively, so the screen always shows a set the stack can actually run.
"""

import curses
import sys

HELP = "space toggle  a all  n none  enter apply  q cancel"


def read_rows(path):
    """Rows in display order, as dicts."""
    rows = []
    with open(path) as handle:
        for line in handle:
            line = line.rstrip("\n")
            if not line:
                continue
            fields = line.split(":", 4)
            if len(fields) != 5:
                sys.exit(f"services-picker: malformed row {line!r}")
            service, section, parent, needs, state = fields
            rows.append({
                "service": service,
                "section": section,
                "parent": parent,
                # Everything this service cannot run without, companion included.
                "needs": [n for n in ([parent] if parent else []) + needs.split() if n],
                "on": state == "on",
            })
    return rows


def build_lines(rows):
    """Display lines: ("head", section) or ("svc", row index)."""
    lines = []
    section = None
    for index, row in enumerate(rows):
        if row["section"] and row["section"] != section:
            section = row["section"]
            lines.append(("head", section))
        lines.append(("svc", index))
    return lines


def index_of(rows, service):
    for index, row in enumerate(rows):
        if row["service"] == service:
            return index
    return None


def toggle(rows, index):
    """Flip one box and carry along whatever cannot run without it.

    Ticking pulls in everything the service needs; unticking drops everything
    that needs it. Both walk the graph, so comet pulls in stremio and gluetun,
    and dropping gluetun drops stremio and comet with it.
    """
    on = not rows[index]["on"]
    rows[index]["on"] = on
    moved = []
    pending = [index]
    while pending:
        current = pending.pop()
        if on:
            for service in rows[current]["needs"]:
                target = index_of(rows, service)
                if target is not None and not rows[target]["on"]:
                    rows[target]["on"] = True
                    moved.append(service)
                    pending.append(target)
        else:
            dropped = rows[current]["service"]
            for target, row in enumerate(rows):
                if row["on"] and dropped in row["needs"]:
                    row["on"] = False
                    moved.append(row["service"])
                    pending.append(target)
    if not moved:
        return ""
    verb = "also ticked" if on else "also unticked"
    return f"{verb}: {' '.join(sorted(set(moved)))}"


def set_all(rows, on):
    for row in rows:
        row["on"] = on


def draw(win, rows, lines, cursor, offset, message):
    win.erase()
    height, width = win.getmaxyx()
    body = max(height - 3, 1)
    win.addnstr(0, 0, "Optional services — core infrastructure always runs",
                width - 1, curses.A_BOLD)
    for screen_row, line_index in enumerate(range(offset, min(offset + body, len(lines)))):
        kind, payload = lines[line_index]
        y = screen_row + 1
        if kind == "head":
            win.addnstr(y, 0, f"── {payload} ".ljust(width - 1, "─"), width - 1, curses.A_DIM)
            continue
        row = rows[payload]
        indent = "  " if row["parent"] else ""
        text = f" [{'x' if row['on'] else ' '}] {indent}{row['service']}"
        attr = curses.A_REVERSE if line_index == cursor else curses.A_NORMAL
        win.addnstr(y, 0, text.ljust(width - 1), width - 1, attr)
    selected = sum(1 for row in rows if row["on"])
    footer = message or f"{selected}/{len(rows)} selected   {HELP}"
    win.addnstr(height - 1, 0, footer[:width - 1], width - 1, curses.A_DIM)
    win.refresh()


def first_service_line(lines, start, step):
    """Nearest line at or after start (walking by step) that is a service."""
    index = start
    while 0 <= index < len(lines):
        if lines[index][0] == "svc":
            return index
        index += step
    return None


def move(lines, cursor, start, step):
    """Cursor after a move, staying on a service line and inside the list."""
    target = first_service_line(lines, start, step)
    return cursor if target is None else target


def run(screen, rows):
    curses.curs_set(0)
    lines = build_lines(rows)
    cursor = first_service_line(lines, 0, 1)
    if cursor is None:
        return False
    offset = 0
    message = ""
    while True:
        height = max(screen.getmaxyx()[0] - 3, 1)
        offset = min(offset, cursor)
        if cursor >= offset + height:
            offset = cursor - height + 1
        draw(screen, rows, lines, cursor, offset, message)
        key = screen.getch()
        if key in (ord("q"), 27):
            return False
        if key in (curses.KEY_ENTER, 10, 13):
            return True
        message = ""
        if key in (curses.KEY_DOWN, ord("j")):
            cursor = move(lines, cursor, cursor + 1, 1)
        elif key in (curses.KEY_UP, ord("k")):
            cursor = move(lines, cursor, cursor - 1, -1)
        elif key == curses.KEY_NPAGE:
            cursor = move(lines, cursor, min(cursor + height, len(lines) - 1), -1)
        elif key == curses.KEY_PPAGE:
            cursor = move(lines, cursor, max(cursor - height, 0), 1)
        elif key == ord(" "):
            message = toggle(rows, lines[cursor][1])
        elif key == ord("a"):
            set_all(rows, True)
        elif key == ord("n"):
            set_all(rows, False)
        elif key == curses.KEY_RESIZE:
            offset = 0


def main():
    if len(sys.argv) != 3:
        print("usage: services-picker.py <rows-file> <out-file>", file=sys.stderr)
        return 2
    rows = read_rows(sys.argv[1])
    if not rows:
        print("services-picker: no services to choose from", file=sys.stderr)
        return 2
    if not curses.wrapper(run, rows):
        return 1
    with open(sys.argv[2], "w") as handle:
        for row in rows:
            if row["on"]:
                handle.write(row["service"] + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
