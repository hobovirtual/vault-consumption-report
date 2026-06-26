#!/usr/bin/env bash
set -euo pipefail

METRICS_URL=${METRICS_URL:-""}
INSECURE=${INSECURE:-"false"}
FORMAT=${FORMAT:-"table"}
MODE=${MODE:-"utilization"}
SHOW_PATTERNS=${SHOW_PATTERNS:-"false"}
VERBOSE=${VERBOSE:-"false"}
SECTIONS=${SECTIONS:-"all"}
INVENTORY_ONLY=${INVENTORY_ONLY:-"false"}
NAMESPACES=${NAMESPACES:-""}
VAULT_TOKEN_ARG=${VAULT_TOKEN_ARG:-""}
AUDIT_LOG=${AUDIT_LOG:-""}

STATIC_SECRETS_PATTERN=${STATIC_SECRETS_PATTERN:-'^vault_secret_kv_count(\{| )'}
DYNAMIC_SECRETS_PATTERN=${DYNAMIC_SECRETS_PATTERN:-'^vault_secret_engine_.*_dynamic_role_count(\{| )'}
CERTIFICATES_PATTERN=${CERTIFICATES_PATTERN:-'^vault_.*_pki_issue_count(\{| )'}
SSH_OPERATIONS_PATTERN=${SSH_OPERATIONS_PATTERN:-'^vault_route_.*_ssh__count(\{| )'}
ADP_OPERATIONS_PATTERN=${ADP_OPERATIONS_PATTERN:-'^vault_route_.*_(transit|transform|kms)__count(\{| )'}

if [[ -z "$METRICS_URL" && -n "${VAULT_ADDR:-}" ]]; then
  METRICS_URL="${VAULT_ADDR%/}/v1/sys/metrics?format=prometheus"
fi

usage() {
  cat <<'EOF'
Usage: vault-consumption-report.sh [options]

Produces a customer-facing Vault consumption report from audit logs, metrics, and utilization snapshots.
Audit log input is required for every mode so certificate, SSH, and ADP counts stay accurate.

Warnings:

  Dynamic secrets are authoritative in utilization mode.
  manual reports dynamic as 0; prometheus uses metric-pattern counts that may differ from utilization.

  Utilization and audit-log-derived sections are not real-time.
  Values reflect the current utilization snapshot and events present in the provided audit log file.

Examples:

  Generate the full report with the default utilization-backed inventory:

    $ vault-consumption-report.sh --audit-log ./audit.log

  Show only static inventory and SSH operations:

    $ vault-consumption-report.sh --audit-log ./audit.log --metrics static,ssh

  Restrict the report to selected namespaces:

    $ vault-consumption-report.sh --audit-log ./audit.log --namespaces root,team-a

  Generate a JSON report with verbose certificate diagnostics:

    $ vault-consumption-report.sh --audit-log ./audit.log --format json --verbose

Section selection:

  --metrics list
      Comma-separated list of sections to show.
      Available sections: static, dynamic, certificates, ssh, adp, all
      Default: all

Namespace scope:

  --namespaces list
      Comma-separated list of namespaces to include in the report.
      Default: all namespaces discovered from the Vault cluster.
      Example: --namespaces root,team-a

Report options:

  --mode manual|prometheus|utilization
      Choose the inventory source used for static or dynamic counts.
      manual uses Vault CLI for static inventory and inherits your Vault CLI context.
      Configure VAULT_ADDR, VAULT_TOKEN, VAULT_NAMESPACE, and TLS settings as needed before running.
      prometheus uses metrics for static inventory.
      utilization uses vault operator utilization for static and dynamic inventory.

  --format table|json
      Output format. The default is table.

  --verbose
      Include certificate diagnostics such as the audit window and duration buckets.

  --show-patterns
      Print the patterns or source mappings used for the selected mode.

Audit log and TLS options:

  --audit-log FILE
      Vault audit log input. Required for all modes.

  --insecure
      Use curl -k when calling the metrics endpoint.

Prometheus metrics options:

  Vault must expose /v1/sys/metrics?format=prometheus for prometheus mode.
  In many deployments this is not available by default until telemetry/access is configured.

  The metrics URL is used only in prometheus mode. It defaults to
  $VAULT_ADDR/v1/sys/metrics?format=prometheus when VAULT_ADDR is set.
  If VAULT_ADDR is unset, provide the full metrics URL here or via METRICS_URL.

  --metrics-endpoint URL
      Full Prometheus metrics URL.
      This only affects prometheus mode; manual and utilization modes ignore it.

  --metrics-token TOKEN
      Vault token for authenticated metrics access.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)
      if [[ -z "${2:-}" ]] || [[ "$2" == --* ]]; then
        echo "Error: --mode requires a value (manual, prometheus, or utilization)" >&2
        usage >&2
        exit 2
      fi
      MODE="$2"
      shift 2
      ;;
    --metrics-endpoint|--endpoint)
      if [[ -z "${2:-}" ]] || [[ "$2" == --* ]]; then
        echo "Error: --metrics-endpoint requires a URL value" >&2
        usage >&2
        exit 2
      fi
      METRICS_URL="$2"
      shift 2
      ;;
    --audit-log)
      if [[ -z "${2:-}" ]] || [[ "$2" == --* ]]; then
        echo "Error: --audit-log requires a file path" >&2
        usage >&2
        exit 2
      fi
      AUDIT_LOG="$2"
      shift 2
      ;;
    --metrics-token|--token)
      if [[ -z "${2:-}" ]] || [[ "$2" == --* ]]; then
        echo "Error: --metrics-token requires a Vault token value" >&2
        usage >&2
        exit 2
      fi
      VAULT_TOKEN_ARG="$2"
      shift 2
      ;;
    --format)
      if [[ -z "${2:-}" ]] || [[ "$2" == --* ]]; then
        echo "Error: --format requires a value (table or json)" >&2
        usage >&2
        exit 2
      fi
      FORMAT="$2"
      shift 2
      ;;
    --metrics)
      if [[ -z "${2:-}" ]] || [[ "$2" == --* ]]; then
        echo "Error: --metrics requires a comma-separated list of sections" >&2
        usage >&2
        exit 2
      fi
      SECTIONS="$2"
      shift 2
      ;;
    --namespaces|--namespace)
      if [[ -z "${2:-}" ]] || [[ "$2" == --* ]]; then
        echo "Error: --namespaces requires a comma-separated list of namespace paths" >&2
        usage >&2
        exit 2
      fi
      NAMESPACES="$2"
      shift 2
      ;;
    --insecure)
      INSECURE="true"
      shift
      ;;
    --show-patterns)
      SHOW_PATTERNS="true"
      shift
      ;;
    --verbose)
      VERBOSE="true"
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ "$MODE" != "manual" && "$MODE" != "prometheus" && "$MODE" != "utilization" ]]; then
  echo "Invalid --mode: $MODE (use manual, prometheus, or utilization)" >&2
  exit 2
fi

export NAMESPACES

if [[ "$MODE" == "prometheus" && -z "$METRICS_URL" ]]; then
  echo "Missing metrics endpoint for prometheus mode: set VAULT_ADDR, METRICS_URL, or pass --metrics-endpoint" >&2
  exit 2
fi

if [[ -z "$AUDIT_LOG" ]]; then
  echo "Missing required --audit-log FILE (required for all modes)" >&2
  exit 2
fi

if [[ "$FORMAT" != "table" && "$FORMAT" != "json" ]]; then
  echo "Invalid --format: $FORMAT (use table or json)" >&2
  exit 2
fi

if [[ "$VERBOSE" != "true" && "$VERBOSE" != "false" ]]; then
  echo "Invalid VERBOSE value: $VERBOSE (use true or false)" >&2
  exit 2
fi

if [[ "$INVENTORY_ONLY" != "true" && "$INVENTORY_ONLY" != "false" ]]; then
  echo "Invalid INVENTORY_ONLY value: $INVENTORY_ONLY (use true or false)" >&2
  exit 2
fi

metrics=""
snapshot_timestamp=""
metrics_source=""
certificates_label=""
cert_audit_event_count=""
cert_audit_hours_total=""
cert_audit_window_start=""
cert_audit_window_end=""
cert_audit_bucket_le_24="0"
cert_audit_bucket_25_720="0"
cert_audit_bucket_gt_720="0"
cert_ttl_counts_json="[]"
ssh_audit_by_role="[]"
certificates_semantics=""
certificates_method="audit-log-duration"
certificate_accuracy_note=""
utilization_cert_estimate=""

show_static_section="false"
show_dynamic_section="false"
show_certificates_section="false"
show_ssh_section="false"
show_adp_section="false"
namespace_scope_display="${NAMESPACES:-all}"

if [[ "$INVENTORY_ONLY" == "true" ]]; then
  SECTIONS="static,dynamic"
fi

resolve_sections() {
  local raw="$1"
  local normalized
  normalized=$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]' | tr -d ' ')

  if [[ "$normalized" == "" || "$normalized" == "all" ]]; then
    show_static_section="true"
    show_dynamic_section="true"
    show_certificates_section="true"
    show_ssh_section="true"
    show_adp_section="true"
    return 0
  fi

  IFS=',' read -r -a section_list <<< "$normalized"
  for section in "${section_list[@]}"; do
    case "$section" in
      static) show_static_section="true" ;;
      dynamic) show_dynamic_section="true" ;;
      certificates|certs) show_certificates_section="true" ;;
      ssh) show_ssh_section="true" ;;
      adp) show_adp_section="true" ;;
      all)
        show_static_section="true"
        show_dynamic_section="true"
        show_certificates_section="true"
        show_ssh_section="true"
        show_adp_section="true"
        ;;
      *)
        echo "Invalid value in --metrics: $section (use static, dynamic, certificates, ssh, adp, or all)" >&2
        exit 2
        ;;
    esac
  done
}

resolve_sections "$SECTIONS"

sum_for_pattern() {
  local pattern="$1"
  local val
  val=$(printf '%s\n' "$metrics" |
    grep -E "$pattern" |
    awk '
      {
        v=$NF
        if (v ~ /^-?[0-9]+([.][0-9]+)?([eE][+-]?[0-9]+)?$/) {
          s += v
        }
      }
      END {
        if (s == "") s = 0
        printf "%.0f", s
      }
    ')

  if [[ -z "$val" ]]; then
    echo "0"
  else
    echo "$val"
  fi
}

read_utilization_values() {
  local output_base
  local output_file
  output_base=$(mktemp "${TMPDIR:-/tmp}/vault-utilization-report.XXXXXX")
  rm -f "$output_base"
  output_file="${output_base}.json"
  trap 'rm -f "$output_file"' RETURN

  if ! command -v vault >/dev/null 2>&1; then
    echo "vault CLI is required for --mode utilization" >&2
    return 1
  fi

  if ! command -v python3 >/dev/null 2>&1; then
    echo "python3 is required for --mode utilization" >&2
    return 1
  fi

  vault operator utilization -today-only -output="$output_file" >/dev/null

  python3 - "$output_file" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as file_handle:
    bundle = json.load(file_handle)

snapshot = bundle["snapshots"][-1]
metrics = snapshot["metrics"]

dynamic_secrets = (
    metrics.get("vault.secret.engine.aws.dynamic.role.count", {}).get("value", 0)
    + metrics.get("vault.secret.engine.azure.dynamic.role.count", {}).get("value", 0)
    + metrics.get("vault.secret.engine.gcp.dynamic.role.count", {}).get("value", 0)
    + metrics.get("vault.secret.engine.ldap.dynamic.role.count", {}).get("value", 0)
    + metrics.get("vault.secret.engine.database.dynamic.role.count", {}).get("value", 0)
)

static_secrets = (
    metrics.get("vault.kv.version1.secrets.count", {}).get("value", 0)
    + metrics.get("vault.kv.version2.secrets.count", {}).get("value", 0)
)

print(snapshot["timestamp"])
print(static_secrets)
print(dynamic_secrets)
print(metrics.get("certcount.current_month_estimate", {}).get("value", 0))
PY
}

read_static_secret_count_from_vault() {
  if ! command -v vault >/dev/null 2>&1; then
  echo "vault CLI is required" >&2
  return 1
  fi

  if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 is required" >&2
  return 1
  fi

  python3 - <<'PY'
import json
import os
import subprocess
import sys

def run_vault(*args):
  result = subprocess.run(
    ["vault", *args],
    check=False,
    stdout=subprocess.PIPE,
    stderr=subprocess.DEVNULL,
    text=True,
  )
  return result.returncode, result.stdout


def namespace_args(namespace):
  if namespace in ("", "root"):
    return []
  return [f"-namespace={namespace}"]


def selected_namespaces():
  raw = os.environ.get("NAMESPACES", "").strip()
  if not raw or raw.lower() == "all":
    return None
  return [ns.rstrip("/") for ns in raw.split(",") if ns.strip()]

total = 0
requested_namespaces = selected_namespaces()

if requested_namespaces is None:
  # Get list of namespaces
  code, output = run_vault("namespace", "list", "-format=json")
  namespaces = ["root"]
  if code == 0 and output.strip():
    try:
      namespaces.extend([ns.rstrip("/") for ns in json.loads(output) if ns])
    except json.JSONDecodeError:
      pass
else:
  namespaces = requested_namespaces

# For each namespace, discover KV mounts and count secrets
for namespace in dict.fromkeys(namespaces):
  # Get list of mounts in this namespace
  code, output = run_vault("secrets", "list", *namespace_args(namespace), "-format=json")
  if code != 0 or not output.strip():
    continue
  
  try:
    mounts = json.loads(output)
  except json.JSONDecodeError:
    continue
  
  # Filter for KV mounts (both v1 and v2)
  for mount_path, mount_info in mounts.items():
    mount_type = mount_info.get("type", "")
    if mount_type not in ("kv", "generic"):  # generic = KV v1, kv = KV v2
      continue
    
    # List secrets from this mount
    code, output = run_vault(
      "kv",
      "list",
      *namespace_args(namespace),
      f"-mount={mount_path.rstrip('/')}",
    )
    if code != 0:
      continue

    for line in output.splitlines():
      entry = line.strip()
      if not entry or entry in {"Keys", "----"}:
        continue
      if entry.endswith("/"):
        continue
      total += 1

print(total)
PY
}

read_cert_units_from_audit_log() {
  local audit_log_file="$1"

  if [[ ! -f "$audit_log_file" ]]; then
  echo "Audit log file not found: $audit_log_file" >&2
  return 1
  fi

  if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 is required for --audit-log" >&2
  return 1
  fi

  python3 - "$audit_log_file" <<'PY'
import json
import os
import math
import re
import sys
from datetime import datetime, timezone


def selected_namespaces():
  raw = os.environ.get("NAMESPACES", "").strip()
  if not raw or raw.lower() == "all":
    return None
  return {ns.rstrip("/") for ns in raw.split(",") if ns.strip()}


requested_namespaces = selected_namespaces()


def parse_ts(value) -> datetime:
  if value is None or value == "":
    raise ValueError("empty timestamp")

  if isinstance(value, (int, float)):
    return datetime.fromtimestamp(value, tz=timezone.utc)

  value = str(value)
  if value.endswith("Z"):
    value = value[:-1] + "+00:00"

  # Normalize sub-second precision to microseconds for fromisoformat.
  match = re.match(r"^(.*?)(\.\d+)([+-]\d\d:\d\d)$", value)
  if match:
    head, frac, tail = match.groups()
    frac = frac[:7]  # keep dot + up to 6 digits
    value = f"{head}{frac}{tail}"

  parsed = datetime.fromisoformat(value)
  if parsed.tzinfo is None:
    parsed = parsed.replace(tzinfo=timezone.utc)
  return parsed


event_count = 0
hours_total = 0.0
units_total = 0
window_start = None
window_end = None
bucket_le_24 = 0
bucket_25_720 = 0
bucket_gt_720 = 0

with open(sys.argv[1], encoding="utf-8") as handle:
  for raw in handle:
    raw = raw.strip()
    if not raw:
      continue

    try:
      entry = json.loads(raw)
    except json.JSONDecodeError:
      continue

    if entry.get("type") != "response":
      continue

    request = entry.get("request") or {}
    if request.get("mount_type") != "pki":
      continue

    namespace = ((request.get("namespace") or {}).get("path") or "root").rstrip("/")
    if requested_namespaces is not None and namespace not in requested_namespaces:
      continue

    path = request.get("path") or ""
    if "/issue/" not in path and "/sign/" not in path and "/generate/" not in path:
      continue

    response = entry.get("response") or {}
    data = response.get("data") or {}
    expiration = data.get("expiration")
    request_time = entry.get("time")

    if not expiration or not request_time:
      continue

    try:
      issued_at = parse_ts(request_time)
      expires_at = parse_ts(expiration)
    except ValueError:
      continue

    delta_hours = (expires_at - issued_at).total_seconds() / 3600.0
    if delta_hours <= 0:
      continue

    event_count += 1
    hours_total += delta_hours
    units_total += math.ceil(delta_hours / 730.0)
    if delta_hours <= 24:
      bucket_le_24 += 1
    elif delta_hours <= 720:
      bucket_25_720 += 1
    else:
      bucket_gt_720 += 1
    if window_start is None or issued_at < window_start:
      window_start = issued_at
    if window_end is None or issued_at > window_end:
      window_end = issued_at

print(units_total)
print(event_count)
print(f"{hours_total:.2f}")
print(window_start.isoformat().replace("+00:00", "Z") if window_start else "")
print(window_end.isoformat().replace("+00:00", "Z") if window_end else "")
print(bucket_le_24)
print(bucket_25_720)
print(bucket_gt_720)
PY
}

read_ssh_sign_counts_from_audit_log() {
  local audit_log_file="$1"

  if [[ ! -f "$audit_log_file" ]]; then
    echo "Audit log file not found: $audit_log_file" >&2
    return 1
  fi

  if ! command -v python3 >/dev/null 2>&1; then
    echo "python3 is required for --audit-log" >&2
    return 1
  fi

  python3 - "$audit_log_file" <<'PY'
import json
import os
import sys


def selected_namespaces():
  raw = os.environ.get("NAMESPACES", "").strip()
  if not raw or raw.lower() == "all":
    return None
  return {ns.rstrip("/") for ns in raw.split(",") if ns.strip()}


requested_namespaces = selected_namespaces()

total = 0
groups = {}

with open(sys.argv[1], encoding="utf-8") as handle:
  for raw in handle:
    raw = raw.strip()
    if not raw:
      continue

    try:
      entry = json.loads(raw)
    except json.JSONDecodeError:
      continue

    if entry.get("type") != "response":
      continue

    request = entry.get("request") or {}
    if request.get("mount_type") != "ssh":
      continue

    namespace = ((request.get("namespace") or {}).get("path") or "root").rstrip("/")
    if requested_namespaces is not None and namespace not in requested_namespaces:
      continue

    path = request.get("path") or ""
    if "/sign/" not in path:
      continue

    role = path.split("/sign/", 1)[1]
    namespace = ((request.get("namespace") or {}).get("path") or "root").rstrip("/")
    mount = request.get("mount_point") or ""

    total += 1
    key = (namespace, mount, role)
    groups[key] = groups.get(key, 0) + 1

rows = [
  {
    "namespace": key[0],
    "mount": key[1],
    "role": key[2],
    "count": count,
  }
  for key, count in sorted(groups.items())
]

print(total)
print(json.dumps(rows, separators=(",", ":")))
PY
}

read_cert_ttl_counts_from_audit_log() {
  local audit_log_file="$1"

  if [[ ! -f "$audit_log_file" ]]; then
    echo "Audit log file not found: $audit_log_file" >&2
    return 1
  fi

  if ! command -v python3 >/dev/null 2>&1; then
    echo "python3 is required for --audit-log" >&2
    return 1
  fi

  python3 - "$audit_log_file" <<'PY'
import json
import os
import re
import sys
from datetime import datetime, timezone


def selected_namespaces():
  raw = os.environ.get("NAMESPACES", "").strip()
  if not raw or raw.lower() == "all":
    return None
  return {ns.rstrip("/") for ns in raw.split(",") if ns.strip()}


requested_namespaces = selected_namespaces()


def parse_ts(value) -> datetime:
  if value is None or value == "":
    raise ValueError("empty timestamp")

  if isinstance(value, (int, float)):
    return datetime.fromtimestamp(value, tz=timezone.utc)

  value = str(value)
  if value.endswith("Z"):
    value = value[:-1] + "+00:00"

  match = re.match(r"^(.*?)(\.\d+)([+-]\d\d:\d\d)$", value)
  if match:
    head, frac, tail = match.groups()
    frac = frac[:7]
    value = f"{head}{frac}{tail}"

  parsed = datetime.fromisoformat(value)
  if parsed.tzinfo is None:
    parsed = parsed.replace(tzinfo=timezone.utc)
  return parsed


counts = {}

with open(sys.argv[1], encoding="utf-8") as handle:
  for raw in handle:
    raw = raw.strip()
    if not raw:
      continue

    try:
      entry = json.loads(raw)
    except json.JSONDecodeError:
      continue

    if entry.get("type") != "response":
      continue

    request = entry.get("request") or {}
    if request.get("mount_type") != "pki":
      continue

    namespace = ((request.get("namespace") or {}).get("path") or "root").rstrip("/")
    if requested_namespaces is not None and namespace not in requested_namespaces:
      continue

    path = request.get("path") or ""
    if "/issue/" not in path and "/sign/" not in path and "/generate/" not in path:
      continue

    response = entry.get("response") or {}
    data = response.get("data") or {}
    expiration = data.get("expiration")
    request_time = entry.get("time")
    if not expiration or not request_time:
      continue

    try:
      issued_at = parse_ts(request_time)
      expires_at = parse_ts(expiration)
    except ValueError:
      continue

    ttl_hours = (expires_at - issued_at).total_seconds() / 3600.0
    if ttl_hours <= 0:
      continue

    ttl_hours_rounded = int(round(ttl_hours))
    counts[ttl_hours_rounded] = counts.get(ttl_hours_rounded, 0) + 1

rows = [
  {
    "ttl_hours": ttl,
    "ttl_days": round(ttl / 24.0, 2),
    "count": count,
  }
  for ttl, count in sorted(counts.items())
]

print(json.dumps(rows, separators=(",", ":")))
PY
}

read_adp_operations_from_audit_log() {
  local audit_log_file="$1"

  if [[ ! -f "$audit_log_file" ]]; then
    echo "Audit log file not found: $audit_log_file" >&2
    return 1
  fi

  if ! command -v python3 >/dev/null 2>&1; then
    echo "python3 is required for --audit-log" >&2
    return 1
  fi

  python3 - "$audit_log_file" <<'PY'
import json
import os
import sys


def selected_namespaces():
  raw = os.environ.get("NAMESPACES", "").strip()
  if not raw or raw.lower() == "all":
    return None
  return {ns.rstrip("/") for ns in raw.split(",") if ns.strip()}


requested_namespaces = selected_namespaces()

count = 0

transit_ops = (
  "/encrypt/",
  "/decrypt/",
  "/rewrap/",
  "/datakey/",
  "/hmac/",
  "/sign/",
  "/verify/",
  "/cmac/",
)

transform_ops = (
  "/encode/",
  "/decode/",
  "/validate/",
  "/tokenized/",
  "/tokens/",
)

gcpkms_ops = (
  "/decrypt/",
  "/encrypt/",
  "/reencrypt/",
  "/sign/",
  "/verify/",
)

with open(sys.argv[1], encoding="utf-8") as handle:
  for raw in handle:
    raw = raw.strip()
    if not raw:
      continue

    try:
      entry = json.loads(raw)
    except json.JSONDecodeError:
      continue

    if entry.get("type") != "response":
      continue

    request = entry.get("request") or {}
    mount_type = request.get("mount_type") or ""
    path = request.get("path") or ""

    namespace = ((request.get("namespace") or {}).get("path") or "root").rstrip("/")
    if requested_namespaces is not None and namespace not in requested_namespaces:
      continue

    if mount_type == "transit" and any(op in path for op in transit_ops):
      count += 1
    elif mount_type == "transform" and any(op in path for op in transform_ops):
      count += 1
    elif mount_type == "gcpkms" and any(op in path for op in gcpkms_ops):
      count += 1

print(count)
PY
}

if [[ "$MODE" == "prometheus" ]]; then
  curl_args=("-sS")
  if [[ "$INSECURE" == "true" ]]; then
    curl_args+=("-k")
  fi
  if [[ -n "$VAULT_TOKEN_ARG" ]]; then
    curl_args+=("-H" "X-Vault-Token: $VAULT_TOKEN_ARG")
  fi

  metrics=$(curl "${curl_args[@]}" "$METRICS_URL")
  metrics_source="metrics endpoint + audit log"

  static_secrets=$(sum_for_pattern "$STATIC_SECRETS_PATTERN")
  dynamic_secrets=$(sum_for_pattern "$DYNAMIC_SECRETS_PATTERN")
  certificates="0"
  certificates_label="Certificates (audit units)"
  certificates_semantics="audit_duration_units"
  certificates_method="audit-log-duration"
  ssh_ops="0"
  adp_ops="0"
elif [[ "$MODE" == "manual" ]]; then
  static_secrets=$(read_static_secret_count_from_vault)
  dynamic_secrets="0"
  certificates="0"
  certificates_label="Certificates (audit units)"
  certificates_semantics="audit_duration_units"
  certificates_method="audit-log-duration"
  ssh_ops="0"
  adp_ops="0"
  metrics_source="vault CLI"
else
  utilization_output=$(read_utilization_values)
  snapshot_timestamp=$(printf '%s\n' "$utilization_output" | sed -n '1p')
  static_secrets=$(read_static_secret_count_from_vault)
  dynamic_secrets=$(printf '%s\n' "$utilization_output" | sed -n '3p')
  utilization_cert_estimate=$(printf '%s\n' "$utilization_output" | sed -n '4p')
  certificates="0"
  certificates_label="Certificates (audit units)"
  certificates_semantics="audit_duration_units"
  certificates_method="audit-log-duration"
  ssh_ops="0"
  adp_ops="0"
  metrics_source="vault utilization snapshot"
fi

audit_output=$(read_cert_units_from_audit_log "$AUDIT_LOG")
certificates=$(printf '%s\n' "$audit_output" | sed -n '1p')
cert_audit_event_count=$(printf '%s\n' "$audit_output" | sed -n '2p')
cert_audit_hours_total=$(printf '%s\n' "$audit_output" | sed -n '3p')
cert_audit_window_start=$(printf '%s\n' "$audit_output" | sed -n '4p')
cert_audit_window_end=$(printf '%s\n' "$audit_output" | sed -n '5p')
cert_audit_bucket_le_24=$(printf '%s\n' "$audit_output" | sed -n '6p')
cert_audit_bucket_25_720=$(printf '%s\n' "$audit_output" | sed -n '7p')
cert_audit_bucket_gt_720=$(printf '%s\n' "$audit_output" | sed -n '8p')
cert_ttl_counts_json=$(read_cert_ttl_counts_from_audit_log "$AUDIT_LOG")

ssh_audit_output=$(read_ssh_sign_counts_from_audit_log "$AUDIT_LOG")
ssh_ops=$(printf '%s\n' "$ssh_audit_output" | sed -n '1p')
ssh_audit_by_role=$(printf '%s\n' "$ssh_audit_output" | sed -n '2p')

adp_ops=$(read_adp_operations_from_audit_log "$AUDIT_LOG")

if [[ "$MODE" == "utilization" && -n "$utilization_cert_estimate" ]]; then
  if [[ "$certificates" -lt "$utilization_cert_estimate" ]]; then
    certificate_accuracy_note="partial_audit_log_for_billing_window"
  elif [[ "$certificates" -eq "$utilization_cert_estimate" ]]; then
    certificate_accuracy_note="audit_and_utilization_aligned"
  else
    certificate_accuracy_note="audit_exceeds_utilization_estimate"
  fi
fi

if [[ "$SHOW_PATTERNS" == "true" ]]; then
  if [[ "$MODE" == "prometheus" ]]; then
    echo "Patterns in use:"
    echo "  static_secrets:   $STATIC_SECRETS_PATTERN"
    echo "  dynamic_secrets:  $DYNAMIC_SECRETS_PATTERN"
    echo "  certificates:     $CERTIFICATES_PATTERN"
    echo "  ssh_operations:   $SSH_OPERATIONS_PATTERN"
    echo "  adp_operations:   $ADP_OPERATIONS_PATTERN"
  elif [[ "$MODE" == "manual" ]]; then
    echo "Manual mode sources:"
    echo "  static_secrets:   vault CLI namespace+kv listing"
    echo "  dynamic_secrets:  set to 0 (no telemetry/utilization dependency)"
    echo "  certificates:     audit log duration units"
    echo "  ssh_operations:   audit log ssh sign responses"
    echo "  adp_operations:   audit log transit/transform/gcpkms responses"
  else
    echo "Metric keys in use:"
    echo "  static_secrets:   vault.kv.version2.secrets.count"
    echo "  dynamic_secrets:  vault.secret.engine.{aws,azure,gcp,ldap,database}.dynamic.role.count"
    echo "  certificates:     derived from audit log duration"
    echo "  ssh_operations:   derived from audit log ssh sign responses"
    echo "  adp_operations:   derived from audit log transit/transform/gcpkms responses"
  fi
  echo "  sections:        $SECTIONS"
  echo "  namespaces:      ${namespace_scope_display}"
  echo "  audit_log:        $AUDIT_LOG"
  echo "  full_inventory:   static + dynamic + certificates + ssh + adp"
  echo "  cert_math:        ceil((expiration - request_time in hours) / 730)"
  echo "  ssh_match:        type=response and mount_type=ssh and path contains /sign/"
  echo "  adp_match:        transit(/encrypt|/decrypt|/rewrap|/datakey|/hmac|/sign|/verify|/cmac), transform(/encode|/decode|/validate|/tokenized|/tokens), gcpkms(/decrypt|/encrypt|/reencrypt|/sign|/verify)"
  if [[ "$VERBOSE" == "true" && "$MODE" == "utilization" && -n "$utilization_cert_estimate" ]]; then
    echo "  cert_estimate:    utilization=$utilization_cert_estimate audit=$certificates"
    echo "  cert_accuracy:    $certificate_accuracy_note"
  fi
  echo
fi

if [[ "$FORMAT" == "json" ]]; then
  printf '{\n'
  printf '  "sections": {"selected": "%s"},\n' "$SECTIONS"
  printf '  "namespaces": "%s",\n' "$namespace_scope_display"
  if [[ "$show_static_section" == "true" ]]; then
    printf '  "static_secrets": {"count": %s}' "$static_secrets"
    if [[ "$show_dynamic_section" == "true" || "$show_certificates_section" == "true" || "$show_ssh_section" == "true" || "$show_adp_section" == "true" ]]; then
      printf ',\n'
    else
      printf '\n'
    fi
  fi
  if [[ "$show_dynamic_section" == "true" ]]; then
    printf '  "dynamic_secrets": {"count": %s}' "$dynamic_secrets"
    if [[ "$show_certificates_section" == "true" || "$show_ssh_section" == "true" || "$show_adp_section" == "true" ]]; then
      printf ',\n'
    else
      printf '\n'
    fi
  fi
  if [[ "$show_certificates_section" == "true" ]]; then
    printf '  "certificates": {\n'
    printf '    "method": "%s",\n' "$certificates_method"
    printf '    "audit_units": %s,\n' "$certificates"
    printf '    "ttl_summary": %s' "$cert_ttl_counts_json"
    if [[ "$VERBOSE" == "true" ]]; then
      printf ',\n'
      printf '    "audit_events": %s,\n' "$cert_audit_event_count"
      printf '    "audit_hours_total": %s,\n' "$cert_audit_hours_total"
      printf '    "audit_window_start": "%s",\n' "$cert_audit_window_start"
      printf '    "audit_window_end": "%s",\n' "$cert_audit_window_end"
      printf '    "duration_buckets": {"0_24h": %s, "25_720h": %s, "gt_720h": %s}' "$cert_audit_bucket_le_24" "$cert_audit_bucket_25_720" "$cert_audit_bucket_gt_720"
      if [[ "$MODE" == "utilization" && -n "$utilization_cert_estimate" ]]; then
        printf ',\n'
        printf '    "utilization_estimate": %s,\n' "$utilization_cert_estimate"
        printf '    "accuracy_note": "%s"\n' "$certificate_accuracy_note"
      else
        printf '\n'
      fi
    else
      printf '\n'
    fi
    if [[ "$show_ssh_section" == "true" || "$show_adp_section" == "true" ]]; then
      printf '  },\n'
    else
      printf '  }\n'
    fi
  fi
  if [[ "$show_ssh_section" == "true" ]]; then
    printf '  "ssh_credentials": {\n'
    printf '    "signed_credentials": %s,\n' "$ssh_ops"
    printf '    "sign_counts_by_role": %s\n' "$ssh_audit_by_role"
    if [[ "$show_adp_section" == "true" ]]; then
      printf '  },\n'
    else
      printf '  }\n'
    fi
  fi
  if [[ "$show_adp_section" == "true" ]]; then
    printf '  "advanced_data_protection_operations": {"count": %s}\n' "$adp_ops"
  fi
  printf '}\n'
else
  LABEL_W=34
  VALUE_W=14
  TABLE_W=$((LABEL_W + VALUE_W + 1))

  repeat_char() {
    local count="$1"
    local char="$2"
    printf '%*s' "$count" '' | tr ' ' "$char"
  }

  print_rule() {
    local char="$1"
    repeat_char "$TABLE_W" "$char"
    printf '\n'
  }

  print_section_title() {
    printf '\n'
    print_rule '='
    printf '%s\n' "$1"
    print_rule '='
  }

  print_table_header() {
    printf '%-*s %*s\n' "$LABEL_W" "$1" "$VALUE_W" "$2"
    printf '%-*s %*s\n' "$LABEL_W" "$(repeat_char "$LABEL_W" '-')" "$VALUE_W" "$(repeat_char "$VALUE_W" '-')"
  }

  print_table_row() {
    printf '%-*s %*s\n' "$LABEL_W" "$1" "$VALUE_W" "$2"
  }

  print_section_title "Report Summary"
  print_table_header "Field" "Value"
  print_table_row "Mode" "$MODE"
  print_table_row "Sections" "$SECTIONS"
  print_table_row "Namespaces" "$namespace_scope_display"
  print_table_row "Inventory source" "$metrics_source"
  print_table_row "Audit log" "$AUDIT_LOG"
  if [[ "$MODE" == "utilization" && -n "$snapshot_timestamp" ]]; then
    print_table_row "Snapshot time" "$snapshot_timestamp"
  fi

  if [[ "$show_static_section" == "true" ]]; then
    print_section_title "Static Secrets"
    print_table_header "Metric" "Value"
    print_table_row "Count" "$static_secrets"
  fi

  if [[ "$show_dynamic_section" == "true" ]]; then
    print_section_title "Dynamic Secrets"
    print_table_header "Metric" "Value"
    print_table_row "Count" "$dynamic_secrets"
  fi

  if [[ "$show_certificates_section" == "true" ]]; then
    print_section_title "Certificates"
    print_table_header "Validity" "Count"
    python3 - "$cert_ttl_counts_json" "$LABEL_W" "$VALUE_W" <<'PY'
import json
import sys

rows = json.loads(sys.argv[1])
label_w = int(sys.argv[2])
value_w = int(sys.argv[3])
for row in rows:
  ttl_hours = row.get("ttl_hours", 0)
  ttl_days = row.get("ttl_days", 0)
  count = row.get("count", 0)
  label = f"{ttl_hours}h ({ttl_days:.2f}d)"
  print(f"{label:<{label_w}} {count:>{value_w}}")
PY
  fi

  if [[ "$show_ssh_section" == "true" ]]; then
    print_section_title "SSH Credentials"
    print_table_header "Metric" "Value"
    print_table_row "Signed credentials" "$ssh_ops"
  fi

  if [[ "$show_adp_section" == "true" ]]; then
    print_section_title "Advanced Data Protection"
    print_table_header "Metric" "Value"
    print_table_row "Operations" "$adp_ops"
  fi

  if [[ "$show_certificates_section" == "true" && "$VERBOSE" == "true" ]]; then
    print_section_title "Certificates Diagnostics"
    print_table_header "Metric" "Value"
    print_table_row "Audit events" "$cert_audit_event_count"
    print_table_row "Audit hours" "$cert_audit_hours_total"
    print_table_row "Audit window start" "$cert_audit_window_start"
    print_table_row "Audit window end" "$cert_audit_window_end"
    print_table_row "Certs 0-24h" "$cert_audit_bucket_le_24"
    print_table_row "Certs 25-720h" "$cert_audit_bucket_25_720"
    print_table_row "Certs >720h" "$cert_audit_bucket_gt_720"
    if [[ "$MODE" == "utilization" && -n "$utilization_cert_estimate" ]]; then
      print_table_row "Utilization estimate" "$utilization_cert_estimate"
      print_table_row "Accuracy note" "$certificate_accuracy_note"
    fi
  fi
fi
