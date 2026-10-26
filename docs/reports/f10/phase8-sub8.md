# Fase 8 Sub-etapa A8 — Header UDP (estrutura minima, sem pilha completa)
Estado: TESTADO LOCALMENTE
Problema: validar layout UDP sem inventar pilha completa.
Evidencia: `virtio_net.zig` adiciona `UdpHeader` (8 bytes) com testes; `net_transmit`/`net_receive` permanecem stubs.
Correção aplicada: estrutura de referencia A8 documentada.
Arquivos: `kernel/arch/x86_64/virtio_net.zig`
Testes: `zig build` PASS; `zig build test` PASS.
Estado final: A8 concluido (referencia). A9 (TCP) ainda bloqueado — requer aprovaçao explicita.
