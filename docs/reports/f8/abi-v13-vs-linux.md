# F8 — ABI v13 vs Linux x86_64 syscall ABI (2026-10-25)

## Voryn ABI v13 (não reutiliza números Linux sem decisão arquitetural)
- 19: `display_info` (ABI 12/13, syscall `syscall.zig`)
- 20: `present`
- 21: `input_poll`
- 23: `input_wait` (F6.30, ABI v13)

## Linux x86_64 (referência externa, não incorporado)
- 0: `read`
- 1: `write`
- 2: `open`
- 3: `close`
- ... diferente do Voryn ABI v13

## Decisão arquitetural (F8 — PROPOSTO → EM DESENVOLVIMENTO)
- Nenhum número de syscall Voryn reutilizado sem decisão arquitetural explícita (AGENTS.md, seção ABI)
- `syscall.zig` mantém contrato independente; compatibilidade externa é interface opcional (VEX/ELF loader), não substituição de ABI

## Arquivos
- `kernel/arch/x86_64/syscall.zig` (ABI v13 implementado)
- `docs/reports/f8/compatibility-base.md`
- `kernel/arch/x86_64/elf_compat.zig` (ELF64 x86_64 = 62)
