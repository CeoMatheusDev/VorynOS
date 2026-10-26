# Fase 8 Sub-etapa A4 — Estrutura de frames Ethernet (sem pilha completa)
Estado: TESTADO LOCALMENTE
Problema: definir estrutura minima para caminho TX/RX sem inventar TCP/IP completo.
Evidencia: `virtio_net.zig` adiciona `EtherHeader` (14 bytes), `EtherTypes` (enum: ipv4, ipv6, arp, vlan), `NetFrame` (header + payload); testes validam tamanho e tipos; nenhuma fila publicada; nenhum driver de rede completo; nenhuma pilha TCP/IP implementada.
Correção aplicada: apenas estruturas; `net_transmit`/`net_receive` permanecem stubs.
Arquivos: `kernel/arch/x86_64/virtio_net.zig`
Testes: zig build PASS; zig build test PASS.
Estado final: A4 concluido (estrutura de referencia). Sub-etapas A5-A12 (Ethernet, ARP, IPv4, ICMP, UDP, TCP) ainda bloqueadas — requerem aprovacao explicita e implementacao incremental com testes independentes.
