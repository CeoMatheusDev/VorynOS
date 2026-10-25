# F9 — Teste de integracao em QEMU (F9.4) — VorynOS
# Executa `zig build` e verifica que kernel inicia com -smp 4 sem panico,
# confirmando que F9 (tensor.zig / model.zig / security.zig) integra sem
# regressoes ao bootloader, memoria, escalonador ou drivers existentes.
# Nenhum mock substitui a execucao no QEMU; os testes existentes
# (boot-qemu.sh, qemu-test) permanecem como baseline.
# Autor: AGENTS.md — fluxo obligatorio (inspecionar → verificar → documentar)

#!/bin/bash
set -euo pipefail

echo "[F9.4] Iniciando validacao de integracao F9"

# 1. Verifica toolchain
zig version || exit 1

# 2. Compila todos os alvos (inclui ai-tests)
echo "[F9.4] zig build ..."
zig build || exit 1

echo "[F9.4] zig build test ..."
zig build test || exit 1

# 3. Boot QEMU com -smp 4 (validado previamente como sem panico)
echo "[F9.4] zig build qemu-test (timeout TCG limita VORYN-KERNEL-READY) ..."
zig build qemu-test || { echo "[F9.4] qemu-test falhou (possivel timeout TCG)"; exit 1; }

echo "[F9.4] PASS (apenas se todas as etapas retornaram 0)"
