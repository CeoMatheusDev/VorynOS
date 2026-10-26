#!/usr/bin/env bash
# Copyright (C) 2020 - 2026 Matheus.A.Santos contributors.
# Copyright (C) 2026 VorynOS - All Rights Reserved.
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

# Reject anything that is not a plain ref name: this also rules out a leading
# '-' (so the ref can never be mistaken for an option) and any path traversal.
if [[ ! "$ref" =~ ^[a-zA-Z0-9][a-zA-Z0-9._/+-]*$ ]]; then
    echo 'Invalid ref name' >&2
    exit 2
fi

if ! root="$(git rev-parse --show-toplevel 2>/dev/null)"; then
    echo 'Not inside a Git repository' >&2
    exit 2
fi
cd -- "$root"

if ! git rev-parse --verify --quiet "${ref}^{commit}" >/dev/null; then
    echo "Unknown commit/tag: $ref" >&2
    exit 2
fi

# Archive name uses the tag label, not an arbitrary filesystem path.
label="$(printf '%s' "$ref" | tr '/' '-')"
mkdir -p -- "$output_dir"
output_dir="$(cd -- "$output_dir" && pwd)"
archive="${output_dir}/VorynOS-${label}-source.tar.gz"
checksum_file="${archive}.sha256"

# Write to a temporary file next to the destination and only move it into
# place after every check passed. A failed run never leaves a truncated
# archive under the published name.
tmp_archive="$(mktemp "${output_dir}/.VorynOS-${label}-source.XXXXXXXX")"
cleanup() {
    rm -f -- "$tmp_archive"
}
trap cleanup EXIT INT TERM

# git archive honors export-ignore in the committed .gitattributes.
# gzip -n avoids embedding host-specific timestamps in the gzip header.
git archive --format=tar --prefix="VorynOS-${label}/" "$ref" \
    | gzip -n -9 > "$tmp_archive"

# Guard against accidental disclosure of internal prompts.
#
# The listing is captured once: if `tar` fails, we abort *before* the grep,
# so a corrupted archive is never mistaken for a clean one (the `pipefail`
# interaction is the reason the two steps are not a single pipeline).
if ! archive_listing="$(tar -tzf "$tmp_archive")"; then
    echo 'Failed to list the generated archive; refusing to publish' >&2
    exit 1
fi

internal_pattern='(^|/)(internal/|\.github/|CONTRIBUTING\.md$|SECURITY\.md$|assets/branding/|INSTRUÇÕES[^/]*|PROMPT[^/]*|AGENTS\.md$)'
if printf '%s\n' "$archive_listing" | grep -Eq -- "$internal_pattern"; then
    printf '%s\n' "$archive_listing" | grep -E -- "$internal_pattern" >&2
    echo 'Archive contains internal development files; refusing to publish' >&2
    exit 1
fi

# All checks passed: publish the archive atomically and write its checksum.
mv -- "$tmp_archive" "$archive"
( cd -- "$output_dir" && sha256sum -- "$(basename "$archive")" > "$(basename "$checksum_file")" )

printf 'Created %s\n' "$archive"
printf 'Checksum %s\n' "$checksum_file"