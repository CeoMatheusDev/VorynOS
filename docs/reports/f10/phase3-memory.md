# Fase 3 — Memoria (correção aplicada)
Estado: TESTADO LOCALMENTE
Problema: substituição silenciosa de mapeamentos existentes (`mapPage`).
Evidência: `paging.zig` linha 281 substituía entry sem verificação.
Correção: `AlreadyMapped` no enum `Error`; verificação `existing & 1 != 0` antes de escrever.
Arquivos: `kernel/arch/x86_64/paging.zig`.
Testes: zig build PASS; zig build test PASS.
Estado final: incremento concluído. Próxima etapa recomendada: confirmar políticas W^X consistentes entre stacks/carregadores (dependência para Fase 4/drivers) — aguardar aprovação.
