#!/usr/bin/env bash
# Copyright (C) 2020 - 2026 Matheus.A.Santos contributors.
# Copyright (C) 2026 VorynOS - All Rights Reserved.
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
# Usage:
#   boot-qemu.sh --image=<path> [--timeout=<seconds>]
#   boot-qemu.sh --verify-vvdi-log=<path>

set -euo pipefail

IMAGE=""
TIMEOUT=60
VERIFY_VVDI_LOG=""

for argument in "$@"; do
    case "$argument" in
        --image=*) IMAGE="${argument#--image=}" ;;
        --timeout=*) TIMEOUT="${argument#--timeout=}" ;;
        --verify-vvdi-log=*) VERIFY_VVDI_LOG="${argument#--verify-vvdi-log=}" ;;
        *)
            echo "qemu-boot-test: unknown argument: $argument" >&2
            exit 2
            ;;
    esac
done

FAILURES=0

# Nomes dos checks que falharam, na ordem em que falharam.
#
# A anotacao que a CI publica a partir de um passo com falha contem apenas o
# fim do log. Repetir a lista no fim faz o nome de cada check que falhou
# chegar ao relatorio da execucao, em vez de ficar enterrado no log inteiro.
FAILED_CHECKS=()

record_failure() {
    local description="$1"
    echo "FAIL: $description" >&2
    FAILED_CHECKS+=("$description")
    FAILURES=$((FAILURES + 1))
}

require_marker() {
    local marker="$1"
    if grep -qF -- "$marker" "$SERIAL_LOG"; then
        echo "ok: found '$marker'"
    else
        record_failure "missing '$marker'"
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
        record_failure "missing '$description'"
    fi
}

# Verifica o contrato de inicializacao VVDI sobre o log serial capturado.
#
# Impede comportamento fail-open exigindo simultaneamente:
#   1. arquivo de log existente e nao vazio;
#   2. ausencia do prefixo antigo `[VNK] virtio-pci:` e de prefixo incorreto;
#   3. presenca dos 9 padroes VVDI obrigatorios;
#   4. sequencia completa de inicializacao;
#   5. ordem estritamente crescente dos 9 eventos;
#   6. exatamente uma ocorrencia valida de `DRIVER_OK`;
#   7. ausencia de `status=0xf` (ou `0x0f`) fora da linha valida de `DRIVER_OK`.
verify_vvdi_log() {
    local log_file="$1"

    if [[ ! -f "$log_file" || ! -s "$log_file" ]]; then
        record_failure "serial log is empty"
        return
    fi

    local normalized
    normalized="$(tr -d '\r' < "$log_file")"
    if [[ -z "${normalized//[[:space:]]/}" ]]; then
        record_failure "serial log is empty"
        return
    fi

    if grep -qE '\[VNK\] virtio-pci:' <<< "$normalized"; then
        record_failure "obsolete '[VNK] virtio-pci:' prefix in serial log"
    fi

    local wrong_prefix_lines
    wrong_prefix_lines="$(grep -E '(modern device detected|capabilities validated|MMIO mapped|VERSION_1 negotiated|FEATURES_OK accepted|awaiting virtqueue setup|virtqueue 0 (dma|enabled)|DRIVER_OK status=)' <<< "$normalized" \
        | grep -vE '^\[VNK\] vvdi: ' || true)"
    if [[ -n "$wrong_prefix_lines" ]]; then
        record_failure "VVDI boot log line emitted with incorrect prefix"
    fi

    local -a vvdi_patterns=(
        '^\[VNK\] vvdi: modern device detected 00:[0-9]+\.0 id=0x1042 type=block$'
        '^\[VNK\] vvdi: 00:[0-9]+\.0 capabilities validated bar=[0-9]+ common=\+0x[0-9a-f]+/[0-9]+ notify=\+0x[0-9a-f]+/[0-9]+ multiplier=[0-9]+$'
        '^\[VNK\] vvdi: MMIO mapped 00:[0-9]+\.0 bar[0-9]+ phys=0x[0-9a-f]+ size=0x[0-9a-f]+ virt=0x[0-9a-f]+ common=0x[0-9a-f]+ notify=0x[0-9a-f]+$'
        '^\[VNK\] vvdi: 00:[0-9]+\.0 VERSION_1 negotiated features=0x[0-9a-f]+ offered=0x[0-9a-f]+$'
        '^\[VNK\] vvdi: 00:[0-9]+\.0 FEATURES_OK accepted status=0x[0-9a-f]+$'
        '^\[VNK\] vvdi: 00:[0-9]+\.0 awaiting virtqueue setup queues=[1-9][0-9]* status=0xb$'
        '^\[VNK\] vvdi: 00:[0-9]+\.0 virtqueue 0 dma phys=0x[0-9a-f]+ virt=0x[0-9a-f]+ size=[1-9][0-9]* bytes=[1-9][0-9]* desc=0x[0-9a-f]+ avail=0x[0-9a-f]+ used=0x[0-9a-f]+$'
        '^\[VNK\] vvdi: 00:[0-9]+\.0 virtqueue 0 enabled size=[1-9][0-9]* queues=[1-9][0-9]* free=[1-9][0-9]* avail=0 used=0$'
        '^\[VNK\] vvdi: 00:[0-9]+\.0 DRIVER_OK status=0xf queues_ready=1 virtqueue=0$'
    )

    local -a vvdi_descriptions=(
        'the modern virtio-blk detection via VVDI'
        'the validated VVDI transport capabilities'
        'the mapped device BAR via VVDI'
        'VIRTIO_F_VERSION_1 negotiation over the features read from the device'
        'the FEATURES_OK confirmation'
        'FEATURES_OK confirmed before the virtqueue'
        'the DMA memory of the virtqueue'
        'the enabled and empty virtqueue'
        'DRIVER_OK after the virtqueue'
    )

    local -a step_lines=()
    local missing_steps=0
    local idx line_match line_no

    for idx in "${!vvdi_patterns[@]}"; do
        line_match="$(grep -nE -- "${vvdi_patterns[$idx]}" <<< "$normalized" | head -n 1 || true)"
        if [[ -z "$line_match" ]]; then
            record_failure "missing '${vvdi_descriptions[$idx]}'"
            missing_steps=$((missing_steps + 1))
            step_lines+=("0")
        else
            line_no="${line_match%%:*}"
            step_lines+=("$line_no")
            echo "ok: found '${vvdi_descriptions[$idx]}'"
        fi
    done

    if (( missing_steps > 0 )); then
        record_failure "incomplete VVDI initialization sequence ($missing_steps of ${#vvdi_patterns[@]} required step(s) missing)"
    else
        local prev_line=0
        local prev_desc=""
        for idx in "${!vvdi_patterns[@]}"; do
            local curr_line="${step_lines[$idx]}"
            local curr_desc="${vvdi_descriptions[$idx]}"
            if (( curr_line <= prev_line )); then
                record_failure "VVDI initialization order violated: '$curr_desc' (line $curr_line) did not follow '$prev_desc' (line $prev_line)"
            fi
            prev_line="$curr_line"
            prev_desc="$curr_desc"
        done
    fi

    local valid_driver_ok_pattern='^\[VNK\] vvdi: 00:[0-9]+\.0 DRIVER_OK status=0xf queues_ready=1 virtqueue=0$'
    local valid_driver_ok_count
    valid_driver_ok_count="$(grep -cE -- "$valid_driver_ok_pattern" <<< "$normalized" || true)"
    if (( valid_driver_ok_count != 1 )); then
        record_failure "expected exactly 1 valid VVDI DRIVER_OK line, found $valid_driver_ok_count"
    fi

    local total_driver_ok_count
    total_driver_ok_count="$(grep -cF -- 'DRIVER_OK' <<< "$normalized" || true)"
    if (( total_driver_ok_count != 1 )); then
        record_failure "expected exactly 1 DRIVER_OK occurrence in serial log, found $total_driver_ok_count"
    fi

    local stray_driver_ok
    stray_driver_ok="$(grep -E 'status=0x0*[fF]([^0-9a-fA-F]|$)' <<< "$normalized" \
        | grep -vE -- "$valid_driver_ok_pattern" || true)"
    if [[ -n "$stray_driver_ok" ]]; then
        record_failure "status=0xf outside the DRIVER_OK line"
    fi
}

if [[ -n "$VERIFY_VVDI_LOG" ]]; then
    if [[ -n "$IMAGE" ]]; then
        echo "qemu-boot-test: --verify-vvdi-log cannot be combined with --image" >&2
        exit 2
    fi
    if [[ ! -e "$VERIFY_VVDI_LOG" ]]; then
        echo "qemu-boot-test: log file not found: $VERIFY_VVDI_LOG" >&2
        exit 2
    fi
    verify_vvdi_log "$VERIFY_VVDI_LOG"
    if [[ $FAILURES -ne 0 ]]; then
        echo "qemu-boot-test: $FAILURES check(s) failed" >&2
        for check in "${FAILED_CHECKS[@]}"; do
            echo "qemu-boot-test: failed check: $check" >&2
        done
        exit 1
    fi
    echo "qemu-boot-test: VVDI log assertions passed"
    exit 0
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

# --- run --------------------------------------------------------------------

WORK_DIRECTORY="$(mktemp -d)"
trap 'rm -rf "$WORK_DIRECTORY"' EXIT

SERIAL_LOG="$WORK_DIRECTORY/serial.log"
QEMU_ERROR_LOG="$WORK_DIRECTORY/qemu.stderr"
SCREENSHOT="$WORK_DIRECTORY/presentation.ppm"
cp "$OVMF_VARS_PATH" "$WORK_DIRECTORY/vars.fd"
cp "$IMAGE" "$WORK_DIRECTORY/disk.img"

echo "qemu-boot-test: booting $IMAGE (firmware: $OVMF_CODE_PATH, format: $OVMF_CODE_FORMAT)"

set +e
qemu-system-x86_64 \
    -machine q35 \
    -m 256 \
    -smp 1 \
    -drive "file=$WORK_DIRECTORY/disk.img,format=raw,if=none,id=virtio-disk0" \
    -device "virtio-blk-pci,drive=virtio-disk0,disable-legacy=on" \
    -drive "if=pflash,format=$OVMF_CODE_FORMAT,readonly=on,file=$OVMF_CODE_PATH" \
    -drive "if=pflash,format=$OVMF_VARS_FORMAT,file=$WORK_DIRECTORY/vars.fd" \
    -serial "file:$SERIAL_LOG" \
    -monitor "unix:$WORK_DIRECTORY/monitor.sock,server=on,wait=off" \
    -display none \
    -no-reboot \
    >/dev/null 2>"$QEMU_ERROR_LOG" &
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
WAIT_KEY_SENT=0
SCREENSHOT_TAKEN=0

while (( SECONDS < DEADLINE )); do
    if [[ "$KEY_SENT" -eq 0 ]] && grep -qF "[VNK] keyboard: ready for PS/2 input" "$SERIAL_LOG" 2>/dev/null; then
        # HMP envia make e break pela controladora PS/2 virtualizada.
        # A janela de 200 ticks mantém o kernel disponível para 16 eventos.
        if python3 - "$WORK_DIRECTORY/monitor.sock" <<'PY'
import socket
import sys
import time
with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as monitor:
    monitor.settimeout(2)
    monitor.connect(sys.argv[1])
    monitor.sendall(b"sendkey a 50\n")
    # Each press must include a release before the next make event.
    # Only left and up are sent here: the right arrow is reserved for the
    # blocking input probe, which the test sends after the kernel reports
    # that the task is blocked.
    for index in range(16):
        key = b"left" if index % 2 == 0 else b"up"
        monitor.sendall(b"sendkey " + key + b" 30\n")
        time.sleep(0.085)
PY
        then
            KEY_SENT=1
        fi
    fi

    # F6.30: the kernel reports the registration of the blocking wait. Send
    # the dedicated right arrow only after that marker, so the event is
    # delivered to a task that is already blocked and not taken by the
    # immediate path of the call.
    if [[ "$WAIT_KEY_SENT" -eq 0 ]] && grep -qF "[VNK] input_wait: task " "$SERIAL_LOG" 2>/dev/null; then
        if python3 - "$WORK_DIRECTORY/monitor.sock" <<'PY'
import socket
import sys
with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as monitor:
    monitor.settimeout(2)
    monitor.connect(sys.argv[1])
    monitor.sendall(b"sendkey right 50\n")
PY
        then
            WAIT_KEY_SENT=1
        fi
    fi

    # F6.28: the application holds the composed frame until it receives Q.
    # Capture the P6 screenshot first and only then release the application,
    # so the screenshot is taken while the user-space pixels are visible.
    if [[ "$SCREENSHOT_TAKEN" -eq 0 ]] && grep -qF "composition ready frame=32x24 at=0,0 checksum=0x" "$SERIAL_LOG" 2>/dev/null; then
        if python3 - "$WORK_DIRECTORY/monitor.sock" "$SCREENSHOT" <<'PY'
import os
import socket
import sys
import time

monitor_path, screenshot_path = sys.argv[1], sys.argv[2]
if os.path.exists(screenshot_path):
    os.unlink(screenshot_path)

until = time.monotonic() + 2.0
monitor = None
while time.monotonic() < until:
    candidate = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    candidate.settimeout(0.5)
    try:
        candidate.connect(monitor_path)
        monitor = candidate
        break
    except OSError:
        candidate.close()
        time.sleep(0.02)
if monitor is None:
    sys.exit("monitor connection unavailable")

buffer = b""

def read_prompt():
    global buffer
    deadline = time.monotonic() + 10.0
    while time.monotonic() < deadline:
        if buffer.endswith(b"(qemu) "):
            response = buffer
            buffer = b""
            return response
        try:
            chunk = monitor.recv(4096)
        except socket.timeout:
            continue
        if not chunk:
            raise OSError("QEMU monitor disconnected")
        buffer += chunk
        if len(buffer) > 1048576:
            raise OSError("QEMU monitor response exceeds 1 MiB")
    raise TimeoutError("QEMU monitor prompt timeout")

try:
    monitor.settimeout(0.5)
    read_prompt()
    monitor.sendall(("screendump " + screenshot_path + "\n").encode("ascii"))
    response = read_prompt()
    if b"unknown command" in response.lower() or b"error:" in response.lower():
        sys.exit("QEMU monitor rejected screendump: " + repr(response[-300:]))

    captured = False
    for _ in range(200):
        if os.path.isfile(screenshot_path) and os.path.getsize(screenshot_path) > 100:
            captured = True
            break
        time.sleep(0.02)
    if not captured:
        sys.exit("QEMU screendump missing")

    monitor.sendall(b"sendkey q 50\n")
    response = read_prompt()
    if b"unknown command" in response.lower() or b"error:" in response.lower():
        sys.exit("QEMU monitor rejected sendkey q: " + repr(response[-300:]))
finally:
    monitor.close()
PY
        then
            SCREENSHOT_TAKEN=1
        fi
    fi

    if grep -q "VORYN-KERNEL-READY" "$SERIAL_LOG" 2>/dev/null; then
        # The kernel marker is independent of the user task holding the
        # composition. Under TCG the input waiter may need extra scheduler
        # ticks after QEMU accepts sendkey q; wait for the causal release
        # marker before stopping the emulator instead of racing the task.
        for _ in {1..200}; do
            grep -qF "composition released" "$SERIAL_LOG" 2>/dev/null && break
            sleep 0.1
        done
        # Keep the original post-marker settling window for the kernel's
        # remaining exception/self-test diagnostics.
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

if [[ ! -s "$SERIAL_LOG" && -s "$QEMU_ERROR_LOG" ]]; then
    echo "----- QEMU startup error -----" >&2
    cat "$QEMU_ERROR_LOG" >&2
    echo "------------------------------" >&2
fi

if [[ ! -s "$SERIAL_LOG" ]]; then
    echo "FAIL: serial log is empty (qemu exit status $QEMU_STATUS)" >&2
    echo "qemu-boot-test: serial console produced no output" >&2
    exit 1
fi

echo "----- serial console -----"
cat "$SERIAL_LOG"
echo "-------------------------"

# --- verify -----------------------------------------------------------------

require_marker "[VNB] VorynOS"
require_marker "[VNB] kernel placed"
require_marker "[VNK] Voryn Nucleus Kernel"
require_marker "[VNK] handoff ok"
require_marker "[VNK] segments: gdt installed and verified"
require_marker "[VNK] interrupts: idt installed and verified"
require_marker "[VNK] segments: task state segment loaded"
require_marker "[VNK] paging: cr3"
require_marker "[VNK] paging: no-execute enabled"
require_pattern '\[VNK\] pci: bus 0 scan complete, virtio=[1-9][0-9]*' 'the PCI config scan on bus 0'
require_marker "[VNK] dma: window map probe ok"
require_marker "[VNK] virtio: split queue layout ok"

# VVDI (Voryn Virtual Device Interface): valida os 9 padroes obrigatorios, a
# sequencia completa, a ordem estrita dos eventos, a unicidade de DRIVER_OK, a
# ausencia de status=0xf indevido e a rejeicao do prefixo antigo.
verify_vvdi_log "$SERIAL_LOG"
require_marker "[VNK] timer:"
require_marker "[VNK] keyboard: ready for PS/2 input"
require_pattern '\[VNK\] keyboard: key scancode=0x1e extended=0 pressed=1' 'PS/2 A key press'
require_pattern '\[VNK\] keyboard: key scancode=0x1e extended=0 pressed=0' 'PS/2 A key release'

require_pattern '\[VNK\] graphics: keyboard move x=[0-9]+ y=[0-9]+ redraw=[1-9][0-9]* pixels' 'keyboard-driven incremental redraw'
require_pattern '\[VNK\] graphics: event pump [1-9][0-9]* arrow presses over ([5-9][0-9]|[1-9][0-9]{2,}) ticks' 'continuous graphics event pump'
require_marker "[VNK] fs: ramfs ready"
require_marker "[VNK] fs: /apps/hello.txt round trip ok"
require_marker "[VNK] fs: /apps/hello.elf installed"
require_marker "[VNK] fs: lifecycle cleanup normal exit and user fault ok"
# F4: o volume raiz é commitado em um dispositivo de blocos, apagado e
# recuperado; os arquivos da árvore sobrevivem ao ciclo completo.
require_pattern '\[VNK\] fs: persistence device ready, [1-9][0-9]* sectors of [0-9]+ bytes' 'the block device geometry'
require_pattern '\[VNK\] fs: vnv committed sequence=[1-9][0-9]* image=[1-9][0-9]* bytes over [1-9][0-9]* sectors' 'the VNV commit to the block device'
require_marker "[VNK] fs: volume wiped, /apps/hello.txt no longer resolvable"
require_pattern '\[VNK\] fs: vnv recovered sequence=[1-9][0-9]* from the block device' 'the VNV recovery from the block device'
require_marker "[VNK] fs: persistence round trip ok"
# F5: o pacote VPK gravado no RamFS sobrevive à recuperação e desempacota.
require_pattern '\[VNK\] vpk: packed [1-9][0-9]* entries, [1-9][0-9]* bytes' 'the VPK packing'
require_marker "[VNK] fs: /apps/sample.vpk installed"
require_pattern '\[VNK\] vpk: /apps/sample.vpk validated and unpacked \([1-9][0-9]* entries' 'the VPK validation and unpack'
require_marker "[VNK] vpk: pack/persist/recover/unpack round trip ok"
# F4: o arquivo grande (100 KiB) usa a tabela indireta e sobrevive ao ciclo
# de persistência; o conteúdo é conferido no início, na fronteira indireta
# e no fim.
require_marker "[VNK] fs: /apps/large.bin installed"
require_marker "[VNK] fs: large file round trip ok"
require_marker "[VNK] fs: directory rename round trip ok"
require_marker "[VNK] tasks: 9 created"
require_marker "[VNK] native: /apps/hello.elf entry="
require_marker "[VNK] native: process"
require_marker "[VNK] native: task"
require_marker "[VNK] native: page permissions verified"
require_marker "[VNK] native: the ELF task wrote 0x464c456e79726f56 in its data page"
require_marker "[VNK] native: the relative relocation holds the load bias"
require_marker "[VNK] native: the ELF task terminated with code 0"
require_marker "[VNK] native: /apps/hello.elf ran from the RamFS"
require_marker "[VNK] toolchain: /apps/toolchain.vex ran from the toolchain"
require_marker "native ELF"
require_marker "toolchain ELF"
# F5: o executável da toolchain é um container VEX com manifest validado.
require_marker "[VNK] fs: /apps/toolchain.vex installed"
require_pattern '\[VNK\] vex: manifest declares display\(0x[0-9a-f]+\) and input\(0x[0-9a-f]+\)' 'the VEX capability manifest'
require_marker "[VNK] vex: unwrapped and planned from the VEX image"
require_marker "[VNK] vex: manifest enforced against the kernel grant"
require_pattern '\[VNK\] syscall 19 from user display_info result 0x28' 'the display metadata call from the user mode'
require_marker "display metadata"
require_pattern '\[VNK\] capabilities: the display belongs to the process [0-9]+' 'the display capability'
require_pattern '\[VNK\] display: present 16x16 at 0,0 first=0xff' 'the framebuffer read back after the presentation'
require_pattern '\[VNK\] syscall 20 from user present result 0x0' 'the presentation call from the user mode'
require_marker "display present"
require_pattern '\[VNK\] capabilities: the input belongs to the process [0-9]+' 'the input capability'
require_marker "input probe ready"
require_pattern '\[VNK\] syscall 23 from user input_wait result 0x0' 'the blocked input call from the user mode'
require_pattern '\[VNK\] input_wait: task [0-9]+ blocked, timeout 50 ticks' 'the registration of the blocking input wait'
require_pattern '\[VNK\] input_wait: task [0-9]+ resumed with scancode=0x[0-9a-f]+ pressed=[01] extended=[01]' 'the event delivered to the blocked task'
require_marker "input wait resumed"
require_pattern '\[VNK\] input_wait: task [0-9]+ expired' 'the expiry of the blocking input wait'
require_marker "input wait timeout ok"
require_marker "input event scancode=0x4d pressed=1 extended=1"
require_pattern '\[VNK\] display: present 16x16 at 16,0 first=0xff' 'the input-driven presentation'
require_marker "input present x=16 y=0"
require_pattern '\[VNK\] display: present 32x24 at 0,0 first=0x606060' 'the composed frame read back'
require_pattern 'composition ready frame=32x24 at=0,0 checksum=0x[0-9a-f]{16}' 'the user-space composition checksum'
require_marker "composition released"
require_pattern '\[VNK\] tasks: [0-9]+ ready' 'the report of the ready tasks'
require_pattern '\[VNK\] tasks: [0-9]+ blocks' 'the report of the blocked tasks'
require_marker "switch cost"
require_marker "[VNK] framebuffer: write probe succeeded"
require_pattern '\[VNK\] graphics: managed desktop presented \([0-9]+x[0-9]+\)' 'the managed desktop presentation'
# F6.31: a shell. A barra ocupa as ultimas linhas, tem um botao por janela
# visivel, o alvo de clique do primeiro botao e conferido no proprio kernel
# (e a calha nao pertence a botao nenhum), e o foco troca de janela sem
# alterar o z-order. Qualquer divergencia mata o boot com FATAL, entao o
# marcador que existe aqui e o que o teste exige.
require_pattern '\[VNK\] shell: bar height=[0-9]+ buttons=[1-9][0-9]* windows=[0-9]+' 'the shell taskbar'
require_pattern '\[VNK\] shell: the first button answers a click at x=[0-9]+ y=[0-9]+' 'the click target of the first shell button'
require_pattern '\[VNK\] shell: focus cycled to slot=[0-9]+ frame=[0-9]+x[0-9]+' 'the focus cycle of the shell'
require_pattern '\[VNK\] graphics: keyboard move x=[0-9]+ y=[0-9]+ redraw=[1-9][0-9]* pixels' 'the keyboard-driven desktop redraw'
require_marker "[VNK] syscall: instruction installed and verified"
require_marker "[VNK] user: process 0"
require_marker "[VNK] user: process 1"
require_marker "[VNK] syscall 1 from user"
require_marker "[VNK] syscall 2 from user wrote 0x8 bytes"
require_marker "[VNK] syscall 3 from user copied 0x8 bytes"
require_marker "[VNK] syscall 4 from user"
# M0.3.16: user-mode ELF exercises syscall 22, not only kernel compilation.
require_marker "[VNK] syscall 22 from user fs_truncate result 0x0"
require_marker "fs truncate user probe ok"
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
require_marker "[VNK] user: the presentation without the display capability was refused with the error 10"
require_marker "[VNK] user: the input without the input capability was refused with the error 10"
require_pattern '\[VNK\] capabilities: the channel 1 belongs to the process [0-9]+' 'the capability of the channel of the timeout'
require_marker "[VNK] syscall 11 from user"
require_marker "[VNK] user: the wait with a timeout expired with the error 13"
require_pattern '\[VNK\] channel: [0-9]+ waits expired with the timeout' 'the expiry of the wait with a timeout'
require_marker "[VNK] user: the second process wrote 0x5a5a1235 in its own page"
require_marker "[VNK] user: the copy between the two processes moved 8 bytes"
# F9: o modelo embarcado e validado e executado no kernel antes do timer, e
# o processo que compoe recebe a capability da IA. O checksum e o do
# contrato (`shared/ai.zig`), e nao um valor que o teste aceite de qualquer
# forma: um modelo diferente, um peso trocado ou um resultado arredondado
# falham a comparacao.
require_pattern '\[VNK\] ai: model validated id=0 input=4 hidden=4 output=3 image=[0-9]+ bytes weights=48 bytes crc ok' 'the validation of the embedded model'
require_marker "[VNK] ai: inference ok output_x1000=2125,5250,4000 checksum=0x30f2bf7325eecf35 model=0"
require_pattern '\[VNK\] capabilities: the inference engine belongs to the process [0-9]+' 'the grant of the inference capability'
# O processo recusa um pedido com tamanho fora do contrato (erro 3), depois
# executa a chamada valida (12 bytes) e publica o checksum do resultado.
require_marker "ai infer wrong size refused"
require_marker "[VNK] syscall 24 from user ai_infer result 0xfffffffffffffffd"
require_pattern '\[VNK\] ai: process [0-9]+ ran the model output=0x[0-9a-f]+ inputs=0x[0-9a-f]+ checksum=0x30f2bf7325eecf35' 'the inference of the user process'
require_marker "[VNK] syscall 24 from user ai_infer result 0xc"
require_marker "ai infer ok checksum=0x30f2bf7325eecf35"
# O cliente nao possui a capability: a chamada e recusada com o erro 10 antes
# de qualquer leitura do buffer, e o processo continua depois da recusa.
require_marker "[VNK] syscall 24 from user ai_infer result 0xfffffffffffffff6"
require_marker "ai infer denied without the capability"
require_marker "VORYN-KERNEL-READY"
require_marker "[VNK] self test: the handler returned 0x42"
require_marker "[VNK] EXCEPTION 6: invalid opcode"

# F6.28: compare the pixels captured while the application was holding the
# composed frame. The checksum comes from the application's own buffer, so
# the test detects a wrong rectangle, a wrong stride or a lost pixel, not
# only the presence of the serial marker.
COMPOSITION_HASH="$(grep -oE 'composition ready frame=32x24 at=0,0 checksum=0x[0-9a-f]+' "$SERIAL_LOG" | tail -1 | sed -E 's/.*checksum=0x//')"
if [[ "$SCREENSHOT_TAKEN" -ne 1 || ! -s "$SCREENSHOT" ]]; then
    record_failure "no presentation screenshot was captured"
elif [[ -z "$COMPOSITION_HASH" ]]; then
    record_failure "the composition checksum is missing from the serial console"
elif python3 tests/integration/compare-presentation.py "$SCREENSHOT" 0 0 32 24 "$COMPOSITION_HASH"; then
    echo "ok: QEMU screenshot matches the user-space composition"
else
    record_failure "the QEMU screenshot does not match the user-space composition"
fi

# F6.29: o cliente publica o checksum da janela que copiou por `copy_to`;
# o compositor confere o mesmo hash sobre a região da superfície antes de
# apresentar. A igualdade prova que a cópia entre processos transferiu os
# pixels byte a byte, e não apenas que as duas partes terminaram com êxito.
if python3 - "$SERIAL_LOG" <<'PY'
import re
import sys

log = open(sys.argv[1], encoding="utf-8", errors="replace").read()
client = re.findall(r"client checksum=0x([0-9a-f]{16})", log)
compositor = re.findall(r"client frame accepted checksum=0x([0-9a-f]{16})", log)
if not client:
    sys.exit("the client published window checksum is missing")
if not compositor:
    sys.exit("the compositor acceptance checksum is missing")
if client[-1] != compositor[-1]:
    sys.exit(f"client and compositor checksums differ: {client[-1]} != {compositor[-1]}")
print(f"ok: F6.29 client frame accepted checksum=0x{compositor[-1]}")
PY
then
    :
else
    record_failure "the F6.29 client frame verification failed"
fi

# F15.6: require four bounded RAM/GOP trials and exact framebuffer restoration.
if python3 - "$SERIAL_LOG" <<'PY'
import re
import sys

log = open(sys.argv[1], encoding="utf-8", errors="replace").read()
trials = re.findall(
    r"\[VNK\] graphics: memory benchmark trial=(\d+) bytes=(\d+) "
    r"ram_cycles=(\d+) framebuffer_cycles=(\d+)", log,
)
if len(trials) != 4:
    sys.exit(f"F15.6 requires four benchmark trials, got {len(trials)}")
for index, (trial, size, ram, video) in enumerate(trials, 1):
    if (int(trial), int(size)) != (index, 65536) or int(ram) <= 0 or int(video) <= 0:
        sys.exit(f"invalid F15.6 benchmark record {index}")
if re.findall(r"\[VNK\] graphics: memory benchmark restore_mismatches=(\d+)", log) != ["0"]:
    sys.exit("F15.6 framebuffer restore verification failed")
print("ok: F15.6 four RAM/framebuffer trials and lossless restore")
PY
then
    :
else
    record_failure "F15.6 RAM/framebuffer benchmark verification failed"
fi

# F14.2: verify latency counters and pixel savings from the actual QEMU log.
# Independently recompute exact nearest-rank percentiles for every available sample.\n# F15.3 requires at least 16 measured redraws from real PS/2 events.
if python3 - "$SERIAL_LOG" <<'PY'
import re
import sys

log = open(sys.argv[1], encoding="utf-8", errors="replace").read()
summary = re.findall(
    r"\[VNK\] graphics: latency samples=(\d+) min_cycles=(\d+) "
    r"mean_cycles=(\d+) max_cycles=(\d+) total_pixels=(\d+) total_baseline=(\d+)",
    log,
)
window = re.findall(
    r"\[VNK\] graphics: latency window=(\d+) p50_cycles=(\d+) "
    r"p95_cycles=(\d+) p99_cycles=(\d+)",
    log,
)
benchmark = re.findall(
    r"\[VNK\] graphics: redraw benchmark cycles=(\d+) pixels=(\d+) "
    r"baseline=(\d+) saved=(\d+)",
    log,
)
timing = re.findall(
    r"\[VNK\] graphics: redraw timing cycles=(\d+) elapsed_ticks=(\d+)",
    log,
)
if len(timing) != len(benchmark):
    sys.exit("missing or unmatched F15.4 redraw timing records")
detail = re.findall(
    r"\[VNK\] graphics: redraw detail geometry_cycles=(\d+) paint_cycles=(\d+)",
    log,
)
if len(detail) != len(benchmark):
    sys.exit("missing or unmatched F15.5 redraw detail records")
for geometry, paint in detail:
    if int(paint) <= 0:
        sys.exit("F15.5 painting must consume positive cycles")
if not summary or len(summary) != len(window) or len(summary) != len(benchmark):
    sys.exit("missing or unmatched F14 latency/redraw records")
if len(summary) < 16:
    sys.exit(f"F15.3 requires at least 16 measured redraws, got {len(summary)}")
previous_samples = 0
previous_pixels = 0
previous_baseline = 0
observed_cycles = []
def nearest_rank(values, percentile):
    ordered = sorted(values)
    return ordered[max(0, (percentile * len(ordered) + 99) // 100 - 1)]

for index, (stats, percentiles, redraw) in enumerate(zip(summary, window, benchmark), 1):
    samples, minimum, mean, maximum, total_pixels, total_baseline = map(int, stats)
    count, p50, p95, p99 = map(int, percentiles)
    cycles, pixels, baseline, saved = map(int, redraw)
    timing_cycles, elapsed_ticks = map(int, timing[index - 1])
    if timing_cycles != cycles or elapsed_ticks > 200:
        sys.exit(f"invalid F15.4 redraw timing at record {index}")
    if samples != previous_samples + 1:
        sys.exit(f"nonconsecutive sample count at record {index}")
    if count != min(samples, 32):
        sys.exit(f"incorrect rolling window size at record {index}")
    if not (0 < minimum <= mean <= maximum and minimum <= p50 <= p95 <= p99 <= maximum):
        sys.exit(f"invalid latency ordering at record {index}")
    if not (minimum <= cycles <= maximum):
        sys.exit(f"current sample outside cumulative range at record {index}")
    if not (pixels > 0 and baseline >= pixels and saved == baseline - pixels):
        sys.exit(f"invalid redraw pixel accounting at record {index}")
    if total_pixels != previous_pixels + pixels or total_baseline != previous_baseline + baseline:
        sys.exit(f"invalid cumulative pixel accounting at record {index}")
    if samples == 1 and not (minimum == mean == maximum == cycles == p50 == p95 == p99):
        sys.exit("single-sample statistics disagree")
    observed_cycles.append(cycles)
    recent = observed_cycles[-32:]
    expected = tuple(nearest_rank(recent, p) for p in (50, 95, 99))
    if (p50, p95, p99) != expected:
        sys.exit(f"incorrect nearest-rank percentiles at record {index}: "
                 f"kernel={(p50, p95, p99)} expected={expected}")
    if minimum != min(observed_cycles) or maximum != max(observed_cycles):
        sys.exit(f"incorrect cumulative extrema at record {index}")
    if mean != sum(observed_cycles) // len(observed_cycles):
        sys.exit(f"incorrect cumulative mean at record {index}")
    previous_samples, previous_pixels, previous_baseline = samples, total_pixels, total_baseline
print(f"ok: F14.2 latency counters samples={samples} window={count} p50={p50} p95={p95} p99={p99}")
print(f"ok: F14.2 redraw pixel savings {saved}/{baseline}")
print(f"ok: F15.4 redraw tick instrumentation verified for {samples} samples")
PY
then
    :
else
    record_failure "F14.2 graphics latency consistency checks failed"
fi

if grep -qF "FATAL" "$SERIAL_LOG"; then
    record_failure "the boot chain reported a fatal error"
fi

if [[ $FAILURES -ne 0 ]]; then
    echo "qemu-boot-test: $FAILURES check(s) failed" >&2
    for check in "${FAILED_CHECKS[@]}"; do
        echo "qemu-boot-test: failed check: $check" >&2
    done
    # O console serial e longo e as linhas das sondas ficam no meio dele. A
    # falha costuma ser a ausencia de uma dessas linhas, e por isso elas sao
    # repetidas aqui, no fim: quem le o relatorio ve o diagnostico do kernel
    # sem precisar do log completo.
    DIAGNOSTIC="$(grep -E '\[VNK\] (pci|virtio|vvdi)' "$SERIAL_LOG" | tail -n 12 || true)"
    if [[ -n "$DIAGNOSTIC" ]]; then
        echo "qemu-boot-test: last console lines of the PCI, VirtIO and VVDI probes:" >&2
        while IFS= read -r line; do
            echo "qemu-boot-test:   $line" >&2
        done <<< "$DIAGNOSTIC"
    else
        echo "qemu-boot-test: the console has no PCI, VirtIO or VVDI probe lines" >&2
    fi
    exit 1
fi

echo "qemu-boot-test: all checks passed"
