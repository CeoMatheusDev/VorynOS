#!/usr/bin/env bash
# Copyright (C) 2020 - 2026 Matheus.A.Santos contributors.
# Copyright (C) 2026 VorynOS - All Rights Reserved.
# SPDX-License-Identifier: GPL-3.0-only
#
# Two-boot VirtIO Block test. The EFI boot image and writable test disk are
# distinct files and distinct PCI devices. The test disk is created once;
# neither Boot 2 nor this script's Boot 2 path truncates or recreates it.

set -euo pipefail

IMAGE=""
BOOT_TIMEOUT=120
for arg in "$@"; do
    case "$arg" in
        --image=*) IMAGE="${arg#--image=}" ;;
        --timeout=*) BOOT_TIMEOUT="${arg#--timeout=}" ;;
        *) echo "virtio-block-test: unknown argument: $arg" >&2; exit 2 ;;
    esac
done
[[ -n "$IMAGE" && -f "$IMAGE" ]] || { echo "virtio-block-test: --image is required" >&2; exit 2; }
command -v qemu-system-x86_64 >/dev/null || { echo "virtio-block-test: qemu-system-x86_64 is unavailable" >&2; exit 2; }
command -v timeout >/dev/null || { echo "virtio-block-test: timeout(1) is unavailable" >&2; exit 2; }

OVMF_PAIRS=(
    "${OVMF_CODE:-}:${OVMF_VARS:-}"
    "/usr/share/edk2/ovmf/OVMF_CODE.fd:/usr/share/edk2/ovmf/OVMF_VARS.fd"
    "/usr/share/edk2/ovmf/OVMF_CODE_4M.fd:/usr/share/edk2/ovmf/OVMF_VARS_4M.fd"
    "/usr/share/edk2/x64/OVMF_CODE.fd:/usr/share/edk2/x64/OVMF_VARS.fd"
    "/usr/share/edk2-ovmf/OVMF_CODE.fd:/usr/share/edk2-ovmf/OVMF_VARS.fd"
    "/usr/share/OVMF/OVMF_CODE.fd:/usr/share/OVMF/OVMF_VARS.fd"
    "/usr/share/OVMF/OVMF_CODE_4M.fd:/usr/share/OVMF/OVMF_VARS_4M.fd"
    "/usr/share/qemu/OVMF_CODE.fd:/usr/share/qemu/OVMF_VARS.fd"
)
OVMF_CODE_PATH=""
OVMF_VARS_PATH=""
for pair in "${OVMF_PAIRS[@]}"; do
    code="${pair%%:*}"
    vars="${pair#*:}"
    if [[ -n "$code" && -f "$code" && -n "$vars" && -f "$vars" ]]; then
        OVMF_CODE_PATH="$code"
        OVMF_VARS_PATH="$vars"
        break
    fi
done
if [[ -z "$OVMF_CODE_PATH" ]]; then
    for root in /usr/share /usr/lib /usr/local/share /opt; do
        [[ -d "$root" ]] || continue
        code="$(find "$root" -maxdepth 5 -type f -name OVMF_CODE.fd -print -quit 2>/dev/null || true)"
        [[ -n "$code" ]] || continue
        vars="${code/OVMF_CODE/OVMF_VARS}"
        [[ -f "$vars" ]] || continue
        OVMF_CODE_PATH="$code"
        OVMF_VARS_PATH="$vars"
        break
    done
fi
[[ -n "$OVMF_CODE_PATH" ]] || { echo "virtio-block-test: no OVMF CODE/VARS pair found" >&2; exit 2; }

format_of() { [[ "$1" == *.qcow2 ]] && echo qcow2 || echo raw; }
CODE_FORMAT="$(format_of "$OVMF_CODE_PATH")"
VARS_FORMAT="$(format_of "$OVMF_VARS_PATH")"
WORK="$(mktemp -d)"
QEMU_PID=""
cleanup() {
    if [[ -n "$QEMU_PID" ]] && kill -0 "$QEMU_PID" 2>/dev/null; then
        kill "$QEMU_PID" 2>/dev/null || true
        wait "$QEMU_PID" 2>/dev/null || true
    fi
    rm -rf "$WORK"
}
trap cleanup EXIT

BOOT_IMAGE="$WORK/boot-image.img"
DATA_DISK="$WORK/virtio-data.img"
cp "$IMAGE" "$BOOT_IMAGE"
# This is the only creation/zero-initialization of the disposable data disk.
truncate -s 16M "$DATA_DISK"
python3 - "$DATA_DISK" <<'PY'
import pathlib, sys
with pathlib.Path(sys.argv[1]).open("r+b") as disk:
    disk.write(b"VORYNBLKTEST0001")
    disk.flush()
PY
DATA_DISK_INODE="$(stat -c %i "$DATA_DISK")"

fail_with_log() {
    local stage="$1" reason="$2"
    echo "FAIL: $stage: $reason" >&2
    if [[ -f "$WORK/$stage.serial" ]]; then
        echo "----- $stage serial -----" >&2
        cat "$WORK/$stage.serial" >&2
        echo "-------------------------" >&2
    fi
    if [[ -f "$WORK/$stage.qemu.err" ]]; then cat "$WORK/$stage.qemu.err" >&2; fi
    exit 1
}
require_line() {
    local stage="$1" needle="$2"
    grep -qF -- "$needle" "$WORK/$stage.serial" || fail_with_log "$stage" "missing assertion: $needle"
}

run_boot() {
    local stage="$1"
    local monitor="$WORK/$stage.monitor"
    local serial="$WORK/$stage.serial"
    local qemu_err="$WORK/$stage.qemu.err"
    local vars="$WORK/$stage.vars.fd"
    cp "$OVMF_VARS_PATH" "$vars"

    echo "virtio-block-test: starting $stage with dedicated disk $DATA_DISK"
    timeout --signal=TERM --kill-after=5s "$BOOT_TIMEOUT" qemu-system-x86_64 \
        -machine q35 -m 256 -smp 1 \
        -drive "file=$BOOT_IMAGE,format=raw,if=none,id=boot-disk" \
        -device "virtio-blk-pci,drive=boot-disk,disable-legacy=on,bootindex=1" \
        -drive "file=$DATA_DISK,format=raw,if=none,id=test-data-disk,cache=writeback" \
        -device "virtio-blk-pci,drive=test-data-disk,disable-legacy=on" \
        -drive "if=pflash,format=$CODE_FORMAT,readonly=on,file=$OVMF_CODE_PATH" \
        -drive "if=pflash,format=$VARS_FORMAT,file=$vars" \
        -serial "file:$serial" \
        -monitor "unix:$monitor,server=on,wait=off" \
        -display none -no-reboot \
        >/dev/null 2>"$qemu_err" &
    QEMU_PID=$!

    local ready=0
    for _ in $(seq 1 600); do
        if [[ -s "$serial" ]] && grep -qF "VORYN-KERNEL-READY" "$serial"; then
            ready=1
            break
        fi
        if ! kill -0 "$QEMU_PID" 2>/dev/null; then
            local status=0
            wait "$QEMU_PID" || status=$?
            QEMU_PID=""
            fail_with_log "$stage" "QEMU exited before the ready marker (status $status)"
        fi
        sleep 0.2
    done
    [[ "$ready" -eq 1 ]] || fail_with_log "$stage" "external timeout waiting for VORYN-KERNEL-READY"

    # HMP quit closes QEMU normally, allowing the block backend to commit its
    # host-side cache. The guest must already have completed FLUSH before this.
    python3 - "$monitor" <<'PY' || fail_with_log "$stage" "could not request controlled QEMU shutdown"
import socket, sys, time
path = sys.argv[1]
last = None
for _ in range(50):
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as monitor:
            monitor.settimeout(2)
            monitor.connect(path)
            try:
                monitor.recv(4096)
            except TimeoutError:
                pass
            monitor.sendall(b"quit\n")
        break
    except OSError as error:
        last = error
        time.sleep(0.1)
else:
    raise SystemExit(f"monitor connection failed: {last}")
PY
    local status=0
    wait "$QEMU_PID" || status=$?
    QEMU_PID=""
    [[ "$status" -eq 0 ]] || fail_with_log "$stage" "QEMU did not exit cleanly (status $status)"
    [[ "$(stat -c %i "$DATA_DISK")" == "$DATA_DISK_INODE" ]] || fail_with_log "$stage" "data disk file was replaced"
}

verify_device_and_queue() {
    local stage="$1"
    require_line "$stage" "[VNK] vvdi: selected modern virtio-blk"
    require_line "$stage" "[VNK] vvdi: modern device detected"
    require_line "$stage" "virtqueue 0 enabled"
    require_line "$stage" "DRIVER_OK status=0xf"
    grep -Eq '\\[VNK\\] vvdi: 00:[0-9]+\\.0 block I/O ready sectors=[1-9][0-9]* sector_size=512 flush=1$' "$WORK/$stage.serial" ||
        fail_with_log "$stage" "dedicated VirtIO Block geometry/FLUSH assertion missing"
    require_line "$stage" "storage-test signature recognized on dedicated data disk"
    require_line "$stage" "VORYN-KERNEL-READY"
}

run_boot boot1
verify_device_and_queue boot1
require_line boot1 "storage-test phase=boot1"
require_line boot1 "storage write completed lba=64 bytes=512"
require_line boot1 "storage FLUSH completed lba=64"
require_line boot1 "storage read completed lba=64 bytes=512"
require_line boot1 "storage data compare verified bytes=512"
if grep -qF "storage persistence confirmed" "$WORK/boot1.serial"; then
    fail_with_log boot1 "Boot 1 claimed persistence before restart"
fi

echo "virtio-block-test: Boot 1 write, FLUSH, read and byte comparison passed"

# Do not truncate, zero, copy, or recreate DATA_DISK after this point.
run_boot boot2
verify_device_and_queue boot2
require_line boot2 "storage-test phase=boot2"
require_line boot2 "storage read completed lba=64 bytes=512"
require_line boot2 "storage data compare verified bytes=512"
require_line boot2 "storage persistence confirmed boot=2 lba=64 bytes=512"
if grep -qF "storage write completed" "$WORK/boot2.serial" || grep -qF "storage FLUSH completed" "$WORK/boot2.serial"; then
    fail_with_log boot2 "Boot 2 rewrote the payload instead of proving persistence"
fi

echo "virtio-block-test: PASS — byte-for-byte persistence proven across two QEMU/OVMF boots"
