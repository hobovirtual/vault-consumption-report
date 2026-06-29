# Vault Consumption Report

![Platform Linux](https://img.shields.io/badge/Linux-Supported-2EA043?logo=linux&logoColor=white)
![Platform macOS](https://img.shields.io/badge/macOS-Supported-1F6FEB?logo=apple&logoColor=white)
![Platform Windows](https://img.shields.io/badge/Windows-Supported-0A66C2?logo=windows&logoColor=white)
![Podman](https://img.shields.io/badge/Podman-Supported-892CA0?logo=podman&logoColor=white)
![Docker](https://img.shields.io/badge/Docker-Supported-2496ED?logo=docker&logoColor=white)
![Audit Log](https://img.shields.io/badge/Audit%20Log-Required-D1242F)
![Default Mode](https://img.shields.io/badge/Default%20Mode-Utilization-7A3FF2)
![TLS](https://img.shields.io/badge/TLS-Verify%20By%20Default-0E8A16)

This script builds a customer-facing Vault consumption report from:

- Vault audit log events
- Vault metrics endpoint (Prometheus format)
- Vault utilization snapshots

It is designed to be practical and fast to run during customer reporting, troubleshooting, and periodic checks.

> [!TIP]
> Use `--mode utilization` when you need the most reliable dynamic secret counts.

### At a Glance

| What | Status |
|---|---|
| Cross-platform | Linux, macOS, Windows (WSL/Git Bash) |
| Required input | `--audit-log FILE` |
| Secure default | TLS verify enabled |
| Default mode | `utilization` |
| Output formats | `table`, `json` |

## Quick Start 🚀

The only hard requirement across all modes is an audit log file.

```bash
./vault-consumption-report.sh --audit-log /path/to/audit.log
```

That command uses the default mode (`utilization`) and prints a table report.

If you want JSON output:

```bash
./vault-consumption-report.sh --audit-log /path/to/audit.log --format json
```

## Containerized Runner 🐳

If your environment restricts local installs (for example, no local `python3`), you can run the same report from a container image that already includes:

- `bash`, `curl`, `grep`, `awk`, `python3`
- Vault CLI

### Build the image

#### Podman

```bash
podman build -t vault-consumption-report:local -f Containerfile .
```

#### Docker

```bash
docker build -t vault-consumption-report:local .
```

### Run with an audit log mounted read-only

#### Podman

```bash
podman run --rm \
  -v "/path/to/audit-dir:/input:ro" \
  vault-consumption-report:local \
  --audit-log /input/audit.log --mode prometheus --insecure
```

#### Docker

```bash
docker run --rm \
  -v "/path/to/audit-dir:/input:ro" \
  vault-consumption-report:local \
  --audit-log /input/audit.log --mode prometheus --insecure
```

### Run in manual/utilization mode

Pass Vault CLI context into the container:

#### Podman

```bash
podman run --rm \
  -v "/path/to/audit-dir:/input:ro" \
  -e VAULT_ADDR \
  -e VAULT_TOKEN \
  -e VAULT_NAMESPACE \
  -e VAULT_SKIP_VERIFY \
  vault-consumption-report:local \
  --audit-log /input/audit.log --mode utilization --format json
```

#### Docker

```bash
docker run --rm \
  -v "/path/to/audit-dir:/input:ro" \
  -e VAULT_ADDR \
  -e VAULT_TOKEN \
  -e VAULT_NAMESPACE \
  -e VAULT_SKIP_VERIFY \
  vault-consumption-report:local \
  --audit-log /input/audit.log --mode utilization --format json
```

Notes:

- The container outputs the same table/JSON as local execution.
- Your audit log path changes to the mounted path inside the container (for example `/input/audit.log`).
- For private or internal Vault endpoints, ensure container network access is allowed in your environment.
- This repo includes both `Containerfile` and `Dockerfile`.

### Multi-Architecture Support 🏗️

The container image automatically detects and builds for the CPU architecture of your current machine. No manual configuration needed.

**Native builds on each architecture:**

```bash
# On Mac (arm64), Linux ARM64, or Raspberry Pi
podman build -t vault-consumption-report:local -f Containerfile .
# Builds for arm64

# On Linux x86_64 or Intel-based systems
**How it works:**

When you run `podman build` or `docker build`, the build system automatically detects your CPU architecture and sets the `TARGETARCH` build argument. The Containerfile then uses that value to download the matching Vault CLI binary. Each machine builds natively for its own CPU—no cross-compilation or emulation needed.
# Builds for amd64
```

- `linux/amd64` (Intel, AMD, x86_64 64-bit)

**Supported architectures:**

- `linux/amd64` (Intel/AMD 64-bit)
- `linux/arm64` (ARM 64-bit: Apple Silicon Macs, AWS Graviton, etc.)

If you need to override the Vault version (for example to test a different release):

```bash
podman build --build-arg VAULT_VERSION=1.18.0 -t vault-consumption-report:local -f Containerfile .
```

---

## Platform Support 🖥️

This script is cross-platform, with one important detail:

- The script itself is Bash.
- On Linux and macOS, run it directly in your shell.
- On Windows, run it in WSL or Git Bash (recommended: WSL).

> [!IMPORTANT]
> This is a Bash script. On Windows, run it in WSL or Git Bash instead of plain PowerShell.

### Common Tools Needed 🛠️

All platforms need these tools:

- bash
- curl
- grep
- awk
- python3

Depending on mode, you may also need:

- vault CLI (`manual` and `utilization` modes)

---

## Install Guide by Platform 📦

### Linux 🐧

Install dependencies with your distro package manager.

Ubuntu/Debian example:

```bash
sudo apt update
sudo apt install -y bash curl grep gawk python3
```

Install Vault CLI separately from HashiCorp packages or your internal package source.

### macOS 🍎

Homebrew example:

```bash
brew install bash curl gawk python
brew tap hashicorp/tap
brew install hashicorp/tap/vault
```

### Windows ⊞

Recommended path: WSL (Ubuntu or similar), then follow Linux steps inside WSL.

Alternative path: Git Bash + Windows tools.

Winget example:

```powershell
winget install --id Git.Git -e
winget install --id Python.Python.3.12 -e
winget install --id Hashicorp.Vault -e
```

Note for Windows users:

- Run the script from Git Bash or WSL, not plain PowerShell.
- If your audit log is on C:, a WSL path looks like `/mnt/c/path/to/audit.log`.

---

## Modes and Data Sources 🧭

The report always uses the audit log for certificates, SSH, and ADP.

### `--mode manual`

> 🧩 Best when your Vault CLI context is already configured and you want direct static inventory from Vault.

- Static secrets: Vault CLI inventory
- Dynamic secrets: not available
- Certificates: audit-log duration units
- SSH and ADP: audit-log derived

Prereq: your Vault CLI context is already configured (`VAULT_ADDR`, `VAULT_TOKEN`, optional `VAULT_NAMESPACE`, and TLS settings if needed).

### `--mode prometheus`

> 📈 Best when you want metric-backed inventory and have telemetry endpoint access.

- Static secrets: metrics endpoint
- Dynamic secrets: not always available
- Certificates: audit-log duration units
- SSH and ADP: audit-log derived

Prometheus prerequisite:

- Vault must expose `/v1/sys/metrics?format=prometheus`
- In many environments this is not enabled by default until telemetry/access settings are configured
- Some environments do not emit dynamic-role metrics for database or other dynamic backends; in that case Prometheus mode can still report `0` even when dynamic secret issuance works.

Metrics endpoint behavior:

- If `VAULT_ADDR` is set, default endpoint is `$VAULT_ADDR/v1/sys/metrics?format=prometheus`
- Otherwise provide a full URL with `--metrics-endpoint` or `METRICS_URL`
- `--endpoint` and `--token` are kept as compatibility aliases

### `--mode utilization` (default)

> 🧠 Best overall accuracy for dynamic counts; uses Vault utilization snapshots.

- Static and dynamic secrets: `vault operator utilization -today-only`
- Certificates: audit-log duration units
- SSH and ADP: audit-log derived

This is the most reliable mode for dynamic secret counts.

---

## Output Reference 📋

The report always prints the same top-level sections, but what each value means depends on the selected mode.

| Output | What it means | Manual | Prometheus | Utilization |
|---|---|---|---|---|
| `Static Secrets` | Count of KV/static secrets discovered for the selected namespaces | Vault CLI inventory | Metrics-based count | Utilization-backed count |
| `Dynamic Secrets` | Count of dynamic secret roles/usages that Vault telemetry can attribute | Not available | Not available | Utilization snapshot count |
| `Certificates` | Audit-derived certificate units grouped by validity/TTL | Available | Available | Available |
| `SSH Credentials` | Audit-derived count of SSH signing operations | Available | Available | Available |
| `Advanced Data Protection` | Audit-derived count of transit/transform/gcpkms operations | Available | Available | Available |
| `Report Summary` | Metadata about mode, section selection, namespace scope, and data source | Available | Available | Available |
| `Snapshot time` | Timestamp of the utilization snapshot used for inventory values | Not shown | Not shown | Available |

### Verbose Fields

When you use `--verbose`, the report adds certificate diagnostics:

- `Audit events`: number of PKI issuance/sign/generate events found in the audit log
- `Audit hours`: total certificate lifetime hours observed in the audit log
- `Audit window start/end`: first and last qualifying PKI event timestamps in the provided audit log
- `Certs 0-24h`, `Certs 25-720h`, `Certs >720h`: certificate event buckets by requested lifetime
- `Utilization estimate` and `Accuracy note`: shown only in utilization mode when certificate estimate comparison data is available

### JSON Output Notes

When you use `--format json`:

- The same report concepts are returned as machine-readable fields
- `sections.selected` reflects your `--metrics` selection
- `namespaces` reflects your namespace scope
- `ttl_summary` contains certificate validity buckets as structured rows
- `sign_counts_by_role` contains SSH signing counts grouped by namespace, mount, and role

---

## Important Accuracy Notes ⚠️

> 🟨 Heads up: this report is operationally accurate, but not strict real-time telemetry.
>
> 🟩 Best dynamic counts come from `--mode utilization`.

- `--audit-log FILE` is required in all modes.
- TLS verification is enabled by default.
- Use `--insecure` only when you intentionally need to skip TLS validation.
- This report is not strict real-time telemetry.
- Utilization mode reflects the latest snapshot, not a live stream.
- Prometheus mode can under-report dynamic secrets if Vault does not publish the matching dynamic-role metric family.
- Audit-derived values depend on the events present in the audit file you provide.

Certificate unit math:

- Certificates are computed from audit events as: `ceil((expiration - request_time in hours) / 730)`

---

## Most Useful Options 🎛️

- `--audit-log FILE`: required
- `--mode manual|prometheus|utilization`
- `--format table|json`
- `--metrics static,dynamic,certificates,ssh,adp|all`
- `--namespaces root,team-a` to scope the report
- `--verbose` for deeper certificate diagnostics
- `--show-patterns` to print active metric patterns/sources
- `--metrics-endpoint URL` and `--metrics-token TOKEN` for prometheus mode

---

## Examples by Platform 💡

### Linux/macOS (Bash/Zsh)

Run default report:

```bash
./vault-consumption-report.sh --audit-log ./vault-audit.log
```

Prometheus mode with explicit endpoint:

```bash
./vault-consumption-report.sh \
  --mode prometheus \
  --metrics-endpoint "https://vault.example.com/v1/sys/metrics?format=prometheus" \
  --audit-log ./vault-audit.log
```

Utilization mode in JSON with diagnostics:

```bash
./vault-consumption-report.sh \
  --mode utilization \
  --audit-log ./vault-audit.log \
  --format json \
  --verbose
```

### Windows (WSL or Git Bash)

Git Bash/WSL example:

```bash
./vault-consumption-report.sh --audit-log /mnt/c/temp/vault-audit.log --format json
```

If you need to set Vault context first:

```bash
export VAULT_ADDR='https://vault.example.com'
export VAULT_TOKEN='...'
./vault-consumption-report.sh --mode manual --audit-log /mnt/c/temp/vault-audit.log
```

---

## Quick Pre-Flight Checks (Prometheus Mode) ✅

```bash
export VAULT_ADDR='https://vault.example.com'

# Endpoint responds
curl -sk "$VAULT_ADDR/v1/sys/metrics?format=prometheus" | head -n 5

# Core static metric exists
curl -sk "$VAULT_ADDR/v1/sys/metrics?format=prometheus" | grep '^vault_secret_kv_count'
```

---

## Pattern Overrides (Prometheus Mode) 🎯

If a customer environment uses different metric names, override patterns with env vars:

```bash
STATIC_SECRETS_PATTERN='^vault_secret_kv_count(\\{| )' \
DYNAMIC_SECRETS_PATTERN='^vault_secret_engine_.*_dynamic_role_count(\\{| )' \
ADP_OPERATIONS_PATTERN='^vault_route_.*_(transit|transform|kms)__count(\\{| )' \
./vault-consumption-report.sh --mode prometheus --show-patterns --audit-log ./vault-audit.log
```

---

## Replication and Interpretation Notes 🔁

- For Performance Replication, metrics are billed on the PR primary cluster.
- When collecting from PR secondary clusters, align interpretation with the customer before sharing totals.

---

## Troubleshooting Tips 🛠️

### ❌ `vault: command not found`

- Install Vault CLI and ensure it is in PATH.

### ❌ Prometheus mode fails with endpoint errors

- Verify Vault telemetry/access settings expose `/v1/sys/metrics?format=prometheus`.
- Pass `--metrics-endpoint` explicitly if `VAULT_ADDR` is not set.

### ❌ Report looks lower than expected

- Check audit log coverage window.
- Verify the audit file includes the period you are reporting.
- Use `--verbose` to inspect certificate coverage details.

---

## Utilization Snapshots 🧪

The `utilization-snapshots/` folder contains saved `vault operator utilization -today-only` outputs used for troubleshooting.

These files are reference artifacts only; the script does not read them at runtime.
