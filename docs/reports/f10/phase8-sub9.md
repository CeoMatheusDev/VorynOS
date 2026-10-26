# Fase 8 Sub-etapa A9 — Header TCP (estrutura minima, sem pilha completa)
Estado: TESTADO LOCALMENTE
Problema: validar layout TCP sem inventar handshake/completo.
Evidencia: `virtio_net.zig` adiciona `TcpHeader` (20 bytes) com testes; `net_transmit`/`net_receive` permanecem stubs.
Correção aplicada: estrutura de referencia A9 documentada.
Arquivos: `kernel/arch/x86_64/virtio_net.zig`
Testes: `zig build` PASS; `zig build test` PASS.
Estado final: A9 concluido (referencia). Nenhum driver de rede completo inventado; nenhum TCP/IP próprio criado.
