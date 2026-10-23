# syntax=docker/dockerfile:1.7
# Hermes Agent image with k8s + MCP toolbelt baked on top of upstream.

# Global ARG — must be declared before the first FROM so subsequent FROM
# directives can substitute it.  See: https://docs.docker.com/reference/dockerfile/#scope
# Pinned by digest so the image only rebuilds when upstream actually moves:
# Renovate opens a digest PR when `latest` changes, its merge triggers the build.
# renovate: datasource=docker depName=nousresearch/hermes-agent versioning=docker
ARG HERMES_VERSION=latest@sha256:9c5561579f3ffdf333401797094ac3a743738d6c25d40f4331c7bf77b694238d

# ---------- Stage 1: Go MCP servers ----------
FROM golang:1.26-alpine AS gobuilder

# renovate: datasource=github-releases depName=grafana/mcp-grafana
ARG MCP_GRAFANA_VERSION=v0.17.2
# renovate: datasource=github-releases depName=hashicorp/vault-mcp-server
ARG VAULT_MCP_SERVER_VERSION=v0.2.0

WORKDIR /go
ENV CGO_ENABLED=0
RUN apk add --no-cache git make bash

RUN go install github.com/grafana/mcp-grafana/cmd/mcp-grafana@${MCP_GRAFANA_VERSION}

# Upstream's Makefile sets GOARCH=$(uname -m), which on aarch64 hosts
# becomes "aarch64" — invalid in Go's GOOS/GOARCH (Go uses "arm64").
# `go install` honours the buildx-provided TARGETARCH automatically.
RUN go install github.com/hashicorp/vault-mcp-server/cmd/vault-mcp-server@${VAULT_MCP_SERVER_VERSION}

RUN ls -altr /go/bin

# ---------- Stage 2: CLI release binaries (downloaded, stripped) ----------
FROM debian:trixie-slim AS clitools

# renovate: datasource=github-releases depName=argoproj/argo-cd
ARG ARGOCD_VERSION=v3.5.6
# renovate: datasource=github-releases depName=helm/helm
ARG HELM_VERSION=v4.3.1
# renovate: datasource=github-releases depName=kubernetes/kubernetes
ARG KUBECTL_VERSION=v1.35.1
# renovate: datasource=npm depName=@anthropic-ai/claude-code
ARG CLAUDE_CODE_VERSION=2.1.309
# Provided by buildx: amd64|arm64 — matches the target platform.
ARG TARGETARCH

RUN apt-get update && \
    apt-get install -yq --no-install-recommends ca-certificates curl binutils

COPY scripts/install-clitools.sh /tmp/install-clitools.sh
RUN ARGOCD_VERSION="$ARGOCD_VERSION" \
    HELM_VERSION="$HELM_VERSION" \
    KUBECTL_VERSION="$KUBECTL_VERSION" \
    CLAUDE_CODE_VERSION="$CLAUDE_CODE_VERSION" \
    ARCH="$TARGETARCH" \
    /tmp/install-clitools.sh

# ---------- Stage 3: hermes base + extra tools ----------
# HERMES_VERSION is declared globally above; ${HERMES_VERSION} substitutes here.
FROM nousresearch/hermes-agent:${HERMES_VERSION}

USER root

# --- apt packages (shell QoL on top of upstream's set) ---
COPY scripts/install-system-pkgs.sh /tmp/scripts/install-system-pkgs.sh
RUN /tmp/scripts/install-system-pkgs.sh

# --- pinned CLI binaries from the clitools stage ---
COPY --from=clitools /out/argocd  /usr/local/bin/argocd
COPY --from=clitools /out/helm    /usr/local/bin/helm
COPY --from=clitools /out/kubectl /usr/local/bin/kubectl
COPY --from=clitools /out/claude  /usr/local/bin/claude
# The baked claude binary is root-owned; don't let it try to self-update.
ENV DISABLE_AUTOUPDATER=1

# --- Go MCP server binaries from the gobuilder stage ---
COPY --from=gobuilder /go/bin/mcp-grafana       /usr/local/bin/mcp-grafana
COPY --from=gobuilder /go/bin/vault-mcp-server  /usr/local/bin/vault-mcp-server

# --- pipx + pnpm globals ---
ENV PIPX_HOME=/opt/pipx
ENV PIPX_BIN_DIR=/usr/local/bin
ENV PIP_NO_CACHE_DIR=1
ENV PNPM_HOME=/usr/local/share/pnpm
ENV PATH="$PNPM_HOME/bin:$PATH"

# renovate: datasource=npm depName=pnpm
ARG PNPM_VERSION=11.22.0
# renovate: datasource=npm depName=mcporter
ARG MCPORTER_VERSION=0.13.7
# renovate: datasource=npm depName=@agentmemory/mcp
ARG AGENTMEMORY_MCP_VERSION=0.9.30

COPY scripts/install-global-pnpm.sh /tmp/scripts/install-global-pnpm.sh
RUN apt-get update && \
    apt-get install -yq --no-install-recommends pipx && \
    mkdir -p "$PIPX_HOME" && \
    PNPM_VERSION="$PNPM_VERSION" \
    MCPORTER_VERSION="$MCPORTER_VERSION" \
    AGENTMEMORY_MCP_VERSION="$AGENTMEMORY_MCP_VERSION" \
    /tmp/scripts/install-global-pnpm.sh && \
    chown -R 10000:10000 "$PNPM_HOME" "$PIPX_HOME" && \
    # corepack/pnpm download+metadata caches are build-time junk; the global
    # store under $PNPM_HOME (hardlink source) must stay.
    rm -rf /root/.cache /tmp/node-compile-cache \
        /var/lib/apt/lists/* /var/cache/apt/archives/*

# --- agentmemory hermes plugin (pure-stdlib Python, no deps) ---
# Staged in the image; HERMES_HOME lives on a volume, so activate it with:
#   cp -r /opt/agentmemory-hermes-plugin $HERMES_HOME/plugins/agentmemory
# plus `memory.provider: agentmemory` in config.yaml (see its README).
# renovate: datasource=github-tags depName=rohitg00/agentmemory
ARG AGENTMEMORY_VERSION=v0.9.30
ADD --chown=10000:10000 \
    https://github.com/rohitg00/agentmemory.git#${AGENTMEMORY_VERSION}:integrations/hermes \
    /opt/agentmemory-hermes-plugin
# Boot-time sync of the plugin into the $HERMES_HOME volume (s6 cont-init).
COPY --chmod=0755 scripts/cont-init.d/03-agentmemory-plugin /etc/cont-init.d/03-agentmemory-plugin

# --- openviking memory plugin, at the commit the base image's catalog pins ---
# hermes-agent v0.21.7 moved it out of core and clones it from GitHub at boot,
# which fails on pods with default-deny egress (GLaDOS). No separate Renovate
# pin: the SHA comes from /opt/hermes/plugin-catalog/openviking.yaml, so it
# moves with the base digest.
COPY --chmod=0755 scripts/install-openviking-plugin.sh /tmp/scripts/install-openviking-plugin.sh
RUN /tmp/scripts/install-openviking-plugin.sh && \
    chown -R 10000:10000 /opt/openviking-hermes-plugin
COPY --chmod=0755 scripts/cont-init.d/04-openviking-plugin /etc/cont-init.d/04-openviking-plugin

# Cleanup our staging dir.
RUN rm -rf /tmp/scripts

# Convenience alias only.  /opt/data is the hermes user's real home per
# /etc/passwd and is what main-wrapper.sh exports as $HOME; this symlink just
# gives it a name a human expects to find.  Nothing depends on it, and it is a
# harmless dangling link when the volume is absent.
RUN ln -sfn /opt/data /home/hermes

# IMPORTANT: do not redefine ENTRYPOINT, CMD or USER.
#
# Upstream sets ENTRYPOINT ["/opt/hermes/docker/entrypoint-dispatch.sh"] and
# CMD [].  The dispatcher delegates to s6-overlay's /init when it is PID 1 (and
# warns + runs an unsupervised fallback when it is not), /init runs the
# /etc/cont-init.d scripts as root, and main-wrapper.sh finally drops to the
# hermes user with s6-setuidgid.  Our kubernetes manifest passes
# `args: ["gateway", "run"]` at runtime.
#
# The image therefore MUST stay root at boot: stage2-hook.sh needs privileges
# to usermod/chown the data volume, and main-wrapper.sh hard-fails (exit 1) on
# any uid that is neither root nor hermes.  A trailing `USER hermes` here — or
# a runAsUser in Kubernetes — stops the container from starting.  To control
# ownership of the volume, pass HERMES_UID/HERMES_GID (or PUID/PGID) instead.
