#!/usr/bin/env python3
"""Install the roon-mediasage MCP server into Claude Desktop's configuration.

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


def build_server_entry(mcp_server_path: Path) -> dict:
    return {
        "command": "python",
        "args": [str(mcp_server_path)],
    }


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> None:
    config_path = get_config_path()
    mcp_server_path = get_mcp_server_path()
    server_name = "roon-mediasage"

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

    # Idempotency check
    if server_name in mcp_servers:
        existing_path = mcp_servers[server_name].get("args", [None])[0]
        print(
            f"[=] '{server_name}' staat al in Claude Desktop config.\n"
            f"    Pad: {existing_path}\n"
            "    Niets gewijzigd."
        )
        return

    # Add the new entry
    mcp_servers[server_name] = build_server_entry(mcp_server_path)

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
