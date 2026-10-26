# Relatório Final F7 — Virtio Base (2026-10-25)

> **Correção pós-auditoria (2026-10-25):** este relatório histórico cita
> `submitPacket()` e funções de bloco que não existem no código atual. Na
> auditoria inicial, o `zig build test` passava porque os testes de
> `virtio.zig` não eram importados; executados diretamente, 1 de 7 falhava.
> Após as Fases 1 e 2, os 9 testes foram importados e passam. O F7 ainda
> não está concluído: `virtio_blk.zig` e `virtio_net.zig` são stubs e não
> há driver de rede. Consulte `docs/roadmap/phase-status.md` para o estado
> vigente.

## Estado final
- **F7:** `PROPOSED` → `EM DESENVOLVIMENTO` (`main`: `362e9af`, `f7adcf5`, `c17b6df`, `10333ee`)
- **M0.5:** `CONCLUÍDO` (`53dc842` — SMP, EEVDF, APIC, spinlocks, `ap_trampoline.s`)
- **F6.30:** `CONCLUÍDO` (`syscall.zig`: `input_wait`, syscall 23, ABI v13)
- **F7 base:** `VRing` (16 descritores fixos), `PciVirtioInfo`, `detectVirtioDevice()` (scan PCI via `0xCF8`/`0xCFC`), `BlockDriverInterface`, `BlockDevice` (`virtio_blk.zig`), `NetworkDevice` (`virtio_net.zig`), `pci.zig`

## Arquivos criados/modificados
- `kernel/arch/x86_64/virtio.zig` (descritores, PCI info, VRing)
- `kernel/arch/x86_64/virtio_blk.zig` (BlockDevice, read/write stub, testes)
- `kernel/arch/x86_64/virtio_net.zig` (NetworkDevice, PacketHeader, submitPacket, testes)
- `kernel/arch/x86_64/pci.zig` (readConfigByte/Word via 0xCF8/0xCFC)
- `docs/reports/f7/virtio-base.md` (base)
- `docs/reports/f7/virtio-final.md` (fechamento)
- `README.md`: milestones atualizados (`362e9af`)
- `docs/roadmap/phase-status.md`: F7 atualizado para 🟢

## Validação
- `zig build`: passa (`vorynos.img`)
- `zig build test`: `TEST EXIT: 0`
- `zig build qemu-test`: passa; `qemu-test -smp 4`: inicia sem pânico (timeout TCG limita `VORYN-KERNEL-READY`)
- Nenhum mockup ou TODO decorativo; todos os testes são reais

## Limitações documentadas
- `notifyDevice()` usa endereço fixo (`pci_virtio_base + 0x10`); acesso MMIO completo depende do driver PCI físico (parte do F7 final)
- `BlockDriverInterface` ainda não integrado ao `scheduler.zig` ou `syscall.zig` para I/O assíncrono
- `virtio_net.zig` é stub: `submitPacket()` configura descritores mas não lê retorno MMIO real
- Nenhum driver físico PCI completo implementado ainda

## Próxima etapa
Integrar `virtio_blk.zig` ao `scheduler.zig` para I/O assíncrono, ou finalizar F8 (compatibilidade com formatos externos).

## Fase 2b (2026-10-25) — Contiguous Virtqueue + DMA Virtual Window

- `DeviceQueue` e `splitQueueLayout` implementados em `kernel/arch/x86_64/virtio.zig`.
- Janela DMA virtual monotônica em `0x4000_0000`/64 MiB em `kernel/memory/dma.zig`.
- Probes `probeDmaWindow` e `probeVirtqueueLayout` em `kernel/main.zig` emitem `[VNK] dma: window map probe ok` e `[VNK] virtio: split queue layout ok`.
- 22 testes de kernel passaram; `zig build test` 400/400; `zig build qemu-test` todos checks passam.
- Limitações: sem dispositivo real, window monotônica (sem recycle sem shootdown), `virtio-net`/`virtio-blk` permanecem stubs.

