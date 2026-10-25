# F9.2 — Modelo binário nativo (`model.zig`) (2026-10-25)

Estado: iniciado → conclusão condensada (o formato `validate()` + `infer()` foram
implementados com validação CRC32 e execução determinística via `tensor.zig`,
com teste positivo e negativo; a próxima incremento é F9.3 segue).

## Entregas
- `kernel/ai/model.zig`: campos binários (`MAGIC` = `0x564F5259`, `VERSION` 1,
  `WEIGHT_TYPE_F32`, dimensões, offsets, `CRC32`), `validate()` (magic/version/
  tipo/dimensões/bounds/CRC32), `fromBytes()` parseado, `infer()` execução
  determinística (reconhece ReLU via `tensor.relu`), `Error` definido explícito.
- `build.zig`: módulo `voryn_ai` + suíte `ai-tests`.
- `docs/reports/f9/f9-infra.md`: mais limitacoes registadas.
- Testes reais (`test "modelBinaryFormatValidatesAndRejectsCorrupt"`): cabecalho
  minimo 58B + payload 4B + CRC32 valido → ok; corrupção CRC → `ChecksumMismatch`
  rejeitado.
- Nenhuma alteração aos componentes estáveis (`A`, `loader.zig`, `apic.zig`, etc.);
  preservar a ABI v13.

## Próximo(s) incremento (F9.3)
- `security.zig`: cotas de memória, protecao NX e validaçao de tamanhos.
- Testes de integracao com `tests/f9/` e QEMU quando infraestrutura permitir.
- Relatorio `docs/reports/f9/f9-infra-completo.md`.

## Limitacoes registadas
- O caminho critico nao faz alocacao dinamica (buffers fornecidos chamador).
- Corrompe tamanho de dimensao adicao deslocamento cabe em buffer real.
- Inferencia determinista simplificada (linear + ReLU); futura nestoria AC dla funcoes
  mais complexas (`tensor.matMul`, `tensor.relu`, JIT e provavelmente carga fisica
  + drivers virtuio existentes — `F7` desfeito).
