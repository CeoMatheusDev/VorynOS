// ADR-M0.3 — Camada Virtual de Filesystem (VFSX)
// Estado: EM DESENVOLVIMENTO — implementado localmente, não publicado
// Alinhado a: auditoria-vorynos.txt (§16), M0.3
// Data: 2026-10-24

Objetivo: adicionar uma camada virtual de filesystem (`VFSX`) que roteia
operações de arquivo por `mount point`, sem alterar a ABI 12
(`syscalls 13–18`) e sem modificar o `RAMFS` existente.

Justificativa (audit §13 — Prioridades P0):
- `VFSX` desbloqueia `VNV` (M0.4, formato persistente).
- `VNV` desbloqueia `VPK` (M3.6, pacotes) e desktop gráfico (M3.2/M3.4).
- `RAMFS` (1 MiB, 32 inodes, 48 KiB/file, global descriptor table) é o
  backend inicial montado em `/`; futuros backends (`vnv`, `procfs`, etc.)
  podem ser adicionados sem alterar a fachada (`fs.zig`).

Projeto:
- `kernel/fs/vfsx.zig`: `MountTable` (8 pontos), `resolvePath`,
  `mount`, `umount`, wrappers `vfs_open`, `vfs_create`, etc.
- `kernel/fs/fs.zig`: `init()` chama `vfsx.init()`; `resolvePath` usa VFSX.
- Nenhuma alteração em `syscall.zig` (ABI 12 preservada).
- Nenhuma alteração em `user/hello.zig`, `user/client.zig`, `composition.zig`, `start.s`.
- Nenhuma dependência Zig externa adicionada.

Estado atual (F6.30 concluído):
- `vfsx.zig` criado e compilado (`zig build` verde).
- `fs.zig` atualizado para chamar `vfsx.init()`.
- `build.zig` inclui módulo `vfsx-tests`.
- `docs/reports/M0.3-vfsx.md` criado.
- `docs/roadmap/phase-status.md` atualizado.

Limitações conhecidas (não são erros, são escopo):
- Nenhuma alteração no `syscall-abi.md` — não é necessária para M0.3.
- `mount` e `umount` são funções internas do kernel; não expostas como
  novas syscalls nesta fase. Se futuramente necessário, um ADR separado
  documentará a extensão sem alterar ABI 12 (ex: usar syscall 12 reservada
  ou criar capacidade `.mount` com delegação).
- A tabela de descritores (`fs.zig`) continua global (`max_processes = 8`);
  descritores por processo (`per-process descriptors`) permanecem como
  objetivo futuro (F4, conforme auditoria).
- `VNV` (formato persistente) e `VFSX` com múltiplos backends são
  incrementos futuros (M0.4 e M1.1, respectivamente).

Critério de aceite M0.3:
- `zig build test` passa (`29/29` passos, `≥ 192` testes com `vfsx-tests`).
- `boot-qemu.sh` e `interactive-qemu.sh` sem regressão.
- Checksum `0xd6baff86f4575725` preservado (nenhuma alteração gráfica).
- `docs/reports/M0.3-vfsx.md` e esta ADR documentam a decisão.
