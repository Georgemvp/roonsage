#!/usr/bin/env python3
"""Install the roonsage MCP server into Claude Desktop's configuration.

This script is idempotent: running it multiple times is safe.
It will never overwrite existing MCP server entries.

Usage:
    python scripts/install_mcp.py

Supported platforms:
    - macOS:  ~/Library/Application Support/Claude/claude_desktop_config.json
    - Linux:  ~/.config/claude/claude_desktop_config.json
"""

import json
import platform
import shutil
import sys
from pathlib import Path

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def get_config_path() -> Path:
    """Return the Claude Desktop config file path for the current OS."""
    system = platform.system()
    if system == "Darwin":
        return Path.home() / "Library" / "Application Support" / "Claude" / "claude_desktop_config.json"
    elif system == "Linux":
        return Path.home() / ".config" / "claude" / "claude_desktop_config.json"
    else:
        print(
            f"[!] Niet-ondersteund besturingssysteem: {system}\n"
            "    Voeg de MCP server handmatig toe aan claude_desktop_config.json.",
            file=sys.stderr,
        )
        sys.exit(1)


def get_mcp_server_path() -> Path:
    """Return the absolute path to mcp_server.py (sibling of the scripts/ folder)."""
    return (Path(__file__).parent.parent / "mcp_server.py").resolve()


def detect_python() -> str:
    """Return the absolute path to the best available Python interpreter.

    Priority:
    1. If a virtualenv is active (sys.prefix != sys.base_prefix), use
       sys.executable — this guarantees Claude Desktop runs inside the same
       environment where the MCP dependencies are installed.
    2. Otherwise fall back to the first python3 / python found on PATH.

    Always returns an absolute path so the entry works regardless of the
    user's PATH when Claude Desktop is launched.
    """
    if sys.prefix != sys.base_prefix:
        # Running inside a virtualenv — use its interpreter directly.
        return sys.executable

    # No active venv — find the system Python.
    python = shutil.which("python3") or shutil.which("python")
    if python is None:
        print(
            "[!] Geen Python binary gevonden op PATH.\n"
            "    Installeer Python 3 of activeer een virtualenv.",
            file=sys.stderr,
        )
        sys.exit(1)
    return python


def build_server_entry(mcp_server_path: Path) -> dict:
    python_bin = detect_python()
    in_venv = sys.prefix != sys.base_prefix
    source = "virtualenv" if in_venv else "system PATH"
    print(f"[i] Python binary gedetecteerd via {source}: {python_bin}")
    return {
        "command": python_bin,
        "args": [str(mcp_server_path)],
    }


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> None:
    config_path = get_config_path()
    mcp_server_path = get_mcp_server_path()
    server_name = "roonsage"

    # Verify mcp_server.py exists
    if not mcp_server_path.exists():
        print(
            f"[!] mcp_server.py niet gevonden op: {mcp_server_path}\n"
            "    Zorg dat je dit script vanuit de repo-root of scripts/ map uitvoert.",
            file=sys.stderr,
        )
        sys.exit(1)

    # Load existing config (or start fresh)
    config_path.parent.mkdir(parents=True, exist_ok=True)
    if config_path.exists():
        try:
            config: dict = json.loads(config_path.read_text(encoding="utf-8"))
        except json.JSONDecodeError as exc:
            print(
                f"[!] Kan {config_path} niet lezen: {exc}\n"
                "    Controleer of het bestand geldig JSON is.",
                file=sys.stderr,
            )
            sys.exit(1)
    else:
        config = {}

    # Ensure mcpServers key exists
    mcp_servers: dict = config.setdefault("mcpServers", {})

    # Build the desired entry (also prints the detected Python path)
    desired_entry = build_server_entry(mcp_server_path)
    desired_command = desired_entry["command"]

    # Idempotency check — update if the command path changed, skip if identical
    if server_name in mcp_servers:
        existing_command = mcp_servers[server_name].get("command", "")
        if existing_command == desired_command:
            existing_args = mcp_servers[server_name].get("args", [None])[0]
            print(
                f"[=] '{server_name}' staat al correct in Claude Desktop config.\n"
                f"    Command: {existing_command}\n"
                f"    Server:  {existing_args}\n"
                "    Niets gewijzigd."
            )
            return
        # Command path differs — update the entry
        mcp_servers[server_name] = desired_entry
        config_path.write_text(
            json.dumps(config, indent=2, ensure_ascii=False) + "\n",
            encoding="utf-8",
        )
        print(
            f"[~] Config bijgewerkt: command gewijzigd naar {desired_command}\n"
            f"    Config: {config_path}\n"
            "\n"
            "    Herstart Claude Desktop om de wijziging te activeren."
        )
        return

    # Add the new entry
    mcp_servers[server_name] = desired_entry

    # Write back (pretty-printed, UTF-8)
    config_path.write_text(
        json.dumps(config, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )

    print(
        f"[+] MCP server toegevoegd aan Claude Desktop.\n"
        f"    Config: {config_path}\n"
        f"    Server: {mcp_server_path}\n"
        "\n"
        "    Herstart Claude Desktop om de integratie te activeren."
    )


if __name__ == "__main__":
    main()
