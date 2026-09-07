#!/usr/bin/env python3
"""Validate octoDNS dry-run output before allowing --doit."""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path


SUMMARY_RE = re.compile(
    r"Summary:\s*Creates=(\d+),\s*Updates=(\d+),\s*Deletes=(\d+),",
    re.IGNORECASE,
)
PLAN_LINE_RE = re.compile(r"^\*\s+(Create|Update|Delete)\s+<", re.MULTILINE)
NO_CHANGES_RE = re.compile(r"^\*\s+No changes were planned\s*$", re.MULTILINE)


def _normalize_fqdn(value: str) -> str:
    return value.strip().rstrip(".").lower()


def _fail(message: str) -> int:
    print(f"octodns plan gate failed: {message}", file=sys.stderr)
    return 1


def validate(mode: str, fqdn: str, token: str, plan_text: str, allow_add_noop: bool = False) -> int:
    if allow_add_noop and mode == "add":
        summaries = SUMMARY_RE.findall(plan_text)
        actions = PLAN_LINE_RE.findall(plan_text)
        no_change_markers = NO_CHANGES_RE.findall(plan_text)
        if not summaries and not actions and len(no_change_markers) == 1:
            return 0

    summaries = SUMMARY_RE.findall(plan_text)
    if len(summaries) != 1:
        return _fail(f"expected exactly one Summary line, got {len(summaries)}")

    creates, updates, deletes = [int(x) for x in summaries[0]]
    expected = (1, 0, 0) if mode == "add" else (0, 0, 1)
    got = (creates, updates, deletes)
    if got != expected:
        return _fail(
            f"unexpected summary counts: got Creates={creates}, Updates={updates}, Deletes={deletes}; "
            f"expected Creates={expected[0]}, Updates={expected[1]}, Deletes={expected[2]}"
        )

    plan_actions = PLAN_LINE_RE.findall(plan_text)
    if len(plan_actions) != 1:
        return _fail(f"expected exactly one planned action line, got {len(plan_actions)}")

    expected_action = "Create" if mode == "add" else "Delete"
    if plan_actions[0] != expected_action:
        return _fail(f"expected action {expected_action}, got {plan_actions[0]}")

    rr = f"_acme-challenge.{_normalize_fqdn(fqdn)}."
    action_marker = f"{expected_action} <TxtRecord TXT"
    if action_marker not in plan_text:
        return _fail(f"missing expected TXT action marker: {action_marker}")
    if rr not in plan_text:
        return _fail(f"missing expected record fqdn: {rr}")

    if mode == "add" and token not in plan_text:
        return _fail("expected token not found in add plan output")

    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate octoDNS dry-run plan output.")
    parser.add_argument("--mode", choices=["add", "del"], required=True)
    parser.add_argument("--fqdn", required=True, help="Challenge domain (without _acme-challenge prefix).")
    parser.add_argument("--token", default="", help="Expected TXT token (required for add mode).")
    parser.add_argument(
        "--allow-add-noop",
        action="store_true",
        help="Accept a strict no-change add plan after the mutator confirmed the TXT already exists.",
    )
    parser.add_argument("--plan-file", required=True)
    args = parser.parse_args()

    plan_path = Path(args.plan_file)
    if not plan_path.exists():
        return _fail(f"plan file not found: {plan_path}")

    text = plan_path.read_text(encoding="utf-8", errors="replace")
    return validate(args.mode, args.fqdn, args.token, text, args.allow_add_noop)


if __name__ == "__main__":
    raise SystemExit(main())
