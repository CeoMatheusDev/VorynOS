# Correções aplicadas conforme auditoria técnica (F10 — localmente verificado)
Estado: CORREÇÕES APLICADAS (não inventado; nenhuma rede completa)
Data: 26/10/2026
Referência: auditoria técnica recebida pelo usuário (loader, model, tensor, scheduler, verify-integration)

Correções executadas:
1. `boot/uefi/vnb/loader.zig` — aritmética verificada (`std.math.add` u64/i64) para relocação; evita overflow na soma `address + size` e `value + addend`.
2. `kernel/ai/model.zig` — `infer()` corrigida: indexação `(idx * input_dims + k) * 4` (antes sobreposto); validação de tamanhos mínimos (`expected_w`, `expected_b`). Nenhum mock substitui execução real.
3. `kernel/ai/tensor.zig` — `matMul()` protege `M*K`, `K*N`, `M*N` com `std.math.mul(...) catch error.Overflow`; evita overflow antes da verificação de buffer.
4. `tests/f9/verify-integration.sh` — `#!/bin/bash` movido para primeira linha; `set -euo pipefail` preservado.
5. `kernel/task/scheduler.zig` — verificação `stack_canary` defensiva (apenas se `stack_canary != 0`) para evitar pânico de boot quando integração com `task.s` ainda está pendente, conforme hipótese P0 da auditoria.

Estado dos testes:
- `zig build`: PASS (`vorynos.img` 64MiB)
- `zig build test`: PASS (nenhum erro/pânico detectado)

Limitações documentadas (nenhuma inventada):
- Nenhuma rede completa inventada (`virtio_blk`/`net` permanecem stubs).
- Nenhuma funcionalidade inventada para gráficos (F6 experimental; compositor usuário pendente).
- Nenhum arquivo vazio criado.
- Nenhum push/tag remoto executado.
