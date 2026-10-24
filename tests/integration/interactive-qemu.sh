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
STRESS=false
BOUNDS=false
BURST=false
BURST_COUNT=16

for argument in "$@"; do
    case "$argument" in
        --image=*) IMAGE="${argument#--image=}" ;;
        --timeout=*) TIMEOUT="${argument#--timeout=}" ;;
        --edges) EDGES=true ;;
        --stress) STRESS=true ;;
        --bounds) BOUNDS=true ;;
        --burst) BURST=true ;;
        --burst-count=*) BURST=true; BURST_COUNT="${argument#--burst-count=}" ;;
        *)
            echo "qemu-boot-test: unknown argument: $argument" >&2
            exit 2
            ;;
    esac
done

if ! [[ "$BURST_COUNT" =~ ^(16|64|128|256)$ ]]; then
    echo "qemu-interactive-test: --burst-count must be 16, 64, 128 or 256" >&2
    exit 2
fi

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
if ! python3 - "$SERIAL_LOG" "$MONITOR_SOCKET" "$QEMU_PID" "$TIMEOUT" "$WORK_DIRECTORY" "$EDGES" "$STRESS" "$BOUNDS" "$BURST" "$BURST_COUNT" <<'PY'
import os
import re
import socket
import sys
import time

log_path, monitor_path, pid_text, timeout_text, work_dir, edges_text, stress_text, bounds_text, burst_text, burst_count_text = sys.argv[1:]
edges = edges_text == "true"
stress = stress_text == "true"
bounds = bounds_text == "true"
burst = burst_text == "true"
burst_count = int(burst_count_text)
if sum((edges, stress, bounds, burst)) > 1:
    sys.exit("FAIL: --edges, --stress, --bounds and --burst are mutually exclusive")
pid = int(pid_text)
deadline = time.monotonic() + int(timeout_text)
state = "boot"
steps = ["right", "down", "left", "up", "left", "right"]
step = 0
old_position = None
stage_origin = None
before_path = os.path.join(work_dir, "before.ppm")
after_path = os.path.join(work_dir, "after.ppm")
movement_pattern = re.compile(r"\[VNK\] graphics: keyboard move x=(\d+) y=(\d+)")
ack_pattern = re.compile(r"\[VNK\] graphics: arrow ack scancode=0x([0-9a-f]+) moved=([01]) x=(\d+) y=(\d+)")

def monitor_command(command):
    # Rapid sendkey bursts can exhaust the host-side UNIX monitor socket
    # buffer. Retry transient EAGAIN without silently dropping a command.
    retry_deadline = min(deadline, time.monotonic() + 5)
    while True:
        try:
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
                sock.settimeout(2)
                sock.connect(monitor_path)
                sock.sendall((command + "\n").encode("ascii"))
            return
        except BlockingIOError:
            if time.monotonic() >= retry_deadline:
                sys.exit("FAIL: QEMU monitor remained unavailable: " + command)
            time.sleep(0.02)

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
ack_baseline = 0
no_op_deadline = None
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
        stage_origin = old_position
        if edges or bounds:
            x, y = old_position
            stride = max(1, width // 32)
            max_x = width - width // 2
            max_y = height - height // 3
            targets = [("right", (max_x - x + stride - 1) // stride),
                       ("down", (max_y - y + stride - 1) // stride),
                       ("left", (max_x + stride - 1) // stride),
                       ("up", (max_y + stride - 1) // stride)]
            steps = [direction for direction, count in targets
                     for _ in range(count + (3 if bounds else 0))]
            print(f"ok: {'bounds' if bounds else 'edge'} route has {len(steps)} acknowledged movements", flush=True)
        if stress:
            # Alternate directions repeatedly, checking the complete scene
            # after each segment to detect accumulated rendering artifacts.
            steps = ["right"] * 4 + ["down"] * 4 + ["left"] * 4 + ["up"] * 4
            steps *= 3
            print(f"ok: stress route has {len(steps)} acknowledged movements", flush=True)
        baseline = len(movement_pattern.findall(log))
        ack_baseline = len(ack_pattern.findall(log))
        if burst:
            steps = ["right", "down", "left", "up"] * (burst_count // 4)
            burst_started = time.monotonic()
            burst_origin = old_position
            burst_expected = []
            position = old_position
            for key in steps:
                following = expected_move(position, key, width, height)
                burst_expected.append((key, following, int(following != position)))
                position = following
            print(f"ok: burst route sends {len(steps)} ordered arrows", flush=True)
            for key in steps:
                monitor_command("sendkey " + key + " 50")
            state = "burst"
            continue
        monitor_command("sendkey " + steps[step] + " 50")
        state = "movement"
        if bounds and expected_move(old_position, steps[step], width, height) == old_position:
            no_op_deadline = time.monotonic() + 0.25
    elif state == "burst":
        acknowledgements = ack_pattern.findall(log)[ack_baseline:]
        positions = movement_pattern.findall(log)[baseline:]
        if len(acknowledgements) > len(steps):
            sys.exit("FAIL: duplicate burst acknowledgements")
        scan_codes = {"left": 0x4b, "right": 0x4d, "up": 0x48, "down": 0x50}
        for index, (actual, expected) in enumerate(zip(acknowledgements, burst_expected)):
            key, position, moved = expected
            code, actual_moved, x, y = actual
            if (int(code, 16), int(actual_moved), int(x), int(y)) != (scan_codes[key], moved, *position):
                sys.exit(f"FAIL: burst acknowledgement {index + 1}: expected {expected}, got {actual}")
        if len(acknowledgements) == len(steps):
            expected_positions = [position for _, position, moved in burst_expected if moved]
            # The kernel emits the acknowledgement before the movement log.
            # Do not compare until both streams have reached their expected
            # lengths; the next polling iteration will read the pending line.
            if len(positions) < len(expected_positions):
                time.sleep(0.02)
                continue
            actual_positions = [tuple(map(int, item)) for item in positions]
            if actual_positions != expected_positions:
                mismatch = next(
                    (index for index, (actual, expected) in
                     enumerate(zip(actual_positions, expected_positions))
                     if actual != expected),
                    min(len(actual_positions), len(expected_positions)),
                )
                sys.exit(
                    f"FAIL: burst movement log differs from acknowledgements "
                    f"(expected={len(expected_positions)}, actual={len(actual_positions)}, "
                    f"first_mismatch={mismatch + 1}, "
                    f"expected_positions={expected_positions}, "
                    f"actual_positions={actual_positions}, "
                    f"acks={acknowledgements})"
                )
            screenshot(after_path)
            import subprocess
            result = subprocess.run(
                [sys.executable, "tests/integration/compare-framebuffer.py",
                 before_path, after_path, *map(str, (*burst_origin, *burst_expected[-1][1]))],
                check=False, capture_output=True, text=True,
            )
            print(result.stdout, end="", flush=True)
            if result.returncode:
                sys.exit("FAIL: burst framebuffer validation: " + (result.stderr.strip() or result.stdout.strip()))
            elapsed = time.monotonic() - burst_started
            print(f"ok: burst {len(steps)} ordered acknowledgements and framebuffer verified", flush=True)
            print(f"ok: burst {len(steps)} events in {elapsed:.3f}s ({len(steps) / elapsed:.1f} events/s end-to-end)", flush=True)
            sys.exit(0)
    elif state == "movement":
        positions = movement_pattern.findall(log)
        acknowledgements = ack_pattern.findall(log)
        if len(acknowledgements) > ack_baseline + 1:
            sys.exit(f"FAIL: duplicate arrow acknowledgements at step {step + 1}")
        if len(acknowledgements) == ack_baseline + 1:
            scancode, moved_text, ack_x, ack_y = acknowledgements[-1]
            expected_scancode = {"left": 0x4b, "right": 0x4d, "up": 0x48, "down": 0x50}[steps[step]]
            expected_position = expected_move(old_position, steps[step], width, height)
            if int(scancode, 16) != expected_scancode or (int(ack_x), int(ack_y)) != expected_position:
                sys.exit(f"FAIL: invalid arrow acknowledgement at step {step + 1}")
            if int(moved_text) != int(expected_position != old_position):
                sys.exit(f"FAIL: incorrect arrow moved flag at step {step + 1}")
        no_op = bounds and expected_move(old_position, steps[step], width, height) == old_position
        if no_op and len(acknowledgements) == ack_baseline + 1:
            if len(positions) != baseline:
                sys.exit(f"FAIL: unexpected movement while clamped at step {step + 1}")
            screenshot(after_path)
            import subprocess
            result = subprocess.run(
                [sys.executable, "tests/integration/compare-framebuffer.py",
                 before_path, after_path, *map(str, (*old_position, *old_position))],
                check=False, capture_output=True, text=True,
            )
            print(result.stdout, end="", flush=True)
            if result.returncode:
                sys.exit(f"FAIL: step {step + 1} clamped framebuffer validation: "
                         + (result.stderr.strip() or result.stdout.strip() or "no comparator output"))
            print(f"ok: clamped step {step + 1}/{len(steps)} {steps[step]} "
                  f"at {old_position} (framebuffer unchanged)", flush=True)
            step += 1
            if step == len(steps):
                print("ok: persistent loop received all arrows after readiness", flush=True)
                sys.exit(0)
            before_path, after_path = after_path, before_path
            stage_origin = old_position
            baseline = len(positions)
            ack_baseline = len(acknowledgements)
            no_op_deadline = None
            monitor_command("sendkey " + steps[step] + " 50")
            if bounds and expected_move(old_position, steps[step], width, height) == old_position:
                no_op_deadline = time.monotonic() + 0.25
        elif len(positions) > baseline:
            if len(acknowledgements) != ack_baseline + 1:
                sys.exit(f"FAIL: missing arrow acknowledgement at step {step + 1}")
            if len(positions) != baseline + 1:
                sys.exit("FAIL: unexpected additional keyboard movements")
            new_position = tuple(map(int, positions[-1]))
            expected = expected_move(old_position, steps[step], width, height)
            if new_position != expected:
                sys.exit(f"FAIL: step {step + 1} {steps[step]} expected {expected}, got {new_position}")
            reached_limit = bounds and new_position != old_position and expected_move(new_position, steps[step], width, height) == new_position
            verify = (not (edges or stress or bounds) or step == len(steps) - 1
                      or steps[step] != steps[step + 1] or reached_limit
                      or (bounds and new_position == old_position))
            if verify:
                screenshot(after_path)
                import subprocess
                result = subprocess.run(
                    [sys.executable, "tests/integration/compare-framebuffer.py",
                     before_path, after_path, *map(str, (*stage_origin, *new_position))],
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
            if verify:
                before_path, after_path = after_path, before_path
                stage_origin = new_position
            baseline = len(positions)
            ack_baseline = len(acknowledgements)
            monitor_command("sendkey " + steps[step] + " 50")
            if bounds and expected_move(old_position, steps[step], width, height) == old_position:
                no_op_deadline = time.monotonic() + 0.25
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        sys.exit("FAIL: QEMU exited before interactive validation")
    time.sleep(0.02)
sys.exit(f"FAIL: timeout waiting for interactive state {state}, step {step + 1}"
         + (f", burst acks={len(acknowledgements)}/{len(steps)}, movements={len(positions)}" if state == "burst" else ""))

PY
then
    echo "----- serial console -----"
    cat "$SERIAL_LOG"
    exit 1
fi
echo "qemu-interactive-test: all checks passed"
