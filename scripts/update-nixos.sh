#!/usr/bin/env bash
set -euo pipefail

# Script to get latest NixOS netboot file hashes from nix-community/nixos-images
# Usage: ./update-nixos.sh [version]
#   version: 25.11, unstable, etc. (default: 25.11)

VERSION="${1:-25.11}"
BASE_URL="https://github.com/nix-community/nixos-images/releases/download/nixos-${VERSION}"
MIRROR_BASE="https://dl.jakstys.lt/boot"

echo "Fetching NixOS netboot files for version: ${VERSION}" >&2

# Fetch kernel hash
KERNEL_URL="${BASE_URL}/bzImage-x86_64-linux"
echo "Downloading kernel from: $KERNEL_URL" >&2
KERNEL_HASH_B32=$(nix-prefetch-url "$KERNEL_URL" 2>/dev/null)
KERNEL_HASH_HEX=$(nix-hash --type sha256 --to-base16 "$KERNEL_HASH_B32")
KERNEL_HASH_SRI=$(nix-hash --type sha256 --to-sri "$KERNEL_HASH_HEX")

# Fetch initrd hash
INITRD_URL="${BASE_URL}/initrd-x86_64-linux"
echo "Downloading initrd from: $INITRD_URL" >&2
INITRD_HASH_B32=$(nix-prefetch-url "$INITRD_URL" 2>/dev/null)
INITRD_HASH_HEX=$(nix-hash --type sha256 --to-base16 "$INITRD_HASH_B32")
INITRD_HASH_SRI=$(nix-hash --type sha256 --to-sri "$INITRD_HASH_HEX")

echo ""
echo "Update pkgs/mrescue-nixos.nix with:"
echo ""
echo "  version = \"${VERSION}\";"
echo ""
echo "  kernel hash = \"${KERNEL_HASH_SRI}\";"
echo "  initrd hash = \"${INITRD_HASH_SRI}\";"
echo ""

# Check mirror availability
KERNEL_MIRROR="${MIRROR_BASE}/nixos-${VERSION}-bzImage-x86_64-linux"
INITRD_MIRROR="${MIRROR_BASE}/nixos-${VERSION}-initrd-x86_64-linux"

echo "Checking mirror availability..." >&2
KERNEL_EXISTS=$(curl -sI "$KERNEL_MIRROR" | head -1 | grep -q "200" && echo "yes" || echo "no")
INITRD_EXISTS=$(curl -sI "$INITRD_MIRROR" | head -1 | grep -q "200" && echo "yes" || echo "no")

if [[ "$KERNEL_EXISTS" == "no" ]] || [[ "$INITRD_EXISTS" == "no" ]]; then
  echo ""
  echo "⚠ Warning: Files not found on mirror!" >&2
  echo ""
  echo "To upload to mirror, run:" >&2
  echo ""
  if [[ "$KERNEL_EXISTS" == "no" ]]; then
    echo "  ssh fwminex sh -c 'cd /var/www/dl/boot && wget -O nixos-${VERSION}-bzImage-x86_64-linux ${KERNEL_URL}'" >&2
  fi
  if [[ "$INITRD_EXISTS" == "no" ]]; then
    echo "  ssh fwminex sh -c 'cd /var/www/dl/boot && wget -O nixos-${VERSION}-initrd-x86_64-linux ${INITRD_URL}'" >&2
  fi
  echo ""
else
  echo "✓ All files available on mirror" >&2
fi
