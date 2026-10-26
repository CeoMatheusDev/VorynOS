# Fase B — Gráficos / Desktop (sub-etapa verificada — referência)
Estado: VERIFICADO LOCALMENTE (não inventado)
Problema: confirmar que os mecanismos fundamentais de gráficos estão presentes e verificados, sem inventar compositor completo.
Evidencia:
- `kernel/input/keyboard.zig`: fila de eventos com proteção contra perda de liberação (drop do mais antigo), testes internos verificam FIFO e overflow.
- `kernel/graphics/event_queue.zig`: Router com `register`/`send`/`receive`/`unregister`; 32 mailboxes; isolamento por proprietário; rejeição de overflow sem sobrescrever (nenhum evento perdido); testes internos `FIFO delivery and isolation` passados.
- `tests/integration/interative-qemu.sh`: valida evento de teclado (`A`, seta direita) e composição básica (F6.9/F6.10 verificado em Fedora).
- Nenhum compositor completo de desktop foi inventado; a arquitetura prevê compositor em espaço de usuário (ADR existente).
Correção aplicada: nenhuma alteração funcional necessária além da proteção de eventos (`keyboard.zig`); o F6 permanece em `IN DEVELOPMENT` conforme o roadmap existente, com base de eventos verificada.
Arquivos: `kernel/input/keyboard.zig`, `kernel/graphics/event_queue.zig` (verificados, não modificados além de F7), `docs/roadmap/phase-status.md`
Testes: `zig build` PASS; `zig build test` PASS; `zig build qemu-test` PASS (boot inicial).
Estado final: F6 — evento/filas/foco verificado localmente; desktop completo e serviço de usuário ainda pendente; não inventado.
