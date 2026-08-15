#!/usr/bin/env python3
"""Contract for CodegiOS AgentType.parse / encode.

Mirrors CodegiOS/Models/AgentType.swift. Run on any machine:
  python scripts/test_agent_type_wire.py
"""
from __future__ import annotations

BUILTINS = {
    "claude_code": "claude_code",
    "codex": "codex",
    "open_code": "open_code",
    "gemini": "gemini",
    "open_claw": "open_claw",
    "cline": "cline",
    "hermes": "hermes",
    "code_buddy": "code_buddy",
    "kimi_code": "kimi_code",
    "pi": "pi",
    "grok": "grok",
    "cursor": "cursor",
}


def parse(raw: str) -> tuple[str, str]:
    """Return (kind, wire_to_encode)."""
    if raw in BUILTINS:
        return raw, raw
    if raw.startswith("custom:"):
        return "custom", raw
    return "unknown", raw


def encode(kind: str, wire: str) -> str:
    return wire


def main() -> int:
    cases = [
        ("grok", "grok", "grok"),
        ("claude_code", "claude_code", "claude_code"),
        ("custom:claude-code-2", "custom", "custom:claude-code-2"),
        ("custom:codex-2", "custom", "custom:codex-2"),
        ("not_a_real_agent", "unknown", "not_a_real_agent"),
    ]
    failed = 0
    for raw, kind, encoded in cases:
        got_kind, got_wire = parse(raw)
        got_enc = encode(got_kind, got_wire)
        if got_kind == "claude_code" and raw != "claude_code":
            print(f"FAIL {raw}: decoded as Claude")
            failed += 1
            continue
        if (got_kind, got_enc) != (kind, encoded):
            print(f"FAIL {raw}: got {(got_kind, got_enc)} want {(kind, encoded)}")
            failed += 1
        else:
            print(f"ok {raw} -> {got_kind} encode={got_enc}")
    if failed:
        print(f"{failed} failed")
        return 1
    print("all agent-type wire cases passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
