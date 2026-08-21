#!/usr/bin/env python3
"""Interactive picker for the optional services of the stack.

Usage: services-picker.py <rows-file> <out-file>

The rows file holds one service per line, "service:section:parent:state",
as produced by scripts/services.sh (which owns everything else: reading
compose.yaml, writing .env, running the per-service hooks). This script only
lets the user choose, then writes the selected service names to the out file,
one per line. Exit status is 0 on confirm, 1 on cancel.

Files rather than stdio: curses owns the terminal, so a captured stdout would
either swallow the UI or the result.

Linked services move together as the boxes are toggled: a service that only
runs with another (qbittorrent inside gluetun's network namespace, n8n-runners
behind n8n) is indented under it, unticking the one it hangs off unticks it
too, and ticking it back ticks that one. Compose behaves the same way -- the
child's own profile activates the parent -- so the screen matches what the
stack will do.
"""

import curses
import sys

HELP = "space toggle  a all  n none  enter apply  q cancel"


def read_rows(path):
    """[(service, section, parent, on)] in display order."""
    rows = []
    with open(path) as handle:
        for line in handle:
            line = line.rstrip("\n")
            if not line:
                continue
            fields = line.split(":", 3)
            if len(fields) != 4:
                sys.exit(f"services-picker: malformed row {line!r}")
            service, section, parent, state = fields
            rows.append((service, section, parent, state == "on"))
    return rows


def build_lines(rows):
    """Display lines: ("head", section) or ("svc", index), section headers included."""
    lines = []
    section = None
    for index, (_service, svc_section, parent, _on) in enumerate(rows):
        if not parent and svc_section != section:
            section = svc_section
            lines.append(("head", section))
        lines.append(("svc", index))
    return lines


def children_of(rows, service):
    return [i for i, row in enumerate(rows) if row[2] == service]


def parent_index(rows, index):
    parent = rows[index][2]
    if not parent:
        return None
    for i, row in enumerate(rows):
        if row[0] == parent:
            return i
    return None


def toggle(rows, index):
    """Flip one box, then carry the services linked to it along."""
    on = not rows[index][3]
    rows[index] = rows[index][:3] + (on,)
    if on:
        # It cannot run alone: the one it hangs off comes with it.
        parent = parent_index(rows, index)
        if parent is not None and not rows[parent][3]:
            rows[parent] = rows[parent][:3] + (True,)
    else:
        # Nothing that only runs with it can stay.
        for child in children_of(rows, rows[index][0]):
            if rows[child][3]:
                rows[child] = rows[child][:3] + (False,)


def set_all(rows, on):
    for i, row in enumerate(rows):
        rows[i] = row[:3] + (on,)


def draw(win, rows, lines, cursor, offset):
    win.erase()
    height, width = win.getmaxyx()
    body = max(height - 3, 1)
    win.addnstr(0, 0, "Optional services — core infrastructure always runs", width - 1,
                curses.A_BOLD)
    for screen_row, line_index in enumerate(range(offset, min(offset + body, len(lines)))):
        kind, payload = lines[line_index]
        y = screen_row + 1
        if kind == "head":
            win.addnstr(y, 0, f"── {payload} ".ljust(width - 1, "─"), width - 1, curses.A_DIM)
            continue
        service, _section, parent, on = rows[payload]
        indent = "  " if parent else ""
        text = f" [{'x' if on else ' '}] {indent}{service}"
        attr = curses.A_REVERSE if line_index == cursor else curses.A_NORMAL
        win.addnstr(y, 0, text.ljust(width - 1), width - 1, attr)
    selected = sum(1 for row in rows if row[3])
    win.addnstr(height - 1, 0, f"{selected}/{len(rows)} selected   {HELP}"[:width - 1],
                width - 1, curses.A_DIM)
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
    while True:
        height = max(screen.getmaxyx()[0] - 3, 1)
        offset = min(offset, cursor)
        if cursor >= offset + height:
            offset = cursor - height + 1
        draw(screen, rows, lines, cursor, offset)
        key = screen.getch()
        if key in (ord("q"), 27):
            return False
        if key in (curses.KEY_ENTER, 10, 13):
            return True
        if key in (curses.KEY_DOWN, ord("j")):
            cursor = move(lines, cursor, cursor + 1, 1)
        elif key in (curses.KEY_UP, ord("k")):
            cursor = move(lines, cursor, cursor - 1, -1)
        elif key == curses.KEY_NPAGE:
            cursor = move(lines, cursor, min(cursor + height, len(lines) - 1), -1)
        elif key == curses.KEY_PPAGE:
            cursor = move(lines, cursor, max(cursor - height, 0), 1)
        elif key == ord(" "):
            toggle(rows, lines[cursor][1])
        elif key == ord("a"):
            set_all(rows, True)
        elif key == ord("n"):
            set_all(rows, False)
        elif key == curses.KEY_RESIZE:
            offset = 0


def main():
    if len(sys.argv) != 3:
        print(__doc__.strip().splitlines()[2], file=sys.stderr)
        return 2
    rows = read_rows(sys.argv[1])
    if not rows:
        print("services-picker: no services to choose from", file=sys.stderr)
        return 2
    if not curses.wrapper(run, rows):
        return 1
    with open(sys.argv[2], "w") as handle:
        for service, _section, _parent, on in rows:
            if on:
                handle.write(service + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
