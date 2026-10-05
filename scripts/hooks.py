#!/usr/bin/env python3
"""Add or remove the Watchlamp hooks in ~/.claude/settings.json.

    hooks.py install <path-to-Watchlamp-binary>
    hooks.py uninstall

Only entries whose command mentions Watchlamp (or its old name ClaudeStatusLight) are touched;
everything else in the file is kept as is. A backup goes to ~/.claude/watchlamp/backups/ first.
"""
import json
import os
import sys
import time

SETTINGS = os.path.expanduser("~/.claude/settings.json")
BACKUPS = os.path.expanduser("~/.claude/watchlamp/backups")
MARKERS = ("Watchlamp", "ClaudeStatusLight")   # current and pre-rename installs
EVENTS = [
    "SessionStart", "SessionEnd", "UserPromptSubmit",
    "PreToolUse", "PostToolUse", "PostToolUseFailure", "PermissionRequest", "PermissionDenied",
    "Notification", "Elicitation", "ElicitationResult", "PreCompact",
    "SubagentStart", "SubagentStop", "Stop", "StopFailure",
]
TOOL_EVENTS = {"PreToolUse", "PostToolUse", "PostToolUseFailure", "PermissionRequest", "PermissionDenied"}


def load():
    if not os.path.exists(SETTINGS):
        return {}
    with open(SETTINGS, encoding="utf-8") as f:
        text = f.read()
    return json.loads(text) if text.strip() else {}


def save(settings):
    os.makedirs(BACKUPS, exist_ok=True)
    if os.path.exists(SETTINGS):
        stamp = time.strftime("%Y%m%d-%H%M%S")
        with open(SETTINGS, encoding="utf-8") as src, \
             open(os.path.join(BACKUPS, f"settings.json.{stamp}"), "w", encoding="utf-8") as dst:
            dst.write(src.read())
    os.makedirs(os.path.dirname(SETTINGS), exist_ok=True)
    tmp = SETTINGS + ".watchlamp.tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(settings, f, indent=2, ensure_ascii=False)
        f.write("\n")
    os.replace(tmp, SETTINGS)


def strip(settings):
    """Remove our hook entries, then any groups or events left empty."""
    hooks = settings.get("hooks")
    if not isinstance(hooks, dict):
        return
    for event in list(hooks):
        groups = hooks[event]
        if not isinstance(groups, list):
            continue
        for group in groups:
            if isinstance(group, dict) and isinstance(group.get("hooks"), list):
                group["hooks"] = [h for h in group["hooks"]
                                  if not any(m in str(h.get("command", "")) for m in MARKERS)]
        hooks[event] = [g for g in groups if not (isinstance(g, dict) and g.get("hooks") == [])]
        if not hooks[event]:
            del hooks[event]
    if not hooks:
        del settings["hooks"]


def install(binary):
    settings = load()
    strip(settings)
    command = f"'{binary}' hook 2>/dev/null || true"
    hooks = settings.setdefault("hooks", {})
    for event in EVENTS:
        group = {"hooks": [{"type": "command", "command": command, "timeout": 5}]}
        if event in TOOL_EVENTS:
            group = {"matcher": "*", **group}
        hooks.setdefault(event, []).append(group)
    save(settings)
    print(f"Installed {len(EVENTS)} hooks into {SETTINGS}")


def uninstall():
    settings = load()
    before = json.dumps(settings, sort_keys=True)
    strip(settings)
    if json.dumps(settings, sort_keys=True) == before:
        print("No Watchlamp hooks found.")
        return
    save(settings)
    print(f"Removed Watchlamp hooks from {SETTINGS}")


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "install":
        install(sys.argv[2])
    elif len(sys.argv) == 2 and sys.argv[1] == "uninstall":
        uninstall()
    else:
        sys.exit(__doc__)
