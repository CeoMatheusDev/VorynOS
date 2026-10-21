#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 VorynOS contributors
#
# VorynOS automated boot test.
#
# Boots the generated EFI system partition image in QEMU with the OVMF
# firmware, captures the serial console and verifies that the boot chain
# reaches the kernel.
#
# The test is part of the automated pipeline: `zig build qemu-test`.
#
# Usage: qemu-boot-test.sh --image=<path> [--timeout=<seconds>]

set -euo pipefail

IMAGE=""
TIMEOUT=25

for argument in "$@"; do
    case "$argument" in
        --image=*) IMAGE="${argument#--image=}" ;;
        --timeout=*) TIMEOUT="${argument#--timeout=}" ;;
        *)
            echo "qemu-boot-test: unknown argument: $argument" >&2
            exit 2
            ;;
    esac
done

if [[ -z "$IMAGE" ]]; then
    echo "qemu-boot-test: --image is required" >&2
    exit 2
fi

if [[ ! -f "$IMAGE" ]]; then
    echo "qemu-boot-test: image not found: $IMAGE" >&2
    exit 2
fi

# --- locate the firmware ----------------------------------------------------

OVMF_CANDIDATES=(
    "${OVMF_CODE:-}"
    /usr/share/edk2/ovmf/OVMF_CODE.fd
    /usr/share/edk2/x64/OVMF_CODE.fd
    /usr/share/edk2-ovmf/OVMF_CODE.fd
    /usr/share/OVMF/OVMF_CODE.fd
    /usr/share/qemu/OVMF_CODE.fd
)

OVMF_VARS_CANDIDATES=(
    "${OVMF_VARS:-}"
    /usr/share/edk2/ovmf/OVMF_VARS.fd
    /usr/share/edk2/x64/OVMF_VARS.fd
    /usr/share/edk2-ovmf/OVMF_VARS.fd
    /usr/share/OVMF/OVMF_VARS.fd
    /usr/share/qemu/OVMF_VARS.fd
)

find_first() {
    for candidate in "$@"; do
        if [[ -n "$candidate" && -f "$candidate" ]]; then
            echo "$candidate"
            return 0
        fi
    done
    return 1
}

if ! OVMF_CODE_PATH="$(find_first "${OVMF_CANDIDATES[@]}")"; then
    echo "qemu-boot-test: no OVMF firmware found, set OVMF_CODE" >&2
    exit 2
fi

if ! OVMF_VARS_PATH="$(find_first "${OVMF_VARS_CANDIDATES[@]}")"; then
    echo "qemu-boot-test: no OVMF variable store found, set OVMF_VARS" >&2
    exit 2
fi

if ! command -v qemu-system-x86_64 >/dev/null 2>&1; then
    echo "qemu-boot-test: qemu-system-x86_64 is not installed" >&2
    exit 2
fi

# --- run --------------------------------------------------------------------

WORK_DIRECTORY="$(mktemp -d)"
trap 'rm -rf "$WORK_DIRECTORY"' EXIT

SERIAL_LOG="$WORK_DIRECTORY/serial.log"
cp "$OVMF_VARS_PATH" "$WORK_DIRECTORY/vars.fd"

echo "qemu-boot-test: booting $IMAGE (firmware: $OVMF_CODE_PATH)"

set +e
timeout --signal=TERM "$TIMEOUT" qemu-system-x86_64 \
    -machine q35 \
    -m 256 \
    -smp 1 \
    -drive "file=$IMAGE,format=raw,if=virtio" \
    -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE_PATH" \
    -drive "if=pflash,format=raw,file=$WORK_DIRECTORY/vars.fd" \
    -serial "file:$SERIAL_LOG" \
    -display none \
    -no-reboot \
    >/dev/null 2>&1
QEMU_STATUS=$?
set -e

# A timeout is the expected outcome, the kernel halts and never exits.
if [[ $QEMU_STATUS -ne 0 && $QEMU_STATUS -ne 124 ]]; then
    echo "qemu-boot-test: qemu exited with status $QEMU_STATUS" >&2
fi

echo "----- serial console -----"
cat "$SERIAL_LOG"
echo "-------------------------"

# --- verify -----------------------------------------------------------------

FAILURES=0

require_marker() {
    local marker="$1"
    if grep -qF -- "$marker" "$SERIAL_LOG"; then
        echo "ok: found '$marker'"
    else
        echo "FAIL: missing '$marker'" >&2
        FAILURES=$((FAILURES + 1))
    fi
}

require_marker "[VNB] VorynOS"
require_marker "[VNB] kernel placed"
require_marker "[VNK] Voryn Nucleus Kernel"
require_marker "[VNK] handoff ok"
require_marker "[VNK] segments: gdt installed and verified"
require_marker "[VNK] interrupts: idt installed and verified"
require_marker "[VNK] segments: task state segment loaded"
require_marker "[VNK] paging: cr3"
require_marker "[VNK] timer:"
require_marker "[VNK] tasks: 4 created"
require_marker "[VNK] tasks: 3 ready"
require_marker "[VNK] tasks: switch cost"
require_marker "[VNK] framebuffer: write probe succeeded"
require_marker "[VNK] syscall: instruction installed and verified"
require_marker "[VNK] syscall 1 argument 0xf00d from user"
require_marker "[VNK] user: the program of the user mode wrote 0x5a5a1234 in its page"
require_marker "[VNK] user: the result of the call came back, 0x42"
require_marker "VORYN-KERNEL-READY"
require_marker "[VNK] self test: the handler returned 0x42"
require_marker "[VNK] EXCEPTION 6: invalid opcode"

if grep -qF "FATAL" "$SERIAL_LOG"; then
    echo "FAIL: the boot chain reported a fatal error" >&2
    FAILURES=$((FAILURES + 1))
fi

if [[ $FAILURES -ne 0 ]]; then
    echo "qemu-boot-test: $FAILURES check(s) failed" >&2
    exit 1
fi

echo "qemu-boot-test: all checks passed"
