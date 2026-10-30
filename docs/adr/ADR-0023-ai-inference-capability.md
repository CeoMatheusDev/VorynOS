# ADR-0023 — The inference call and the capability of the engine

| Field | Value |
|-------|-------|
| **State** | ACCEPTED |
| **Date** | 2026-10-30 |
| **Scope** | F9 — the inference engine as a capability of the system |
| **Contract** | `docs/specs/syscall-abi.md`, version 13, call 24 |

## 1. Context

The milestone F9 delivered `kernel/ai/{tensor,model,security}.zig`: a binary
model format with a CRC32 over the weights, checked size limits, a dense
product with ReLU and an inference routine. The code was correct and covered
by host tests, and it was **not reachable from the operating system**:
`build.zig` referenced it only as a test target, no file of the kernel
imported it, there was no call, no capability and no marker in the boot.

The consequence is a documentation defect before it is a technical one: the
README described F9 as "Scoped complete — native CPU inference", and a
reader concludes that a program can run a model. It could not.

## 2. Decision

The engine becomes a **capability of the kernel**, and not a library that a
process links.

1. The kernel embeds **one** model image, built at **compile time** with the
   same binary format that the validator reads (`kernel/ai/embedded.zig`).
   Nothing is read from the disk, from the firmware or from the network.
2. The kernel validates the image and runs it **before the timer starts**,
   and a failure halts the boot. A kernel that cannot run its own model would
   answer the call 24 with numbers that look valid.
3. A new kind of capability, `ai` (wire value 4), with the right `execute`
   (value 32). The root authority is the kernel; it gives the capability to
   the process that already composes the display, and it does not give the
   right of delegation, because there is no second consumer today.
4. A new call, number 24 `ai_infer`: the process sends features and receives
   the result. The weights, the workspace and the address of the image never
   leave the kernel.
5. The geometry is part of the ABI, published in `shared/ai.zig` and in the
   SDK, so that a program sizes its buffers without asking the kernel.

## 3. Alternatives considered

| Alternative | Why it was rejected |
|---|---|
| Export the inference as a VLIB library that the application links | The model, the weights and the workspace would live in the address space of every application. There would be no boundary, no revocation and no way to tell an inference of the kernel from one of the process. |
| Load the model from the RamFS at boot | A model file is an untrusted input with a CRC that the loader would have to validate anyway; the boot would depend on a file that can be absent. The embedded image is part of the signed-by-build kernel image. |
| No capability, only the call | Any process could spend the CPU of the machine on inference. The capability model of `ADR-0001` and the isolation work of F3 exist exactly to avoid that. |
| A blocking or asynchronous inference | The model of this version is one layer over 4 features. A queue, a completion and a wake-up would add three failure modes to a computation that takes tens of cycles. The synchronous call is the honest size of the increment. |
| Trust the image after the first validation | One corrupt read after the boot would produce valid-looking numbers for the rest of the execution. The CRC of 48 bytes is cheaper than the class of defect it avoids. |

## 4. Consequences

**Positive**

- F9 stops being a library and becomes a property of the system: a process
  runs an inference, the kernel checks the capability, and the boot proves
  both the positive and the negative case.
- The isolation is testable in one line of the boot log: the client process
  does not hold the capability and is refused with the error 10 before its
  buffer is read.
- The load is bounded: 4 inputs, 3 outputs, one layer, no allocation.

**Negative and pending**

- The geometry is **fixed**. A different model requires a new version of the
  contract, and a version that accepts several models needs the identifier
  as an argument (the field `model_id` exists for that and is checked).
- There is no GPU acceleration, no quantized weights, no batching and no
  asynchronous completion. The claim of the milestone is CPU inference over
  one embedded model, and nothing more.
- The inference runs inside the system call, on the kernel stack. A model
  large enough to matter would have to become a service with its own task,
  which is future work and a different decision.

## 5. Evidence

| Check | Result |
|---|---|
| `zig build test` | 612 tests, 0 failures; `ai-tests` 3 → 10 |
| Embedded image | validates against `model.validate`, CRC recomputed at compile time |
| Exact output | `[2.125, 5.25, 4.0]`, checksum `0x30f2bf7325eecf35` |
| Kernel boot self-test | fatal on a corrupted or divergent image, before the timer |
| Positive path | the composing process calls 24 and receives 12 bytes |
| Negative path | the client process, without the capability, is refused with 10 |
| Boundary | a request with a wrong length is refused with 3 before any copy |

The measured environment and the limits of the validation are in
[`../reports/f9/f9-inference-call.md`](../reports/f9/f9-inference-call.md).
