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

if [[ $QEMU_STATUS -ne 0 && $QEMU_STATUS -ne 124 && $QEMU_STATUS -ne 143 && ! -s "$SERIAL_LOG" ]]; then
    echo "qemu-boot-test: QEMU failed before producing serial output" >&2
    exit 1
fi

echo "----- serial console -----"
cat "$SERIAL_LOG"
echo "-------------------------"

# --- verify -----------------------------------------------------------------

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
# PR B do VirtIO moderno: o disco e um virtio-blk-pci explicito com o
# transporte legado desabilitado, e as linhas abaixo so podem aparecer depois
# de operacoes concluidas — identificacao, validacao das capabilities,
# mapeamento do BAR com cache desabilitado, leitura real dos registradores,
# negociacao de VERSION_1 e aceite de FEATURES_OK.
require_pattern '\[VNK\] virtio-pci: modern device detected 00:[0-9]+\.0 id=0x1042 type=block' 'the modern virtio-blk detection'
require_pattern '\[VNK\] virtio-pci: 00:[0-9]+\.0 capabilities validated bar=[0-9]+ common=\+0x[0-9a-f]+/[0-9]+ notify=\+0x[0-9a-f]+/[0-9]+ multiplier=[0-9]+' 'the validated transport capabilities'
require_pattern '\[VNK\] virtio-pci: MMIO mapped 00:[0-9]+\.0 bar[0-9]+ phys=0x[0-9a-f]+ size=0x[0-9a-f]+ virt=0x[0-9a-f]+' 'the mapped device BAR'
require_pattern '\[VNK\] virtio-pci: 00:[0-9]+\.0 VERSION_1 negotiated features=0x[0-9a-f]+ offered=0x[0-9a-f]+' 'VIRTIO_F_VERSION_1 negotiation over the features read from the device'
require_pattern '\[VNK\] virtio-pci: 00:[0-9]+\.0 FEATURES_OK accepted status=0x[0-9a-f]+' 'the FEATURES_OK confirmation'
require_pattern '\[VNK\] virtio-pci: 00:[0-9]+\.0 awaiting virtqueue setup queues=[1-9][0-9]* status=0xb; DRIVER_OK not written' 'the final state before the virtqueues'

# O estado do dispositivo tem que ser 0x0b (ACKNOWLEDGE|DRIVER|FEATURES_OK).
# Qualquer linha com DRIVER_OK (0x0f) provaria uma ativacao antes das
# virtqueues, e o teste tem que falhar.
if grep -qE '\[VNK\] virtio-pci: .*status=0x[fF]' "$SERIAL_LOG"; then
    record_failure 'DRIVER_OK was written before the virtqueues (status=0x0f)'
fi
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
    DIAGNOSTIC="$(grep -E '\[VNK\] (pci|virtio)' "$SERIAL_LOG" | tail -n 12 || true)"
    if [[ -n "$DIAGNOSTIC" ]]; then
        echo "qemu-boot-test: last console lines of the PCI and VirtIO probes:" >&2
        while IFS= read -r line; do
            echo "qemu-boot-test:   $line" >&2
        done <<< "$DIAGNOSTIC"
    else
        echo "qemu-boot-test: the console has no PCI or VirtIO probe lines" >&2
    fi
    exit 1
fi

echo "qemu-boot-test: all checks passed"
