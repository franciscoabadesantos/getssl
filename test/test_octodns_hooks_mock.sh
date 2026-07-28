#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
GETSSL_ROOT="$(cd -- "${SCRIPT_DIR}/.." &>/dev/null && pwd)"
ADD_HOOK="${GETSSL_ROOT}/dns_scripts/dns_add_octodns"
DEL_HOOK="${GETSSL_ROOT}/dns_scripts/dns_del_octodns"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

MOCK_REPO="$TMP_DIR/octodns"
mkdir -p "$MOCK_REPO/scripts"
touch "$MOCK_REPO/config.yaml"

cat >"$MOCK_REPO/scripts/mutate_octodns_zone.py" <<'EOF'
#!/usr/bin/env python3
import json
print(json.dumps({"changed": True}))
EOF
chmod +x "$MOCK_REPO/scripts/mutate_octodns_zone.py"

cat >"$TMP_DIR/mock_octodns_sync.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ " $* " == *" --doit "* ]]; then
  echo "apply ok"
  exit 0
fi
cat "$MOCK_PLAN_FILE"
EOF
chmod +x "$TMP_DIR/mock_octodns_sync.sh"

cat >"$TMP_DIR/mock_python.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "-" ]]; then
  cat >/dev/null
  exit 0
fi
exec python3 "$@"
EOF
chmod +x "$TMP_DIR/mock_python.sh"

run_expect_ok() {
  local name="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    pass "$name"
  else
    fail "$name"
  fi
}

run_expect_fail() {
  local name="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    fail "$name"
  else
    pass "$name"
  fi
}

cat >"$TMP_DIR/add_ok.plan" <<'EOF'
*   Create <TxtRecord TXT 300, _acme-challenge.example.corporativo.pt., ['tok123'], {'cloudflare': {'auto-ttl': True}}> (yaml_zonefile)
*   Summary: Creates=1, Updates=0, Deletes=0, Existing=22, Meta=False
EOF

cat >"$TMP_DIR/add_bad.plan" <<'EOF'
*   Create <TxtRecord TXT 300, _acme-challenge.example.corporativo.pt., ['tok123'], {'cloudflare': {'auto-ttl': True}}> (yaml_zonefile)
*   Summary: Creates=1, Updates=1, Deletes=0, Existing=22, Meta=False
EOF

cat >"$TMP_DIR/add_wildcard_ok.plan" <<'EOF'
*   Create <TxtRecord TXT 300, _acme-challenge.web.corporativo.pt., ['tok123'], {'cloudflare': {'auto-ttl': True}}> (yaml_zonefile)
*   Summary: Creates=1, Updates=0, Deletes=0, Existing=22, Meta=False
EOF

cat >"$TMP_DIR/del_ok.plan" <<'EOF'
*   Delete <TxtRecord TXT 300, _acme-challenge.example.corporativo.pt., ['tok123'], {'cloudflare': {'auto-ttl': True}}> (cloudflare)
*   Summary: Creates=0, Updates=0, Deletes=1, Existing=22, Meta=False
EOF

export GETSSL_OCTODNS_REPO="$MOCK_REPO"
export GETSSL_OCTODNS_CONFIG="config.yaml"
export GETSSL_OCTODNS_ZONE="corporativo.pt"
export GETSSL_OCTODNS_ENVIRONMENT="prd"
export GETSSL_OCTODNS_MUTATE_BIN="$MOCK_REPO/scripts/mutate_octodns_zone.py"
export GETSSL_OCTODNS_SYNC_BIN="$TMP_DIR/mock_octodns_sync.sh"
export GETSSL_OCTODNS_PYTHON_BIN="$TMP_DIR/mock_python.sh"
export CLOUDFLARE_TOKEN="dummy"
export CLOUDFLARE_ACCOUNT_ID="dummy"

export MOCK_PLAN_FILE="$TMP_DIR/add_ok.plan"
run_expect_ok "dns_add hook succeeds on strict create plan" "$ADD_HOOK" "example.corporativo.pt" "tok123"

export MOCK_PLAN_FILE="$TMP_DIR/add_bad.plan"
run_expect_fail "dns_add hook fails on non-strict plan" "$ADD_HOOK" "example.corporativo.pt" "tok123"

export MOCK_PLAN_FILE="$TMP_DIR/add_wildcard_ok.plan"
run_expect_ok "dns_add hook normalizes wildcard name" "$ADD_HOOK" "*.web.corporativo.pt" "tok123"

export MOCK_PLAN_FILE="$TMP_DIR/del_ok.plan"
run_expect_ok "dns_del hook succeeds on strict delete plan" "$DEL_HOOK" "example.corporativo.pt" "tok123"

echo "All hook mock tests passed."
