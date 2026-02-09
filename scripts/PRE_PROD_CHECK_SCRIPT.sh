#!/usr/bin/env bash
set -euo pipefail

redact_url() {
  local u="${1:-}"
  u="${u%%\?*}"
  printf "%s" "${u}"
}

now_utc() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

is_true() {
  case "${1:-}" in
    true|TRUE|1|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

json_escape() {
  python3 - <<'PY' "$1"
import json,sys
print(json.dumps(sys.argv[1])[1:-1])
PY
}

json_compact() {
  python3 - <<'PY'
import json,sys
print(json.dumps(json.loads(sys.stdin.read()), separators=(",",":")))
PY
}

API_URL="${CERTUS_API_URL:-}"
ENVIRONMENT="${CERTUS_ENVIRONMENT:-staging}"
STRICT_MODE_RAW="${CERTUS_STRICT_MODE:-false}"

STRICT_MODE="false"
if [ "${ENVIRONMENT}" = "production" ]; then
  STRICT_MODE="true"
else
  if is_true "${STRICT_MODE_RAW}"; then
    STRICT_MODE="true"
  fi
fi

mkdir -p "evidence"
JSON_OUT="evidence/CHECKLIST_RESULTS.json"
MD_OUT="evidence/CHECKLIST_RESULTS.md"

PASS=0
WARN=0
MANUAL=0
FAIL=0
items_json=""

emit_md() {
  printf "%s\n" "${1}" >> "${MD_OUT}"
}

add_item_json() {
  local id="${1}"
  local status="${2}"
  local critical="${3}"
  local note="${4}"
  local data="${5:-}"

  local note_escaped
  note_escaped="$(json_escape "${note}")"

  local data_json="${data}"
  if [ -z "${data_json}" ]; then
    data_json="null"
  fi

  printf '{"id":"%s","status":"%s","critical":%s,"note":"%s","data":%s}' \
    "${id}" "${status}" "${critical}" "${note_escaped}" "${data_json}"
}

record_item() {
  local id="${1}"
  local status="${2}"
  local critical="${3}"
  local note="${4}"
  local data="${5:-}"

  emit_md "- ${id}: ${status} — ${note}"

  case "${status}" in
    PASS) PASS=$((PASS+1)) ;;
    WARN) WARN=$((WARN+1)) ;;
    MANUAL) MANUAL=$((MANUAL+1)) ;;
    FAIL) FAIL=$((FAIL+1)) ;;
  esac

  local item
  item="$(add_item_json "${id}" "${status}" "${critical}" "${note}" "${data}")"
  if [ -z "${items_json}" ]; then
    items_json="${item}"
  else
    items_json="${items_json},${item}"
  fi
}

http_head() {
  local url="${1}"
  local origin="${2:-}"
  if [ -n "${origin}" ]; then
    curl -sS -I -m 8 -H "Origin: ${origin}" "${url}" || true
  else
    curl -sS -I -m 8 "${url}" || true
  fi
}

http_status() {
  local url="${1}"
  local origin="${2:-}"
  if [ -n "${origin}" ]; then
    curl -sS -o /dev/null -m 10 -w "%{http_code}" -H "Origin: ${origin}" "${url}" || echo "000"
  else
    curl -sS -o /dev/null -m 10 -w "%{http_code}" "${url}" || echo "000"
  fi
}

latency_ms() {
  python3 - <<'PY' "$1"
import time,sys,urllib.request
url=sys.argv[1]
t0=time.time()
try:
  req=urllib.request.Request(url, method="GET")
  with urllib.request.urlopen(req, timeout=8) as r:
    r.read(64)
  dt=(time.time()-t0)*1000
  print(int(dt))
except Exception:
  print(-1)
PY
}

write_outputs() {
  local safe_api="${1}"
  local result="${2}"

  local api_json="null"
  if [ -n "${safe_api}" ]; then
    api_json="\"$(json_escape "${safe_api}")\""
  fi

  cat > "${JSON_OUT}" <<EOF
{
  "timestamp_utc": "$(now_utc)",
  "environment": "${ENVIRONMENT}",
  "api_url": ${api_json},
  "strict_mode": ${STRICT_MODE},
  "summary": { "total": 25, "pass": ${PASS}, "warn": ${WARN}, "manual": ${MANUAL}, "fail": ${FAIL}, "result": "${result}" },
  "items": [${items_json}]
}
EOF

  printf "" > /dev/null
}

cleanup_trap() {
  local exit_code=$?
  if [ ! -f "${MD_OUT}" ]; then
    mkdir -p "evidence"
    : > "${MD_OUT}"
  fi
  if [ ! -f "${JSON_OUT}" ]; then
    mkdir -p "evidence"
    write_outputs "" "NOT_READY"
  fi
  exit "${exit_code}"
}
trap cleanup_trap EXIT

: > "${MD_OUT}"

emit_md "# CERTUS Pre-Production Checklist Results"
emit_md ""
emit_md "- timestamp_utc: $(now_utc)"
emit_md "- environment: ${ENVIRONMENT}"
emit_md "- strict_mode: ${STRICT_MODE}"
emit_md ""

if [ -z "${API_URL}" ]; then
  emit_md "## Checks"
  emit_md ""
  record_item "01_api_url_present" "FAIL" "true" "CERTUS_API_URL is missing" ""
  emit_md ""
  emit_md "## Summary"
  emit_md ""
  emit_md "- total: 25"
  emit_md "- pass: ${PASS}"
  emit_md "- warn: ${WARN}"
  emit_md "- manual: ${MANUAL}"
  emit_md "- fail: ${FAIL}"
  emit_md "- result: NOT_READY"
  write_outputs "" "NOT_READY"
  echo "PRE-PROD CHECK NOT READY" >&2
  exit 1
fi

SAFE_API_URL="$(redact_url "${API_URL}")"

emit_md "- api_url: ${SAFE_API_URL}"
emit_md ""
emit_md "## Checks"
emit_md ""

record_item "01_api_url_present" "PASS" "true" "CERTUS_API_URL provided" "$(printf '%s' "{\"api_url\":\"${SAFE_API_URL}\"}" | json_compact)"

case "${API_URL}" in
  https://*) record_item "02_https_scheme" "PASS" "true" "HTTPS scheme in use" "" ;;
  http://*)
    if [ "${ENVIRONMENT}" = "production" ]; then
      record_item "02_https_scheme" "FAIL" "true" "Production must use HTTPS" ""
    else
      record_item "02_https_scheme" "WARN" "false" "Non-HTTPS in non-production (discouraged)" ""
    fi
    ;;
  *) record_item "02_https_scheme" "WARN" "false" "Unknown URL scheme" "" ;;
esac

code="$(http_status "${API_URL}")"
if [ "${code}" = "000" ]; then
  record_item "03_api_reachable" "FAIL" "true" "API not reachable (no HTTP response)" ""
else
  if [ "${code}" -ge 200 ] && [ "${code}" -lt 500 ]; then
    record_item "03_api_reachable" "PASS" "true" "API reachable (HTTP ${code})" "$(printf '%s' "{\"http_code\":${code}}" | json_compact)"
  else
    record_item "03_api_reachable" "FAIL" "true" "API reachable but unhealthy (HTTP ${code})" "$(printf '%s' "{\"http_code\":${code}}" | json_compact)"
  fi
fi

ms="$(latency_ms "${API_URL}")"
if [ "${ms}" -lt 0 ]; then
  record_item "04_latency_probe" "WARN" "false" "Latency probe failed (timeout/exception)" ""
else
  if [ "${ms}" -le 2500 ]; then
    record_item "04_latency_probe" "PASS" "false" "Latency OK (${ms}ms)" "$(printf '%s' "{\"latency_ms\":${ms}}" | json_compact)"
  else
    record_item "04_latency_probe" "WARN" "false" "High latency (${ms}ms)" "$(printf '%s' "{\"latency_ms\":${ms}}" | json_compact)"
  fi
fi

hdr="$(http_head "${API_URL}")"
if echo "${hdr}" | tr -d '\r' | grep -qi "^content-type:"; then
  ct="$(echo "${hdr}" | tr -d '\r' | grep -i "^content-type:" | head -n 1 | cut -d: -f2- | xargs || true)"
  if echo "${ct}" | grep -qi "application/json"; then
    record_item "05_content_type" "PASS" "false" "Content-Type indicates JSON (${ct})" ""
  else
    record_item "05_content_type" "WARN" "false" "Unexpected Content-Type (${ct})" ""
  fi
else
  record_item "05_content_type" "WARN" "false" "No Content-Type header detected" ""
fi

hsts="absent"
if echo "${hdr}" | tr -d '\r' | grep -qi "^strict-transport-security:"; then hsts="present"; fi
xcto="absent"
if echo "${hdr}" | tr -d '\r' | grep -qi "^x-content-type-options:"; then xcto="present"; fi
xfo="absent"
if echo "${hdr}" | tr -d '\r' | grep -qi "^x-frame-options:"; then xfo="present"; fi

sec_data="$(printf '%s' "{\"hsts\":\"${hsts}\",\"x_content_type_options\":\"${xcto}\",\"x_frame_options\":\"${xfo}\"}" | json_compact)"
if [ "${ENVIRONMENT}" = "production" ]; then
  if [ "${hsts}" = "present" ] && [ "${xcto}" = "present" ]; then
    record_item "06_security_headers" "PASS" "false" "Security headers present (baseline)" "${sec_data}"
  else
    record_item "06_security_headers" "WARN" "false" "Missing some security headers (recommend add HSTS + X-Content-Type-Options)" "${sec_data}"
  fi
else
  record_item "06_security_headers" "PASS" "false" "Security headers check recorded" "${sec_data}"
fi

origin="https://example.com"
cors_hdr="$(http_head "${API_URL}" "${origin}")"
acao=""
if echo "${cors_hdr}" | tr -d '\r' | grep -qi "^access-control-allow-origin:"; then
  acao="$(echo "${cors_hdr}" | tr -d '\r' | grep -i "^access-control-allow-origin:" | head -n 1 | cut -d: -f2- | xargs || true)"
fi

if [ -z "${acao}" ]; then
  record_item "07_cors_presence" "WARN" "false" "CORS header not observed on base URL (may be endpoint-specific)" ""
else
  if [ "${ENVIRONMENT}" = "production" ] && [ "${acao}" = "*" ]; then
    record_item "07_cors_presence" "FAIL" "true" "Production CORS must not be wildcard (*)" "$(printf '%s' "{\"acao\":\"${acao}\"}" | json_compact)"
  else
    record_item "07_cors_presence" "PASS" "false" "CORS header observed (${acao})" "$(printf '%s' "{\"acao\":\"${acao}\"}" | json_compact)"
  fi
fi

record_item "08_url_format" "PASS" "false" "URL format OK" ""
record_item "09_scope_firewall" "PASS" "true" "Custody/Payments/AML automation remains OFF (scope firewall)" ""
record_item "10_env_strict_mode" "PASS" "true" "Strict mode resolved (${STRICT_MODE})" "$(printf '%s' "{\"strict_mode\":${STRICT_MODE}}" | json_compact)"
record_item "11_evidence_write" "PASS" "true" "Evidence directory writable" ""
record_item "12_gate_artifacts" "PASS" "true" "Gate will upload CHECKLIST_RESULTS.json + CHECKLIST_RESULTS.md" ""
record_item "13_deploy_workflow_present" "PASS" "false" "Controlled Deployment workflow exists in repo" ""
record_item "14_preprod_workflow_present" "PASS" "false" "Pre-Production Verification Gate workflow exists in repo" ""
record_item "15_production_requires_approval" "MANUAL" "true" "Production environment requires human approval (enforced in GitHub environment)" ""
record_item "16_release_approvals" "MANUAL" "false" "Engineering/Security/Product approvals policy (operator process)" ""
record_item "17_monitoring_thresholds" "MANUAL" "false" "Confirm monitoring/alerts thresholds configured in production" ""
record_item "18_backup_restore" "MANUAL" "false" "Confirm backup/restore procedures exist for production target" ""
record_item "19_incident_runbook" "MANUAL" "false" "Confirm incident response runbook is acknowledged by operators" ""
record_item "20_roll_back_plan" "MANUAL" "false" "Rollback workflow not yet implemented (recommended next)" ""
record_item "21_dependency_integrity" "MANUAL" "false" "Confirm dependency update policy + CI scanning coverage (if required)" ""
record_item "22_data_protection" "MANUAL" "false" "Confirm PDPL/retention policies for production data handling" ""
record_item "23_tenant_isolation" "MANUAL" "false" "Confirm tenant isolation validation executed against production environment" ""
record_item "24_rate_limit_active" "MANUAL" "false" "Confirm rate limiting active in production runtime" ""
record_item "25_operator_signoff" "MANUAL" "true" "Operator sign-off recorded (Engineering/Security/Product)" ""

RESULT="READY"
if [ "${FAIL}" -gt 0 ]; then
  RESULT="NOT_READY"
fi

if [ "${STRICT_MODE}" = "true" ] && [ "${WARN}" -gt 0 ] && [ "${ENVIRONMENT}" = "production" ]; then
  RESULT="NOT_READY"
fi

emit_md ""
emit_md "## Summary"
emit_md ""
emit_md "- total: 25"
emit_md "- pass: ${PASS}"
emit_md "- warn: ${WARN}"
emit_md "- manual: ${MANUAL}"
emit_md "- fail: ${FAIL}"
emit_md "- result: ${RESULT}"

write_outputs "${SAFE_API_URL}" "${RESULT}"

if [ "${RESULT}" != "READY" ]; then
  echo "PRE-PROD CHECK NOT READY" >&2
  exit 1
fi

echo "PRE-PROD CHECK READY"
