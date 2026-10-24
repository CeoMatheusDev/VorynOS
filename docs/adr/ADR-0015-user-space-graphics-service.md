//************************************************************************//
//  ADR-0015.md                                                           //
//************************************************************************//
//                         This file is part of:                          //
//                               VorynOS                                  //
//              https://github.com/CeoMatheusDev/VorynOS                  //
//************************************************************************//
// Copyright (C) 2026 VorynOS contributors.                               //
//                                                                        //
// SPDX-License-Identifier: GPL-3.0-only                                  //
//************************************************************************//

# ADR-0015 — User-space graphics service and display presentation

| Field | Value |
|-------|-------|
| **Status** | ACCEPTED |
| **Date** | 2026-10-24 |
| **Scope** | Graphics, system calls and process isolation |
| **Implementation** | `display_info`, `present` and `input_poll` TESTED LOCALLY; the compositor, the window manager and the input service PROPOSED |

## 1. Context

The F6 compositor runs inside the kernel. It owns the framebuffer, the
window list, the damage tracker and the keyboard path. That design made the
first pixels possible and allowed the F6.22.2–F6.24 measurements, but it is
not the desktop that the project needs: an application could not create a
window, could not present its own pixels and could not receive input through
a permission-checked interface.

The framebuffer is mapped in the kernel page tables as writable MMIO and
**without the user bit**. The user mode therefore cannot write it, and it
must not receive that mapping: the framebuffer is a physical device, not a
buffer of the process. A process that mapped it could overwrite every
window, bypass the compositor and escape the accounting of the damage
tracker.

The next increments need a contract between the user mode and the graphics
service. The contract has to preserve three properties:

1. the user mode never receives a writable mapping of the framebuffer;
2. every buffer that the kernel reads because of a graphics call is
   validated in the page tables of the caller;
3. the authority to change the display is a capability, not a convention
   based on the process identifier.

The first part of the contract, the read-only metadata call, is small
enough to implement and verify before the presentation path exists. It is
the subject of the F6.25 increment.

## 2. Decision

### 2.1 Display metadata is public; the framebuffer address is not

The call 19, `display_info`, writes a versioned `DisplayInfo` structure to a
writable range of the caller. The structure contains the visible width,
height, pitch, bits per pixel, pixel format, channel masks and shifts. It
does **not** contain the physical base address, the mapping size or any
other address of the device.

The call is read-only and requires no capability. The geometry of the
display is public information, and the call cannot write a pixel. A boot
without a framebuffer answers with the error 22, `no_display`.

The layout is in `shared/display.zig`; the kernel registry is in
`kernel/graphics/display.zig`. The SDK exposes the same structure through
the `voryn_display` module, so the kernel and the application cannot drift
apart silently.

### 2.2 Presentation is a validated copy, not a mapping

The call 20, `present`, copies pixels from a buffer of the caller to the
framebuffer. It does **not** map the framebuffer into the process and it
does **not** accept a kernel address.

The request is a versioned structure with the buffer address, the buffer
length, the destination rectangle, the stride and the pixel format. The
kernel validates, in this order:

1. the caller is a process of the user mode;
2. the caller holds the display capability with the write right, **before**
   the request is read;
3. the request structure itself is a readable range of the user;
4. the version is known;
5. the geometry does not overflow and fits the visible display;
6. the pixel format matches the format reported by `display_info` and is
   RGB32 or BGR32;
7. the stride is at least `width * 4`, and `stride * height` does not
   overflow;
8. the length is at most 64 MiB;
9. the pixel buffer is a readable range of the user with at least
   `stride * height` bytes;
10. the rectangle fits the mapped framebuffer.

Only then does the kernel copy the rows into the framebuffer. The copy is
synchronous: when the call returns, the pixels are in the device. There is
no queue and no asynchronous completion in the first version.

### 2.3 The display capability

The contract adds a capability kind `display`, value 2, with two rights:

| Right | Value | Meaning |
|-------|------:|---------|
| `write` | 8 | present pixels to the display |
| `delegate` | 4 | give the capability to another process |

The kernel grants the capability of the display to the compositor process
when it creates that process. The identifier of the process is not the
authority: a process that receives the identifier without the capability is
refused with the error 10, `not_authorized`.

The first implementation has one compositor. In F6.26 the native toolchain
application is the compositor stand-in: it receives the capability at boot
and presents a 16x16 probe. The user-space compositor of F6.28 will receive
the same capability; the kernel does not change the authority model for the
demo. The capability model is used from the beginning, because adding it
later would change the security properties of every existing presentation
path.

### 2.4 Input is a capability and a queue

The call 21, `input_poll`, takes one event from the user input queue. The
caller holds a capability of kind `input`, value 3, subject 0, with the
right `read`, value 16. The kernel checks the capability before the output
range is touched and validates the output range before it pops an event, so
a bad address does not lose an event and a process without the authority
cannot use the call as a probe of the queue.

The event is a versioned 16-byte `InputEvent` in `shared/input.zig`. It
carries the key code of PS/2 set 1 and the pressed and extended flags. The
call is non-blocking: it returns 1 when it wrote an event, 0 when the queue
is empty and a negative error otherwise. There is no blocking wait and no
per-process queue in F6.27.

The PS/2 interrupt fills **two** queues: the kernel diagnostic queue and the
user input queue. The kernel's boot pump and the interactive loop consume
the diagnostic queue; the graphics service consumes the user queue. The
separation is deliberate: the boot test sends `A` and `right` to the
kernel, and the user probe must not be able to steal the `I` key that
selects the interactive mode. The first implementation has one user queue;
a future input service can add per-process queues without changing the
event structure.

The first input call is a probe, not a full input service. It has no
blocking form, no pointer or mouse event, no focus and no timestamp. Those
belong to the compositor and window manager increment (F6.28). The keyboard
interrupt handler never calls into a user process, and the service never
reads the PS/2 controller directly.

### 2.5 Surfaces and composition

The first presentation path uses a buffer that belongs to the caller. It is
enough for a full-screen demo and for a compositor that draws into its own
memory. Sharing a surface between a client and the compositor requires a
memory capability, which the contract does not have yet; that is a later
increment.

The compositor will draw the window decorations and the window contents
into its own buffer and present the damaged rectangle. The kernel will not
know about windows in the final design: it will know about the display and
the validated rectangle. The window list, the focus and the z-order belong
to the user-space service.

## 3. Alternatives considered

### 3.1 Map the framebuffer into every process

Rejected. It is the shortest path to a demo and the worst path for
isolation: any process could overwrite any pixel, including the pixels of
another process, and the kernel could not enforce a window boundary. It
would also expose the MMIO programming model of the firmware to the
application.

### 3.2 Map the framebuffer only into a trusted compositor

Rejected for the first version. A mapping is still a device mapping: a bug
in the compositor would give the process raw MMIO, and the kernel would
have no place to validate the rectangle. A copy through `present` costs
more, but it keeps the device behind a checked interface. The copy can be
optimized later without changing the authority model.

### 3.3 Keep the compositor in the kernel

Rejected as the final architecture. It cannot provide per-application
windows, focus, a crash-contained graphics service or an SDK that an
application can use without kernel changes. The kernel-side compositor
remains useful as a diagnostic and as the fallback while the service is
built.

### 3.4 Present without a capability

Rejected. Any process could take over the screen, including a process that
was only supposed to write a log. The capability is the mechanism that
makes the display authority explicit and revocable.

### 3.5 Asynchronous presentation with a queue

Deferred. A queue needs a completion event, a back-pressure policy and a
way to cancel a frame when the window moves. The synchronous copy is
simpler, and the first measurements will tell whether the copy is the
bottleneck.

## 4. Consequences

### 4.1 ABI

- Version 10 adds the call 19 and the error 22; it is additive.
- Version 11 adds the call 20, `present`, the display capability kind and
  the errors 23 and 24; it is additive.
- Version 12 adds the call 21, `input_poll`, the input capability kind and
  the error 25; it is additive.
- The existing calls keep their numbers and meanings.

### 4.2 Security

- The user mode never receives the framebuffer address.
- Every pointer is checked in the page tables of the caller, with the
  writable or readable bit that the operation needs.
- Geometry and stride are checked with explicit overflow rules before any
  byte is copied.
- The display capability is checked before the buffer is touched, so a
  process without the authority cannot use the call as a probe of the
  framebuffer.
- The input capability is checked before the output is touched and before
  an event is popped, so a process without the authority cannot drain the
  queue, and a bad address cannot lose an event.
- The copy is bounded by the visible rectangle, by the 64 MiB presentation
  bound and by the framebuffer mapping that the kernel verified.

### 4.3 Performance

- The copy is the new cost. F6.24 already reduced the kernel-side redraw to
  the exposed strips; the presentation path should preserve that property
  by accepting a rectangle, not only a full screen.
- The first version has no double buffering and no vsync. Tearing is
  possible, and it is documented as a limitation.
- The release build measured 3.79 ms per arrow for the kernel compositor.
  The F6.26 presentation and the F6.27 input-driven probe are 16x16
  rectangles, not frame paths; F6.28 will instrument the user-space
  compositor with the same TSC and QEMU harness.

### 4.4 Tests

- Host tests for the `DisplayInfo` layout and for the registry.
- Host tests for the version, geometry, stride, length and format validation
  of `present`, before the call touches a framebuffer.
- A QEMU test that calls `display_info` from the native SDK application and
  verifies the serial marker (F6.25).
- A QEMU test that presents a known 16x16 pattern from the native SDK
  application and reads the first pixel back from the framebuffer (F6.26).
- A QEMU test that calls `input_poll` from the native SDK application. The
  boot test already sends `A` and `right`; the user queue receives the
  right arrow, the application presents at (16,0) and the serial markers
  prove the path end to end (F6.27). The empty result is exercised by the
  polls before the key arrives.
- A host test for the `InputEvent` layout, the flags, the version and the
  input capability kind and rights.
- A host test that a process without the display capability is refused by
  the capability check. A separate user process that exercises the refusal
  through the `present` call in QEMU is F6.28.
- The full screenshot comparison of a user-space frame is F6.28.

## 5. Increments

| Increment | Content | State |
|-----------|---------|-------|
| F6.25 | `display_info`, ABI 10, native SDK query, user stack alignment fix | TESTED LOCALLY |
| F6.26 | display capability, `present`, ABI 11, validated rectangle, 16x16 probe | TESTED LOCALLY |
| F6.27 | input capability, `input_poll`, ABI 12, user-space input probe and input-driven presentation | TESTED LOCALLY |
| F6.28 | user-space compositor demo, window manager, focus, cursor, screenshot verification and the first desktop shell | PROPOSED |

The F6.25 increment also fixed a latent ABI bug: user tasks started with a
16-byte-aligned `RSP`, while a function entry expects `RSP + 8` to be
aligned because a call would have pushed a return address. The added
`DisplayInfo` structure made the compiler emit an aligned SSE spill, which
exposed the bug as a general protection fault. The scheduler now starts
both user and kernel tasks at `top - 8`.

The F6.26 increment keeps the diagnostic kernel scene as the boot
background. After the toolchain task terminates, the kernel draws the scene
again, so the interactive screenshot test starts from the scene that the
kernel owns. The presentation is proven by the serial read-back of the
first pixel, not by a persistent rectangle; the full user-space frame is
F6.28.

The F6.27 increment adds the input capability and the non-blocking
`input_poll`. The native SDK application is still the graphics stand-in: it
receives the display and the input capabilities, presents a 16x16 probe at
(0,0), polls the user input queue and, when the right arrow arrives,
presents the same probe at (16,0). The boot test sends `A` and `right` for
the kernel; the user queue receives the right arrow while the diagnostic
queue keeps the kernel's copy. The test therefore covers the capability
grant, the syscall, the event decoding, the user-side validation and the
input-driven presentation. The full compositor, the window manager and the
screenshot comparison remain F6.28.

## 6. References

- [`docs/specs/syscall-abi.md`](../specs/syscall-abi.md) — version 12.
- [`shared/display.zig`](../../shared/display.zig) — the metadata and
  presentation contract.
- [`shared/input.zig`](../../shared/input.zig) — the input event contract.
- [`kernel/graphics/display.zig`](../../kernel/graphics/display.zig) — the
  kernel registry and the private framebuffer surface.
- [`kernel/input/ps2.zig`](../../kernel/input/ps2.zig) — the PS/2 interrupt
  and the two independent queues.
- [`kernel/security/capability.zig`](../../kernel/security/capability.zig) —
  the capability model, including the display and input kinds.
- [`docs/reports/f6/display-metadata-and-user-stack-alignment.md`](../reports/f6/display-metadata-and-user-stack-alignment.md)
  — the F6.25 report.
- [`docs/reports/f6/display-presentation-and-display-capability.md`](../reports/f6/display-presentation-and-display-capability.md)
  — the F6.26 report.
- [`docs/reports/f6/input-event-capability-and-user-input-probe.md`](../reports/f6/input-event-capability-and-user-input-probe.md)
  — the F6.27 report.
- [`docs/reports/f6/input-latency-and-exposed-strip-damage.md`](../reports/f6/input-latency-and-exposed-strip-damage.md)
  — the F6.24 measurements.
