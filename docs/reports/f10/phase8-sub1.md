# Fase 8 — Rede (sub-etapa 1: descoberta PCI/VirtIO init verificada)
Estado: TESTADO LOCALMENTE
Problema: confirmar que a rede nao pode ser declarada funcional sem sub-etapas.
Evidencia: `virtio_net.zig` — `init()` adicionado como stub verificado (sem fila, sem BAR, sem alocacao dinamica); `net_transmit()`/`net_receive()` permanecem stubs; `virtio.zig` estruturas prontas.
Correção aplicada: `init()` documentado; nao inventado driver completo.
Arquivos: `kernel/arch/x86_64/virtio_net.zig`.
Testes: zig build PASS; zig build test PASS.
Estado final: sub-etapa 1 concluida (confirmacao de dispositivo). Proximas sub-etapas (virtqueues, TX/RX, Ethernet, ARP, IPv4...) requerem aprovacao explicita e testes separadas.
