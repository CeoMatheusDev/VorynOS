# Roadmap and implementation state

| Field | Value |
|-------|-------|
| **State** | ALIVE |
| **Date** | 2026-10-30 |
| **Published version** | `v0.1.0-dev.3` (tag) |
| **Working tree** | F4 block-device persistence/recovery (VNV volume), F5 VPK container, F6.29 client-frame verification, **F9 inference as a system call (2026-10-30)**, **F5 VLIB library container (2026-10-30)** **F6.31 shell taskbar with keyboard focus cycling (2026-10-30)** and **F6.32 PS/2 mouse and kernel cursor (2026-10-30)**; F9, VLIB and F6.31 were verified on the host **and** in the CI boot, F6.32 on the host only so far (run 41013843472, SHA `2348a56`). Not yet tagged |

The state below reflects the **existing and verified code**, and not the
intention. An item is only marked as completed when it meets every criterion
of the "definition of done" of the `AGENTS.md`.

The published version is registered here, and the official release notes are
in [`../releases/v0.1.0-dev.1.md`](../releases/v0.1.0-dev.1.md). The
reorganization of the public versioning milestones is registered in
[`../releases/VERSIONING-RESET-2026.md`](../releases/VERSIONING-RESET-2026.md).

> **Correction.** The tag `v0.1.0-dev.3` was published with source files
> that were not valid Zig (`kernel/fs/*.zig`, `kernel/elf_loader.zig`) and
> that were not part of any build. The working tree described below replaces
> them with compiling code covered by `zig build test` and by the boot test.
> No new tag is claimed by this document.

## Milestones

### F0 — Foundation — COMPLETED

| Objective | State | Evidence |
|----------|--------|-----------|
| Environment audit | COMPLETED | Zig 0.17.0, QEMU 10.2.2, OVMF, Fedora 44 verified |
| Toolchain and conventions | COMPLETED | ADR-0003, VN-NAMES-0001 |
| Minimal structure | COMPLETED | `boot/`, `kernel/`, `shared/`, `tools/`, `scripts/`, `docs/`, `tests/` |
| Reproducible build | COMPLETED | `build.zig` + `build.zig.zon` |
| Documentation | COMPLETED | README, AGENTS, ADRs, specifications, roadmap, testing strategy |
| ADRs | COMPLETED | ADR-0001 to ADR-0003 |
| Git | COMPLETED | branch `main`, descriptive commits, no publication |
| Initial tests | COMPLETED | `zig build test` (unit) and `zig build qemu-test` (boot) |

### F1 — Boot — COMPLETED

| Objective | State | Evidence |
|----------|--------|-----------|
| Minimal UEFI application | COMPLETED | `boot/uefi/main.zig`, target `x86_64-uefi` |
| Valid UEFI entry | COMPLETED | `EfiMain` per the ABI, `RDI` = contract |
| Diagnostic through the console | COMPLETED | firmware console, visible on the screen of the OVMF |
| Serial output | COMPLETED | UART 16550 on COM1, `shared/arch/x86_64/serial.zig` |
| Framebuffer discovery | COMPLETED | GOP, selection of the 32 bpp mode, mask and channel offset |
| Memory map | COMPLETED | reading and normalization, tolerant to the descriptor size |
| Loading of the kernel image | COMPLETED | EFI volume, file `VORYNK.ELF` |
| Validation of the segments | COMPLETED | `shared/elf64.zig`, with unit tests |
| Bootloader-kernel contract | COMPLETED | `shared/handoff.zig`, specified in `docs/specs/` |
| Correct `ExitBootServices` | COMPLETED | final map captured before the call, repetition in case of an altered map |
| Transfer of control | COMPLETED | jump to `voryn_kernel_entry` with the contract in `RDI` |

### F2 — Kernel — LOCALLY TESTED

| Objective | State | Evidence |
|----------|--------|-----------|
| Kernel entry | COMPLETED | `kernel/arch/x86_64/entry.s`, own stack, documented ABI |
| GDT | COMPLETED | own table with the code and data of levels 0 and 3, verified by `sgdt` |
| TSS | COMPLETED | task segment loaded, with the interrupt stack for the double fault |
| IDT | COMPLETED | 256 entries, verified by `sidt` |
| Exceptions | COMPLETED | handler with the vector, the error code, the RIP and the registers |
| Hardware interrupts | COMPLETED | entries 32 to 47, 8259 controllers reprogrammed |
| Timer | COMPLETED | 8254 in mode 3, 100 Hz, counting verified |
| Physical memory | COMPLETED | `kernel/memory/physical.zig`, 4 GiB bitmap, 51551 pages |
| Virtual memory | COMPLETED | `kernel/arch/x86_64/paging.zig`, own tables, `CR3` switched |
| Kernel heap | COMPLETED | `kernel/memory/heap.zig`, boundary tags, block merging, corruption detection |
| Isolation | COMPLETED | each process has its own address space; the kernel and the framebuffer are mapped in every space, and the rest of the memory is not reachable |

Verified sequence on the serial console:

```text
[VNK] segments: gdt installed and verified
[VNK] interrupts: idt installed and verified
[VNK] segments: task state segment loaded
[VNK] memory: 51551 pages, 360 used, 51191 free
[VNK] paging: cr3 0xf401000 -> 0x355000
[VNK] heap: 256 KiB region, 0 allocations, 0 bytes used
[VNK] timer: 100 Hz, 5 ticks
[VNK] framebuffer: write probe succeeded
VORYN-KERNEL-READY
[VNK] EXCEPTION 6: invalid opcode
```

Known limitations of the milestone:

- The heap is a fixed region of 256 KiB inside the kernel image, because the
  region has to stay mapped after the switch of the page tables.
- The bitmap of the physical memory manager covers 4 GiB of the physical
  address space.
- The task segment is loaded, and the index of the interrupt stack is used by
  the stack of the double fault.
- The user mode exists: the user segments are in the table, the user pages
  have the user bit, and the user task runs, calls the kernel and receives
  the answer.
- The exception handler is fatal **in the kernel**: the execution stops at
  the first kernel error, because the state of the kernel after the error is
  unknown. The exception that came from the user mode kills the process, and
  the kernel continues.

### F3 — Execution — IN DEVELOPMENT

Objectives: threads, scheduler, processes, user mode, syscalls, IPC,
capabilities.

| Objective | State | Evidence |
|----------|--------|-----------|
| Preemptive scheduler | COMPLETED | alternation verified by the timer |
| Kernel tasks | COMPLETED | two worker tasks, 20 switches measured |
| Cost of the context switch | COMPLETED | measured on every switch, with the smallest and the average on the console |
| Policy without starvation | COMPLETED | the visit continues after the current task |
| Preparation of the coprocessor | COMPLETED | the firmware leaves it disabled |
| Page tables with user mode | COMPLETED | the user bit exists in every level |
| Complete task context | COMPLETED | the fifteen registers are preserved on every switch |
| Floating point state per task | COMPLETED | the state is saved at the entry of the interruption and of the call, and restored by the switch |
| Kernel stack separated from the code stack | COMPLETED | the processor frame is never in a page of the user |
| System call | COMPLETED | the `syscall` instruction, with the handler in Zig |
| Contract of the system call | COMPLETED | eleven calls, with the contract in `docs/specs/syscall-abi.md`, version 6 |
| Checking of the user ranges | COMPLETED | a call with an address of the kernel is refused |
| User mode | COMPLETED | the task writes in its page and the answer of the call comes back |
| Task segment of the 64 bit mode | COMPLETED | the layout is verified at compile time |
| Tolerance of the overlap in the copy | COMPLETED | a copy with overlapping ranges is answered, and does not raise a panic |
| Verification of the content of the copy | COMPLETED | the content is checked byte by byte, and not only the length |
| User mode window | COMPLETED | the address is chosen outside the kernel image and delivered to the task |
| Address spaces per process | COMPLETED | each process has own tables, and the scheduler switches the space |
| Isolation between processes | COMPLETED | two processes write different values in the same virtual address |
| Copy between processes | COMPLETED | the block goes from one process to the other, and the space of the caller does not change |
| VNX channel | COMPLETED | the message leaves one process and arrives at the other, and the answer comes back |
| Latency of the delivery | COMPLETED | the interval between the message leaving and the message arriving, measured in the clock of the processor |
| Wait that does not occupy the processor | COMPLETED | the task stays blocked, the scheduler chooses another one, and the message wakes it up |
| Wait with a timeout | COMPLETED | the call 11 waits at most the given number of ticks, the timer expires the wait, and the call answers with the error 13; ADR-0010 |
| Direct delivery to the context of the task | COMPLETED | the message does not stay in the queue, and the task continues after the call |
| Frame of the call with the format of the interrupt frame | COMPLETED | the same switch serves the blocking and the preemption |
| Processor frame with one single shape | COMPLETED | the stub normalizes the frame, and the handler and the switch read the same shape |
| Handling of the exceptions by type | COMPLETED | the exception of the user mode kills the process, and the one of the kernel stops the machine |
| Recovery of the process that failed | COMPLETED | the process dies, the others continue, and the machine reaches the end of the boot |
| Capability fabric of the VNC | COMPLETED | the kernel holds the table, the process holds the set, and the chain of delegation stops |
| Capabilities of the channels of the VNX | COMPLETED | a process without the capability of the channel is refused, and the owner delegates and revokes it |
| Capability of the address space of a process | COMPLETED | the copy into the space of a process without the capability is refused |
| Delegation of the address space through the calls | COMPLETED | the owner delegates the capability of the process to the third process and takes it back, with the kind of the capability |
| Capability of the display | COMPLETED | kind 2, subject 0, rights `write` and `delegate`; `present` checks it before reading the request |
| Capability of the input | COMPLETED | kind 3, subject 0, rights `read` and `delegate`; `input_poll` checks it before the output or the queue |
| Capability of a generic device | PROPOSED | the capability of drivers and other devices is not implemented; only the display and input kinds exist |

The user mode is **implemented and verified**. The user task runs in the
third privilege level, writes in its own page of data, calls the kernel with
the `syscall` instruction and receives the answer in the same register. The
interrupt trace of the emulator **does not register any exception** during
the whole execution.

The defect that blocked the milestone was the **layout of the task segment**:
the kernel used the layout of the protected mode, and in the 64 bit mode the
stack of ring 3 is at offset 4, the table of the interrupt stacks begins at
36, and the structure has 104 bytes. The processor read the stack pointer at
the wrong offset, and the delivery of every exception that came from the
user failed with a stack fault and a double fault. The full diagnosis, with
the measurements and the conclusion that proved to be wrong, is in ADR-0005.

The system call uses the `syscall` instruction, the path that the
architecture provides for the 64 bit mode, because the interrupt gate is a
legacy path and because the handler runs on the kernel stack of the task,
and not on the stack of the user.

The increment of the processes corrected three defects that came from the
previous design, and that the diagnosis of ADR-0005 had not reached: the
context switch did not save the registers that the architecture does not
save between calls, the processor frame of the way back was built over the
stack of the interrupted code, and the user mode window had a fixed address
inside the kernel image. The full diagnosis, with the measurements and the
conclusion, is in ADR-0006.

Acceptance criteria of the rest of the milestone:

1. A task in user mode runs, which proves the segment table, the user stack
   and the switch of privilege. **Fulfilled.**
2. The first system call copies a block of memory of the user.
   **Fulfilled:** the `memcpy` call copies a block between two pages of the
   user, after checking the two ranges in the page tables, and a call with an
   address of the kernel is refused. The copy **between processes** also
   exists: the `copy_to` call carries a block from the space of one process
   to the space of another, and the space of the caller does not change.
3. The message channel of the VNX delivers a message between two processes
   and measures the latency. **Fulfilled:** the process of role zero sends
   the message, the process of role one receives it and answers, and the
   answer comes back through the same channel. The measured latency is the
   interval between the message leaving and the message arriving, read in
   the clock of the processor, and not the wait of a turn of the scheduler.
4. The wait for a message **does not occupy the processor**. **Fulfilled:**
   the call that blocks marks the task as blocked, the scheduler chooses
   another one, and the message wakes the task up. The result of the call
   arrives in the context saved of the task, and the task continues after
   the call, as if it had answered at once. The delivery is direct, and
   therefore the latency that is reported is the one of the delivery. The
   diagnosis and the measurement are in ADR-0007.
5. An exception of the user mode **kills the process**, and not the machine.
   **Fulfilled:** a third process writes in an address that is not mapped,
   and the page fault is handled: the process is killed, the console says
   that the kernel continues, the timer keeps counting, the conversation
   between the other two processes completes the round trip, and the machine
   reaches the `VORYN-KERNEL-READY` marker. The increment also corrected a
   defect that already existed: the processor frame has two shapes, and the
   one with an error code is eight bytes larger. The diagnosis is in
   ADR-0008.

6. A process does not use a channel that it does not hold the
   capability of. **Fulfilled:** the kernel holds the table of the
   capabilities and every process holds a set of them, the calls of the
   channel check the capability of the process of the caller before they
   touch the queue, and the process that holds no capability is refused
   with the error 10. The owner of the channel delegates the capability to
   another process and takes it back, and the delegation that does not
   carry the right of delegation stops the chain. The diagnosis is in
   ADR-0009.

7. A wait has a **bound**. **Fulfilled:** the call 11 waits for a message
   at most the given number of ticks of the timer, the handler of the
   timer expires the wait before it chooses the next task, the wait is
   removed from the queue, the message that arrives later stays in the
   queue, and the call answers with the error 13. The unit tests of the
   queue verify the expiry, and the boot test verifies the call end to
   end. The decision is in ADR-0010.

What is still missing in the milestone:

1. **The capability of the devices.** The model covers the channels and
   the address spaces, and a device is not a subject yet: the framebuffer
   is the only device of the kernel, and no capability describes it. The
   question of the ADR-0001 is answered for the shared resources, and it is
   open for the devices.
2. **More processes.** The kernel creates three processes, and it is two of
   them that talk: the third exists to prove that a process that fails does
   not bring the others down. The number of address spaces is limited by a
   constant of the paging module.
3. **The wait on several channels.** A task waits for one channel and one
   side; the timeout bounds one wait, and it does not select among several
   ones.
4. **The dynamic heap** with the VNM, the **signal in the process**, with a
   handler in the user space, and the **policy by type of exception**,
   which today is the same for every exception of the user mode.
5. **The measurement of the cost of the context switch** under a
   representative load, with more tasks and more processes.

The message channel taught an initialization rule that is valid for the whole
kernel: everything that the tasks can use has to exist **before** the timer,
because the timer is what starts to run the tasks. The initialization of the
channels came after, and reset the queues, and erased the message that the
task of the user mode had sent in its first turn. The diagnosis and the
rule are in ADR-0005.

### F4 — Storage and file systems — IN PROGRESS

Objectives: RamFS, block layer, VNV, VFSX, persistence and recovery.

| Objective | State | Evidence |
|----------|--------|-----------|
| Block allocator | COMPLETED | bitmap with one bit per block, block 0 reserved, allocation, release and exhaustion verified by unit tests |
| File data | COMPLETED | up to 12 direct blocks (48 KiB), write, write at offset, truncate and read at offset, with old content preserved when a write is refused |
| Directory table | COMPLETED | fixed table with parent, name and inode, duplicate-name refusal, `listDir` |
| Path lookup | COMPLETED | absolute or root-relative paths, `.` ignored, `..` refused, nested directories |
| Descriptor facade | COMPLETED | `open`, `close`, `read`, `write`, `seek`, `create` and `mkdir`, with access flags and a bounded table |
| Host tests | COMPLETED | `zig build test` runs 13 tests of the RamFS and the descriptor facade |
| Syscalls 13–18 | COMPLETED (kernel glue) | `fs_open`, `fs_close`, `fs_read`, `fs_write`, `fs_create` and `fs_mkdir` call the facade after checking the user range |
| Boot self-test | COMPLETED | the kernel creates `/apps`, writes `/apps/hello.txt`, reads it back and compares the content before `VORYN-KERNEL-READY` |
| Persistence and block driver | IN DEVELOPMENT | `kernel/storage/block.zig` mantém a API e o backend RAM/VNV já verificados; `kernel/drivers/vvdi/block.zig` conecta VirtIO Block à API com DMA, IN/OUT, conclusão validada, timeout e FLUSH opcional. Na auditoria, `zig build test --summary all` passou 554/554 (544 existentes + 10 novos testes VVDI); o HEAD anterior executava 550 porque quatro testes da API de bloco não eram coletados após a migração para módulo nomeado, corrigido pelo alvo explícito `block-api-tests`. CI `40580172526` validou dois boots QEMU/OVMF no SHA `186e14c1f02ca455d784aea6908e401edb51c5e1`; a evidência de commits posteriores é a CI associada ao SHA correspondente. Sem validação em hardware físico. Ver `docs/reports/f7/virtio-blk-pr-d.md` |
| VNV and VFSX | IN DEVELOPMENT | `kernel/fs/vfsx.zig` provides bounded mount routing and generation checks; `kernel/fs/vnv.zig` provides a validated host/kernel codec and `vnv_volume.zig` the block-device commit/recovery; durable physical storage remains pending |
| Per-process descriptors | COMPLETED (host/QEMU) | `fs.zig` keeps independent descriptor tables, offsets, lifecycle cleanup and generation-checked internal handles per process |
| Unlink, rename, indirect blocks | COMPLETED (host/QEMU) | regular-file unlink/rename, deferred inode reclamation, single indirect blocks (files beyond 12 direct blocks, up to 524 blocks per the format) and directory rename with subtree preservation and cycle rejection are all tested; double indirect blocks remain absent |

Known limits of the verified core:

- the RamFS is fixed at 1 MiB (256 blocks of 4 KiB), with 32 inodes and 64
  directory entries;
- a file uses the 12 direct block pointers plus a single indirect table
  (up to 524 blocks per the format, bounded by the 1 MiB volume in
  practice); the double indirect table is not implemented;
- there are no `.` and `..` entries, and `..` is refused by the resolver;
- each process has a fixed table of 16 descriptors; internal checked handles
  add generation validation, while the public syscall ABI still uses `u32` FDs;
- the filesystem is exercised end to end by the native ELF application,
  including `fs_truncate` (syscall 22); block-device commit/wipe/recovery
  is verified over the RAM-backed device, and a physical driver remains
  pending;

### F5 — Runtime, SDK and native applications — IN PROGRESS

Objectives: VEX, VLIB, VPK, runtime, SDK and native applications.

| Objective | State | Evidence |
|----------|--------|-----------|
| ELF64 parser | COMPLETED | `shared/elf64.zig`, with bounds-checked headers, segments and relative relocations |
| Load planner | COMPLETED | `kernel/elf_loader.zig`, `plan` validates the image and computes the page range, permissions and entry point |
| W^X | COMPLETED | a segment with write and execute is refused; there is a unit test for it |
| Page overlap | COMPLETED | two segments that share a page are refused; there is a unit test for it |
| Window and alignment | COMPLETED | segment and entry must fall inside the requested window, with `p_vaddr ≡ p_offset (mod p_align)` |
| Entry validation | COMPLETED | the entry has to be inside an executable segment that comes from the file |
| RamFS integration | COMPLETED | `planFromRamFs` reads the file, refuses a truncating buffer and plans the image |
| Host tests | COMPLETED | nine planner tests, including the RamFS path |
| Materialization | COMPLETED | `kernel/elf_materializer.zig`: physical allocation, mapping, content copy, zeroing of BSS, relative relocations, stack pages, CR3 restore and cleanup of a partial load |
| Hardware W^X | COMPLETED | `EFER.NXE` is required at boot; code pages are R+X, data and stack pages are R+W+NX; the kernel reads the page-table entries back before starting the native task |
| Native user application | COMPLETED | `/apps/hello.elf`, an ET_DYN image with two PT_LOAD segments and one R_X86_64_RELATIVE, runs as the fourth process and exits with code 0 |
| Host tests | COMPLETED | 26 tests in `fs-loader-tests` (RamFS, planner, native image and per-process descriptors); 90 host tests in total |
| Per-process descriptors | COMPLETED | `fs.zig` keeps one table per process, with independent offsets and unknown-process rejection |
| VEX, VLIB, VPK and SDK | IN DEVELOPMENT | the freestanding SDK, syscall wrappers, display/input/compositor contracts and native ELF applications are present; the VPK container (`formats/vpk.zig`) is implemented with host tests and a boot self-test (pack → RamFS → VNV persistence → recovery → unpack); the VEX executable container (`formats/vex.zig`, spec in `docs/specs/vex.md`) wraps the SDK-built toolchain ELF with a capability manifest, and `planFromRamFs` unwraps, validates (magic, geometry, CRC, manifest) and plans the inner ELF during the boot; the manifest is enforced against the kernel grant at process spawn; the VLIB library container (`formats/vlib.zig`, spec in `docs/specs/vlib.md`) carries an ELF64 relocatable image with the library name, its symbols (exported and hidden), the syscall ABI version and the required capability mask, protected by an image CRC and a table CRC, and the boot packs `/lib/libvoryn.vlb` from the toolchain image, commits it through VNV, recovers the volume, compares the recovered file byte for byte with the packed buffer, revalidates the container and checks that `voryn_main` is exported while `internal_helper` is not. **No linker, relocation processing or in-process library loading is implemented or claimed** |

The planner is deliberately pure: it does not allocate, map or spawn. The
materializer consumes the `LoadPlan` and owns the hardware-dependent work.
Its verification is the QEMU boot, where the kernel reads the page-table
permissions back, checks that the relative relocation holds the load bias
and waits for the native tasks to terminate. The freestanding SDK now builds
`hello` and compositor-client ELF images through the normal Zig build graph;
the ELF files go through the RamFS and are validated by the same planner used on
the host.

### F6 — Graphics and input — IN DEVELOPMENT

Objective: an own rasterizer, opaque window compositor, damage tracking and
PS/2 input, with a verified interactive path in QEMU.

Lido com cuidado, o estado é este: existe um **desktop de cena** dentro do
kernel (`kernel/graphics/desktop.zig`, com `window_manager.zig`,
`window_renderer.zig` e `session.zig`), e o boot apresenta duas janelas
gerenciadas, agora com a **barra da shell** (F6.31).

Correção de duas afirmações anteriores deste documento e do `README.md`:

- **o foco entre clientes existe** desde `session.zig`: o teclado vai
  exclusivamente à janela em foco, o clique muda o foco e o renderizador
  colore a janela focada. A frase "sem foco entre clientes" era falsa;
- **29 testes de oito arquivos gráficos não rodavam**, porque nenhum binário
  de teste os importava (`frame`, `session`, `window_manager`,
  `window_renderer`, `pointer_input`, `event_queue`, `framebuffer_bridge` e
  `desktop`). Desde F6.31 existe o binário `desktop-tests` (49 provas).

O que **não** existe: texto na barra (não há fonte no kernel), lançador, área
de notificação e serviço gráfico em espaço de usuário. O **cursor** e o
**driver de mouse PS/2 (IRQ12)** passaram a existir em F6.32, junto com o
decodificador de pacotes, o handshake do 8042 e a seta desenhada pelo
kernel; o que falta é o uso dos **botões** (clique, arrasto, foco por clique)
e a aceleração do ponteiro. A frase "desktop shell remains future work" continua verdadeira para
esses itens; a frase "desktop pending" seria falsa.

| Objective | State | Evidence |
|----------|--------|-----------|
| GOP framebuffer | COMPLETED | `boot/uefi/vnb/framebuffer.zig` selects a 32 bpp mode and hands the base, pitch and masks to the kernel |
| Rasterizer and opaque compositor | COMPLETED | `kernel/graphics/raster.zig`, `compositor.zig`, with host tests for clipping and z-order |
| Damage tracking | COMPLETED | `kernel/graphics/damage.zig`, with pixel-equivalence tests against full composition |
| PS/2 Set 1 input | COMPLETED | `kernel/input/ps2.zig` consumes IRQ1; `keyboard.zig` decodes make/break and extended keys with a bounded queue |
| Arrow-key window motion | COMPLETED | `kernel/graphics/keyboard_motion.zig`, clamping at every framebuffer edge |
| Interactive event loop | TESTED LOCALLY | selected by the I key; `tests/integration/interactive-qemu.sh` validates it in QEMU |
| Framebuffer integration tests | TESTED LOCALLY | six-step, edges, bounds and stress routes compare P6 screendumps pixel by pixel |
| F6.22.2 monitor/ACK instrumentation | TESTED LOCALLY | HMP round trips and ACK-window timings distinguish the harness from the kernel |
| F6.23 kernel phase timing | TESTED LOCALLY | TSC calibration against the PIT; PS/2 IRQ, motion, ACK log, render and trailing log are reported per eight arrows |
| F6.24 exposed-strip damage | TESTED LOCALLY | opaque moves invalidate only the exposed strips; 16-event throughput rose from 0.4 to 6.7 events/s in Debug/TCG |
| F6.31 shell taskbar | TESTED IN CI | `kernel/graphics/taskbar.zig`: one button per visible window in z-order, click target and gutter tested, focused button highlighted; the bar is not a window and stays out of the z-order. The three boot assertions passed in QEMU/OVMF (run 41013843472, SHA `2348a56`) |
| F6.31 focus switching | TESTED IN CI | `window_manager.focusNext` cycles the visible windows of the z-order without reordering them; `Desktop.cycleFocusAndPresent` repaints the frame and keeps the bar |
| F6.32 PS/2 mouse | TESTED LOCALLY (host) | `kernel/input/mouse.zig` decodes the three-byte packet (sync bit, signs, Y inverted once, overflow saturated and counted), FIFO of 32 packets that drops the newest; `ps2.initAuxiliaryIrqsDisabled` does the 8042 handshake with ACK required and every wait bounded; IRQ12 dispatched and unmasked with the cascade line. Boot assertions implemented, CI pending |
| F6.32 kernel cursor | TESTED LOCALLY (host) | `kernel/graphics/cursor.zig`: text-defined arrow sprite, clipping, clamping; `Desktop.movePointerAndPresent` re-composes the covered rectangle from the window model and draws the arrow last — a test proves two partial moves match a full presentation byte for byte |
| F6.31 harness repair | COMPLETED | `desktop-tests` collects the eight graphics files that no test binary imported: **29 tests that never ran** now run in `zig build test` (49 in the binary, 9 of them repeats) |
| F6.25 display metadata call | TESTED LOCALLY | syscall 19 (`display_info`, ABI 10) returns the versioned `DisplayInfo` to the native SDK application; no framebuffer address is exposed |
| F6.26 display presentation | TESTED LOCALLY | syscall 20 (`present`, ABI 11) copies a validated 16x16 rectangle from the native SDK application; the display capability (kind 2) is checked first and the first pixel is read back as `0xff` |
| F6.27 input event capability | TESTED LOCALLY | syscall 21 (`input_poll`, ABI 12) takes one event from the user queue with the input capability (kind 3, `read`); the boot test sends `right`, the application presents at (16,0) and the kernel diagnostic queue keeps its copy |
| F6.28 user-space composition | TESTED LOCALLY | `user/composition.zig` composes a 32x24 grayscale frame in the native application; the boot test captures a P6 screenshot and matches its FNV-1a checksum to the application; a third process without display/input capabilities is refused by `present` and `input_poll` with error 10 |
| F6.29 client-frame IPC | TESTED LOCALLY | the client process sends WNDPLACE, waits for COMPRDY, copies its frame to the compositor surface via `copy_to` and publishes FRAME1 with the window checksum; the compositor verifies the same hash over the received region and presents it; the boot test asserts the client-published checksum equals the compositor-accepted checksum and the QEMU screenshot matches the composed surface |
| User-space graphics service | IN DEVELOPMENT | `display_info`, `present`, `input_poll`, the composition demo, screenshot verification, the refusal tests and the client→compositor frame handshake are verified locally; surface sharing, focus, cursor and blocking/per-process input remain proposed in ADR-0015 **for the user-space service**; the kernel scene has its own focus delivery and, since F6.31, a taskbar |

Measured environment for F6.22.2/F6.23/F6.24: Fedora 44, Zig 0.17.0,
QEMU 10.2.2, OVMF, `-smp 1`, 256 MiB, no KVM (TCG), GOP mode 2048x2048.
The absolute numbers are emulator numbers, not hardware numbers. The
optimization removed the full-window repaint from the hot path. In Debug
the remaining cost was guest code plus MMIO; ReleaseFast reduced the
render to 3.79 ms per arrow, and the end-to-end test then became limited
by QEMU's key-hold pacing.

Known limitations of the verified F6 core:

- `display_info`, `present` and `input_poll` are the user-space graphics
  calls; there is no surface sharing, window manager, focus model, cursor,
  blocking input or per-process input queue;
- the `present` path is synchronous, without double buffering or vsync;
  the F6.28 composition is a single-application 32x24 frame, not a
  multi-client compositor scene;
- the QEMU refusal without the display and input capabilities is verified,
  but the composition and copy path still has no TSC measurement;
- text and general shapes are not part of the rasterizer yet;
- input is PS/2 Set 1 only; there is no mouse or USB HID;
- the bootloader prefers the largest 32 bpp GOP mode, which in QEMU is
  2048x2048 and amplifies framebuffer emulation cost;
- the performance numbers were measured under TCG in Debug and
  ReleaseFast; a real machine remains unmeasured.

### F9 — Inference — TESTED IN CI (2026-10-30)

The inference stopped being a library that nobody imported. The decisions and
the measurements are in [`../reports/f9/f9-inference-call.md`](../reports/f9/f9-inference-call.md)
and in the [`ADR-0023`](../adr/ADR-0023-ai-inference-capability.md).

| Objective | State | Evidence |
|-----------|--------|-----------|
| Model embedded in the kernel | COMPLETED | `kernel/ai/embedded.zig`: image built at compile time, CRC32 of the weights computed by the compiler |
| Validation on every call | COMPLETED | `model.validate` recomputes the CRC before the inference; a corrupt image answers with the error 26 |
| Boot self-test | COMPLETED | `verifyAiSelfTest()` runs before the timer and halts the boot on a divergence |
| Capability of the engine | COMPLETED | kind 4, wire value 4, right `execute` (32); granted to the composing process without delegation |
| Call 24 `ai_infer` | COMPLETED | `shared/ai.zig` is the contract; capability checked before length and address |
| Ring 3 proof | TESTED IN CI | `user/hello.zig` sends the sample and compares the result bit by bit; the boot log line `[VNK] syscall 24 from user ai_infer result 0xc` is asserted in run 41013843472 |
| Isolation proof | TESTED IN CI | `user/client.zig` has no capability and is refused with the error 10; the boot log line with `0xfffffffffffffff6` is asserted in run 41013843472 |
| Host tests | COMPLETED | `ai-tests` 10/10, `shared-tests` 59/59, `sdk-tests` 5/5 |
| Boot assertions | TESTED IN CI | nine markers in `tests/integration/boot-qemu.sh`; run [41013843472](https://github.com/CeoMatheusDev/VorynOS/actions/runs/41013843472) passed the QEMU boot step on SHA `2348a56`. Locally QEMU/OVMF remain absent (BLOQUEADO) |
| GPU, quantization, batching | ABSENT | out of scope of the milestone, and not claimed |

### F4 to F10 — summary

| Milestone | Content | State |
|-------|----------|--------|
| F2 | Processor structures, interrupts, memory | LOCALLY TESTED — `timer.zig` (safe_divisor); `paging.zig` (`AlreadyMapped`, não substitui); `apic.zig`; `interrupt.zig`/`.s` (vetor 64) |
| F3 | Threads, scheduler, processes, syscalls, IPC | COMPLETED — `syscall.zig` (`local_buffer`); `keyboard.zig` (drop mais antigo) |
| F4 | Storage, file systems | IN PROGRESS — RamFS/VFSX e persistência/recovery em backend RAM verificados; VirtIO Block foi integrado à API em PR D e passou dois boots QEMU/OVMF no CI anterior; sem montagem de filesystem em disco nem validação em hardware físico |
| F5 | Runtime, SDK, native applications | LOCALLY TESTED + BOOT IN CI — `elf_loader.zig` (auditado W^X, relocations, entry executável); `native_image.zig`; SDK `hello`; `vex.zig`; `vlib.zig` (contêiner de biblioteca: 9 testes de host e autoteste de boot verde no run 41013843472). SEM LINKER: nenhuma biblioteca é ligada ou carregada em processo |
| F6 | Graphics, desktop, input | EXPERIMENTAL — F6.30 `input_wait` (syscall 23, ABI v13) verificado; F6.31 barra da shell com foco por teclado (**TESTADO NO CI**) e `desktop-tests`; F6.32 mouse PS/2 (IRQ12, handshake com ACK) e cursor desenhado pelo kernel, **testados no host**; sem fonte e sem uso dos botões; compositor usuário pendente |
| F7 | Virtio drivers / PCI / block / net | IN DEVELOPMENT — `virtio.zig` (fila split-virtqueue, 9 testes); `pci.zig` (limites byte/word, IRQ-safe); `virtio_blk.zig` é interface provisória, **não** é driver: `blk_read`/`blk_write` devolvem `error.NotImplemented` sempre (4 testes de regressão em `arch-tests`); `virtio_net.zig` continua stub (sem init/RX/TX); nenhum driver de bloco funcional, nenhuma rede completa; regressão validada em `zig build test` e no boot QEMU da CI (run `40361111218`). PR A do VirtIO moderno (2026-10-26): fundação em `kernel/drivers/virtio/` (tipos, identificadores, estados, features e capabilities) mais percurso genérico de capabilities e validação de BAR em `pci.zig`; 42 testes novos no host (`arch-tests` 63 → 76, `virtio-modern-tests` 29); **não** há transporte MMIO, negociação real, virtqueue nem driver — ver `docs/reports/f7/virtio-pci-modern-pr-a.md` PR B do VirtIO moderno (2026-10-26): transporte PCI moderno funcional — MMIO próprio com mapeamento injetado, BAR medido e validado, configuração comum lida do hardware, `VIRTIO_F_VERSION_1` negociado e `FEATURES_OK` confirmado; estado final `awaiting virtqueue setup`, sem virtqueue e sem `DRIVER_OK`; ver `docs/reports/f7/virtio-pci-modern-pr-b.md`. PR C do VirtIO moderno (2026-10-27): virtqueue dividida nativa em `kernel/drivers/virtio/virtqueue.zig` (descritores de 16 B alinhados a 16, anel `available` alinhado a 2, anel `used` alinhado a 4, free list O(1) no campo `next`, bitsets livre/alocado/publicado, publicação com `release` + `mfence` e consumo com `acquire`), programação de `queue_size`/`queue_desc`/`queue_driver`/`queue_device` e `queue_enable` confirmado por leitura em `pci_transport.zig`, e `DRIVER_OK` com fechadura em `transport.zig` (`NoQueueConfigured`/`NotReadyForDriverOk`); o boot termina com status `0x0f`, fila 0 habilitada e vazia, sem publicar pedido e sem I/O de bloco; ver `docs/reports/f7/virtio-pci-modern-pr-c.md` e o ADR-0020. PR VVDI (2026-10-27): subsistema reorganizado sob a identidade nativa **VVDI — Voryn Virtual Device Interface** (`kernel/drivers/vvdi/`, import `vvdi`, alvo `vvdi-tests` 110/110, prefixo serial `[VNK] vvdi:`), preservando identificadores da especificação VirtIO 1.2 e os módulos legados `kernel/arch/x86_64/virtio*.zig` intocados; `boot-qemu.sh` endurecido contra *fail-open* com autoteste `tests/integration/log-assertions-test.sh` (7/7 cenários na CI); ver ADR-0021 e `docs/reports/f7/vvdi-debt.md` (dívidas A-3, D-6 e D-7). PR D (2026-10-27): `kernel/drivers/vvdi/block.zig` conecta VirtIO Block à API de bloco com IN/OUT, conclusão validada, timeout limitado, contenção após falha, read-modify-write e FLUSH opcional. Na auditoria local, o HEAD anterior executava 550 testes: quatro testes da API de bloco tinham saído do runner ao virar módulo nomeado; foi adicionado `block-api-tests` explícito para preservá-los. O total esperado no HEAD corrigido é 554 (544 base + 10 novos testes VVDI), a confirmar na validação local abaixo. `tests/integration/virtio-block-persistence.sh` exige disco de dados separado, assinatura opt-in, escrita/FLUSH/leitura/comparação no Boot 1 e leitura/comparação do mesmo arquivo no Boot 2 sem reescrita. CI 40580172526 passou no SHA anterior `186e14c1f02ca455d784aea6908e401edb51c5e1`, comprovando dois boots QEMU/OVMF nesse HEAD; esta auditoria retém BAR e DMA se reset não for confirmado, ignora falha de leitura antes da assinatura opt-in e serializa os testes QEMU no grafo de build. Para commits posteriores, vale somente a CI do SHA correspondente; QEMU/OVMF ausentes localmente, hardware físico não testado. PR #15 permanece Draft, sem merge. Ver `docs/reports/f7/virtio-blk-pr-d.md`, `docs/reports/f7/vvdi-debt.md` e `docs/testing/testing-strategy.md`.  Contenção PCI/DMA (2026-10-28, ADR-0022): `pci.zig` passa a expor `setBusMaster`/`setBusMasterWith` com leitura de volta, e `kernel/drivers/vvdi/containment.zig` modela o estado do dispositivo (`disarmed`/`armed`/`contained`/`contained_unrevoked`) com motivo e resultado de revogação; o driver de bloco escala cada envenenamento para esse estado e a orquestração de boot só devolve a memória da fila com reset confirmado, agora também exigindo `Containment.permitsMemoryRelease`; a falha de configuração depois de `DRIVER_OK`, que antes retornava sem diagnóstico nem estado, passa a conter o dispositivo e emitir `FATAL`. Revogar *bus master* não é tratado como quiescência DMA e o reset confirmado não é alegado como prova portável de drenagem. A confirmação da escrita foi ampliada (R-3): a leitura de volta passou a exigir a preservação de *todos* os bits do `Command`, com comparação relativa justificada pela ausência de bits RW1C nesse registrador, e o `Status` continua fora da comparação. Isolamento de ciclo de vida (F-1): `Containment.beginNewLifecycle` só apaga o estado quando o chamador comprova que a fila foi devolvida, que não sobrou memória DMA e que nenhum driver ativo aponta para a instância, além do reset confirmado e da ausência de quarentena; qualquer recusa preserva a contenção. A CI passou em 12/12 no SHA `470c5f8` (run 40662431437), anterior a esta correção, que tem apenas validação local. `zig build test` passa com 596 testes (`arch-tests` 91, `vvdi-tests` 148; antes 554); `zig build`, `zig fmt --check` e `log-assertions-test.sh` 7/7 passam localmente; QEMU/OVMF seguem ausentes neste ambiente, então os passos de boot ficam para a CI do SHA. Correção documental: o PR #15 está **integrado** (merge em 2026-10-28), não Draft; o total de 554 testes citado acima foi confirmado na auditoria local deste ambiente. Ver `docs/reports/f7/vvdi-containment.md` e `docs/adr/ADR-0022-pci-dma-containment.md`. Injeção de falhas e verificação de contenção DMA (2026-10-28, PR #19): `kernel/drivers/vvdi/fault_injection.zig` acrescenta um dispositivo VirtIO Block simulado (registradores da configuração comum, configuração do tipo bloco, anel `available` lido e anel `used` escrito por bytes) atrás do transporte PCI **de produção**: `caps.parse`/`caps.build`, `Transport.attach`, `transport.Device`, `pci_transport.configureQueue`/`enableQueue`, `virtqueue.Queue` e `block.Driver` são os mesmos do boot, e o simulador não chama nenhuma rotina do driver. `FakeBar` de `pci_transport.zig` continua privado. 19 testes novos em `vvdi-tests` (148 → 167; total 596 → 615) executam os caminhos reais de `Driver.init`, `device()`, leitura, escrita com read-modify-write e FLUSH, e injetam: timeout com conclusão tardia, notificação recusada, conclusão com `id` errado, comprimento curto e status fora da especificação, erro de dispositivo, fila esgotada, `used.flags` com `no_notify`, reset não confirmado, reset confirmado sem rearme e três falhas de configuração depois de `DRIVER_OK`. O contrato de notificação de §4.1.4.4 passou a ser aplicado pelo simulador (endereço `queue_notify_off × notify_off_multiplier`, 16 bits, índice de fila existente) e tem teste próprio; a cadeia de um pedido expirado tem prova dedicada de que a liberação é recusada com `DescriptorInFlight` e que os descritores continuam fora da free list até a conclusão tardia. A composição PCI → contenção → retenção de DMA é verificada com revogação confirmada pela leitura de volta do `Command` e com `Memory Space` preservado; toda falha inexplicável deixa `freeCount` intacto, a cadeia publicada e os 4 KiB de DMA byte a byte idênticos depois de novos pedidos com o driver em quarentena. Nenhuma costura de teste foi necessária: os 10 milhões de iterações de `timeout_polls` custam ≈297 ms por timeout e o `vvdi-tests` inteiro roda em ≈2,36 s. Treze mutações reais foram aplicadas em cópia isolada: M1, M3–M9 e M11–M12 derrubam entre 1 e 14 testes; M5 (remoção da lista de status em `validCompletion`) derruba 3, inclusive o teste de integração, porque a falha `corrupt_status` passou a publicar o comprimento de uma conclusão que só escreveu o status; M10 (notificação em `scaled + 4`) derruba 12, porque o simulador passou a exigir endereço, largura e índice; M2 aplicada isoladamente é **inerte**, e não uma regressão não detectada — a guarda `DescriptorInFlight` faz `Queue.release` responder erro, que o ramo de timeout descarta, sem mudar a fila; só a mutação combinada (M2b, com a guarda removida) derruba 8 testes. `zig build test` 615/615, `zig build`, `zig fmt --check` e `log-assertions-test.sh` 7/7 passam localmente; QEMU/OVMF e hardware físico continuam ausentes neste ambiente, então o boot fica para a CI do SHA. Ver `docs/reports/f7/vvdi-fault-injection.md`. |
| F8 | Compatibility / external formats / APIs | PARTIAL — `vex.zig` (contêiner nativo com manifest), ABI própria v13 e `elf_compat.zig` (somente `e_machine`, **não importado por nenhum módulo**). **Não existe** carregador PE, tradução Win32/POSIX, camada Linux binária nem qualquer formato externo além do ELF64 nativo. A lacuna está registrada na auditoria de 2026-10-30. |
| F9 | AI infrastructure (tensor / model / security) | TESTADO NO CI — `tensor.zig` (matMul + relu); `model.zig` (infer real + CRC32 sobre os pesos); `security.zig` (limites e overflow verificados); `embedded.zig` (imagem do modelo construída em comptime, CRC verificado pelo compilador); chamada 24 `ai_infer`, capability de kind 4 com o direito `execute` e autoteste fatal no boot; `ai-tests` 10/10. Sem GPU. Ver `docs/reports/f9/f9-inference-call.md`; boot em QEMU/OVMF verde no run 41013843472 |
| M0.5 | SMP / APIC / EEVDF / spinlocks / APs | COMPLETED — `smp.zig`, `apic.zig`, `scheduler.zig`, `spinlock.zig`, `installSmp`; commit `53dc842` |
| F10 | Installation, security, recovery, production readiness | COMPLETED (local) — `README.md` atualizado; `docs/reports/f10/phase{1..9}-*.md`; `final-development-complete.md`; `flush`; benchmark documentado; nenhuma rede completa inventada |space composition, blocking input wait (F6.30, syscall 23, ABI v13), screenshot validation and the F6.29 client→compositor frame handshake are verified; a cursor, surface sharing and a user-space shell service are pending, and the kernel scene already carries a taskbar with keyboard focus switching (F6.31) |
| F7 | Virtio, network, audio, physical hardware, GPU | IN DEVELOPMENT — `pci.zig` corrigiu limites byte/word e serializa 0xCF8/0xCFC com `IrqSpinlock`; sonda PCI do bus 0 verificada no QEMU (`virtio=1`). Phase 2b: layout contíguo de split-virtqueue (`DeviceQueue`), janela DMA virtual em `0x4000_0000`/64 MiB, `mapKernelDataPage`/`unmapKernelPage`, e probes `probeDmaWindow`/`probeVirtqueueLayout`; 22 testes de kernel passaram; `zig build qemu-test` confirma `[VNK] dma: window map probe ok` e `[VNK] virtio: split queue layout ok`. Phase 3: stubs inicializados `virtio_blk.zig` e `virtio_net.zig` com interfaces `read`/`write` e `transmit`/`receive`; 22 testes de kernel passaram; `zig build qemu-test` confirma `[VNK] dma: window map probe ok` e `[VNK] virtio: split queue layout ok`. `virtio.zig` continua host-only, mas libera cadeias, rejeita mutação em voo e aceita RX com `write`; os 9 testes entram em `zig build test`. `virtio_blk.zig` e `virtio_net.zig` são stubs sem init/RX/TX; nenhum driver de rede funcional. Correção (2026-10-26): as interfaces citadas na Fase 3 não existem com esses nomes nem com esses parâmetros — `virtio_blk.zig` expõe `blk_read()`/`blk_write()` **sem** LBA, buffer ou contagem de setores, e `virtio_net.zig` expõe apenas `net_transmit()`, sem `receive`. O Virtio Block **não é um driver funcional**: não há detecção de dispositivo, handshake de status, negociação de features, virtqueue programada nem pedido enviado. Os dois pontos de entrada eram corpos vazios, o que em Zig devolve sucesso — uma leitura ou escrita publicada como concluída sem tocar em dispositivo algum; agora devolvem `error.NotImplemented` de forma incondicional, com 4 testes de regressão em `zig build test` (`arch-tests`: 59 → 63 testes). A integração com `block.Device` continua pendente, a persistência física em disco não foi validada e o backend de bloco verificado segue sendo o ramdisk em memória. A correção passou em `zig build test`, `zig build`, `zig build qemu-test` e `zig build check` na CI (run `40361111218`, commit `55d9fe3`). Ver `docs/reports/f7/virtio-blk-false-success.md`. PR A do VirtIO PCI moderno (2026-10-26, `arena/9207f83d-vorynos`): `pci.zig` ganhou `Reader`/`ConfigImage`, `CapabilityIterator` (ponteiro, alinhamento, `cap_len`, ciclo e limite de 48 offsets), `barKind`/`barSize`/`BarTable`/`barSupportsRegion`; novo subsistema `kernel/drivers/virtio/` com `types`, `status`, `features` e `caps` (ADR-0018); `initVirtioDevice()` — que registrava `device init complete` sem inicializar nada — foi substituída pela sonda somente-leitura `identifyVirtioDevices()`, que declara a ausência de inicialização e é exigida pelo teste de boot. Estado: IMPLEMENTADO — TESTADO LOCALMENTE (host) e NA CI; `zig build test` passa (`arch-tests` 76/76, `virtio-modern-tests` 29/29, 462 testes no total) e `zig build` gera a imagem; QEMU/OVMF não existem no ambiente da sessão, então `qemu-test`/`check` rodam só na CI, onde os 11 passos do workflow passam. A revisão técnica final corrigiu três desvios da especificação: `cap_len` maior que o definido era recusado (o driver MUST aceitá-lo), a variante `cap64` era lida como se as metades altas fossem padding, e `status.transition` aceitava apagar bits ao escrever FAILED (o driver MUST NOT limpar um bit). O driver legado `virtio.zig`/`virtio_blk.zig` não foi alterado. Ver `docs/reports/f7/virtio-pci-modern-pr-a.md` PR B do VirtIO PCI moderno (2026-10-26, `arena/9207f83d-vorynos`): três módulos novos em `kernel/drivers/virtio/` — `mmio.zig` (12 testes de faixa, alinhamento, transbordo, permissão, estado do mapeamento e janela virtual), `transport.zig` (13 testes da sequência `reset → ACKNOWLEDGE → DRIVER → features → FEATURES_OK`, com `Outcome{stage, reason}` e sem caminho para `DRIVER_OK`) e `pci_transport.zig` (11 testes do layout 4.1.4.3, do endereço de notificação e da leitura de configuração e de endereços de fila). `pci.zig` ganhou `probeBarSizes` (máscara do BAR sob o lock, restauração do valor, BAR de 64 bits) e `writeConfigDword`. A janela de MMIO de 16 MiB em `0x6000_0000` é reservada em `buildPageTables` e ligada a `paging.mapDevicePage`/`unmapKernelPage` — não há segundo gerenciador de paginação. `bringUpVirtioDevices()` substitui a sonda somente-leitura do PR A: seleciona explicitamente o primeiro `virtio-blk` moderno (`0x1042`), valida as capabilities contra o BAR real, mapeia, lê os registradores, negocia `VERSION_1` e confirma `FEATURES_OK`, parando em `awaiting virtqueue setup`. `boot-qemu.sh` usa `virtio-blk-pci,disable-legacy=on` explícito e falha se o status chegar a `0x0f`. `zig build test` passa (499 testes; `arch-tests` 77, `virtio-modern-tests` 65, antes 29) e `zig build` gera a imagem; QEMU/OVMF não existem no ambiente da sessão, então `qemu-test`/`check` rodaram na CI (run `40478940990`, commit `f550190`), onde o boot no QEMU/OVMF confirmou a fila habilitada e `status=0x0f`. Virtqueue, `DRIVER_OK`, I/O de bloco real e MSI-X continuam ausentes. Ver `docs/reports/f7/virtio-pci-modern-pr-b.md` e o ADR-0019. PR C do VirtIO moderno (2026-10-27, `arena/eb8e8a07-vorynos`): split virtqueue nativa de 26 testes (`virtqueue.zig`: layout 2.7.4–2.7.8, free list O(1), recusa de publicação dupla, de liberação em voo, de `id` não publicado e de ciclo; ordenação de memória explícita), `configureQueue`/`enableQueue` com confirmação de `queue_enable` e `DRIVER_OK` escrito só depois de uma fila registrada, elevando o dispositivo a `status=0x0f` com a fila 0 programada em memória DMA do alocador existente e verificadamente vazia. `virtio-modern-tests` 65 → 91 e `zig build test` passa com 525 testes; `zig build` gera a imagem, agora de 128 MiB, porque o ELF do kernel em Debug mede 72,0 MB e o FAT de 64 MiB estava a 1% do limite. QEMU/OVMF não existem no ambiente da sessão, então `qemu-test`/`check` rodaram na CI (run `40478940990`, commit `f550190`), onde o boot no QEMU/OVMF confirmou a fila habilitada e `status=0x0f`. Publicação de pedido, consumo em uso, notificação, MSI-X e driver de bloco continuam ausentes. Ver `docs/reports/f7/virtio-pci-modern-pr-c.md` e o ADR-0020. PR VVDI (2026-10-27, `arena/3aee4e28-vorynos`): identidade nativa **VVDI — Voryn Virtual Device Interface** estabelecida sem alteração funcional (`kernel/drivers/virtio/` → `kernel/drivers/vvdi/`, `virtio_modern` → `vvdi`, `virtio-modern-tests` → `vvdi-tests`, `[VNK] virtio-pci:` → `[VNK] vvdi:`); 544/544 testes Zig aprovados (`vvdi-tests` 110/110); `tests/integration/boot-qemu.sh` endurecido contra *fail-open* (9 padrões obrigatórios, sequência completa, ordem estrita, unicidade de `DRIVER_OK`, ausência de `status=0xf` indevido, rejeição de log vazio e de prefixo obsoleto) com `tests/integration/log-assertions-test.sh` (7/7 cenários) integrado ao GitHub Actions; código legado em `kernel/arch/x86_64/virtio*.zig` preservado integralmente; dívidas técnicas A-3, D-6 e D-7 catalogadas em `docs/reports/f7/vvdi-debt.md` e decisão registrada no ADR-0021. |
| F8 | ELF, Linux ABI, PE, Win32, external formats | PARCIAL — `vex.zig` (wrap/validate/unwrap + manifest), `elf_compat.zig`, ABI própria v13 (`syscall.zig`), loader P0 `AllocatePages` (`591bde4`). **Correção de 2026-10-30:** a versão anterior desta linha dizia `CONCLUÍDO` e citava PE e Win32; não há uma linha de PE, de Win32 nem de ABI Linux no repositório |
| F9 | AI, tensor, model, security, inference | TESTADO LOCALMENTE (host) — `tensor.zig`, `model.zig`, `security.zig`, F9.4 audit (`591bde4`/`7167434`/`3418766`); **2026-10-30:** a inferência deixou de ser biblioteca host-only e virou capacidade do sistema (chamada 24, capability kind 4, direito `execute`, autoteste no boot, prova positiva em ring 3 e prova negativa no processo sem a capability). A geometria é fixa (4 → 3) e não há GPU. Ver `docs/reports/f9/f9-inference-call.md` e o ADR-0023 |
| F10 | Installation, update, recovery, hardening, benchmarks, other architectures | PARCIAL — há endurecimento inicial (NX obrigatório, W^X, canário de pilha, verificação de permissões de página), o benchmark `tools/benchmarks/syscall_bench.zig` e a ferramenta de host `tools/scripts/recovery_mode.zig` (que agora compila e entra no build como `recovery-mode`). **Não existe** instalador, atualização nem recuperação do sistema no alvo; a ferramenta anterior chamava-se `recovery-mode.sh` sem ser shell e sem compilar, e apenas lança o QEMU no host. A linha anterior desta tabela dizia `CONCLUÍDO (localmente verificado)`. |
| F11 | Kernel stability, scheduler, initialization, stack canary | TESTADO LOCALMENTE — canário no limite inferior da stack; stacks de kernel ampliadas; polling da calibração APIC limitado; `zig build test`, `zig build` e `zig build qemu-test` PASS (`VORYN-KERNEL-READY`, todos os checks); `docs/reports/f11/f11-kernel-stability.md`; hardware físico ainda não testado |
| F12 | Memory security, ELF64, system robustness | IMPLEMENTADO — defensivas loader (`file_size>memory_size`, zero-size); testes negativos; `docs/reports/f12/f12-memory-security.md`; `zig build`/`test` PASS; nenhum arquivo vazio; nenhuma rede completa inventada |
| F13 | Runtime de IA nativo, desempenho e validação | IMPLEMENTADO — corrigido `security.zig` overflow + `loader.zig` defensivas; testes `zig build`/`test` PASS; `docs/reports/f13/f13-ai-performance.md`; nenhuma rede completa inventada |

## Open risks

| Risk | Impact | Treatment |
|-------|---------|------------|
| Absence of capabilities | High | The capability model of ADR-0001 remains open |
| Fixed heap in the kernel image | Medium | Dynamic heap with the VNM in F3 |
| Fatal exceptions | Medium | Resolved in F3: the exception of the user kills the process, and the one of the kernel remains fatal |
| Fixed number of processes | Medium | `paging.max_process_spaces` is a fixed limit of eight address spaces in the current source; dynamic growth remains absent |
| NX requirement | High | The kernel requires EFER.NXE and refuses to boot without it; verified in QEMU/OVMF, with no fallback |
| Bootstrap native image | Medium | The native ELF is built in kernel memory, not by an SDK; the next increment replaces the builder |
| Absence of a hardware test | Medium | Marked as not verified until a reference machine exists |
| SMP: spinlocks, per-CPU data, APIC local, AP trampoline | Medium | Fundacoes implementadas (M0.5); escalonador multi-CPU, EEVDF e IPIs de reescalonamento pendentes |
| SMP: escalonador multi-CPU e EEVDF | CONCLUÍDO | Per-CPU ready queues (1b5a909), EEVDF fields + policy (d1c3ca0/d92a99a1), IPI reschedule (f8929be) — validado com `zig build test`; `-smp 4` inicia sem pânico |
| SMP: boot de APs via SIPI/trampoline | CONCLUÍDO | Trampoline (`ap_trampoline.s`) + `voryn_ap_entry` + `initAps()` + `installSmp()` integrado no `voryn_kmain()` |
