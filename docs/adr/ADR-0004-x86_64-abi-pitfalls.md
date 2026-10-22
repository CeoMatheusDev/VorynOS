# ADR-0004 — x86_64 ABI pitfalls found during the VNK bring-up

| Field | Value |
|-------|-------|
| **Status** | ACCEPTED — the pitfalls are recorded and the code avoids them |
| **Date** | 2026-10-21 |
| **Decided by** | VorynOS Engineering |
| **Context** | Milestone F2, kernel bring-up |

## 1. Context

The installation of the kernel's segment, interrupt, and paging structures
uncovered a series of errors that do not produce a compilation failure and
that the emulator reports in a not very obvious way. All of them were
diagnosed with QEMU's exception log (`-d int`), which shows the vector, the
error code, and the processor state at the moment of the failure.

This document records the pitfalls, so that they do not reappear and so that
reading the kernel code becomes faster.

## 2. The pitfalls

### 2.1 The segment table entry is eight bytes

The entry structure is made of two quad words, not of a pair of quad words.
With sixteen-byte entries, the offset of each descriptor was twice the
expected value and **all** the selectors pointed to the wrong descriptor.

```zig
const Entry = extern struct {
    low: u32 = 0,   // limit and low base
    high: u32 = 0,  // access byte, flags, and high base
};
```

### 2.2 The selector encodes the offset in bytes

The selector is not an index: bits zero to twelve are the **byte offset** of
the descriptor in the table, bit three is the table indicator, and bits four
and five are the privilege level. The table indicator sits **inside** the
offset field, so the selector cannot be described by a packed structure and
is built by a function.

```zig
pub fn makeSelector(byte_offset: u13, table_indicator: u1, rpl: u2) u16 {
    return @as(u16, byte_offset) | (@as(u16, table_indicator) << 3) | (@as(u16, rpl) << 4);
}
```

### 2.3 The task segmentation descriptor requires the present bit

For system descriptors, the type byte carries the present bit in the highest
position. A present and available 64-bit task segment has type `0x89`, and
not `0x09`. With `0x09` the processor refuses the `ltr` instruction with a
stack segment fault (#SS) whose error code is the segment selector itself.

### 2.4 The interrupt table gate has a stack index byte

The interrupt gate format is:

```text
0-1   handler offset, low part
2-3   code segment selector
4     interrupt stack table index in the three low bits
5     gate type, privilege level, and present bit
6-7   handler offset, middle part
8-11  handler offset, high part
12-15 reserved
```

Omitting the index byte shifts the gate type and the processor delivers the
exception to an invalid address, which results in a sequence of page faults
that have no relation to the original cause.

### 2.5 The segment table precedes the interrupt table

The interrupt table gates carry a code segment selector. If the interrupt
table is installed while the firmware's segment table is still active, the
selector may not exist in the firmware table (OVMF uses `0x38` for code and
`0x30` for data) and the exception delivery fails with a general protection
fault.

The correct order is: **segment table, then interrupt table**. The kernel
also needs the task segment for the gate's stack index, which requires it to
be loaded after the interrupt table, so that a failure is reported by the
kernel's own handler.

### 2.6 The `ltr` instruction operates with sixteen bits

Zig's integrated assembler promotes the register operand to the thirty-two
bit form, which is a different encoding of the instruction. The sixteen-bit
form is only reachable through the memory form:

```asm
    movw %di, voryn_tss_selector(%rip)
    ltrw voryn_tss_selector(%rip)
```

The same applies to the segment table and to the interrupt table: `lgdt` and
`lidt` have no register form, the operand is always memory.

### 2.7 The far return requires a zero-extended selector

The far return reads the selector from a full quad word and refuses a
selector whose upper bits are not zero. The upper bits of the argument
register are not defined by the ABI, therefore the selector has to be
extended explicitly.

The far switch was preferred over the far return: it does not touch the
stack and it eliminates a class of alignment problems of the removed frame.

### 2.8 Zig 0.17's inline assembly has its own rules

- The input operand has to be an **identifier**, not an expression: an
  address or a conversion must live in a local variable.
- The operand section always has **three** sections: outputs, inputs, and
  clobbers. An empty inputs section is still a section.
- The instructions without a register form have to stay in assembly.

## 3. Decision

Each pitfall has a form in the code that avoids it:

| Pitfall | Form in the code |
|-----------|------------------|
| Eight-byte entry | `kernel/arch/x86_64/segment.zig` |
| Selector by offset | `makeSelector` |
| Present bit of the task segment | `task_type = 0x89` |
| Stack index byte | `kernel/arch/x86_64/interrupt.zig` |
| Order of the installations | `kernel/main.zig` |
| Sixteen-bit selector | `kernel/arch/x86_64/segment.s` |
| Zero-extended selector | `movzwq` before the far jump |
| Inline assembly rules | accesses in assembly |

## 4. Consequences

- The kernel bring-up cannot be done with the compiler alone: QEMU's
  exception log was the tool that turned a symptom (the machine hanging)
  into a cause (the vector and the error code).
- The automated test verifies the installation of each structure by the
  value read back from the processor (`sgdt`, `sidt`) and by the observable
  effect (the count of timer interrupts).
- The processor structures have an integration test, because they depend on
  the processor state and cannot be exercised on the host.
