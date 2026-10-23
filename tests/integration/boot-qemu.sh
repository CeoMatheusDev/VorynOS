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
TIMEOUT=60

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
#
# The QEMU firmware is looked for in three places: the environment variables,
# the known file pairs of the distributions, and a search of the file system.
# The search exists because the reference distribution of the test
# environment may install the firmware in a path that the project does not
# know, and a test that fails because of a path is not a test: it is an
# environment failure.
#
# Each pair is "code:variables", and the pair has to be coherent: the
# firmware of four megabytes comes with the variables file of four
# megabytes, and the one of two megabytes with the one of two megabytes.
#
# The format of each file comes from its name, and the QEMU accepts
# different formats in the two flash devices: a code of four megabytes in
# qcow2 with the variables in raw works.

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

# The roots searched when none of the known paths has the firmware.
OVMF_SEARCH_ROOTS=("/usr/share" "/usr/lib" "/usr/local/share" "/opt")

# The format of a firmware file, from its name.
format_of() {
    case "$1" in
        *.qcow2) echo "qcow2" ;;
        *) echo "raw" ;;
    esac
}

# The first file with the given name, in the known roots.
search_file() {
    local name="$1"
    local root found
    for root in "${OVMF_SEARCH_ROOTS[@]}"; do
        [[ -d "$root" ]] || continue
        found="$(find "$root" -maxdepth 5 -type f -name "$name" 2>/dev/null | sort | head -1)"
        if [[ -n "$found" ]]; then
            echo "$found"
            return 0
        fi
    done
    return 1
}

OVMF_CODE_PATH=""
OVMF_VARS_PATH=""

for pair in "${OVMF_PAIRS[@]}"; do
    code="${pair%%:*}"
    vars="${pair#*:}"
    [[ -n "$code" && -f "$code" ]] || continue
    [[ -n "$vars" && -f "$vars" ]] || continue
    OVMF_CODE_PATH="$code"
    OVMF_VARS_PATH="$vars"
    break
done

# The search of the system, when the known paths do not have the firmware.
if [[ -z "$OVMF_CODE_PATH" ]]; then
    for candidate in OVMF_CODE.fd OVMF_CODE_4M.fd OVMF_CODE_4M.qcow2; do
        code="$(search_file "$candidate")" || continue
        vars_name="${candidate/CODE/VARS}"
        vars="$(search_file "$vars_name")" || continue
        OVMF_CODE_PATH="$code"
        OVMF_VARS_PATH="$vars"
        break
    done
fi

if [[ -z "$OVMF_CODE_PATH" ]]; then
    echo "qemu-boot-test: no OVMF firmware found" >&2
    echo "qemu-boot-test: the pairs searched were:" >&2
    for pair in "${OVMF_PAIRS[@]}"; do
        echo "qemu-boot-test:   $pair" >&2
    done
    echo "qemu-boot-test: the roots searched were: ${OVMF_SEARCH_ROOTS[*]}" >&2
    echo "qemu-boot-test: set OVMF_CODE and OVMF_VARS to point at the firmware" >&2
    exit 2
fi

OVMF_CODE_FORMAT="$(format_of "$OVMF_CODE_PATH")"
OVMF_VARS_FORMAT="$(format_of "$OVMF_VARS_PATH")"

# --- run --------------------------------------------------------------------

WORK_DIRECTORY="$(mktemp -d)"
trap 'rm -rf "$WORK_DIRECTORY"' EXIT

SERIAL_LOG="$WORK_DIRECTORY/serial.log"
cp "$OVMF_VARS_PATH" "$WORK_DIRECTORY/vars.fd"

echo "qemu-boot-test: booting $IMAGE (firmware: $OVMF_CODE_PATH, format: $OVMF_CODE_FORMAT)"

set +e
qemu-system-x86_64 \
    -machine q35 \
    -m 256 \
    -smp 1 \
    -drive "file=$IMAGE,format=raw,if=virtio" \
    -drive "if=pflash,format=$OVMF_CODE_FORMAT,readonly=on,file=$OVMF_CODE_PATH" \
    -drive "if=pflash,format=$OVMF_VARS_FORMAT,file=$WORK_DIRECTORY/vars.fd" \
    -serial "file:$SERIAL_LOG" \
    -monitor "unix:$WORK_DIRECTORY/monitor.sock,server=on,wait=off" \
    -display none \
    -no-reboot \
    >/dev/null 2>&1 &
QEMU_PID=$!

# The kernel does not stop: it stops on purpose, and the emulator waits
# forever. The test terminates the emulator as soon as the console reaches
# the end of the boot, and the timeout is the safety net for a machine
# that never gets there.
#
# The wait makes the test both fast and deterministic: the emulator does
# not run until the timeout when the kernel is already at the end.
DEADLINE=$(( SECONDS + TIMEOUT ))
KEY_SENT=0

while (( SECONDS < DEADLINE )); do
    if [[ "$KEY_SENT" -eq 0 ]] && grep -qF "[VNK] keyboard: ready for PS/2 input" "$SERIAL_LOG" 2>/dev/null; then
        # HMP envia make e break pela controladora PS/2 virtualizada.
        # A janela de 50 ticks mantém o kernel disponível para o evento.
        if python3 - "$WORK_DIRECTORY/monitor.sock" <<'PY'
import socket
import sys
with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as monitor:
    monitor.settimeout(2)
    monitor.connect(sys.argv[1])
    monitor.sendall(b"sendkey a 50\\n")
PY
        then
            KEY_SENT=1
        fi
    fi
    if grep -q "VORYN-KERNEL-READY" "$SERIAL_LOG" 2>/dev/null; then
        # The self test of the kernel runs after the marker, and the
        # console needs a moment to write the rest of the report.
        sleep 1
        break
    fi
    if ! kill -0 "$QEMU_PID" 2>/dev/null; then
        break
    fi
    sleep 0.01
done

kill "$QEMU_PID" 2>/dev/null || true
wait "$QEMU_PID" 2>/dev/null
QEMU_STATUS=$?
set -e

# The termination of the emulator is the expected outcome: the kernel
# halts and never exits.
if [[ $QEMU_STATUS -ne 0 && $QEMU_STATUS -ne 124 && $QEMU_STATUS -ne 143 ]]; then
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

# Checks a line that has a number that varies from one run to the other, and
# whose format is part of the contract of the report.
require_pattern() {
    local pattern="$1"
    local description="$2"
    if grep -qE -- "$pattern" "$SERIAL_LOG"; then
        echo "ok: found '$description'"
    else
        echo "FAIL: missing '$description'" >&2
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
require_marker "[VNK] paging: no-execute enabled"
require_marker "[VNK] timer:"
require_marker "[VNK] keyboard: ready for PS/2 input"
require_pattern '\\[VNK\\] keyboard: key scancode=0x1e extended=0 pressed=1' 'PS/2 A key press'
require_pattern '\\[VNK\\] keyboard: key scancode=0x1e extended=0 pressed=0' 'PS/2 A key release'

require_marker "[VNK] fs: ramfs ready"
require_marker "[VNK] fs: /apps/hello.txt round trip ok"
require_marker "[VNK] fs: /apps/hello.elf installed"
require_marker "[VNK] tasks: 8 created"
require_marker "[VNK] native: /apps/hello.elf entry="
require_marker "[VNK] native: process"
require_marker "[VNK] native: task"
require_marker "[VNK] native: page permissions verified"
require_marker "[VNK] native: the ELF task wrote 0x464c456e79726f56 in its data page"
require_marker "[VNK] native: the relative relocation holds the load bias"
require_marker "[VNK] native: the ELF task terminated with code 0"
require_marker "[VNK] native: /apps/hello.elf ran from the RamFS"
require_marker "[VNK] toolchain: /apps/toolchain.elf ran from the toolchain"
require_marker "native ELF"
require_marker "toolchain ELF"
require_pattern '\[VNK\] tasks: [0-9]+ ready' 'the report of the ready tasks'
require_pattern '\[VNK\] tasks: [0-9]+ blocks' 'the report of the blocked tasks'
require_marker "switch cost"
require_marker "[VNK] framebuffer: write probe succeeded"
require_pattern '\[VNK\] graphics: framebuffer scene presented \([0-9]+x[0-9]+\)' 'the framebuffer scene presentation'
require_pattern '\[VNK\] graphics: incremental redraw [1-9][0-9]* pixels' 'the incremental graphics redraw'
require_marker "[VNK] syscall: instruction installed and verified"
require_marker "[VNK] user: process 0"
require_marker "[VNK] user: process 1"
require_marker "[VNK] syscall 1 from user"
require_marker "[VNK] syscall 2 from user wrote 0x8 bytes"
require_marker "[VNK] syscall 3 from user copied 0x8 bytes"
require_marker "[VNK] syscall 4 from user"
require_marker "[VNK] user: the program of the user mode wrote 0x5a5a1234 in its page"
require_marker "[VNK] user: the result of the call came back, 0x42"
require_marker "[VNK] user: the write of the user mode wrote 8 bytes"
require_marker "[VNK] user: the copy of the user mode moved 8 bytes"
require_marker "[VNK] user: the copy of the user mode with overlapping ranges moved 8 bytes"
require_marker "[VNK] user: the kernel refused the call of an address of the kernel"
require_marker "[VNK] channel: the answer of the other process came back"
require_marker "[VNK] channel: the message arrived in"
require_marker "deliveries to a task that was waiting"
require_pattern '\[VNK\]   the process [0-9]+ was killed, and the kernel continues' 'the process that was killed by the exception'
require_pattern '\[VNK\] tasks: [0-9]+ blocks, [0-9]+ killed' 'the report of the killed processes'
require_marker "[VNK] user: the process without the capability was refused with the error 10"
require_marker "[VNK] user: the copy without the capability of the address space was refused with the error 10"
require_marker "[VNK] capabilities: the address space of the process 1 belongs to the process 0"
require_pattern '\[VNK\] capabilities: the process [0-9]+ holds the capability of the channel 0' 'the delegation of the capability'
require_pattern '\[VNK\] capabilities: the process [0-9]+ does not hold the capability of the channel 0 any more' 'the revocation of the capability'
require_marker "[VNK] syscall 9 from user gave the capability of the process 1 to the process 2, result 0x0"
require_marker "[VNK] syscall 10 from user took the capability of the process 1 back from the process 2, result 0x0"
require_marker "[VNK] capabilities: the calls delegated the address space of the process 1 to the process 2 and took it back"
require_marker "[VNK] user: the grant with an unknown kind was refused with the error 11"
require_marker "[VNK] user: the grant with the rights of another kind was refused with the error 12"
require_pattern '\[VNK\] capabilities: the channel 1 belongs to the process [0-9]+' 'the capability of the channel of the timeout'
require_marker "[VNK] syscall 11 from user"
require_marker "[VNK] user: the wait with a timeout expired with the error 13"
require_pattern '\[VNK\] channel: [0-9]+ waits expired with the timeout' 'the expiry of the wait with a timeout'
require_marker "[VNK] user: the second process wrote 0x5a5a1235 in its own page"
require_marker "[VNK] user: the copy between the two processes moved 8 bytes"
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
