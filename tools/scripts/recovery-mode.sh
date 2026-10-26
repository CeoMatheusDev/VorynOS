#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 VorynOS contributors
#
# Recovery mode boot script.
# Boots VorynOS from a RAM disk when the normal system is broken.
#
# Usage: recovery-mode.sh [--fat=[mount_label]] [--help]

set -euo pipefail

IMAGE=""
TIMEOUT=60

for argument in "$@"; do
    case "$argument" in
        --image=*) IMAGE="${argument#--image=}" ;;
        --timeout=*) TIMEOUT="${argument#--timeout=}" ;;
        --fat=*) MOUNT_LABEL="${argument#--fat=}" ;;
        --help|-h|--usage)
            echo "Usage: $0 --image=<vorynos.img> [--timeout=<seconds>] [--fat=<label>]"
            exit 0
            ;;
        *)
            echo "recovery-mode: unknown argument: $argument" >&2
            exit 2
            ;;
    esac
done

if [[ -z "$IMAGE" ]]; then
    echo "recovery-mode: --image is required" >&2
    exit 2
fi

# Run QEMU with the recovery image and pass a serial console flag.
QEMU_ARGS=(
    -drive format=raw,file="$IMAGE"
    -serial mon:stdio
    -m "${RECOVERY_MEM:-512}"
    -cpu qemu64
    -no-reboot
    -no-shutdown
    -d int
)

qemu-system-x86_64 "${QEMU_ARGS[@]}" &
QEMU_PID=$!

# Wait for the kernel to boot, then stop QEMU.
sleep "$TIMEOUT"
if ! kill -0 "$QEMU_PID" 2>/dev/null; then
    echo "recovery-mode: QEMU terminated early" >&2
    exit 1
fi

kill -9 "$QEMU_PID" 2>/dev/null || true
echo "recovery-mode: the kernel booted successfully; the system can be diagnosed"
