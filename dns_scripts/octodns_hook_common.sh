#!/usr/bin/env bash
set -euo pipefail

_octodns_script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
_getssl_root="$(cd -- "${_octodns_script_dir}/.." &>/dev/null && pwd)"

GETSSL_OCTODNS_REPO="${GETSSL_OCTODNS_REPO:-/home/user/dsi-octoDNS}"
GETSSL_OCTODNS_CONFIG="${GETSSL_OCTODNS_CONFIG:-config/config_yaml_prd.yaml}"
GETSSL_OCTODNS_ZONE="${GETSSL_OCTODNS_ZONE:-corporativo.pt}"
GETSSL_OCTODNS_ENVIRONMENT="${GETSSL_OCTODNS_ENVIRONMENT:-prd}"
GETSSL_OCTODNS_ACCOUNT_ID="${GETSSL_OCTODNS_ACCOUNT_ID:-}"
OCTODNS_ZONE_FILE_TEMPLATE="${OCTODNS_ZONE_FILE_TEMPLATE:-}"
if [[ -z "${OCTODNS_ZONE_FILE_TEMPLATE}" ]]; then
  OCTODNS_ZONE_FILE_TEMPLATE="${GETSSL_OCTODNS_REPO}/config/zones/yaml/{zone}.yaml"
fi
export OCTODNS_ZONE_FILE_TEMPLATE

if [[ -z "${CLOUDFLARE_TOKEN:-}" && -n "${CLOUDFLARE_API_TOKEN:-}" ]]; then
  export CLOUDFLARE_TOKEN="$CLOUDFLARE_API_TOKEN"
fi
if [[ -z "${CLOUDFLARE_ACCOUNT_ID:-}" && -n "${GETSSL_OCTODNS_ACCOUNT_ID}" ]]; then
  export CLOUDFLARE_ACCOUNT_ID="$GETSSL_OCTODNS_ACCOUNT_ID"
fi

GETSSL_OCTODNS_MUTATE_BIN="${GETSSL_OCTODNS_MUTATE_BIN:-${GETSSL_OCTODNS_REPO}/scripts/mutate_octodns_zone.py}"
GETSSL_OCTODNS_GATE_BIN="${GETSSL_OCTODNS_GATE_BIN:-${_octodns_script_dir}/octodns_plan_gate.py}"

if [[ -n "${GETSSL_OCTODNS_SYNC_BIN:-}" ]]; then
  _octodns_sync="$GETSSL_OCTODNS_SYNC_BIN"
elif [[ -x "${GETSSL_OCTODNS_REPO}/.venv/bin/octodns-sync" ]]; then
  _octodns_sync="${GETSSL_OCTODNS_REPO}/.venv/bin/octodns-sync"
else
  _octodns_sync="octodns-sync"
fi
GETSSL_OCTODNS_SYNC_BIN="${_octodns_sync}"

if [[ -n "${GETSSL_OCTODNS_PYTHON_BIN:-}" ]]; then
  _octodns_python="$GETSSL_OCTODNS_PYTHON_BIN"
elif [[ -x "${GETSSL_OCTODNS_REPO}/.venv/bin/python" ]]; then
  _octodns_python="${GETSSL_OCTODNS_REPO}/.venv/bin/python"
else
  _octodns_python="python3"
fi
GETSSL_OCTODNS_PYTHON_BIN="${_octodns_python}"

octodns_zone_file_path() {
  local template
  if [[ -n "${OCTODNS_ZONE_FILE_TEMPLATE:-}" ]]; then
    template="${OCTODNS_ZONE_FILE_TEMPLATE}"
  else
    template="${GETSSL_OCTODNS_REPO}/config/zones/yaml/{zone}.yaml"
  fi
  local path
  path="$(printf '%s' "$template" | sed \
    -e "s#{environment}#${GETSSL_OCTODNS_ENVIRONMENT}#g" \
    -e "s#{zone}#${GETSSL_OCTODNS_ZONE}#g")"
  printf '%s\n' "$path"
}


octodns_sort_zone_file() {
  local zone_file="$1"
  "$GETSSL_OCTODNS_PYTHON_BIN" - "$zone_file" <<'PY'
from pathlib import Path
import sys

from octodns.yaml import safe_dump, safe_load

zone_file = Path(sys.argv[1])
with zone_file.open() as fh:
    data = safe_load(fh, enforce_order=False)
with zone_file.open("w") as fh:
    safe_dump(data, fh)
PY
}


octodns_require_paths() {
  [[ -d "$GETSSL_OCTODNS_REPO" ]] || { echo "octodns repo not found: $GETSSL_OCTODNS_REPO" >&2; return 2; }
  [[ -f "$GETSSL_OCTODNS_REPO/$GETSSL_OCTODNS_CONFIG" ]] || {
    echo "octodns config not found: $GETSSL_OCTODNS_REPO/$GETSSL_OCTODNS_CONFIG" >&2
    return 2
  }
  [[ -f "$GETSSL_OCTODNS_MUTATE_BIN" ]] || { echo "mutate script not found: $GETSSL_OCTODNS_MUTATE_BIN" >&2; return 2; }
  [[ -x "$GETSSL_OCTODNS_GATE_BIN" ]] || { echo "gate script not executable: $GETSSL_OCTODNS_GATE_BIN" >&2; return 2; }
}


octodns_normalize_domain() {
  local d="$1"
  printf '%s' "${d#\*.}" | tr 'A-Z' 'a-z'
}


octodns_mutate() {
  local action="$1"
  local fqdn="$2"
  local token="$3"
  local zone_file
  zone_file="$(octodns_zone_file_path)"
  # ACME dns-01 uses TXT records, which must not carry Cloudflare proxied metadata.
  "$GETSSL_OCTODNS_PYTHON_BIN" "$GETSSL_OCTODNS_MUTATE_BIN" \
    "$GETSSL_OCTODNS_ENVIRONMENT" \
    "$GETSSL_OCTODNS_ZONE" \
    "_acme-challenge.${fqdn}" \
    "TXT" \
    "$token" \
    "300" \
    "$action" \
    "" \
    ""
  octodns_sort_zone_file "$zone_file"
}


octodns_dry_run_to_file() {
  local plan_file="$1"
  (
    cd "$GETSSL_OCTODNS_REPO"
    if [[ -f ".venv/bin/activate" ]]; then
      # shellcheck disable=SC1091
      source ".venv/bin/activate"
    fi
    "$GETSSL_OCTODNS_SYNC_BIN" --config-file="$GETSSL_OCTODNS_CONFIG" "${GETSSL_OCTODNS_ZONE%.}."
  ) >"$plan_file" 2>&1
}


octodns_apply() {
  (
    cd "$GETSSL_OCTODNS_REPO"
    if [[ -f ".venv/bin/activate" ]]; then
      # shellcheck disable=SC1091
      source ".venv/bin/activate"
    fi
    "$GETSSL_OCTODNS_SYNC_BIN" --config-file="$GETSSL_OCTODNS_CONFIG" --doit "${GETSSL_OCTODNS_ZONE%.}."
  )
}


octodns_gate_and_apply() {
  local mode="$1"
  local fqdn="$2"
  local token="$3"
  local plan_file
  plan_file="$(mktemp)"

  if ! octodns_dry_run_to_file "$plan_file"; then
    cat "$plan_file" >&2 || true
    rm -f "$plan_file"
    return 1
  fi

  if ! "$GETSSL_OCTODNS_GATE_BIN" --mode "$mode" --fqdn "$fqdn" --token "$token" --plan-file "$plan_file"; then
    cat "$plan_file" >&2 || true
    rm -f "$plan_file"
    return 1
  fi
  rm -f "$plan_file"

  octodns_apply
}
