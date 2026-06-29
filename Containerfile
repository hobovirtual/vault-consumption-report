FROM debian:bookworm-slim

ARG VAULT_VERSION=latest
# TARGETARCH is automatically set by the container build system (podman/docker)
# based on your platform. This default is used only if not set by the builder.
ARG TARGETARCH=amd64

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bash \
        ca-certificates \
        curl \
        gawk \
        grep \
        python3 \
        unzip \
    && rm -rf /var/lib/apt/lists/*

RUN set -eux; \
        case "$TARGETARCH" in \
            amd64) vault_arch="amd64" ;; \
            arm64) vault_arch="arm64" ;; \
            *) echo "Unsupported TARGETARCH: $TARGETARCH"; exit 1 ;; \
        esac; \
        requested_version="$VAULT_VERSION"; \
        if [ "$requested_version" = "latest" ]; then \
            resolved_version=$(curl -fsSL https://checkpoint-api.hashicorp.com/v1/check/vault | python3 -c 'import json,sys; print(json.load(sys.stdin)["current_version"])'); \
        else \
            resolved_version="$requested_version"; \
        fi; \
        vault_url="https://releases.hashicorp.com/vault/${resolved_version}/vault_${resolved_version}_linux_${vault_arch}.zip"; \
        if ! curl -fsSLo /tmp/vault.zip "$vault_url"; then \
            echo "Failed to download Vault CLI from: $vault_url" >&2; \
            echo "If this version is unavailable for ${vault_arch}, build with: --build-arg VAULT_VERSION=<older_version>" >&2; \
            exit 1; \
        fi; \
    unzip /tmp/vault.zip -d /usr/local/bin; \
    rm -f /tmp/vault.zip; \
    chmod +x /usr/local/bin/vault

WORKDIR /work

COPY vault-consumption-report.sh /usr/local/bin/vault-consumption-report.sh
RUN chmod +x /usr/local/bin/vault-consumption-report.sh

ENTRYPOINT ["vault-consumption-report.sh"]