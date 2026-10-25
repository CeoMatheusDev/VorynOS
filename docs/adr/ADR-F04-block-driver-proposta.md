# Proposta F4 — Driver físico de bloco e persistência VNV
# Atualizado: 2026-10-25

## Estado atual (verificado)
- RamFS + VFSX + per-process descriptors: OK
- Unlink/rename (com rejeição de ciclo): OK
- Single indirect blocks: OK
- User-mode truncation: OK
- Host/kernel VNV codec: OK
- Block-device commit → wipe → recover sobre RAM-backed: OK
- Physical driver: **PENDENTE**

## Próximo incremento verificável
1. Implementar `kernel/arch/x86_64/virtio_blk.zig` completo (VRing, descritor, submit) — base já corrigido.
2. Integrar `kernel/storage/block.zig` com driver físico (AHCI/NVMe stub verificado).
3. Nenhum mock substitui execução real; benchmark de latência de commit/wipe/recover a ser medido.

## Critérios de aceite
- `zig build test` passa; `zig build qemu-test` passa; commit publicado para `main`.
- Nenhum arquivo vazio representa progresso.
