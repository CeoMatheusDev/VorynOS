# VorynOS testing strategy

| Field | Value |
|-------|-------|
| **State** | ACCEPTED |
| **Date** | 2026-10-21 |
| **Last revision** | 2026-10-24 |

## 1. Principle

No feature is declared working without an executed command that demonstrates
the behavior. The strategy separates what can be tested without hardware
from what requires emulation or a real machine, and keeps the separation
between **implemented** and **validated** visible in
`docs/roadmap/phase-status.md`.

## 2. Layers

| Layer | Where | What it covers | Command |
|--------|------|-------------|---------|
| L1 — Unit | Host | Pure logic: ELF64, memory map, handoff contract, formats | `zig build test` |
| L2 — Boot integration | QEMU + OVMF | Complete chain firmware → loader → kernel | `zig build qemu-test` |
| L3 — Behavior in QEMU | QEMU + OVMF | Observable behavior (exceptions, timer, allocators) | dedicated script, to be created per milestone |
| L4 — Hardware | Real PC | Boot on hardware, physical drivers, performance | to be created when the target hardware exists |
| L5 — Performance | Host and QEMU | Boot metrics, latency, memory | to be created with F10 |

## 3. L1 — Unit tests

The modules of `shared/` are compiled for the host and tested with
`std.testing`. They are modules with no allocation and no system
dependency, which makes it possible to test the logic that runs inside the
kernel and the loader:

- `shared/elf64.zig`: malformed header, segment outside the file, invalid
  or non-executable entry point, inconsistent fixed virtual/physical address,
  invalid alignment, W+X segment, relocation outside writable memory,
  symbol-based unsupported relative relocation, segment with no RAM behind
  it and excessive number of segments.
- `shared/memmap.zig`: region search, usable range, address overflow, map
  summary, load region with alignment and lower bound.
- `shared/handoff.zig`: magic, version, header size, coherence of the
  memory map.

Rule: every module of `shared/` is born with tests, because it is the
layer that the kernel will depend on to not repeat a firmware mistake.

The kernel modules that do not depend on hardware are tested the same way
and in the same `zig build test` run, through the binaries `kernel-tests`,
`security-tests`, `arch-tests`, `ipc-tests` and `fs-loader-tests`:

- `kernel/arch/x86_64/virtio_blk.zig`: the provisional block entry points
  must return `error.NotImplemented`, and the declared error set must stay
  the whole contract of the two functions. An empty `!void` body returns
  success in Zig, so these tests are what stops a restored stub from
  publishing a read or a write that never reached a device. They run on the
  host, do not depend on hardware, and they fail — three of them at once —
  if the empty bodies come back.

## 4. L2 — Boot test in QEMU

`tests/integration/boot-qemu.sh` runs the disk image in QEMU with OVMF,
captures the serial console and verifies progress markers:

```text
ok: found '[VNB] VorynOS'
ok: found '[VNB] kernel placed'
ok: found '[VNK] Voryn Nucleus Kernel'
ok: found '[VNK] handoff ok'
ok: found '[VNK] user: process 0'
ok: found '[VNK] user: process 1'
ok: found '[VNK] user: the second process wrote 0x5a5a1235 in its own page'
ok: found '[VNK] user: the copy between the two processes moved 8 bytes'
ok: found '[VNK] channel: the answer of the other process came back'
ok: found 'VORYN-KERNEL-READY'
qemu-boot-test: all checks passed
```

The test also fails if the console holds the `FATAL` marker, which detects
failures that do not stop the boot but that indicate an incorrect state.

Since F6.28 the boot test also captures a P6 screenshot through the QEMU
monitor while the native application holds a 32x24 composed frame. The
application publishes an FNV-1a checksum of the frame, and
`tests/integration/compare-presentation.py` verifies that the screenshot
rectangle is grayscale and has the same checksum. The test therefore
detects a wrong rectangle, a wrong stride or a lost pixel, not only a
missing serial marker. The application is released with `Q` after the
capture, so the kernel can continue to `VORYN-KERNEL-READY`.

The test is the **only** proof of the behavior of the user mode, of the
processes and of the channel, and the markers verify the **content** and not
only the execution: the marker of the page of data of each process is
checked, the content of the copy with overlapping ranges is checked byte by
byte, and the space of the caller of the copy between processes is checked
after the copy.

Characteristics:

- Deterministic: the image is built by the project itself, with no
  dependency on external state.
- Without network; the interaction is a bounded monitor script, not a
  human. The test stops the emulator after READY, with a timeout as safety
  net.
- The serial console is the verified channel, because it is the only one
  that exists on the two sides of the firmware/kernel boundary.
- The write in the serial console is **atomic**: the task that writes
  disables the interrupts while the message is assembled, and therefore two
  tasks do not write over each other. Without that guarantee, the console
  stops being evidence, because it starts to report lines that nobody
  wrote.

## 5. L3 — Behavior in QEMU

The kernel provokes a `#DE` at the end of the boot and prints the vector,
the error code, the address that caused the fault and the processor frame.
The test verifies the presence of the report.

The **recovery** exists and is verified. A third process writes in an
address that is not mapped, and the page fault is handled: the process is
killed, the console says that the kernel continues, and the test verifies
that the timer keeps counting, that the conversation between the other two
processes **completes** the round trip, and that the machine reaches the
`VORYN-KERNEL-READY` marker.

The exception in the kernel remains fatal, and the test of the end of the
boot verifies that the report of the `#DE` appears: stopping the machine
with a provoked exception is what the test asks for.

The **capabilities** are verified the same way. The third process holds no
capability of any channel, and the call that uses one is refused; the
owner of the channel delegates the capability to a third process and takes
it back from the process that answered; and the test verifies the refusal,
the delegation and the revocation. F6.28 extends the same process: it calls
`present` and `input_poll` without the display and input capabilities, with
deliberately invalid addresses, and the kernel must answer error 10 before
reading the request or the output range.

The unit tests of the module of the capabilities verify the properties of
the model itself: the capability that nobody holds authorizes nothing, the
rights of the holder are a subset of the rights of the capability, the
delegation that does not carry the right of delegation stops the chain, the
revocation takes the capability back, and the table and the set do not grow
without a limit.

The performance measurement is done with the time counter of the processor,
and the cost of the context switch and the latency of the delivery of a
message are reported on the console on every run.

## 6. L4 — Hardware

It requires a physical machine with UEFI and reference hardware. While that
does not exist, every statement about real hardware is marked as not
verified. The emulator does not replace the hardware: the differences of
firmware, of page table, of timer and of console are predictable.

## 7. Evidence

Every relevant test run is registered with:

1. the exact command;
2. the real output;
3. the environment (version of Zig, QEMU, OVMF, machine);
4. the date.

The increment report of `AGENTS.md` §4.8 follows this format. The results
are never invented nor rounded to "correct".

## 8. Limitations of the current set

- There is no fuzzing test yet. The ELF64 reader is the priority target,
  because it processes untrusted input from the firmware.
- There is no stress or fuzzing test of concurrency: the boot test
  exercises scheduler and user-mode concurrency in QEMU, but not under
  load.
- There is no general performance gate in the automated set. The
  F6.22.2–F6.24 work measured input latency and damage under QEMU/TCG, and
  those numbers are reported per run; F6.28 verifies composition pixels but
  does not yet time the composition or the copy.
- The capability model covers the channels of the VNX, address spaces,
  the display and the input queue. There is no capability of a range of
  memory nor of a device, and the process still reaches the whole space of
  the user mode.
