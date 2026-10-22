#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 VorynOS contributors
#
# Create a filtered, reproducible source archive from an immutable Git ref.
# Usage: bash scripts/package-source.sh <tag-or-commit> [output-directory]
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
    printf 'Usage: %s <tag-or-commit> [output-directory]\n' "$0" >&2
    exit 2
fi

ref="$1"
output_dir="${2:-dist}"
if [[ ! "$ref" =~ ^[a-zA-Z0-9][a-zA-Z0-9._/+-]*$ ]]; then
    echo 'Invalid ref name' >&2
    exit 2
fi

root="$(git rev-parse --show-toplevel)"
cd "$root"
git rev-parse --verify --quiet "${ref}^{commit}" >/dev/null || {
    echo "Unknown commit/tag: $ref" >&2
    exit 2
}

# Archive name uses the tag label, not an arbitrary filesystem path.
label="$(printf %s "$ref" | tr / -)"
mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd)"
archive="$output_dir/VorynOS-${label}-source.tar.gz"

# git archive honors export-ignore in the committed .gitattributes.
# gzip -n avoids embedding host-specific timestamps in the gzip header.
git archive --format=tar --prefix="VorynOS-${label}/" "$ref" | gzip -n -9 > "$archive"

# Guard against accidental disclosure of internal prompts.
if tar -tzf "$archive" | grep -E '/(INSTRUÇÕES[^/]*|PROMPT[^/]*|AGENTS\.md|\.github/)' ; then
    echo 'Archive contains internal development files; refusing to publish' >&2
    exit 1
fi

( cd "$output_dir" && sha256sum "$(basename "$archive")" > "$(basename "$archive").sha256" )
printf 'Created %s\n' "$archive"
