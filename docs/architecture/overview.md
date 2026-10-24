# Architecture overview

This document describes the **real** state of the architecture of the
VorynOS in this increment. It does not describe the final system: it
describes what exists, how the parts connect and what does not exist yet.

The model of the components and their costs are in
[`../adr/ADR-0001-voryn-fabric.md`](../adr/ADR-0001-voryn-fabric.md).

## 1. Boot chain

```text
   UEFI Firmware (OVMF)
            │
            │  ExitBootServices
            ▼
   ┌──────────────────────┐
   │  VNB — Voryn Native  │   UEFI application (Zig, without libc)
   │        Boot          │   1. serial console + firmware console
   └──────────┬───────────┘   2. framebuffer (GOP)
              │               3. memory map
              │               4. reading of the kernel image
              │               5. ELF64 validation + relocations
              │               6. handoff contract
              │               7. ExitBootServices and jump
              ▼
   ┌──────────────────────┐
   │  VNK — Voryn Nucleus │   minimal kernel (Zig + Assembly)
   │        Kernel        │   1. validation of the handoff
   └──────────┬───────────┘   2. report of the state of the machine
              │               3. write probe in the framebuffer
              ▼
          F2: GDT, IDT, memory, timer
```

## 2. Modules

### `shared/` — shared contracts and primitives

| File | Responsibility |
|---------|------------------|
| `handoff.zig` | Structure of the VNB → VNK contract and its validation |
| `memmap.zig` | Operations over the memory map (search, summary, load region) |
| `elf64.zig` | ELF64 reader: header, segments, relative relocations, load plan |
| `usermode.zig` | Layout of the user mode window, shared with the user program |
| `display.zig` | Versioned display metadata and presentation contract (`DisplayInfo`, `PresentRequest`; no framebuffer address) |
| `arch/x86_64/port.zig` | Port I/O primitives (in, out, cli, hlt, rdtsc) |
| `arch/x86_64/serial.zig` | Driver of the 16550 UART (COM1) and formatted writer, with atomic write |

`shared/` is compiled for three different targets: UEFI (loader),
freestanding (kernel) and host (tests). No module depends on an operating
system.

### `boot/uefi/` — the VNB loader

| File | Responsibility |
|---------|------------------|
| `main.zig` | Orchestration of the boot and transition to the kernel |
| `vnb/protocols.zig` | UEFI protocol structures and detection of layout at run time |
| `vnb/console.zig` | Dual console: serial and firmware console |
| `vnb/framebuffer.zig` | Discovery and selection of the graphic mode |
| `vnb/memory.zig` | Reading and normalization of the memory map of the firmware |
| `vnb/fs.zig` | Access to the boot volume and reading of the kernel file |
| `vnb/loader.zig` | Placement of the image and application of relocations |

### `kernel/` — the VNK kernel

| File | Responsibility |
|---------|------------------|
| `main.zig` | Kernel entry, initialization sequence, validation of the handoff |
| `arch/x86_64/entry.s` | Entry trampoline, boot stack, ABI rules |
| `arch/x86_64/cpu.zig` | Control registers, `CPUID`, model specific registers |
| `arch/x86_64/segment.zig` and `.s` | Segment table, task segment, reload of the registers |
| `arch/x86_64/interrupt.zig` and `.s` | Interrupt table, exception and interrupt handlers |
| `arch/x86_64/frame.zig` | The contract of the frame that the stubs build |
| `arch/x86_64/paging.zig` | Page tables of the kernel, address spaces of the processes and the switch of `CR3` |
| `arch/x86_64/syscall.zig` and `.s` | Entry of the system call and the handler in Zig |
| `arch/x86_64/task.s` | Context switch, context capture and the user mode program |
| `arch/x86_64/timer.zig` | 8254 timer, 8259 controllers, interrupt counting |
| `memory/physical.zig` | Physical memory manager over the map of the contract |
| `memory/heap.zig` | Kernel heap with boundary tags and corruption detection |
| `task/context.zig` | Complete context of a task: all the registers of the processor |
| `task/scheduler.zig` | Preemptive scheduler, creation of tasks and of processes, switch of space |
| `ipc/channel.zig` | Message channel of the VNX: two queues per channel, the wait and the latency of the delivery |
| `security/capability.zig` | The capability fabric of the VNC: the table of the kernel and the set of each process |

### `tools/` — development tools

| File | Responsibility |
|---------|------------------|
| `fatimg.zig` | Builder of the FAT16 volume with the loader and the kernel |

### `scripts/` — test automation

| File | Responsibility |
|---------|------------------|
| `qemu-boot-test.sh` | Automated boot test: captures the serial console and verifies markers |
| `qemu-run.sh` | Interactive boot in QEMU |

## 3. Contracts between modules

| Contract | Type | Where |
|---------|------|------|
| VNB → VNK handoff | versioned `extern` structure | `shared/handoff.zig` |
| Memory map | array of `MemoryDescriptor` (40 bytes) | `shared/handoff.zig` |
| Kernel image | relocatable ELF64 (`ET_DYN`) | `shared/elf64.zig` |
| User mode window | offset constants, shared with the assembly | `shared/usermode.zig` |
| System call contract | version `syscall_abi = 11`, nineteen calls (12 reserved) | `docs/specs/syscall-abi.md` |
| Task context | `extern struct` with the fifteen registers | `kernel/task/context.zig` |
| Console | `std.Io.Writer` writer over the UART | `shared/arch/x86_64/serial.zig` |

No contract uses an opaque pointer without a description: every field has
an explicit and documented layout.

## 4. Security properties of the increment

1. The loader validates the kernel image before executing it: magic, class,
   endianness, machine, type, table of program headers, segments inside the
   file, entry point inside a segment, and conventional RAM behind each
   segment.
2. The image is relocatable, and the applied relocations are only of the
   type `R_X86_64_RELATIVE`; any other type is refused.
3. The load address is chosen above 1 MiB, so as not to overwrite the data
   structures of the firmware in the low area of the PC.
4. The kernel verifies the magic, the version and the coherence of the
   memory map before using any field.
5. The console of the firmware is decoupled before `ExitBootServices`.
6. The write probe in the framebuffer only runs when the memory map does
   **not** report the region of the framebuffer as common RAM, so as not to
   corrupt the memory that the kernel is going to use.
7. The kernel stack of each task is a different memory from the code stack
   of the task, and the processor frame of the way back is built in the
   kernel stack. A process of the user mode, therefore, has no control
   over the frame that decides the privilege level of the way back.
8. Each process has its own address space, and the ranges of memory that
   the kernel checks are the ones of the space of the process that called.
9. The user mode window is outside the kernel image, and its address is
   delivered to the task at the moment of the creation.
10. The task that waits for a message **is not run**, and the frame that it
    leaves is the same processor frame that the preemption leaves, and
    therefore the same switch serves the two cases.
11. The processor frame has **one single shape**: the stub of an exception
    that has an error code saves the code and moves the five words of the
    return down, and the handler, the switch and the return of the
    processor read the same positions.
12. The exception that comes from the **user mode** kills the process, and
    not the machine: the process is marked as terminated, the frame of the
    processor is rewritten to a loop of the kernel, and the scheduler does
    not choose it again. The exception that comes from the **kernel** is
    fatal, because the state of the kernel after the error is unknown.
13. A process does not use a channel that it does not hold the capability
    of: the check of the capability happens in the kernel, before the queue
    is touched, and the process that does not hold it is refused. The
    handle of a capability is an index of a table of the kernel, and it
    means nothing outside it.

## 5. Known limitations

1. The heap of the kernel is a fixed region of 256 KiB inside the image,
   because the region has to stay mapped after the switch of the page
   tables.
2. The bitmap of the physical memory manager covers 4 GiB of the physical
   address space.
3. The exception handler is fatal **when the error happens in the kernel**:
   the execution stops, because the state of the kernel after the error is
   unknown. The exception that comes from the user mode kills the process,
   and the kernel continues.
4. The index of the interrupt stack of the task segment is prepared, but
   the entries of the interrupt table do not use it yet.
5. The loader does not locate the ACPI RSDP; the field exists in the
   contract but holds zero.
6. The test volume uses FAT 8.3 names; there is no support for long names.
7. The system is single processor; there is no support for SMP.
8. There is no hardware detection beyond the framebuffer: VNH does not
   exist yet.
9. The number of address spaces is a constant of the paging module, and
   the number of processes is fixed in the kernel.
10. The timeout of the wait is counted in ticks of the timer, and a wait
    on **several** channels does not exist: a task waits for one channel
    and one side.
11. The kernel is loaded from a FAT volume through the simple file system
    protocol of the firmware; there is no block driver of its own.
12. The capability of the model of the VNC covers the channels of the VNX
    only: the process has access to the whole space of the user mode, and
    there is no capability of a range of memory nor of a device.

## 6. What comes next

The F3 milestone (execution) implements, in this order: the alternation
between tasks measured by the timer, the user mode with the user stack and
the switch of privilege, the first system call, the message channel of the
VNX and the capabilities of the VNC. Every step has a verifiable
acceptance criterion and an automated test in QEMU.
