#!/usr/bin/env bash
# Copyright (C) 2020 - 2026 Matheus.A.Santos contributors.
# Copyright (C) 2026 VorynOS - All Rights Reserved.
# SPDX-License-Identifier: GPL-3.0-only
#
# Testes de seguranca das assercoes VVDI de `tests/integration/boot-qemu.sh`.
#
# Exercita diretamente o verificador `--verify-vvdi-log` de `boot-qemu.sh`
# sobre sete cenarios deterministas para impedir regressoes fail-open:
#
#   1. Log vazio              -> falha explicita
#   2. Prefixo antigo         -> falha explicita
#   3. Sequencia incompleta   -> falha explicita
#   4. Passo ausente          -> falha explicita
#   5. Ordem invertida        -> falha explicita
#   6. `status=0xf` indevido  -> falha explicita
#   7. Log correto            -> sucesso

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOOT_TEST_SCRIPT="$SCRIPT_DIR/boot-qemu.sh"

if [[ ! -f "$BOOT_TEST_SCRIPT" ]]; then
    echo "log-assertions-test: script not found: $BOOT_TEST_SCRIPT" >&2
    exit 2
fi

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

TOTAL=0
PASSED=0
FAILED=0

expect_failure() {
    local name="$1"
    local log_file="$2"
    local expected_reason="$3"
    local output=""
    local status=0

    TOTAL=$((TOTAL + 1))
    set +e
    output="$(bash "$BOOT_TEST_SCRIPT" --verify-vvdi-log="$log_file" 2>&1)"
    status=$?
    set -e

    if [[ $status -eq 0 ]]; then
        echo "FAIL [$TOTAL] $name: expected failure, got exit status 0" >&2
        FAILED=$((FAILED + 1))
        return
    fi

    if [[ $status -eq 2 ]]; then
        echo "FAIL [$TOTAL] $name: script rejected arguments (exit 2) instead of failing assertion:" >&2
        echo "$output" >&2
        FAILED=$((FAILED + 1))
        return
    fi

    if ! grep -qF -- "$expected_reason" <<< "$output"; then
        echo "FAIL [$TOTAL] $name: failed without expected diagnostic '$expected_reason':" >&2
        echo "$output" >&2
        FAILED=$((FAILED + 1))
        return
    fi

    echo "PASS [$TOTAL] $name (rejected as expected: $expected_reason)"
    PASSED=$((PASSED + 1))
}

expect_success() {
    local name="$1"
    local log_file="$2"
    local output=""
    local status=0

    TOTAL=$((TOTAL + 1))
    set +e
    output="$(bash "$BOOT_TEST_SCRIPT" --verify-vvdi-log="$log_file" 2>&1)"
    status=$?
    set -e

    if [[ $status -ne 0 ]]; then
        echo "FAIL [$TOTAL] $name: expected exit status 0, got $status:" >&2
        echo "$output" >&2
        FAILED=$((FAILED + 1))
        return
    fi

    echo "PASS [$TOTAL] $name"
    PASSED=$((PASSED + 1))
}

# 1. Log vazio -> falha explicita.
EMPTY_LOG="$WORK_DIR/01-empty.log"
: > "$EMPTY_LOG"
expect_failure "log vazio -> falha" "$EMPTY_LOG" "FAIL: serial log is empty"

# 2. Prefixo antigo (`[VNK] virtio-pci:`) -> falha explicita.
OLD_PREFIX_LOG="$WORK_DIR/02-old-prefix.log"
cat > "$OLD_PREFIX_LOG" <<'EOF'
[VNK] pci: bus 0 scan complete, virtio=1
[VNK] dma: window map probe ok
[VNK] virtio: split queue layout ok desc=0 avail=4096 used=8192 size=12288
[VNK] virtio-pci: modern device detected 00:3.0 id=0x1042 type=block
[VNK] virtio-pci: 00:3.0 capabilities validated bar=4 common=+0x0/56 notify=+0x3000/4096 multiplier=4
[VNK] virtio-pci: MMIO mapped 00:3.0 bar4 phys=0xfe000000 size=0x4000 virt=0x60000000 common=0x60000000 notify=0x60003000
[VNK] virtio-pci: 00:3.0 VERSION_1 negotiated features=0x100000000 offered=0x139000ed4
[VNK] virtio-pci: 00:3.0 FEATURES_OK accepted status=0xb
[VNK] virtio-pci: 00:3.0 awaiting virtqueue setup queues=1 status=0xb
[VNK] virtio-pci: 00:3.0 virtqueue 0 dma phys=0x200000 virt=0x40000000 size=256 bytes=6672 desc=0x200000 avail=0x201000 used=0x201208
[VNK] virtio-pci: 00:3.0 virtqueue 0 enabled size=256 queues=1 free=256 avail=0 used=0
[VNK] virtio-pci: 00:3.0 DRIVER_OK status=0xf queues_ready=1 virtqueue=0
EOF
expect_failure "prefixo antigo -> falha" "$OLD_PREFIX_LOG" "FAIL: obsolete '[VNK] virtio-pci:' prefix in serial log"

# 3. Sequencia incompleta -> falha explicita.
INCOMPLETE_LOG="$WORK_DIR/03-incomplete.log"
cat > "$INCOMPLETE_LOG" <<'EOF'
[VNK] vvdi: modern device detected 00:3.0 id=0x1042 type=block
[VNK] vvdi: 00:3.0 capabilities validated bar=4 common=+0x0/56 notify=+0x3000/4096 multiplier=4
[VNK] vvdi: MMIO mapped 00:3.0 bar4 phys=0xfe000000 size=0x4000 virt=0x60000000 common=0x60000000 notify=0x60003000
[VNK] vvdi: 00:3.0 VERSION_1 negotiated features=0x100000000 offered=0x139000ed4
[VNK] vvdi: 00:3.0 FEATURES_OK accepted status=0xb
[VNK] vvdi: 00:3.0 awaiting virtqueue setup queues=1 status=0xb
EOF
expect_failure "sequencia incompleta -> falha" "$INCOMPLETE_LOG" "FAIL: incomplete VVDI initialization sequence"

# 4. Passo ausente (inicio e DRIVER_OK presentes, mas passo intermediario omitido) -> falha explicita.
MISSING_STEP_LOG="$WORK_DIR/04-missing-step.log"
cat > "$MISSING_STEP_LOG" <<'EOF'
[VNK] vvdi: modern device detected 00:3.0 id=0x1042 type=block
[VNK] vvdi: 00:3.0 capabilities validated bar=4 common=+0x0/56 notify=+0x3000/4096 multiplier=4
[VNK] vvdi: MMIO mapped 00:3.0 bar4 phys=0xfe000000 size=0x4000 virt=0x60000000 common=0x60000000 notify=0x60003000
[VNK] vvdi: 00:3.0 VERSION_1 negotiated features=0x100000000 offered=0x139000ed4
[VNK] vvdi: 00:3.0 awaiting virtqueue setup queues=1 status=0xb
[VNK] vvdi: 00:3.0 virtqueue 0 dma phys=0x200000 virt=0x40000000 size=256 bytes=6672 desc=0x200000 avail=0x201000 used=0x201208
[VNK] vvdi: 00:3.0 virtqueue 0 enabled size=256 queues=1 free=256 avail=0 used=0
[VNK] vvdi: 00:3.0 DRIVER_OK status=0xf queues_ready=1 virtqueue=0
EOF
expect_failure "passo ausente -> falha" "$MISSING_STEP_LOG" "FAIL: missing 'the FEATURES_OK confirmation'"

# 5. Ordem invertida (DRIVER_OK antes de virtqueue 0 enabled) -> falha explicita.
INVERTED_ORDER_LOG="$WORK_DIR/05-inverted-order.log"
cat > "$INVERTED_ORDER_LOG" <<'EOF'
[VNK] vvdi: modern device detected 00:3.0 id=0x1042 type=block
[VNK] vvdi: 00:3.0 capabilities validated bar=4 common=+0x0/56 notify=+0x3000/4096 multiplier=4
[VNK] vvdi: MMIO mapped 00:3.0 bar4 phys=0xfe000000 size=0x4000 virt=0x60000000 common=0x60000000 notify=0x60003000
[VNK] vvdi: 00:3.0 VERSION_1 negotiated features=0x100000000 offered=0x139000ed4
[VNK] vvdi: 00:3.0 FEATURES_OK accepted status=0xb
[VNK] vvdi: 00:3.0 awaiting virtqueue setup queues=1 status=0xb
[VNK] vvdi: 00:3.0 virtqueue 0 dma phys=0x200000 virt=0x40000000 size=256 bytes=6672 desc=0x200000 avail=0x201000 used=0x201208
[VNK] vvdi: 00:3.0 DRIVER_OK status=0xf queues_ready=1 virtqueue=0
[VNK] vvdi: 00:3.0 virtqueue 0 enabled size=256 queues=1 free=256 avail=0 used=0
EOF
expect_failure "ordem invertida -> falha" "$INVERTED_ORDER_LOG" "FAIL: VVDI initialization order violated"

# 6. `status=0xf` indevido fora da linha valida de DRIVER_OK -> falha explicita.
STRAY_STATUS_LOG="$WORK_DIR/06-stray-status-0xf.log"
cat > "$STRAY_STATUS_LOG" <<'EOF'
[VNK] vvdi: modern device detected 00:3.0 id=0x1042 type=block
[VNK] vvdi: 00:3.0 capabilities validated bar=4 common=+0x0/56 notify=+0x3000/4096 multiplier=4
[VNK] vvdi: MMIO mapped 00:3.0 bar4 phys=0xfe000000 size=0x4000 virt=0x60000000 common=0x60000000 notify=0x60003000
[VNK] vvdi: 00:3.0 VERSION_1 negotiated features=0x100000000 offered=0x139000ed4
[VNK] vvdi: 00:3.0 FEATURES_OK accepted status=0xf
[VNK] vvdi: 00:3.0 awaiting virtqueue setup queues=1 status=0xb
[VNK] vvdi: 00:3.0 virtqueue 0 dma phys=0x200000 virt=0x40000000 size=256 bytes=6672 desc=0x200000 avail=0x201000 used=0x201208
[VNK] vvdi: 00:3.0 virtqueue 0 enabled size=256 queues=1 free=256 avail=0 used=0
[VNK] vvdi: 00:3.0 DRIVER_OK status=0xf queues_ready=1 virtqueue=0
EOF
expect_failure "status=0xf indevido -> falha" "$STRAY_STATUS_LOG" "FAIL: status=0xf outside the DRIVER_OK line"

# 7. Log correto (com CRLF identico ao UART 16550 e sonda VirtIO legada preservada) -> sucesso.
VALID_LOG="$WORK_DIR/07-valid.log"
python3 - "$VALID_LOG" <<'PY'
import pathlib
import sys

lines = [
    "[VNB] VorynOS Native Boot",
    "[VNK] Voryn Nucleus Kernel",
    "[VNK] pci: bus 0 scan complete, virtio=1",
    "[VNK] dma: window map probe ok",
    "[VNK] virtio: split queue layout ok desc=0 avail=4096 used=8192 size=12288",
    "[VNK] vvdi: modern device detected 00:3.0 id=0x1042 type=block",
    "[VNK] vvdi: 00:3.0 capabilities validated bar=4 common=+0x0/56 notify=+0x3000/4096 multiplier=4",
    "[VNK] vvdi: MMIO mapped 00:3.0 bar4 phys=0xfe000000 size=0x4000 virt=0x60000000 common=0x60000000 notify=0x60003000",
    "[VNK] vvdi: 00:3.0 VERSION_1 negotiated features=0x100000000 offered=0x139000ed4",
    "[VNK] vvdi: 00:3.0 FEATURES_OK accepted status=0xb",
    "[VNK] vvdi: 00:3.0 awaiting virtqueue setup queues=1 status=0xb",
    "[VNK] vvdi: 00:3.0 virtqueue 0 dma phys=0x200000 virt=0x40000000 size=256 bytes=6672 desc=0x200000 avail=0x201000 used=0x201208",
    "[VNK] vvdi: 00:3.0 virtqueue 0 enabled size=256 queues=1 free=256 avail=0 used=0",
    "[VNK] vvdi: 00:3.0 DRIVER_OK status=0xf queues_ready=1 virtqueue=0",
    "VORYN-KERNEL-READY",
]
pathlib.Path(sys.argv[1]).write_bytes(("\r\n".join(lines) + "\r\n").encode("utf-8"))
PY
expect_success "log correto -> sucesso" "$VALID_LOG"

echo "log-assertions-test: $PASSED/$TOTAL scenarios passed"
if [[ $FAILED -ne 0 ]]; then
    echo "log-assertions-test: $FAILED scenario(s) failed" >&2
    exit 1
fi
