#!/usr/bin/env bash
# Bump the claude-code pin: refetch the official manifest for <version> (or latest).
# Usage: ./update.sh [version]   then rebuild. Uses ambient curl (NixOS system certs).
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

BASE_URL="https://downloads.claude.ai/claude-code-releases"

VERSION="${1:-$(curl -fsSL "$BASE_URL/latest")}"

curl -fsSL "$BASE_URL/$VERSION/manifest.json" --output manifest.json
