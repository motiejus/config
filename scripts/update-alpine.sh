#!/usr/bin/env bash
set -euo pipefail

# Script to get latest Alpine version and hash
# Usage: ./update-alpine.sh

# Get the latest Alpine version by checking the releases page
# Alpine versions are in format like "3.23.2" under v3.23 directory
LATEST_MINOR=$(curl -s https://dl-cdn.alpinelinux.org/alpine/ | \
    grep -oP 'v\d+\.\d+' | \
    sort -V | \
    tail -n1)

if [[ -z "$LATEST_MINOR" ]]; then
    echo "Error: Could not determine latest Alpine minor version" >&2
    exit 1
fi

# Get the latest patch version from that minor version
VERSION=$(curl -s "https://dl-cdn.alpinelinux.org/alpine/${LATEST_MINOR}/releases/x86_64/" | \
    grep -oP 'alpine-netboot-\K[\d.]+(?=-x86_64\.tar\.gz)' | \
    sort -V | \
    tail -n1)

if [[ -z "$VERSION" ]]; then
    echo "Error: Could not determine latest Alpine version" >&2
    exit 1
fi

# Download the .sha256 checksum file
CHECKSUM_URL="https://dl-cdn.alpinelinux.org/alpine/${LATEST_MINOR}/releases/x86_64/alpine-netboot-${VERSION}-x86_64.tar.gz.sha256"
HASH_HEX=$(curl -s "$CHECKSUM_URL" | awk '{print $1}')

if [[ -z "$HASH_HEX" ]]; then
    echo "Error: Could not download checksum from $CHECKSUM_URL" >&2
    exit 1
fi

# Convert hex hash to SRI format
HASH_SRI=$(nix-hash --type sha256 --to-sri "$HASH_HEX")

# Output version and hash
echo "version: $VERSION"
echo "hash: $HASH_SRI"
echo ""

# Check mirror availability
echo "Checking mirror availability..." >&2
MIRROR_URL="https://dl.jakstys.lt/boot/alpine-netboot-${VERSION}-x86_64.tar.gz"
if curl -sI "$MIRROR_URL" | head -1 | grep -q "200"; then
  echo "✓ File available on mirror" >&2
else
  echo "⚠ Warning: File not found on mirror!" >&2
  echo ""
  echo "To upload to mirror, run:" >&2
  echo "  ssh fwminex sh -c 'cd /var/www/dl/boot && wget https://dl-cdn.alpinelinux.org/alpine/${LATEST_MINOR}/releases/x86_64/alpine-netboot-${VERSION}-x86_64.tar.gz'" >&2
  echo ""
fi
