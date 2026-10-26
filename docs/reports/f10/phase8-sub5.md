# Fase 8 Sub-etapa A5 — Header Ethernet + ARP (estrutura de referencia)
Estado: TESTADO LOCALMENTE
Problema: definir estruturas Ethernet/ARP sem inventar pilha completa.
Evidencia: `virtio_net.zig` adiciona `ArpHeader` (28 bytes) com testes de layout; `EtherHeader` (14 bytes) confirmado; nenhum driver TX/RX inventado; `net_transmit`/`net_receive` permanecem stubs.
Correção aplicada: estruturas de referencia; testes de tamanho validam layout.
Arquivos: `kernel/arch/x86_64/virtio_net.zig`
Testes: `zig build` PASS; `zig build test` PASS (54 testes, 1 falha preexistente nao relacionada a esta edicao); `qemu-test` parcial PASS.
Estado final: A5 concluido. Proximas sub-etapas (A6 IPv4, A7 ICMP, A8 UDP, A9 TCP) ainda bloqueadas — exigem aprovacao explicita.
