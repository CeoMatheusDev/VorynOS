# Fase 8 Sub-etapa A2 — VirtIO init verificado (PCI discovery)
Estado: TESTADO LOCALMENTE
Problema: confirmar dispositivo VirtIO-Net via PCI sem inventar driver.
Evidencia: `virtio_net.zig` — `init()` agora usa `pci.readConfigWord()` para verificar vendor (0x1AF4) e device (0x1000); retorna null se nao encontrado; nenhuma fila, nenhuma alocacao dinamica, nenhum TX/RX inventado.
Correção aplicada: `init()` documentado e funcional (verifica PCI); `net_transmit`/`net_receive` permanecem stubs.
Arquivos: `kernel/arch/x86_64/virtio_net.zig`.
Testes: zig build PASS; zig build test PASS.
Estado final: sub-etapa A2 concluido. Sub-etapas A3+A4 (virtqueues, TX/RX) ainda bloqueadas — requerem aprovacao explicita e testes separadas.
