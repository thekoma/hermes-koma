#!/bin/sh
# Stage the OpenViking memory-provider plugin at the exact commit the base
# image's own plugin catalog pins. Hermes v0.21.7 moved openviking out of core:
# on boot it tries to `git clone` it from GitHub, which fails on pods with
# default-deny egress. Baking it here keeps the plugin in lockstep with the
# base image (a hermes-agent bump that moves the catalog SHA moves this too),
# with no extra Renovate pin to drift.
set -eu

CATALOG="${CATALOG:-/opt/hermes/plugin-catalog/openviking.yaml}"
DEST="${DEST:-/opt/openviking-hermes-plugin}"

field() { sed -n "s/^$1:[[:space:]]*\"\{0,1\}\([^\"]*\)\"\{0,1\}[[:space:]]*$/\1/p" "$CATALOG" | head -n1; }

REPO=$(field repo)
SHA=$(field sha)
SUBDIR=$(field subdir)
case "$SHA" in
  *[!0-9a-f]* | "") echo "install-openviking-plugin: bad sha '$SHA' in $CATALOG" >&2; exit 1 ;;
esac
[ "${#SHA}" -eq 40 ] || { echo "install-openviking-plugin: sha is not 40 chars" >&2; exit 1; }
[ -n "$REPO" ] && [ -n "$SUBDIR" ] || { echo "install-openviking-plugin: repo/subdir missing" >&2; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
git -C "$WORK" init -q
git -C "$WORK" remote add origin "$REPO"
git -C "$WORK" fetch -q --depth 1 origin "$SHA"
git -C "$WORK" checkout -q FETCH_HEAD

[ -f "$WORK/$SUBDIR/__init__.py" ] || { echo "install-openviking-plugin: no plugin at $SUBDIR" >&2; exit 1; }
rm -rf "$DEST"
mkdir -p "$DEST"
cp -R "$WORK/$SUBDIR"/. "$DEST"/
rm -rf "$DEST/tests"

# Same provenance file `hermes plugins install` writes, so Hermes treats the
# synced copy as the catalog install and never retries the migration.
cat > "$DEST/.hermes-catalog.json" <<EOF
{
  "catalog_name": "openviking",
  "repo": "$REPO",
  "sha": "$SHA",
  "tier": "community",
  "installed_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
echo "install-openviking-plugin: staged $REPO@$SHA:$SUBDIR in $DEST"
