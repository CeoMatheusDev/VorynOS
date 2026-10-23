#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 VorynOS contributors
#
# VorynOS interactive graphics integration test.
#
# Boots the generated EFI system partition image in QEMU with the OVMF
# firmware, captures the serial console and verifies that the boot chain
# reaches the kernel.
#
# The test is part of the automated pipeline: `zig build qemu-test`.
#
# Usage: qemu-interactive-test.sh --image=<path> [--timeout=<seconds>]

set -euo pipefail

IMAGE=""
TIMEOUT=60
EDGES=false

for argument in "$@"; do
    case "$argument" in
        --image=*) IMAGE="${argument#--image=}" ;;
        --timeout=*) TIMEOUT="${argument#--timeout=}" ;;
        --edges) EDGES=true ;;
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


# --- interactive run --------------------------------------------------------
WORK_DIRECTORY="$(mktemp -d)"
trap 'rm -rf "$WORK_DIRECTORY"' EXIT
cp "$OVMF_VARS_PATH" "$WORK_DIRECTORY/vars.fd"
SERIAL_LOG="$WORK_DIRECTORY/serial.log"
MONITOR_SOCKET="$WORK_DIRECTORY/monitor.sock"
echo "qemu-interactive-test: booting $IMAGE"
qemu-system-x86_64 \
    -machine q35 -m 256 -smp 1 \
    -drive "file=$IMAGE,format=raw,if=virtio" \
    -drive "if=pflash,format=$OVMF_CODE_FORMAT,readonly=on,file=$OVMF_CODE_PATH" \
    -drive "if=pflash,format=$OVMF_VARS_FORMAT,file=$WORK_DIRECTORY/vars.fd" \
    -serial "file:$SERIAL_LOG" \
    -monitor "unix:$MONITOR_SOCKET,server=on,wait=off" \
    -display none -no-reboot >/dev/null 2>&1 &
QEMU_PID=$!
cleanup_qemu() {
    kill "$QEMU_PID" 2>/dev/null || true
    wait "$QEMU_PID" 2>/dev/null || true
}
trap 'cleanup_qemu; rm -rf "$WORK_DIRECTORY"' EXIT

# The script injects I during boot, then RIGHT only after the persistent
# loop marker. This distinguishes the permanent loop from the boot pump.
if ! python3 - "$SERIAL_LOG" "$MONITOR_SOCKET" "$QEMU_PID" "$TIMEOUT" "$WORK_DIRECTORY" <<'PY'
import os
import re
import socket
import sys
import time

log_path, monitor_path, pid_text, timeout_text, work_dir, edges_text = sys.argv[1:]
edges = edges_text == "true"
pid = int(pid_text)
deadline = time.monotonic() + int(timeout_text)
state = "boot"
steps = ["right", "down", "left", "up", "left", "right"]
step = 0
old_position = None
before_path = os.path.join(work_dir, "before.ppm")
after_path = os.path.join(work_dir, "after.ppm")
movement_pattern = re.compile(r"\[VNK\] graphics: keyboard move x=(\d+) y=(\d+)")

def monitor_command(command):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
        sock.settimeout(2)
        sock.connect(monitor_path)
        sock.sendall((command + "\n").encode("ascii"))

def screenshot(path):
    if os.path.exists(path):
        os.unlink(path)
    monitor_command("screendump " + path)
    for _ in range(100):
        if os.path.isfile(path) and os.path.getsize(path) > 100:
            return
        time.sleep(0.02)
    sys.exit("FAIL: QEMU screendump missing: " + path)

def initial_position(path):
    with open(path, "rb") as ppm:
        if ppm.readline().strip() != b"P6":
            sys.exit("FAIL: invalid initial QEMU screenshot")
        dimensions = []
        while len(dimensions) < 2:
            line = ppm.readline()
            if not line:
                sys.exit("FAIL: truncated initial PPM header")
            dimensions.extend(line.split(b"#", 1)[0].split())
        width, height = map(int, dimensions[:2])
        return (width // 4 + max(1, width // 16), height // 4), width, height

def expected_move(position, key, width, height):
    x, y = position
    step_size = max(1, width // 32)
    max_x = width - width // 2
    max_y = height - height // 3
    if key == "right":
        return (min(max_x, x + step_size), y)
    if key == "left":
        return (max(0, x - step_size), y)
    if key == "down":
        return (x, min(max_y, y + step_size))
    return (x, max(0, y - step_size))

baseline = 0
while time.monotonic() < deadline:
    try:
        with open(log_path, "r", encoding="utf-8", errors="replace") as stream:
            log = stream.read()
    except FileNotFoundError:
        log = ""
    if "FATAL" in log:
        sys.exit("FAIL: fatal error in interactive boot")
    if "[VNK] EXCEPTION 6: invalid opcode" in log:
        sys.exit("FAIL: fatal self-test executed in interactive mode")
    if state == "boot" and "[VNK] keyboard: ready for PS/2 input" in log:
        try:
            monitor_command("sendkey i 50")
        except (OSError, TimeoutError):
            time.sleep(0.02)
            continue
        state = "interactive"
    elif state == "interactive" and "[VNK] graphics: interactive event loop ready" in log:
        if "VORYN-KERNEL-READY" not in log:
            sys.exit("FAIL: interactive loop started before readiness")
        screenshot(before_path)
        old_position, width, height = initial_position(before_path)
        if edges:
            x, y = old_position
            stride = max(1, width // 32)
            max_x = width - width // 2
            max_y = height - height // 3
            targets = [("right", (max_x - x + stride - 1) // stride),
                       ("down", (max_y - y + stride - 1) // stride),
                       ("left", (max_x + stride - 1) // stride),
                       ("up", (max_y + stride - 1) // stride)]
            steps = [direction for direction, count in targets for _ in range(count)]
            print(f"ok: edge route has {len(steps)} acknowledged movements", flush=True)
        baseline = len(movement_pattern.findall(log))
        monitor_command("sendkey " + steps[step] + " 50")
        state = "movement"
    elif state == "movement":
        positions = movement_pattern.findall(log)
        if len(positions) > baseline:
            if len(positions) != baseline + 1:
                sys.exit("FAIL: unexpected additional keyboard movements")
            new_position = tuple(map(int, positions[-1]))
            expected = expected_move(old_position, steps[step], width, height)
            if new_position != expected:
                sys.exit(f"FAIL: step {step + 1} {steps[step]} expected {expected}, got {new_position}")
            if not edges or step == len(steps) - 1 or steps[step] != steps[step + 1]:
                screenshot(after_path)
                import subprocess
                result = subprocess.run(
                    [sys.executable, "tests/integration/compare-framebuffer.py",
                     before_path, after_path, *map(str, (*old_position, *new_position))],
                    check=False, capture_output=True, text=True,
                )
                print(result.stdout, end="", flush=True)
                if result.returncode:
                    sys.exit(f"FAIL: step {step + 1} {steps[step]} framebuffer validation: "
                             + (result.stderr.strip() or result.stdout.strip() or "no comparator output"))
                print(f"ok: movement {step + 1}/{len(steps)} {steps[step]} "
                      f"{old_position}->{new_position}", flush=True)
            step += 1
            if step == len(steps):
                print("ok: persistent loop received all arrows after readiness", flush=True)
                sys.exit(0)
            old_position = new_position
            if not edges or steps[step - 1] != steps[step]:
                before_path, after_path = after_path, before_path
            baseline = len(positions)
            monitor_command("sendkey " + steps[step] + " 50")
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        sys.exit("FAIL: QEMU exited before interactive validation")
    time.sleep(0.02)
sys.exit(f"FAIL: timeout waiting for interactive state {state}, step {step + 1}")

PY
then
    echo "----- serial console -----"
    cat "$SERIAL_LOG"
    exit 1
fi
echo "qemu-interactive-test: all checks passed"
