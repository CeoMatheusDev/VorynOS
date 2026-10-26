#!/usr/bin/env bash
# Copyright (C) 2020 - 2026 Matheus.A.Santos contributors.
# Copyright (C) 2026 VorynOS - All Rights Reserved.
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 VorynOS contributors
#
# Boots the VorynOS image in QEMU with an interactive serial console.
#
# Usage: qemu-run.sh --image=<path> [--memory=<MiB>]

set -euo pipefail

IMAGE=""
MEMORY=256

show_usage() {
    cat <<EOF
Usage: $0 --image=<path> [--memory=<MiB>]

  --image=PATH    raw disk image to boot (required)
  --memory=MiB    guest memory in MiB (default: 256)
  --help, -h      show this message
EOF
}

for argument in "$@"; do
    case "$argument" in
        --image=*)  IMAGE="${argument#--image=}" ;;
        --memory=*) MEMORY="${argument#--memory=}" ;;
        --help|-h)  show_usage; exit 0 ;;
        *)
            echo "qemu-run: unknown argument: $argument" >&2
            show_usage >&2
            exit 2
            ;;
    esac
done

if [[ -z "$IMAGE" ]]; then
    echo "qemu-run: --image is required" >&2
    show_usage >&2
    exit 2
fi

if ! command -v qemu-system-x86_64 >/dev/null 2>&1; then
    echo "qemu-run: qemu-system-x86_64 not found in PATH" >&2
    exit 2
fi

OVMF_CODE_CANDIDATES=(
    "${OVMF_CODE:-}"
    /usr/share/edk2/ovmf/OVMF_CODE.fd
    /usr/share/edk2/x64/OVMF_CODE.fd
    /usr/share/OVMF/OVMF_CODE.fd
    /usr/share/qemu/OVMF_CODE.fd
)

OVMF_VARS_CANDIDATES=(
    "${OVMF_VARS:-}"
    /usr/share/edk2/ovmf/OVMF_VARS.fd
    /usr/share/edk2/x64/OVMF_VARS.fd
    /usr/share/OVMF/OVMF_VARS.fd
    /usr/share/qemu/OVMF_VARS.fd
)

find_first() {
    local candidate
    for candidate in "$@"; do
        if [[ -n "$candidate" && -f "$candidate" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

if ! OVMF_CODE_PATH="$(find_first "${OVMF_CODE_CANDIDATES[@]}")"; then
    echo "qemu-run: no OVMF firmware found, set OVMF_CODE" >&2
    exit 2
fi

if ! OVMF_VARS_PATH="$(find_first "${OVMF_VARS_CANDIDATES[@]}")"; then
    echo "qemu-run: no OVMF variable store found, set OVMF_VARS" >&2
    exit 2
fi

WORK_DIRECTORY="$(mktemp -d)"

# The trap must cover signals as well as the normal exit; otherwise a Ctrl+C
# can leave the temporary variable store behind.
cleanup() {
    rm -rf -- "$WORK_DIRECTORY"
}
trap cleanup EXIT INT TERM

cp -- "$OVMF_VARS_PATH" "$WORK_DIRECTORY/vars.fd"

echo "qemu-run: booting $IMAGE"
echo "qemu-run: press Ctrl+a x to quit the emulator"

# Do not use `exec` here: `exec` replaces the shell and the EXIT trap above
# would never run, leaking the temporary directory. Running QEMU in the
# foreground and letting the script return on its own keeps the cleanup.
qemu-system-x86_64 \
    -machine q35 \
    -m "$MEMORY" \
    -smp 1 \
    -drive "file=$IMAGE,format=raw,if=virtio" \
    -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE_PATH" \
    -drive "if=pflash,format=raw,file=$WORK_DIRECTORY/vars.fd" \
    -serial stdio \
    -display none \
    -no-reboot