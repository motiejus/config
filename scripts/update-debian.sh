#!/usr/bin/env bash
set -euo pipefail

# Script to generate updated Debian Live package definition
# Usage: ./update-debian.sh <flavor>
#   flavor: standard, xfce, kde, gnome, etc.

SHA256SUMS_URL="https://cdimage.debian.org/debian-cd/current-live/amd64/iso-hybrid/SHA256SUMS"

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 <flavor>" >&2
    echo "  flavor: standard, xfce, kde, gnome, etc." >&2
    exit 1
fi

FLAVOR="$1"

# Download SHA256SUMS file
SHA256SUMS_CONTENT=$(curl -s "$SHA256SUMS_URL")

if [[ -z "$SHA256SUMS_CONTENT" ]]; then
    echo "Error: Could not download SHA256SUMS file" >&2
    exit 1
fi

# Extract version from any filename in SHA256SUMS
VERSION=$(echo "$SHA256SUMS_CONTENT" | \
    grep -oP 'debian-live-\K[\d.]+(?=-amd64-\w+\.iso)' | \
    head -n1)

if [[ -z "$VERSION" ]]; then
    echo "Error: Could not determine Debian version from SHA256SUMS" >&2
    exit 1
fi

# Extract hash from SHA256SUMS for this flavor
ISO_FILENAME="debian-live-${VERSION}-amd64-${FLAVOR}.iso"
HASH_HEX=$(echo "$SHA256SUMS_CONTENT" | \
    grep " ${ISO_FILENAME}$" | \
    awk '{print $1}')

if [[ -z "$HASH_HEX" ]]; then
    echo "Error: Could not find hash for $ISO_FILENAME in SHA256SUMS" >&2
    echo "" >&2
    echo "Available ISOs:" >&2
    echo "$SHA256SUMS_CONTENT" | grep '\.iso$' | sed 's/^/  /' >&2
    exit 1
fi

# Convert hex hash to SRI format
HASH_SRI=$(nix-hash --type sha256 --to-sri "$HASH_HEX")

# Output the Nix code block
cat <<EOF
          mrescue-debian-${FLAVOR} = mkDebianLive {
            flavor = "${FLAVOR}";
            version = "${VERSION}";
            hash = "${HASH_SRI}";
          };
EOF
