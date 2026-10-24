# Roadmap and implementation state

| Field | Value |
|-------|-------|
| **State** | ALIVE |
| **Date** | 2026-10-24 |
| **Published version** | `v0.1.0-dev.3` (tag) |
| **Working tree** | F6.26 display presentation increment, verified locally in QEMU, not yet tagged |

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
| Capability of a generic device | PROPOSED | the capability of drivers and other devices is not implemented; only the display kind exists |

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
| Persistence and block driver | PROPOSED | the RamFS lives in the image of the kernel and disappears on power-off |
| VNV and VFSX | PROPOSED | no virtual node layer and no disk format yet |
| Per-process descriptors | PROPOSED | the descriptor table is global, because the contract has no process-scoped file table yet |
| Unlink, rename, indirect blocks | PROPOSED | not implemented |

Known limits of the verified core:

- the RamFS is fixed at 1 MiB (256 blocks of 4 KiB), with 32 inodes and 64
  directory entries;
- a file is limited to 48 KiB, because only the 12 direct block pointers
  exist;
- there are no `.` and `..` entries, and `..` is refused by the resolver;
- the descriptor table is global and has 16 entries;
- the file system is not shared with user mode end to end yet: the syscalls
  compile and check the user range, but the embedded user program does not
  call them. The boot verification exercises the kernel-side facade.

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
| VEX, VLIB, VPK and SDK | PROPOSED | no native toolchain, package format or SDK yet |

The planner is deliberately pure: it does not allocate, map or spawn. The
materializer consumes the `LoadPlan` and owns the hardware-dependent work.
Its verification is the QEMU boot, where the kernel reads the page-table
permissions back, checks that the relative relocation holds the load bias
and waits for the native task to terminate. The native image is a bootstrap
built in kernel memory, because the SDK does not exist yet; the ELF file
itself goes through the RamFS and is validated by the same planner used on
the host.

### F6 — Graphics and input — IN DEVELOPMENT

Objective: an own rasterizer, opaque window compositor, damage tracking and
PS/2 input, with a verified interactive path in QEMU. A user-space graphics
service and a desktop shell remain future work.

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
| F6.25 display metadata call | TESTED LOCALLY | syscall 19 (`display_info`, ABI 10) returns the versioned `DisplayInfo` to the native SDK application; no framebuffer address is exposed |
| F6.26 display presentation | TESTED LOCALLY | syscall 20 (`present`, ABI 11) copies a validated 16x16 rectangle from the native SDK application; the display capability (kind 2) is checked first and the first pixel is read back as `0xff` |
| User-space graphics service | IN DEVELOPMENT | `display_info` and `present` are verified locally; the compositor, surface sharing and input events remain proposed in ADR-0015 |

Measured environment for F6.22.2/F6.23/F6.24: Fedora 44, Zig 0.17.0,
QEMU 10.2.2, OVMF, `-smp 1`, 256 MiB, no KVM (TCG), GOP mode 2048x2048.
The absolute numbers are emulator numbers, not hardware numbers. The
optimization removed the full-window repaint from the hot path. In Debug
the remaining cost was guest code plus MMIO; ReleaseFast reduced the
render to 3.79 ms per arrow, and the end-to-end test then became limited
by QEMU's key-hold pacing.

Known limitations of the verified F6 core:

- `display_info` and `present` are the user-space graphics calls; there is
  no surface sharing, window manager, focus model, cursor or input event
  API;
- the `present` path is synchronous, without double buffering or vsync, and
  the QEMU refusal from a second process without the display capability is
  still pending;
- text and general shapes are not part of the rasterizer yet;
- input is PS/2 Set 1 only; there is no mouse or USB HID;
- the bootloader prefers the largest 32 bpp GOP mode, which in QEMU is
  2048x2048 and amplifies framebuffer emulation cost;
- the performance numbers were measured under TCG in Debug and
  ReleaseFast; a real machine remains unmeasured.

### F4 to F10 — summary

| Milestone | Content | State |
|-------|----------|--------|
| F4 | Block drivers, VNV, initial VFSX, persistence, recovery | IN PROGRESS — RamFS core verified |
| F5 | VEX, VLIB, VPK, runtime, SDK, native applications | IN PROGRESS — native ELF and toolchain app verified; SDK pending |
| F6 | Input, rasterizer, compositor, windows, VSH | IN DEVELOPMENT — framebuffer, input, interactive tests and exposed-strip damage verified; display metadata and presentation verified; user-space compositor and input service pending |
| F7 | Virtio, network, audio, physical hardware, GPU | PROPOSED |
| F8 | ELF, Linux ABI, PE, Win32, external formats | PROPOSED |
| F9 | VAI, backends, permissions, API, local execution | PROPOSED |
| F10 | Installation, update, recovery, hardening, benchmarks, other architectures | PROPOSED |

## Open risks

| Risk | Impact | Treatment |
|-------|---------|------------|
| Absence of capabilities | High | The capability model of ADR-0001 remains open |
| Fixed heap in the kernel image | Medium | Dynamic heap with the VNM in F3 |
| Fatal exceptions | Medium | Resolved in F3: the exception of the user kills the process, and the one of the kernel remains fatal |
| Fixed number of processes | Medium | Four address spaces: three embedded test processes and one native ELF; `paging.max_process_spaces` is a constant |
| NX requirement | High | The kernel requires EFER.NXE and refuses to boot without it; verified in QEMU/OVMF, with no fallback |
| Bootstrap native image | Medium | The native ELF is built in kernel memory, not by an SDK; the next increment replaces the builder |
| Absence of a hardware test | Medium | Marked as not verified until a reference machine exists |
