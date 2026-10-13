#!/usr/bin/env bash
# Install pinned pnpm global packages into $PNPM_HOME/bin (see Dockerfile).
# Versions are pinned in the Dockerfile ARGs and bumped by Renovate.
# Edit this list to add/remove tools — changes invalidate only this layer.
set -euo pipefail

: "${PNPM_HOME:?PNPM_HOME is required}"
: "${PNPM_VERSION:?PNPM_VERSION is required}"
: "${MCPORTER_VERSION:?MCPORTER_VERSION is required}"
: "${AGENTMEMORY_MCP_VERSION:?AGENTMEMORY_MCP_VERSION is required}"

PACKAGES=(
    "mcporter@${MCPORTER_VERSION}"
    # MCP bridge to the production agentmemory instance (AGENTMEMORY_URL);
    # the server itself runs elsewhere, so no @agentmemory/agentmemory here.
    # claude-code is NOT here on purpose: its npm package ships the 236M
    # native binary four times over — the Dockerfile bakes the single
    # official binary via the clitools stage instead.
    "@agentmemory/mcp@${AGENTMEMORY_MCP_VERSION}"
)

# Packages whose postinstall scripts MUST run.  pnpm 10+ refuses lifecycle
# scripts unless explicitly allowed.  Add entries here only if a baseline
# package above ships native bindings that fail without postinstall.
ALLOW_BUILDS=()

ALLOW_BUILD_ARGS=()
for pkg in "${ALLOW_BUILDS[@]}"; do
    ALLOW_BUILD_ARGS+=("--allow-build=$pkg")
done

# Bootstrap pnpm.  Upstream shipped corepack while it was on node 22, but as of
# node 26 (v26.5.1 in the base image) corepack is no longer bundled — it was
# unbundled in node 25 — so `corepack enable` exits 127 and takes the build with
# it.  Prefer it when present, otherwise install pnpm straight from npm; either
# way pnpm lands in /usr/local/bin.  The prefix is explicit: since v0.21.6 the
# base image installs node through `pm` and only symlinks npm into
# /usr/local/bin, so npm's default global prefix is no longer on PATH.
if command -v corepack >/dev/null 2>&1; then
    corepack enable pnpm
    corepack prepare pnpm@"${PNPM_VERSION}" --activate
else
    npm install -g --prefix /usr/local pnpm@"${PNPM_VERSION}"
fi

mkdir -p "$PNPM_HOME/bin"
pnpm add -g "${ALLOW_BUILD_ARGS[@]}" "${PACKAGES[@]}"

# --- prune dead weight from the pnpm store ---
# @agentmemory/mcp drags in @agentmemory/agentmemory (the full server) as a
# dependency, and with it onnxruntime for every platform plus the Claude
# Agent SDK's bundled 236M claude binary.  Store payloads are hardlinked
# from links/ — every link of an inode must go for bytes to be freed.
# This intentionally breaks `pnpm add -g` integrity for the pruned
# packages at runtime, which we don't support anyway (/usr/local is
# root-owned).

# Delete every hardlink of each file read from stdin, then the file itself.
prune_inodes() {
    while IFS= read -r f; do
        [ -e "$f" ] || continue
        find "$PNPM_HOME" -samefile "$f" ! -path "$f" -delete 2>/dev/null || true
        rm -f "$f"
    done
}

NODE_ARCH=$(node -p 'process.arch')   # x64 | arm64

# 1. Native blobs for platforms this image can never run.
find "$PNPM_HOME" -type f -size +5M \
    \( -path "*/darwin/*" -o -path "*/win32/*" -o -name "*.exe" \
       -o \( -path "*/linux/*" ! -path "*/linux/${NODE_ARCH}/*" \) \) \
    -print | prune_inodes

# 2. Browser-only wasm runtime — node code paths use onnxruntime-node.
find "$PNPM_HOME" -type f -size +5M -path "*onnxruntime-web*" -print | prune_inodes

# 3. The Agent SDK's bundled claude duplicates the binary the Dockerfile
#    already bakes at /usr/local/bin/claude — swap it for a symlink.
find "$PNPM_HOME" -type f -size +100M -path "*claude-agent-sdk*" -name claude \
    -print | while IFS= read -r f; do
        find "$PNPM_HOME" -samefile "$f" ! -path "$f" -delete 2>/dev/null || true
        rm -f "$f"
        ln -s /usr/local/bin/claude "$f"
done

# 4. Orphaned store payloads left behind by the pruning above.
find "$PNPM_HOME" -type f -size +5M -links 1 -delete
