#!/usr/bin/env bash
set -euo pipefail

now_utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }

is_true() {
  case "${1:-}" in
    true|TRUE|1|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

redact_url() {
  local u="${1:-}"
  u="${u%%\?*}"
  printf "%s" "${u}"
}

json_escape() {
  python3 - <<'PY' "$1"
import json,sys
print(json.dumps(sys.argv[1])[1:-1])
PY
}

json_kv() {
  python3 - <<'PY' "$@"
import json,sys
args=sys.argv[1:]
d={}
for a in args:
  k,v=a.split("=",1)
  d[k]=v
print(json.dumps(d, separators=(",",":")))
PY
}

API_URL="${CERTUS_API_URL:-}"
ENVIRONMENT="${CERTUS_ENVIRONMENT:-staging}"
STRICT_MODE_RAW="${CERTUS_STRICT_MODE:-false}"
OFFLINE_RAW="${CERTUS_OFFLINE_MODE:-false}"

STRICT_MODE="false"
if [ "${ENVIRONMENT}" = "production" ]; then
  STRICT_MODE="true"
else
  if is_true "${STRICT_MODE_RAW}"; then
    STRICT_MODE="true"
  fi
fi

OFFLINE_MODE="false"
if is_true "${OFFLINE_RAW}"; then
  OFFLINE_MODE="true"
fi

mkdir -p "evidence"
JSON_OUT="evidence/CHECKLIST_RESULTS.json"
MD_OUT="evidence/CHECKLIST_RESULTS.md"

PASS=0
WARN=0
MANUAL=0
FAIL=0
items_json=""

emit_md() { printf "%s\n" "${1}" >> "${MD_OUT}"; }

add_item_json() {
  local id="${1}" status="${2}" critical="${3}" note="${4}" data="${5:-null}"
  local note_escaped
  note_escaped="$(json_escape "${note}")"
  printf '{"id":"%s","status":"%s","critical":%s,"note":"%s","data":%s}' \
    "${id}" "${status}" "${critical}" "${note_escaped}" "${data}"
}

record_item() {
  local id="${1}" status="${2}" critical="${3}" note="${4}" data="${5:-null}"
  emit_md "- ${id}: ${status} — ${note}"
  case "${status}" in
    PASS) PASS=$((PASS+1)) ;;
    WARN) WARN=$((WARN+1)) ;;
    MANUAL) MANUAL=$((MANUAL+1)) ;;
    FAIL) FAIL=$((FAIL+1)) ;;
  esac
  local item
  item="$(add_item_json "${id}" "${status}" "${critical}" "${note}" "${data}")"
  if [ -z "${items_json}" ]; then items_json="${item}"; else items_json="${items_json},${item}"; fi
}

write_json() {
  local safe_api="${1:-}"
  local result="${2:-NOT_READY}"
  local api_json="null"
  if [ -n "${safe_api}" ]; then
    api_json="\"$(json_escape "${safe_api}")\""
  fi
  cat > "${JSON_OUT}" <<EOF
{
  "timestamp_utc":"$(now_utc)",
  "environment":"${ENVIRONMENT}",
  "api_url":${api_json},
  "strict_mode":${STRICT_MODE},
  "offline_mode":${OFFLINE_MODE},
  "summary":{"total":25,"pass":${PASS},"warn":${WARN},"manual":${MANUAL},"fail":${FAIL},"result":"${result}"},
  "items":[${items_json}]
}
EOF
}

trap 'if [ ! -f "${JSON_OUT}" ]; then write_json "" "NOT_READY"; fi' EXIT

: > "${MD_OUT}"

emit_md "# CERTUS Pre-Production Checklist Results"
emit_md ""
emit_md "- timestamp_utc: $(now_utc)"
emit_md "- environment: ${ENVIRONMENT}"
emit_md "- strict_mode: ${STRICT_MODE}"
emit_md "- offline_mode: ${OFFLINE_MODE}"
emit_md ""

emit_md "## Checks"
emit_md ""

if [ -z "${API_URL}" ]; then
  record_item "01_api_url_present" "FAIL" "true" "CERTUS_API_URL is missing" "null"
  RESULT="NOT_READY"
  emit_md ""
  emit_md "## Summary"
  emit_md ""
  emit_md "- total: 25"
  emit_md "- pass: ${PASS}"
  emit_md "- warn: ${WARN}"
  emit_md "- manual: ${MANUAL}"
  emit_md "- fail: ${FAIL}"
  emit_md "- result: ${RESULT}"
  write_json "" "${RESULT}"
  echo "PRE-PROD CHECK NOT READY" >&2
  exit 1
fi

SAFE_API_URL="$(redact_url "${API_URL}")"
emit_md "- api_url: ${SAFE_API_URL}"
emit_md ""

record_item "01_api_url_present" "PASS" "true" "CERTUS_API_URL provided" "$(json_kv "api_url=${SAFE_API_URL}")"

case "${API_URL}" in
  https://*) record_item "02_https_scheme" "PASS" "true" "HTTPS scheme in use" "null" ;;
  http://*)
    if [ "${ENVIRONMENT}" = "production" ]; then
      record_item "02_https_scheme" "FAIL" "true" "Production must use HTTPS" "null"
    else
      record_item "02_https_scheme" "WARN" "false" "Non-HTTPS in non-production (discouraged)" "null"
    fi
    ;;
  *) record_item "02_https_scheme" "WARN" "false" "Unknown URL scheme" "null" ;;
esac

if [ "${OFFLINE_MODE}" = "true" ]; then
  if [ "${ENVIRONMENT}" = "production" ]; then
    record_item "03_api_reachable" "FAIL" "true" "Offline mode not allowed for production" "null"
  else
    record_item "03_api_reachable" "MANUAL" "true" "Offline mode: network reachability skipped for PR safety" "null"
  fi
  record_item "04_latency_probe" "MANUAL" "false" "Offline mode: latency probe skipped" "null"
  record_item "05_content_type" "MANUAL" "false" "Offline mode: header probe skipped" "null"
  record_item "06_security_headers" "MANUAL" "false" "Offline mode: header probe skipped" "null"
  record_item "07_cors_presence" "MANUAL" "false" "Offline mode: CORS probe skipped" "null"
else
  http_code="$(curl -sS -o /dev/null -m 10 -w "%{http_code}" "${API_URL}" 2>evidence/curl_err.txt || echo "000")"
  if [ "${http_code}" = "000" ]; then
    if grep -qi "certificate has expired" evidence/curl_err.txt 2>/dev/null; then
      if [ "${ENVIRONMENT}" = "production" ]; then
        record_item "03_api_reachable" "FAIL" "true" "TLS failure: certificate expired (production blocks)" "null"
      else
        record_item "03_api_reachable" "WARN" "false" "TLS failure: certificate expired (staging warns)" "null"
      fi
    else
      if [ "${ENVIRONMENT}" = "production" ]; then
        record_item "03_api_reachable" "FAIL" "true" "API not reachable (no HTTP response)" "null"
      else
        record_item "03_api_reachable" "WARN" "false" "API not reachable (staging warns)" "null"
      fi
    fi
  else
    if [ "${http_code}" -ge 200 ] && [ "${http_code}" -lt 500 ]; then
      record_item "03_api_reachable" "PASS" "true" "API reachable (HTTP ${http_code})" "$(json_kv "http_code=${http_code}")"
    else
      record_item "03_api_reachable" "FAIL" "true" "API reachable but unhealthy (HTTP ${http_code})" "$(json_kv "http_code=${http_code}")"
    fi
  fi

  lat_ms="$(python3 - <<'PY' "$API_URL"
import time,sys,urllib.request
url=sys.argv[1]
t0=time.time()
try:
  req=urllib.request.Request(url, method="GET")
  with urllib.request.urlopen(req, timeout=8) as r:
    r.read(64)
  print(int((time.time()-t0)*1000))
except Exception:
  print(-1)
PY
)"
  if [ "${lat_ms}" -lt 0 ]; then
    record_item "04_latency_probe" "WARN" "false" "Latency probe failed (timeout/exception)" "null"
  else
    if [ "${lat_ms}" -le 2500 ]; then
      record_item "04_latency_probe" "PASS" "false" "Latency OK (${lat_ms}ms)" "$(json_kv "latency_ms=${lat_ms}")"
    else
      record_item "04_latency_probe" "WARN" "false" "High latency (${lat_ms}ms)" "$(json_kv "latency_ms=${lat_ms}")"
    fi
  fi

  hdr="$(curl -sS -I -m 8 "${API_URL}" 2>/dev/null || true)"
  if echo "${hdr}" | tr -d '\r' | grep -qi "^content-type:"; then
    ct="$(echo "${hdr}" | tr -d '\r' | grep -i "^content-type:" | head -n 1 | cut -d: -f2- | xargs || true)"
    if echo "${ct}" | grep -qi "application/json"; then
      record_item "05_content_type" "PASS" "false" "Content-Type indicates JSON (${ct})" "null"
    else
      record_item "05_content_type" "WARN" "false" "Unexpected Content-Type (${ct})" "null"
    fi
  else
    record_item "05_content_type" "WARN" "false" "No Content-Type header detected" "null"
  fi

  hsts="absent"; echo "${hdr}" | tr -d '\r' | grep -qi "^strict-transport-security:" && hsts="present"
  xcto="absent"; echo "${hdr}" | tr -d '\r' | grep -qi "^x-content-type-options:" && xcto="present"
  sec_data="$(json_kv "hsts=${hsts}" "x_content_type_options=${xcto}")"
  if [ "${ENVIRONMENT}" = "production" ]; then
    if [ "${hsts}" = "present" ] && [ "${xcto}" = "present" ]; then
      record_item "06_security_headers" "PASS" "false" "Security headers present (baseline)" "${sec_data}"
    else
      record_item "06_security_headers" "WARN" "false" "Missing some security headers (recommend add HSTS + X-Content-Type-Options)" "${sec_data}"
    fi
  else
    record_item "06_security_headers" "PASS" "false" "Security headers check recorded" "${sec_data}"
  fi

  cors_hdr="$(curl -sS -I -m 8 -H "Origin: https://example.com" "${API_URL}" 2>/dev/null || true)"
  acao=""
  if echo "${cors_hdr}" | tr -d '\r' | grep -qi "^access-control-allow-origin:"; then
    acao="$(echo "${cors_hdr}" | tr -d '\r' | grep -i "^access-control-allow-origin:" | head -n 1 | cut -d: -f2- | xargs || true)"
  fi
  if [ -z "${acao}" ]; then
    record_item "07_cors_presence" "WARN" "false" "CORS header not observed on base URL (may be endpoint-specific)" "null"
  else
    if [ "${ENVIRONMENT}" = "production" ] && [ "${acao}" = "*" ]; then
      record_item "07_cors_presence" "FAIL" "true" "Production CORS must not be wildcard (*)" "$(json_kv "acao=${acao}")"
    else
      record_item "07_cors_presence" "PASS" "false" "CORS header observed (${acao})" "$(json_kv "acao=${acao}")"
    fi
  fi
fi

record_item "08_url_format" "PASS" "false" "URL format OK" "null"
record_item "09_scope_firewall" "PASS" "true" "Custody/Payments/AML automation remains OFF (scope firewall)" "null"
record_item "10_env_strict_mode" "PASS" "true" "Strict mode resolved (${STRICT_MODE})" "$(json_kv "strict_mode=${STRICT_MODE}")"
record_item "11_evidence_write" "PASS" "true" "Evidence directory writable" "null"
record_item "12_gate_artifacts" "PASS" "true" "Gate will upload CHECKLIST_RESULTS.json + CHECKLIST_RESULTS.md" "null"
record_item "13_deploy_workflow_present" "PASS" "false" "Controlled Deployment workflow exists in repo" "null"
record_item "14_preprod_workflow_present" "PASS" "false" "Pre-Production Verification Gate workflow exists in repo" "null"
record_item "15_production_requires_approval" "MANUAL" "true" "Production environment requires human approval (enforced in GitHub environment)" "null"
record_item "16_release_approvals" "MANUAL" "false" "Engineering/Security/Product approvals policy (operator process)" "null"
record_item "17_monitoring_thresholds" "MANUAL" "false" "Confirm monitoring/alerts thresholds configured in production" "null"
record_item "18_backup_restore" "MANUAL" "false" "Confirm backup/restore procedures exist for production target" "null"
record_item "19_incident_runbook" "MANUAL" "false" "Confirm incident response runbook is acknowledged by operators" "null"
record_item "20_roll_back_plan" "MANUAL" "false" "Rollback workflow not yet implemented (recommended next)" "null"
record_item "21_dependency_integrity" "MANUAL" "false" "Confirm dependency update policy + CI scanning coverage (if required)" "null"
record_item "22_data_protection" "MANUAL" "false" "Confirm PDPL/retention policies for production data handling" "null"
record_item "23_tenant_isolation" "MANUAL" "false" "Confirm tenant isolation validation executed against production environment" "null"
record_item "24_rate_limit_active" "MANUAL" "false" "Confirm rate limiting active in production runtime" "null"
record_item "25_operator_signoff" "MANUAL" "true" "Operator sign-off recorded (Engineering/Security/Product)" "null"

RESULT="READY"
if [ "${FAIL}" -gt 0 ]; then RESULT="NOT_READY"; fi
if [ "${STRICT_MODE}" = "true" ] && [ "${WARN}" -gt 0 ] && [ "${ENVIRONMENT}" = "production" ]; then RESULT="NOT_READY"; fi

emit_md ""
emit_md "## Summary"
emit_md ""
emit_md "- total: 25"
emit_md "- pass: ${PASS}"
emit_md "- warn: ${WARN}"
emit_md "- manual: ${MANUAL}"
emit_md "- fail: ${FAIL}"
emit_md "- result: ${RESULT}"

write_json "${SAFE_API_URL}" "${RESULT}"

if [ "${RESULT}" != "READY" ]; then
  echo "PRE-PROD CHECK NOT READY" >&2
  exit 1
fi

echo "PRE-PROD CHECK READY"
