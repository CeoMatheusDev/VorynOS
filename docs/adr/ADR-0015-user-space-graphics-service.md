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
| **Implementation** | `display_info` TESTED LOCALLY; `present` and the service PROPOSED |

## 1. Context

The F6 compositor runs inside the kernel. It owns the framebuffer, the
window list, the damage tracker and the keyboard path. That design made the
first pixels possible and allowed the F6.22.2–F6.24 measurements, but it is
not the desktop that the project needs: an application cannot create a
window, cannot present its own pixels and cannot receive input through a
permission-checked interface.

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

A future call, `present`, will copy pixels from a buffer of the caller to
the framebuffer. It will **not** map the framebuffer into the process and it
will **not** accept a kernel address.

The request is a versioned structure with the buffer address, the buffer
length, the destination rectangle, the stride and the pixel format. The
kernel will validate, in this order:

1. the request structure itself is a readable range of the user;
2. the version is known;
3. the geometry does not overflow and fits the visible display;
4. the stride is at least `width * 4`, and `stride * height` does not
   overflow;
5. the pixel buffer is a readable range of the user with at least
   `stride * height` bytes;
6. the pixel format matches the format reported by `display_info`;
7. the caller holds the display capability with the write right.

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

The first implementation has one compositor. The capability model is still
used from the beginning, because adding it later would change the security
properties of every existing presentation path.

### 2.4 Input

Input events stay in the kernel in F6.25. The future graphics service will
receive them through a call of its own, with a bounded queue per process.
The keyboard interrupt handler will not call into a user process, and the
service will not read the PS/2 controller directly.

The first input call will return one event per invocation, with a
non-blocking and a blocking form, in the same style as the channel calls.
The event carries the device, the key code, the pressed/released state and a
monotonic timestamp. A process without the input capability will be
refused.

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
- Version 11 will add `present` and the display capability kind. The number
  20 is reserved for `present`; it is not used by another call.
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
- The copy is bounded by the visible rectangle and by the maximum block
  length of the contract.

### 4.3 Performance

- The copy is the new cost. F6.24 already reduced the kernel-side redraw to
  the exposed strips; the presentation path should preserve that property
  by accepting a rectangle, not only a full screen.
- The first version has no double buffering and no vsync. Tearing is
  possible, and it is documented as a limitation.
- The release build measured 3.79 ms per arrow for the kernel compositor.
  The user-space path will be measured with the same TSC instrumentation
  and with the QEMU harness.

### 4.4 Tests

- Host tests for the `DisplayInfo` layout and for the registry.
- Host tests for the geometry and stride validation of `present`, before
  the call touches a framebuffer.
- A QEMU test that calls `display_info` from the native SDK application and
  verifies the serial marker (F6.25).
- A QEMU test that presents a known pattern and compares the framebuffer
  with the expected pixels (F6.26).
- A test that a process without the display capability is refused.

## 5. Increments

| Increment | Content | State |
|-----------|---------|-------|
| F6.25 | `display_info`, ABI 10, native SDK query, user stack alignment fix | TESTED LOCALLY |
| F6.26 | display capability, `present` with a validated rectangle, geometry tests | PROPOSED |
| F6.27 | user-space compositor demo, input event call, screenshot verification | PROPOSED |
| F6.28 | window manager, focus, cursor and the first desktop shell | PROPOSED |

The F6.25 increment also fixed a latent ABI bug: user tasks started with a
16-byte-aligned `RSP`, while a function entry expects `RSP + 8` to be
aligned because a call would have pushed a return address. The added
`DisplayInfo` structure made the compiler emit an aligned SSE spill, which
exposed the bug as a general protection fault. The scheduler now starts
both user and kernel tasks at `top - 8`.

## 6. References

- [`docs/specs/syscall-abi.md`](../specs/syscall-abi.md) — version 10.
- [`shared/display.zig`](../../shared/display.zig) — the metadata contract.
- [`kernel/graphics/display.zig`](../../kernel/graphics/display.zig) — the
  kernel registry.
- [`kernel/security/capability.zig`](../../kernel/security/capability.zig) —
  the capability model that the display kind will extend.
- [`docs/reports/f6/input-latency-and-exposed-strip-damage.md`](../reports/f6/input-latency-and-exposed-strip-damage.md)
  — the F6.24 measurements.
