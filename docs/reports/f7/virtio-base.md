# Relatório F7 — Virtio Base (2026-10-25)

> **Correção pós-auditoria (2026-10-25):** este relatório histórico cita
> `notifyDevice()`, `readBlock`, `writeBlock` e o teste
> `virtioBlkInitAndDescriptorChain`, que não existem no código atual. Na
> auditoria inicial, o PCI legado era parcial, `virtio.zig` era host-only
> com defeitos conhecidos e seus testes estavam fora de `zig build test`.
> Após as Fases 1 e 2, o PCI foi corrigido e os 9 testes de `virtio.zig`
> foram importados e passam; `virtio_blk.zig`/`virtio_net.zig` continuam
> apenas com estruturas. Consulte `docs/roadmap/phase-status.md` para o
> estado vigente.

## Estado
- **F7 base:** `PROPOSED` → `EM DESENVOLVIMENTO` (`main`: `10333ee`, `858f32a`, `7b98a70`, `d664633`)
- **M0.5:** `CONCLUÍDO` (`53dc842` — SMP, EEVDF, APIC, spinlocks)
- **ABI:** v13 (F6.30 `input_wait` syscall 23)
- **Zig:** 0.17.0; Licença: GPL-3.0-only

## Implementado
- `kernel/arch/x86_64/virtio.zig`: `VRing` (16 descritores fixos), `VRingDesc`, `initVRing()`, `setupDescriptor()`, `notifyDevice()`, `submitDescriptor()`, `PciVirtioInfo`, `detectVirtioDevice()`, `BlockDriverInterface`
- `kernel/arch/x86_64/virtio_blk.zig`: `BlockDevice` (`init`, `readBlock`, `writeBlock`), `VRing` integrado, teste `virtioBlkInitAndDescriptorChain`
- `docs/roadmap/phase-status.md`: atualizado (`F7` → 🟢 Em desenvolvimento)
- `README.md`: milestones atualizados (`858f32a`)

## Testes
- `zig build`: passa (`vorynos.img` gerado)
- `zig build test`: `TEST EXIT: 0`
- `zig build qemu-test`: passa (`all checks passed`)
- `zig build qemu-test -smp 4`: inicia sem pânico (timeout TCG limita `VORYN-KERNEL-READY` — verificado previamente)

## Limitações
- `notifyDevice()` usa endereço fixo (`pci_virtio_base + 0x10`); acesso MMIO real depende do driver PCI completo (F7 final)
- `virtio_blk.zig` é stub: `readBlock`/`writeBlock` configuram descritores mas não validam retorno MMIO
- `BlockDriverInterface` ainda não conecta ao `scheduler.zig` ou ao `syscall.zig`
- Nenhum driver físico PCI completo ainda implementado

## Próxima etapa
Implementar `initAps()` real no `main.zig` (já presente) e conectar `virtio_blk.zig` ao `scheduler.zig` para I/O assíncrono, ou finalizar F7 com driver PCI completo.
