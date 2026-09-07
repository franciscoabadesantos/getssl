#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
GATE="${SCRIPT_DIR}/../dns_scripts/octodns_plan_gate.py"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

run_expect_ok() {
  local name="$1"
  local mode="$2"
  local fqdn="$3"
  local token="$4"
  local file="$5"
  if "$GATE" --mode "$mode" --fqdn "$fqdn" --token "$token" --plan-file "$file" >/dev/null; then
    pass "$name"
  else
    fail "$name"
  fi
}

run_expect_fail() {
  local name="$1"
  local mode="$2"
  local fqdn="$3"
  local token="$4"
  local file="$5"
  if "$GATE" --mode "$mode" --fqdn "$fqdn" --token "$token" --plan-file "$file" >/dev/null 2>&1; then
    fail "$name"
  else
    pass "$name"
  fi
}

cat >"$TMP_DIR/add_ok.plan" <<'EOF'
*   Create <TxtRecord TXT 300, _acme-challenge.example.corporativo.pt., ['abc123'], {'cloudflare': {'auto-ttl': True}}> (yaml_zonefile)
*   Summary: Creates=1, Updates=0, Deletes=0, Existing=22, Meta=False
EOF

cat >"$TMP_DIR/add_bad_counts.plan" <<'EOF'
*   Create <TxtRecord TXT 300, _acme-challenge.example.corporativo.pt., ['abc123'], {'cloudflare': {'auto-ttl': True}}> (yaml_zonefile)
*   Summary: Creates=1, Updates=1, Deletes=0, Existing=22, Meta=False
EOF

cat >"$TMP_DIR/add_wrong_name.plan" <<'EOF'
*   Create <TxtRecord TXT 300, _acme-challenge.other.corporativo.pt., ['abc123'], {'cloudflare': {'auto-ttl': True}}> (yaml_zonefile)
*   Summary: Creates=1, Updates=0, Deletes=0, Existing=22, Meta=False
EOF

cat >"$TMP_DIR/del_ok.plan" <<'EOF'
*   Delete <TxtRecord TXT 300, _acme-challenge.example.corporativo.pt., ['abc123'], {'cloudflare': {'auto-ttl': True}}> (cloudflare)
*   Summary: Creates=0, Updates=0, Deletes=1, Existing=22, Meta=False
EOF

cat >"$TMP_DIR/del_bad_counts.plan" <<'EOF'
*   Delete <TxtRecord TXT 300, _acme-challenge.example.corporativo.pt., ['abc123'], {'cloudflare': {'auto-ttl': True}}> (cloudflare)
*   Summary: Creates=0, Updates=1, Deletes=1, Existing=22, Meta=False
EOF

run_expect_ok "add ok" add "example.corporativo.pt" "abc123" "$TMP_DIR/add_ok.plan"
run_expect_fail "add reject counts" add "example.corporativo.pt" "abc123" "$TMP_DIR/add_bad_counts.plan"
run_expect_fail "add reject wrong record" add "example.corporativo.pt" "abc123" "$TMP_DIR/add_wrong_name.plan"
run_expect_ok "del ok" del "example.corporativo.pt" "abc123" "$TMP_DIR/del_ok.plan"
run_expect_fail "del reject counts" del "example.corporativo.pt" "abc123" "$TMP_DIR/del_bad_counts.plan"

cat >"$TMP_DIR/add_noop.plan" <<'EOF'
* No changes were planned
EOF

if "$GATE" --mode add --fqdn "example.corporativo.pt" --token "abc123" --allow-add-noop --plan-file "$TMP_DIR/add_noop.plan" >/dev/null; then
  pass "add accepts confirmed no-op"
else
  fail "add accepts confirmed no-op"
fi

run_expect_fail "add rejects no-op without explicit permission" add "example.corporativo.pt" "abc123" "$TMP_DIR/add_noop.plan"

echo "All plan gate tests passed."
