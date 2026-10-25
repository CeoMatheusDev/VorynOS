# Fechamento do ciclo — M0.5 + F7 (2026-10-25)

## Entregas concretas publicadas no `main`
- M0.5 (SMP): `spinlock.zig`, `smp.zig`, `apic.zig`, `ap_trampoline.s`, `scheduler.zig` (EEVDF + per-CPU), `installSmp()` + `startAps()`, `docs/reports/f0-5.md`, `README.md`, `docs/roadmap/phase-status.md`
- F6.30: `syscall.zig` (`input_wait`, syscall 23, ABI v13), `sdk/src/syscall.zig`, `tests/integration/boot-qemu.sh`
- F7: `virtio.zig`, `virtio_blk.zig`, `virtio_net.zig`, `pci.zig`, `docs/reports/f7/virtio-base.md`, `virtio-final.md`
- Corrige: `apic.zig` (`@intFromEnum`), `timer.zig` (`timerStop` removido)

## Commits principais
- `53dc842` (M0.5), `d664633`/`53dc842` (F7 testes VRing), `b28bb31` (relatório M0.5), `eb61550`/`ba4b6cf` (F7 base), `10333ee`/`d664633` (F7 VRing + PCI), `766e47b`/`53dc842` (F7 base), `7b98a70` (fix timer), `858f32a` (README update), `d4a5a46` (relatório F7 base), `c82eae0` (relatório final), `753bd0e` (roadmap F7 IN DEVELOPMENT)

## Validação
- `zig version`: 0.17.0
- `zig build`: passa (`vorynos.img`)
- `zig build test`: `TEST EXIT: 0`
- `zig build qemu-test`: passa; `-smp 4`: inicia sem pânico
- Nenhum mockup/TODO decorativo; nenhum segredo/tag/release alterado

## Estado atual
- M0.5: **CONCLUÍDO**
- F6.30: **CONCLUÍDO** (ABI v13)
- F7: **EM DESENVOLVIMENTO** (base + PCI + blk + net + testes + docs)
- F8/F9/F10: **PROPOSED**

## Próxima etapa (escolha)
1. Finalizar F7: integrar `virtio_blk.zig` ao `scheduler.zig` (I/O assíncrono) e adicionar driver PCI físico completo
2. F8: compatibilidade com formatos externos / APIs
3. Declarar ciclo fechado e iniciar documentação de manutenção
