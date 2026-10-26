# Fase 8 Sub-etapa A6 — Header IPv4 (estrutura minima, sem pilha completa)
Estado: TESTADO LOCALMENTE
Problema: validar layout de referencia IPv4 sem inventar roteamento ou checksum completo.
Evidencia: `virtio_net.zig` adiciona `Ipv4Header` (20 bytes com alinhamento externo verificado) + testes (`expect` com `sz >= 20`); `EtherHeader` e `ArpHeader` confirmados com alinhamento; nenhuma pilha TCP/IP implementada.
Correção aplicada: estruturas de referencia (`EtherHeader`, `ArpHeader`, `Ipv4Header`, `NetFrame`); testes de layout.
Arquivos: `kernel/arch/x86_64/virtio_net.zig`
Testes: `zig build` PASS; `zig build test` PASS (todos os testes de arquitetura passam, incluindo novos).
Estado final: A6 concluido (estrutura IPv4). Sub-etapas A7-A9 (ICMP, UDP, TCP) ainda bloqueadas — requerem aprovacao explicita.
