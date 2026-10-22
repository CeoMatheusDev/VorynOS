# ADR-0001 — Voryn Fabric

| Field | Value |
|-------|-------|
| **Status** | DRAFT — accepted as a working direction, not as a frozen architecture |
| **Date** | 2026-10-21 |
| **Authored by** | VorynOS Engineering |
| **Supersedes** | — |
| **Superseded by** | — |

## 1. Context

The VorynOS needs a system architecture that serves home users, gamers,
developers, professionals, content creators, advanced users, and AI
applications, without depending on any external kernel running
natively.

Structural constraints:

- The kernel must contain **minimal privileged mechanisms**; complex
  policies belong to isolated services.
- Security must be built on capabilities, with least privilege and
  revocation.
- Complex drivers must not be able to bring the system down; the goal is
  fault isolation.
- Performance must be measured, not promised.

## 2. Directives

- **D1** Reduce the kernel's privileged surface.
- **D2** Enable fault isolation in drivers and services.
- **D3** Control interprocess communication in an explicit and
  auditable way.
- **D4** Keep the critical path (system call, context switch, IPC)
  predictable and low-cost.
- **D5** Avoid premature abstractions and unnecessary dependencies.

## 3. Considered Options

### Option A — Modular monolith

A single kernel with well-separated internal subsystems, everything in kernel mode.

- Pros: simplicity, fast path, easy to debug.
- Cons: a driver failure brings the system down; the privileged surface is
  large; policies leak into the kernel.

### Option B — Microkernel with services in user mode

Everything that is not a minimal mechanism becomes a user process.

- Pros: maximum isolation, minimal privileged surface.
- Cons: IPC cost on every critical path, complexity of initialization and
  recovery, risk of disproportionate overhead for a system that does not
  yet have IPC defined.

### Option C — Voryn Fabric (modular hybrid)

**Chosen.** Minimal mechanisms in the kernel; complex policies and drivers
in isolated processes, communicating through typed channels with capability
transfer; written in Zig, with C23 and Assembly only where there is
technical justification.

## 4. Decision

Adopt the **Voryn Fabric**: a modular hybrid model with nine components.

| Acronym | Name | Scope | Where it runs |
|-------|------|--------|--------------|
| VNB | Voryn Native Boot | UEFI loader, firmware/kernel boundary | Firmware |
| VNK | Voryn Nucleus Kernel | Minimal privileged mechanisms | Kernel |
| VNH | Voryn Hardware Nexus | Hardware discovery and interface | Kernel (data) / service (policy) |
| VNM | Voryn Nexus Memory | Physical memory, virtual memory, allocators, protections | Kernel |
| VNT | Voryn Task Fabric | Tasks, scheduling, affinity | Kernel |
| VNX | Voryn Exchange | Interprocess communication | Kernel (mechanism) / services (policy) |
| VNC | Voryn Capability Fabric | Capabilities, revocation, audit | Kernel |
| VND | Voryn Device Fabric | Drivers, fault isolation | Kernel (registry) / user mode (driver) |
| VSN | Voryn Service Node | Lifecycle, supervision, recovery | User mode |

### 4.1 Trust boundaries

1. **Firmware → VNB → VNK**: the only boundary with third-party code
   running privileged. The contract is a versioned structure, validated
   on both sides, with magic, version, and coherence verification.
2. **VNK → services**: the kernel hands out capabilities, never global
   pointers nor unrestricted access.
3. **Driver → VNK**: a driver in an isolated process receives
   device-specific capabilities; exceptions exist only for the bootstrap
   path (minimal VNH).
4. **Application → VNX**: typed messages, with a versioned schema,
   resource limits, and explicit capability transfer.

### 4.2 Where policy does NOT go

- Scheduling: VNT implements the mechanism (queues, context, priority);
  the policy (interactive latency, game profiles) lives in VSN.
- Memory: VNM implements allocators and protections; VSN decides quotas.
- Storage: VFSX implements file semantics; VSN decides cache, quotas, and
  retention policies.

## 5. Rationale

Option C is chosen because it satisfies D1 and D2 without paying the D4
cost that Option B imposes at the current stage: the system still has no
IPC defined, and placing the whole system in user mode before an
efficient communication channel exists would create a performance dead end.

The risk of Option C is known: the boundary between "mechanism" and
"policy" may be poorly drawn and concentrated in the kernel. Mitigation:
every rule that enters the kernel needs a recorded justification, and the
review criterion is "is this rule necessary to maintain the safety or the
correctness of the mechanism, or could it live in a service with the same guarantee?".

## 6. Costs and Risks

| Risk | Impact | Mitigation |
|-------|---------|-----------|
| Excessive privileged surface | High | Review via ADR; a rule in the kernel requires justification |
| High-cost IPC | Medium | Measure VNX latency before deciding scheduling policies |
| Incomplete driver isolation | High | Documented and auditable bootstrap exceptions |
| Initialization complexity | Medium | VSN with explicit dependencies and supervised restart |
| "Voryn Fabric" as a name without content | High | Each component needs an implementation and acceptance criteria |

## 7. Consequences

- The repository begins to be organized by component, and not by horizontal
  layer.
- Every new boundary needs a versioned contract.
- The kernel does not grow out of convenience: it grows out of justification.
- IPC and context switch performance must be measured before any claim
  about suitability for games.

## 8. Validation Status

None of the components beyond VNB and the initial kernel core of VNK is
implemented. This document is a **DRAFT**: the architecture will be
reassessed when VNM, VNX, and VNC exist, because the final shape depends
on decisions that have not yet been made (message format, capability
model, page table granularity).

## 9. Open Questions

1. Will the VNX channel be message-oriented (one queue per pair) or based
   on a shared register with notification? Direct impact on the latency of
   communication between services.
2. Will the VNC capabilities be derived from the process (Rust-style) or
   be references to paginated tables (Capsicum-style)? Direct impact on system call cost.
3. Does VND run drivers in user mode from the first driver, or only from
   a minimal subset onward? Direct impact on the F7 milestone.
