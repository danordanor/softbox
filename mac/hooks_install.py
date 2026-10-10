#!/usr/bin/env python3
"""Add (or with --remove, take out) the Softbox hooks in ~/.claude/settings.json.

Only our own entries are touched; each carries a marker so re-running is safe.
Uses only the Python standard library, so it works on any Mac without Node.
"""
import json
import os
import sys

PORT = os.environ.get("LIGHTD_PORT", "9124")
MARK = "lightd-hook"
PATH = os.path.expanduser("~/.claude/settings.json")


def call(ev):
    # the bridge answers at once and plays the effect in its own thread
    return (f'curl -s -m 3 -X POST -H "X-Lightd: 1" '
            f'http://127.0.0.1:{PORT}/api/event/{ev} >/dev/null 2>&1 || true  # {MARK}')


WANT = {
    "Notification": call("claude-waiting"),  # Claude asks for input or approval
    "Stop": call("claude-done"),             # Claude finished its turn
}


def main():
    remove = "--remove" in sys.argv
    cfg = {}
    if os.path.exists(PATH):
        try:
            with open(PATH) as f:
                cfg = json.load(f)
        except ValueError:
            print(f"  {PATH} isn't valid JSON; leaving it alone.")
            return 1
    hooks = cfg.setdefault("hooks", {})

    for event in set(hooks) | set(WANT):
        groups = hooks.get(event, [])
        for g in groups:
            if isinstance(g.get("hooks"), list):
                g["hooks"] = [h for h in g["hooks"] if MARK not in str(h.get("command", ""))]
        groups = [g for g in groups if g.get("hooks")]   # drop groups we emptied
        if not remove and event in WANT:
            groups.append({"hooks": [{"type": "command", "command": WANT[event]}]})
        if groups:
            hooks[event] = groups
        else:
            hooks.pop(event, None)

    os.makedirs(os.path.dirname(PATH), exist_ok=True)
    tmp = PATH + ".tmp"
    with open(tmp, "w") as f:
        json.dump(cfg, f, indent=2)
        f.write("\n")
    os.replace(tmp, PATH)
    print(f"  hooks {'removed from' if remove else 'set in'} {PATH}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
