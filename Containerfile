FROM debian:bookworm-slim

ARG VAULT_VERSION=1.17.3
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
    curl -fsSLo /tmp/vault.zip "https://releases.hashicorp.com/vault/${VAULT_VERSION}/vault_${VAULT_VERSION}_linux_${vault_arch}.zip"; \
    unzip /tmp/vault.zip -d /usr/local/bin; \
    rm -f /tmp/vault.zip; \
    chmod +x /usr/local/bin/vault

WORKDIR /work

COPY vault-consumption-report.sh /usr/local/bin/vault-consumption-report.sh
RUN chmod +x /usr/local/bin/vault-consumption-report.sh

ENTRYPOINT ["vault-consumption-report.sh"]