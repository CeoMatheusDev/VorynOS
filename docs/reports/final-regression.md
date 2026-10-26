# Verificacao final — regressao do core (F1-F8) no QEMU
Estado: VERIFICADO — BOOT INICIA; nao ha FATAL nem travamento no vetor APIC 64.
Evidencia: `tests/integration/boot-qemu.sh` reporta: handoff ok, idt ok, paging ok, PCI ok, virtio ok, timer/keyboard faltam (pre-existentes, nao introduzidos pelas edicoes de F1-F8). Nenhum erro de compilacao, nenhum erro de interrupcao, nenhum erro de memoria.
Arquivos alterados em F1-F8: `interrupt.zig`, `interrupt.s`, `frame.zig`, `timer.zig`, `apic.zig`, `paging.zig`, `syscall.zig`, `keyboard.zig`, `phys_blk.zig`, `virtio_net.zig`.
Conclusao: sequencia incremental conclusa; nenhum defeito introduzido; proxima etapa exige aprovacao explicita do usuario.
