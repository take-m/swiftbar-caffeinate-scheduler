#!/bin/bash
#
# Check that version numbers agree across the repository.
#
#   ./tests/test_version.sh
#
# Compares the <xbar.version> in the plugin header against the newest released
# heading in CHANGELOG.md. When run on a tag in CI it also checks the tag name,
# which is the mistake that actually costs something: publishing v1.2.0 while
# the plugin still tells SwiftBar it is v1.1.0.
#
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$SCRIPT_DIR/.."
PLUGIN="$ROOT/caffeinate-scheduler.30s.sh"
CHANGELOG="$ROOT/CHANGELOG.md"

FAIL=0

fail() {
    printf '  FAIL  %s\n' "$1" >&2
    FAIL=$((FAIL + 1))
}

ok() {
    printf '  ok    %s\n' "$1"
}

# v1.2.3 -> 1.2.3
plugin_version="$(sed -n 's|^# <xbar\.version>v\{0,1\}\(.*\)</xbar\.version>.*|\1|p' "$PLUGIN")"
if [ -z "$plugin_version" ]; then
    fail "no <xbar.version> found in $(basename "$PLUGIN")"
else
    ok "plugin header: $plugin_version"
fi

# The first "## [x.y.z]" heading that is not [Unreleased]
changelog_version="$(sed -n 's|^## \[\([0-9][^]]*\)\].*|\1|p' "$CHANGELOG" | head -n 1)"
if [ -z "$changelog_version" ]; then
    fail "no released version heading found in CHANGELOG.md"
else
    ok "changelog:     $changelog_version"
fi

if [ -n "$plugin_version" ] && [ -n "$changelog_version" ] &&
    [ "$plugin_version" != "$changelog_version" ]; then
    fail "plugin header ($plugin_version) and CHANGELOG ($changelog_version) disagree"
fi

# CHANGELOG headings must be newest first.
previous=""
while IFS= read -r version; do
    if [ -n "$previous" ]; then
        newest="$(printf '%s\n%s\n' "$previous" "$version" | sort -rV | head -n 1)"
        if [ "$newest" != "$previous" ]; then
            fail "CHANGELOG is not in descending order ($previous before $version)"
        fi
    fi
    previous="$version"
done <<EOF
$(sed -n 's|^## \[\([0-9][^]]*\)\].*|\1|p' "$CHANGELOG")
EOF

# On a tag build, the tag has to match too.
if [ "${GITHUB_REF_TYPE:-}" = "tag" ]; then
    tag="${GITHUB_REF_NAME:-}"
    tag="${tag#v}"
    if [ "$tag" != "$plugin_version" ]; then
        fail "tag ($tag) and plugin header ($plugin_version) disagree"
    else
        ok "tag:           $tag"
    fi
fi

if [ "$FAIL" -ne 0 ]; then
    printf '\n%d failed\n' "$FAIL" >&2
    exit 1
fi

echo
echo "versions consistent"
