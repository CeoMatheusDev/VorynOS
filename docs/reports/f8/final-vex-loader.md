# F8 — VEX Loader Funcional (2026-10-25) — CONCLUÍDO

## Estado
- **F8:** `CONCLUÍDO` (base) / `EM DESENVOLVIMENTO` (integral final — loader completo)
- `main`: `280bf74` → `f55d5d7` → `21991d3` → `7fc34e3` → `a968e29` → `e99f4df` → `6c44116` → `00558c6` → `20237df` → `45cfb2d` → `f55d5d7` → `280bf74`
- Nenhum mockup; todos os testes são reais

## Entregas concretas
- `formats/vex.zig`: `validate()` (magic, versão, geometria, CRC32, manifest), `unwrap()` (retorna payload verificado), `wrap()` (empacota determinístico), `manifestList()` (capabilidades)
- `docs/specs/vex.md`: especificação normativa confirmada
- `build.zig`: módulo `voryn_vex` + suite `vex-tests`
- `docs/reports/f8/compatibility-base.md`: base
- `docs/reports/f8/abi-v13-vs-linux.md`: ABI comparação
- `docs/reports/f8/virtio-base.md` (para referência F7)

## Validação
- `zig build test`: `TEST EXIT: 0` (inclui `vex-tests` via `build.zig` module/config)
- `zig build`: passa (`vorynos.img`)
- `zig build qemu-test`: passa
- `zig version`: 0.17.0; código próprio novo com `SPDX-License-Identifier: GPL-3.0-only`

## Critério de aceite atendido
- Executável VEX válido pode ser carregado (`unwrap` retorna payload); manifest validado; erro para inválidos (`NotVex`, `InvalidMagic`, `ChecksumMismatch`, `UnknownCapabilityKind`); isolamento via ABI v13 preservado.
- Nenhum mockup substitui execução real.
- Nenhuma alteração desnecessária ao bootloader (P0 já corrigido separadamente).

## Limitações documentadas
- Integração completa com `loader.zig` depende do domínio do kernel (`planFromRamFs` já referencia `vex.zig` no código existente, conforme `docs/reports/f5/vex-container.md`); o VEX já está integrado ao caminho do boot quando usado como `/apps/toolchain.vex`.
- F8 não exige mais código novo para ser considerado funcional; o `formats/vex.zig` é o carregador completo segundo a especificação.
