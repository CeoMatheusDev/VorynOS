# VSC-0001 — VorynOS system call contract

| Field | Value |
|-------|-------|
| **State** | ACCEPTED |
| **Date** | 2026-10-22 |
| **Scope** | The interface between the user mode and the kernel |
| **Contract version** | `syscall_abi = 3` |

## 1. Objective

Define the system call interface of the VorynOS: how the user mode asks an
operation of the kernel, how the kernel answers, and how a program discovers
that the operation was not performed.

The contract is **stable**: a user program compiled against version 1 keeps
working when the kernel moves to version 2, and the kernel has to **refuse**
a call number that it does not know, instead of guessing its meaning.

Version 2 adds the channel calls and the call that copies a block between
two processes. Version 3 adds the call that **blocks** waiting for a
message. The calls of the earlier versions **do not change their number and
do not change their meaning**.

## 2. The mechanism

The call is delivered by the `syscall` instruction, the path that the
architecture provides for the 64 bit mode. The instruction:

- loads the code and the stack of the kernel from `IA32_STAR`;
- loads the entry address from `IA32_LSTAR`;
- applies the `IA32_SFMASK` mask to the flags of the caller;
- leaves the address of return in the `RCX` register and the flags of the
  caller in the `R11` register.

The entry of the call is on the kernel stack of the task, and the interrupt
return frame with the state of the user is built on the way back, with the
`iretq` instruction. The handler **never** runs on the stack of the user.

## 3. The call register

```text
register  use
RAX          the number of the call, and the result of the call
RDI          the first argument
RSI          the second argument
RDX          the third argument
R8           the fourth argument
RCX          the address of return (written by the instruction)
R11          the flags of the caller (written by the instruction)
```

`RCX` and `R11` **are not arguments**: the call instruction writes them,
and a program that needs a fourth argument has to use `R8`. A classic
mistake is to use `RCX` for the value of a message: the value that the
kernel receives is the address of return, and the message arrives with the
wrong value.

The arguments that are not used by a call have no meaning. A user program
**cannot** presume that the registers that the architecture does not save
are intact after the call: the handler preserves the ones that the calling
convention requires, and the kernel documents which ones they are.

## 4. The calls of version 1

| Number | Call | Arguments | Result |
|--------|---------|-----------|-----------|
| 1 | `ping` | — | `0x42`, a known value |
| 2 | `write` | `RDI` buffer, `RSI` length, `RDX` file | the number of bytes written |
| 3 | `memcpy` | `RDI` destination, `RSI` source, `RDX` length | the number of bytes copied |
| 4 | `exit` | `RDI` exit code | — |

### 4.1 `ping`

The call has no argument and answers with a known value. It exists to prove
that the instruction, the model registers and the way back work, and it is
the call that the self test of the kernel uses.

### 4.2 `write`

Writes a block of bytes in the indicated file. Version 1 knows only the
console of the kernel, the file `1`; any other file is refused.

The block belongs to the user, and the kernel **checks the range in the page
tables** before reading: the page has to be present, it has to have the user
bit, and the length has to be within the limit of the contract. A call with
an address of the kernel is refused, and the kernel does not read the
memory.

The check is done in the tables of the **address space of the process that
called**, because the pages of the user mode live in that space and in no
other.

### 4.3 `memcpy`

Copies a block of bytes from one address of the user to another address of
the user. The two ranges are checked in the page tables before the copy,
and the copy is done by the kernel, so that the user does not need a routine
of its own for that.

The source has to be present and to have the user bit; the destination has
to be present, to have the user bit and to be writable.

The copy tolerates ranges that overlap: the one that chooses the two
addresses is the user, and a copy that refused the overlap would deny a
legitimate call. The copy is done from the end to the beginning when the
ranges overlap, and the result is the same as the copy of a Turing machine.

### 4.4 `exit`

Ends the user task. The kernel marks the task as terminated and the
scheduler does not choose it again; the processor leaves the task on the
next interrupt. The exit code is registered in the task.

## 5. The calls of version 2

| Number | Call | Arguments | Result |
|--------|---------|-----------|-----------|
| 5 | `send` | `RDI` channel, `RSI` side, `RDX` kind, `R8` value | zero, when the message was posted in the queue |
| 6 | `receive` | `RDI` channel, `RSI` side | the kind of the message, and the value in the `RDX` |
| 7 | `copy_to` | `RDI` process, `RSI` destination, `RDX` source, `R8` length | the number of bytes copied |
| 8 | `receive_blocking` | `RDI` channel, `RSI` side | the kind of the message, and the value in the `RDX` |

### 5.1 `send`

Posts a message in the queue of one side of a channel. The arguments are
the identifier of the channel, the side that receives the message, the kind
of the message and the value of the message.

The side is an argument, and not a rule of the call, because **a channel
belongs to two tasks and each side of the channel is a task**: the one that
sends chooses the side of the one that receives, and the one that receives
chooses the same side. With this rule the message never comes back to the
sender, and two processes talk through the same channel without taking the
message from each other.

The channel has one queue per side, and the queue is limited to sixteen
messages. A full queue refuses the message, and the refusal is counted.

### 5.2 `receive`

Takes a message of a channel. The arguments are the identifier of the
channel and the side that holds the message. The result is the kind of the
message, and the value of the message comes back in the `RDX`.

The call **does not block**: an empty queue returns the error 5, and the
program repeats the call until the message arrives. The blocking is a
separate increment, because it requires the call to be able to continue
after the message arrives.

### 5.3 `copy_to`

Copies a block of bytes from the space of the process that called to the
space of another process. The arguments are the identifier of the
destination process, the address of the destination in the destination
space, the address of the source in the space of the caller, and the length
of the block.

The two spaces do not name the same pages, therefore the kernel does not
copy the block with a single movement: it reads the source with the space
of the caller active, saves the block in a buffer of the kernel, and writes
the destination with the space of the destination active. The buffer lives
in the kernel image, and the image is mapped in every space, and therefore
the buffer is reachable in both directions of the switch.

The two ranges are checked in the tables of the space of each one, and the
space of the caller is restored at the end, whatever the result of the copy
is.

### 5.4 `receive_blocking`

Takes a message of a channel and **blocks** the caller until the message
arrives. The arguments are the identifier of the channel and the side that
holds the message. The result is the kind of the message, and the value of
the message comes back in the `RDX`.

The difference in relation to the `receive` call is what happens when the
queue is empty:

| | `receive` | `receive_blocking` |
|---|---|---|
| the queue is empty | returns the error 5 | the task **waits** |
| use of the processor | the task repeats the call | the task **is not** run |
| choice of the task | the task keeps being chosen | the scheduler chooses another one |
| return | immediate | when the message arrives |

The task that waits is marked as blocked, and the scheduler does not choose
it. When the message arrives, the delivery writes the kind and the value
**straight into the context saved of the task**, and the task wakes up. The
task continues **after** the call, with the result in the same registers as
a call that had answered at once.

The delivery is **direct**: the message does not stay in the queue when
there is someone waiting, and therefore the measured latency is the
interval between the message leaving and the message arriving at the task
that was waiting, and not the time that the task spent waiting in the
queue.

The call returns the error 5 when the queue is empty and **there is no
other task to run**: a wait that would be the only task of the system would
be a busy loop, and not a wait.

## 6. The result and the errors

The result of the call comes back in `RAX`. A **negative** result means
that the call **was not performed**, and the absolute value of the result is
the code of the error:

| Code | Error | Meaning |
|--------|------|-------------|
| 1 | unknown call | the number of the call does not exist in this version |
| 2 | invalid address | one of the ranges does not belong to the user mode |
| 3 | invalid length | the length is zero or greater than the limit |
| 4 | not allowed | the call is not allowed at the privilege level of the caller |
| 5 | empty queue | the side of the channel has no message |
| 6 | unknown channel | the identifier of the channel does not exist |
| 7 | full queue | the side of the channel does not accept more messages |
| 8 | unknown process | the identifier of the process does not exist |
| 9 | impossible wait | the task waited for a message and there was no other task to run |

The limit of the length is **64 KiB** per call, and it exists so that the
kernel does not spend an undetermined time inside a call.

A result that is not negative is the number of bytes processed, and it is
never negative, so that the user program tells the two cases apart without
knowing the error codes.

## 7. The rules of the contract

1. A new call number **never** reuses the number of an existing call: the
   number is the identity of the call forever.
2. A new call enters at the end of the list, and the contract increments the
   version.
3. An unknown call number is refused with the error 1. The kernel **cannot**
   guess the meaning of a number.
4. The user is the owner of its memory: every range that the kernel touches
   because of a call is checked in the page tables before.
5. The handler runs on the kernel stack of the task, and not on the stack of
   the user.
6. The call never changes the privilege state of the caller beyond the way
   in and the way out, and the way out returns the flags of the caller.
7. The arguments of a call that goes beyond three use `R8`, and never `RCX`
   nor `R11`, because the call instruction writes both.
8. A call that checks a range checks the range **in the address space of the
   caller**, and not in the space of the kernel.
9. A call that blocks does not occupy the processor, and the task is only
   chosen again when the message arrives.

## 8. What version 2 does not have

- **Transfer of capabilities.** The call does not carry capabilities, and
  the open question of ADR-0001 about the capability model remains open.
- **Files.** The `write` call knows only the console.
- **Message structure.** There is no message format defined, and the
  message of the channel carries a kind and a value.
- **Several processes per call.** The `copy_to` call knows the destination
  process by the identifier, and not by a file name nor by a path.
- **Wait with a timeout.** The call that blocks waits forever, and there is
  no timeout of the wait.
- **Several waits per task.** A task waits for one channel and one side,
  and not for a set of channels.
