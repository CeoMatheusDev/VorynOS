# Fase 8 Sub-etapa A7 — Header ICMP (estrutura mínima, sem pilha completa)
Estado: TESTADO LOCALMENTE
Problema: validar layout ICMP sem inventar resposta/echo completa.
Evidencia: `virtio_net.zig` adiciona `IcmpHeader` (8 bytes) com testes de layout; `net_transmit`/`net_receive` permanecem stubs.
Correção aplicada: estrutura de referencia A7 documentada.
Arquivos: `kernel/arch/x86_64/virtio_net.zig`
Testes: `zig build` PASS; `zig build test` PASS.
Estado final: A7 concluido. A8 (UDP) / A9 (TCP) ainda bloqueadas — exigem aprovacao explicita.
