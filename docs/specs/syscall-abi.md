# VSC-0001 — VorynOS system call contract

| Field | Value |
|-------|-------|
| **State** | ACCEPTED |
| **Date** | 2026-10-24 |
| **Scope** | The interface between the user mode and the kernel |
| **Contract version** | `syscall_abi = 12` |

## 1. Objective

Define the system call interface of the VorynOS: how the user mode asks an
operation of the kernel, how the kernel answers, and how a program discovers
that the operation was not performed.

The contract is **stable**: a user program compiled against version 1 keeps
working when the kernel moves to version 2, and the kernel has to **refuse**
a call number that it does not know, instead of guessing its meaning.

Version 2 adds the channel calls and the call that copies a block between
two processes. Version 3 adds the call that **blocks** waiting for a
message. Version 4 adds the calls that give a capability to another process
and that take it back, and it **requires** the capability of the channel
that the calls of the channel use. Version 5 adds the **kind** of the
capability to the calls that give and take it, so that a process can
delegate the capability of an address space as well as the capability of a
channel. Version 6 adds the call that waits for a message with a timeout.
Version 9 adds the file system calls 13 to 18. Version 10 adds the
read-only display metadata call 19. Version 11 adds the display
presentation call 20, the display capability and the errors 23 and 24.
Version 12 adds the input event call 21, the input capability and the
error 25.

The calls of the earlier versions **do not change their number**. Their
behavior changes in the points that the sections 9 and 10 describe: the
calls that touch a channel need the capability of the channel, and the
calls 9 and 10 carry the kind of the capability. The version 6 is
additive: it adds a call and an error, and no existing call changes.

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

## 5. The calls from version 2 onwards

| Number | Call | Arguments | Result |
|--------|---------|-----------|-----------|
| 5 | `send` | `RDI` channel, `RSI` side, `RDX` kind, `R8` value | zero, when the message was posted in the queue |
| 6 | `receive` | `RDI` channel, `RSI` side | the kind of the message, and the value in the `RDX` |
| 7 | `copy_to` | `RDI` process, `RSI` destination, `RDX` source, `R8` length | the number of bytes copied |
| 8 | `receive_blocking` | `RDI` channel, `RSI` side | the kind of the message, and the value in the `RDX` |
| 9 | `grant` | `RDI` process, `RSI` kind, `RDX` subject, `R8` rights | zero, when the capability was given |
| 10 | `revoke` | `RDI` process, `RSI` kind, `RDX` subject | zero, when the capability was taken back |
| 11 | `receive_timeout` | `RDI` channel, `RSI` side, `RDX` timeout | the kind of the message, and the value in the `RDX` |
| 13 | `fs_open` | `RDI` path address, `RSI` path length, `RDX` flags | the descriptor |
| 14 | `fs_close` | `RDI` descriptor | zero |
| 15 | `fs_read` | `RDI` descriptor, `RSI` buffer, `RDX` length | the number of bytes read |
| 16 | `fs_write` | `RDI` descriptor, `RSI` buffer, `RDX` length | the number of bytes written |
| 17 | `fs_create` | `RDI` path address, `RSI` path length | the descriptor |
| 18 | `fs_mkdir` | `RDI` path address, `RSI` path length | zero |
| 19 | `display_info` | `RDI` structure address, `RSI` structure length | the number of bytes written |
| 20 | `present` | `RDI` request address, `RSI` request length | zero |
| 21 | `input_poll` | `RDI` event address, `RSI` event length | 1 when an event was written, 0 when the queue is empty |

The number 12 is reserved and is **not** defined by this version: the kernel
refuses it with the error 1, as it refuses any unknown number.

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
program repeats the call until the message arrives. The blocking form is
the call 8, `receive_blocking`, described in section 5.4.

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

The caller has to hold the capability of the address space of the target,
with the right of writing. The check of the capability comes before the
check of the ranges, and the call answers with the error 10,
`not_authorized`, when the capability is missing.

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

### 5.5 The calls that give and take a capability

The calls 9 and 10 entered the contract in the version 4, and the version 5
added the kind of the capability. A capability is about a **subject**, and
the subject is a channel, a process, the display or the input queue: the
kind says which one the call names.

| Kind | Value | Subject |
|---|---|---|
| channel | 0 | the identifier of the channel |
| process | 1 | the identifier of the process whose address space the capability describes |
| display | 2 | always 0, because the kernel has one visible display |
| input | 3 | always 0, because the kernel has one input queue for the graphics service |

A kind that does not have one of the values above is refused with the error
11, `unknown_kind`. The kernel does not guess what a value that it does not
know would mean.

#### 5.5.1 `grant`

Gives a capability of the caller to another process. The arguments are the
identifier of the target process, the kind of the capability, the identifier
of the subject, and the rights that the target receives.

The caller has to hold the capability of the subject with the right of
delegation. The rights that the target receives have to be non-empty, they
have to apply to the kind, and they have to be a subset of the rights that
the caller holds. The right of delegation is **not** part of what the target
receives, unless the caller asks for it explicitly.

The rights of this version are:

| Right | Value | Meaning | Kind |
|---|---|---|---|
| `send` | 1 | The right to put a message in the subject | channel |
| `receive` | 2 | The right to take a message of the subject | channel |
| `delegate` | 4 | The right to give the capability to another process | channel, process, display, input |
| `write` | 8 | The right to write in the address space of the subject, or to present pixels to the display | process, display |
| `read` | 16 | The right to take one event from the input queue | input |

A right that belongs to another kind is refused with the error 12,
`invalid_rights`, and so is an empty set of rights: a capability that
authorizes nothing is not a capability.

The call answers with the error 6 when the channel does not exist, with the
error 8 when the process does not exist, with the error 22 when the display
does not exist, with the error 25 when the input queue does not exist, and
with the error 10 when the caller does not hold the capability, when the
rights are wider than the rights of the caller, or when the target process
does not exist.

#### 5.5.2 `revoke`

Takes a capability back from another process. The arguments are the
identifier of the target process, the kind of the capability and the
identifier of the subject.

The caller has to hold the capability of the subject with the right of
delegation: the owner of the capability takes it back from the process it
gave it to.

The call answers with the error 6 when the channel does not exist, with the
error 8 when the process does not exist, with the error 22 when the display
does not exist, with the error 25 when the input queue does not exist, and
with the error 10 when the caller does not hold the capability with the
right of delegation.

### 5.6 `receive_timeout`

Takes a message of a channel, waiting **at most** the given number of
ticks. The arguments are the identifier of the channel, the side that
holds the message and the timeout, in ticks of the timer. The result is
the kind of the message, and the value of the message comes back in the
`RDX`.

The call is the blocking receive with a deadline:

| | `receive_blocking` | `receive_timeout` |
|---|---|---|
| the queue has a message | the message is taken | the message is taken |
| the queue is empty | the task **waits** | the task waits until the deadline |
| the deadline passes | it does not exist | the call answers with the error 13 |
| timeout zero | the task waits forever | the task waits forever |

When the queue already has a message, the call answers at once and the
timeout has no effect. When the queue is empty, the task is marked as
blocked and the scheduler chooses another one, exactly as in the blocking
receive.

When the deadline passes before the message arrives, the kernel removes
the wait from the queue and wakes the task with the error 13, `timeout`.
The message that arrives later **stays in the queue**, for the next call:
the expiry of the wait takes the waiter, and not the message.

The timeout is counted in the ticks of the timer that the scheduler
already counts. The deadline is `now + timeout`, and the kernel expires
the waits **before** it chooses the next task, so a task whose deadline
arrives is ready in the same tick. The granularity of the timeout is
therefore one tick. A timeout of zero means that the deadline does not
exist, and the call is the same as `receive_blocking`.

The call returns the error 9 when there is no other task to run: a wait
that would be the only task of the system is a busy loop, and not a wait.
The check of the impossible wait happens before the deadline of the
timeout is considered, and the error 9 is what the call answers.

The call needs the capability of the channel, with the right of receiving,
in the same way as the calls 6 and 8.

### 5.7 The file system calls

The calls 13 to 18 expose the RamFS to the user mode. The path is a block
of the user, **not** null terminated: the length is an argument, and the
kernel checks the range in the page tables before reading it. The path is
limited to 255 bytes.

| Flag | Value | Meaning |
|------|-------|---------|
| `O_RDONLY` | `0o0` | read only |
| `O_WRONLY` | `0o1` | write only |
| `O_RDWR` | `0o2` | read and write |
| `O_CREAT` | `0o100` | create the file when it does not exist |
| `O_TRUNC` | `0o1000` | truncate the file on open |
| `O_APPEND` | `0o2000` | start the descriptor at the end of the file |

`fs_open` returns a descriptor in the range `0..15`. The table is **per
process**, as decided in ADR-0014: two processes that open the same path
have independent descriptors and offsets. The limit is 16 open files per
process.

`fs_close` releases the descriptor. A descriptor that is not open is
refused with the error 16, `bad_descriptor`.

`fs_read` and `fs_write` copy at most 64 KiB per call, and the kernel
checks the buffer in the page tables: a read needs a writable range of the
user, and a write needs a readable range. The descriptor advances by the
number of bytes processed.

`fs_create` creates a regular file and returns a descriptor open for
reading and writing. `fs_mkdir` creates a directory and returns zero. The
calls do not create the parent directory: a path whose parent does not
exist is refused with the error 14, `no_such_file`.

This version does **not** have `seek`, `stat`, `unlink`, `rename`,
indirect blocks or persistence. The RamFS is still a kernel-side file
system with a small user-facing window.

### 5.8 `display_info`

Writes the display metadata into a structure of the user mode. The call is
**read-only**, and it exposes neither the physical base address nor the
size of the framebuffer mapping. The user mode never receives access to the
MMIO window; the presentation call 20 is the only path that writes pixels.

The structure is `DisplayInfo`, defined in `shared/display.zig` and in the
SDK as `sdk.display.DisplayInfo`:

| Offset | Size | Field | Meaning |
|-------:|-----:|-------|---------|
| 0 | 4 | `version` | `info_version`, currently 1 |
| 4 | 4 | `width` | visible width in pixels |
| 8 | 4 | `height` | visible height in pixels |
| 12 | 4 | `pitch` | bytes between the start of two rows |
| 16 | 4 | `bits_per_pixel` | bits per pixel |
| 20 | 4 | `pixel_format` | 0 RGB32, 1 BGR32, `0xFFFFFFFF` unknown |
| 24 | 4 | `red_mask` | red channel mask |
| 28 | 4 | `green_mask` | green channel mask |
| 32 | 4 | `blue_mask` | blue channel mask |
| 36 | 1 | `red_shift` | red channel shift |
| 37 | 1 | `green_shift` | green channel shift |
| 38 | 1 | `blue_shift` | blue channel shift |
| 39 | 1 | `reserved` | zero in version 1 |

The structure is 40 bytes and has alignment 4. The caller passes the
address of a writable range of the user mode and its length. A length
smaller than 40 is refused with the error 3, `invalid_length`; a larger
length is accepted, so a caller built against a future, larger version
still works with this kernel. The kernel writes exactly 40 bytes and
returns 40. The `version` field tells the caller which layout it received.

The call does not require a capability: the geometry of the display is
public information. The address of the framebuffer is not part of the
structure, and the call cannot be used to write a pixel. A boot without a
framebuffer answers with the error 22, `no_display`.

The decision about the user-space graphics service, including the display
capability and the presentation call, is in
[`ADR-0015`](../adr/ADR-0015-user-space-graphics-service.md).

### 5.9 `present`

Copies a rectangle of pixels from a buffer of the user mode into the
visible framebuffer. The call is the only path that writes pixels; the
user mode never receives a mapping of the framebuffer.

The caller has to hold the capability of the display: kind 2, subject 0,
with the right of writing (`write`, value 8). The check happens before the
request is read, so a process without the capability is refused with the
error 10, `not_authorized`, and cannot use the call to probe the
framebuffer.

The request is `PresentRequest`, defined in `shared/display.zig` and in
the SDK as `sdk.display.PresentRequest`:

| Offset | Size | Field | Meaning |
|-------:|-----:|-------|---------|
| 0 | 4 | `version` | `present_version`, currently 1 |
| 4 | 4 | `x` | left edge of the destination, in pixels |
| 8 | 4 | `y` | top edge of the destination, in pixels |
| 12 | 4 | `width` | width of the rectangle, in pixels |
| 16 | 4 | `height` | height of the rectangle, in pixels |
| 20 | 4 | `stride` | bytes between two rows of `buffer` |
| 24 | 4 | `pixel_format` | must match the display; 0 RGB32 or 1 BGR32 |
| 28 | 4 | `reserved` | zero in version 1 |
| 32 | 8 | `buffer` | address of the first byte of the pixel buffer |
| 40 | 8 | `length` | number of readable bytes in the pixel buffer |

The structure is 48 bytes and has alignment 8. The buffer belongs to the
caller and is only read. The source stride and the destination pitch may
differ: the kernel copies each row of `width * 4` bytes from the source
stride to the framebuffer pitch.

The kernel validates, in this order:

1. the caller is a process of the user mode;
2. the caller holds the display capability with the right of writing;
3. the request range is readable and has at least 48 bytes;
4. `version` is `present_version` and `reserved` is zero;
5. the rectangle is not empty and fits the visible display;
6. the display is 32 bpp, `pixel_format` matches it and is RGB32 or BGR32;
7. `stride` is at least `width * 4`, and `length` is at least
   `stride * height`, with explicit overflow checks;
8. `length` does not exceed 64 MiB;
9. the pixel buffer is a readable range of the user with `length` bytes;
10. the rectangle fits the mapped framebuffer.

Only after the ten checks does the kernel copy the rows. The call returns
zero on success. The copy is synchronous: when the call returns, the pixels
are in the device. There is no queue, no double buffering and no vsync in
version 12.

A boot without a display, or a framebuffer that does not cover the
rectangle, answers with the error 22, `no_display`. A version, stride or
length that the kernel cannot accept answers with the error 3,
`invalid_length`; a rectangle outside the display answers with the error
23, `invalid_geometry`; a format that the display or the call does not
support answers with the error 24, `invalid_format`; a buffer that is not a
readable range answers with the error 2, `invalid_address`.

### 5.10 `input_poll`

Takes one input event from the queue of the graphics service. The call is
**non-blocking**: it returns 1 when it wrote an event, 0 when the queue is
empty, or a negative error. An empty queue is not an error and does not
consume anything.

The caller has to hold the capability of the input: kind 3, subject 0, with
the right of reading (`read`, value 16). The check happens before the output
is touched, and the output range is validated before the queue is popped, so
a bad address does not lose an event. The event is `InputEvent`, defined in
`shared/input.zig` and in the SDK as `sdk.input.InputEvent`:

| Offset | Size | Field | Meaning |
|-------:|-----:|-------|---------|
| 0 | 4 | `version` | `input_version`, currently 1 |
| 4 | 4 | `kind` | `kind_key`, currently 1 |
| 8 | 4 | `code` | make code of PS/2 set 1 for a key event |
| 12 | 4 | `flags` | bit 0 pressed, bit 1 extended; the other bits are zero |

The structure is 16 bytes and has alignment 4. The caller passes the
address of a writable range of the user mode and its length. A length
smaller than 16 is refused with the error 3, `invalid_length`; a larger
length is accepted, so a caller built against a future, larger structure
still works with this kernel. The kernel writes exactly 16 bytes and
returns 1. A range that is not writable answers with the error 2,
`invalid_address`; a process without the capability answers with the error
10, `not_authorized`; a boot without an input queue answers with the error
25, `no_input`.

The queue is filled by the PS/2 interrupt. The kernel keeps a **separate**
diagnostic queue for its own keyboard handling: the user reader consumes
only the user queue, and the key that selects the kernel's interactive mode
still reaches the kernel. The separation is part of the design and not an
implementation detail; a future input service can replace the single queue
with per-process queues without changing the event structure.

The call does not wait, does not sleep and does not select a file
descriptor. It is the first part of the input service: there is no blocking
input wait, no pointer or mouse event, no focus and no per-process queue in
version 12. The full compositor and window manager remain proposed in
[`ADR-0015`](../adr/ADR-0015-user-space-graphics-service.md).

## 6. The result and the errors

The result of the call comes back in `RAX`. A **negative** result means
that the call **was not performed**, and the absolute value of the result is
the code of the error:

| Code | Error | Meaning |
|--------|------|-------------|
| 1 | unknown call | the number of the call does not exist in this version |
| 2 | invalid address | one of the ranges does not belong to the user mode |
| 3 | invalid length | the length, the stride or the version of the request is not acceptable |
| 4 | not allowed | the call is not allowed at the privilege level of the caller |
| 5 | empty queue | the side of the channel has no message |
| 6 | unknown channel | the identifier of the channel does not exist |
| 7 | full queue | the side of the channel does not accept more messages |
| 8 | unknown process | the identifier of the process does not exist |
| 9 | impossible wait | the task waited for a message and there was no other task to run |
| 10 | not authorized | the process does not hold the capability of the subject |
| 11 | unknown kind | the kind of the capability does not exist |
| 12 | invalid rights | the rights are empty, or they do not apply to the kind |
| 13 | timeout | the wait expired before the message arrived |
| 14 | no such file | the path does not name an existing file or directory |
| 15 | no space | the file system has no free block or no free inode |
| 16 | bad descriptor | the descriptor is not open, or it is out of range |
| 17 | too many open files | the table of open files has no free entry |
| 18 | name exists | a file or directory with the same name already exists |
| 19 | invalid name | the path or a component of it is not valid |
| 20 | file too large | the file exceeds the limit of the file system |
| 21 | I/O error | the file system refused the operation for another reason |
| 22 | no display | there is no usable display, or the framebuffer does not cover the rectangle |
| 23 | invalid geometry | the rectangle is empty or leaves the visible display |
| 24 | invalid format | the pixel format is not supported by the display or by the call |
| 25 | no input | the kernel has no input queue for the user mode |

The limit of the length is **64 KiB** per call for the calls that copy a
block, and it exists so that the kernel does not spend an undetermined time
inside a call. `display_info` is an exception: it writes at most 40 bytes
and accepts a larger length so that a future, larger structure still works
with this kernel. `present` has its own limit of **64 MiB** for the pixel
buffer, which bounds the copy. `input_poll` writes at most 16 bytes and
accepts a larger length, like `display_info`.

A result that is not negative is the number of bytes processed, unless the
call says otherwise, and it is never negative, so that the user program
tells the two cases apart without knowing the error codes. The calls whose
contract says that they return zero (`fs_close`, `fs_mkdir` and `present`)
return zero on success. `input_poll` is the other exception: it returns 1
when it wrote an event and 0 when the queue is empty; neither result is a
byte count.

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
10. A call that touches a channel needs the capability of the channel, and
    the check of the capability happens **before** the queue is touched.
11. A capability that a process receives does not carry the right of
    delegation unless the process that gives it asks for it explicitly.
12. A change to the arguments of an existing call is a break of the
    contract, and it increments the version, as a new call does.
13. A call that writes the display needs the capability of the display with
    the right of writing, and the check of the capability happens **before**
    the pixel buffer is touched.
14. A call that reads the input queue needs the capability of the input with
    the right of reading, and the check happens **before** the output is
    written and **before** an event is popped.

## 8. What version 12 does not have

- **The capability that carries a memory range.** A capability is about a
  subject of the kernel, and a range of memory is not one of them.
- **The rights of read and of execution over a process.** The capability
  of a process carries the right to write in its address space, and not the
  right to read it nor to execute its code.
- **The capability of a generic device.** The display and input
  capabilities exist, but there is no capability of a driver or of another
  device.
- **Surface sharing and a user-space compositor.** `present` writes a
  rectangle and `input_poll` delivers one key event, but there is no call
  that allocates or shares a surface, no window manager, no per-process
  input queue, no pointer and no focus. The design is in ADR-0015, and the
  compositor and the window manager are the next increment.
- **The console and the files in the same call.** The `write` call knows
  only the console, and the file system has the calls 13 to 18. The
  `write` call does not accept a descriptor.
- **Seek, stat, unlink and rename.** The version 12 opens, closes, reads,
  writes, creates and creates directories, and nothing else.
- **Descriptor passing.** A descriptor belongs to one process and cannot be
  passed to another; the channel carries a kind and a value, not a
  descriptor.
- **Persistence.** The RamFS lives in the memory of the kernel and
  disappears when the machine is turned off.
- **Message structure.** There is no message format defined, and the
  message of the channel carries a kind and a value.
- **Several processes per call.** The `copy_to` call knows the destination
  process by the identifier, and not by a file name nor by a path.
- **Several waits per task.** A task waits for one channel and one side,
  and not for a set of channels. The timeout of the call 11 bounds the
  wait of one channel, and it does not select among several ones.

## 9. The break of the version 4

The version 4 **breaks** the contract of the version 3 in one point, and
the break is deliberate.

The version 3 let every process use every channel of the VNX: the
identifier of the channel was enough to put a message in it, or to take one
of it, and nothing in the kernel said that the process had the right to do
so. The version 4 requires the capability of the channel, and the process
that does not hold it is refused with the error 10.

A program that was compiled against the version 3 and that used a channel
that nobody gave it **stops working**. A program that used a channel that
the kernel gave it keeps working, and it keeps working without a change,
because the calls 1 to 8 do not change their number nor their meaning.

The rule of the VVS-0001 asks for a bigger version of the contract for a
change of this kind, and the version 4 is that bigger version. The version
number is the only thing that changes for the programs that keep working.

## 10. The break of the version 5

The version 5 **breaks** the contract of the version 4 in the two calls
that give and take a capability, and the break is deliberate.

The version 4 named the subject of the capability in the second argument
and the rights in the third one, and the subject was always a channel. A
process could not delegate the capability of an address space, because the
call had no way to say that the subject was a process. The version 5 adds
the kind as the second argument, moves the subject to the third one, and
the rights of `grant` to the fourth one.

A program that was compiled against the version 4 and that calls 9 or 10
**stops working**: in `grant`, the kernel reads the channel as the kind and
the rights as the subject; in `revoke`, the channel is read as the kind and
the subject is whatever the third register held. The calls 1 to 8 do not
change their number nor their meaning, and a program that uses only them
keeps working.

The rule of the VVS-0001 asks for a bigger version of the contract for a
change of this kind, and the version 5 is that bigger version.

## 11. The version 6

The version 6 is **additive**. It adds the call 11, `receive_timeout`, and
the error 13, `timeout`, and it does not change the number nor the meaning
of any existing call. A program that was compiled against the version 5
keeps working without a change.

The call is the blocking receive with a deadline, and it exists because a
service that waits for a client that died would otherwise wait forever.
The decision, with the alternatives that were discarded, is in the
[`ADR-0010`](../adr/ADR-0010-wait-timeout.md).

## 12. The version 9

The version 9 is **additive**. It adds the calls 13 to 18 and the errors 14
to 21, and it does not change the number nor the meaning of any existing
call. The version 7 and the version 8 were not published as stable
contracts; the document records the jump so that a number is never reused.

The file system calls are the first user-facing interface of the RamFS. The
kernel checks the path and the buffer in the page tables, translates the
errors of the file system into the codes of the contract, and keeps the
file system state in the kernel. The call 12 remains reserved and is
refused with the error 1.

The decision about the separation between the load planner and the
materialization of an ELF64 image is in
[`ADR-0011`](../adr/ADR-0011-elf64-load-plan.md). The RamFS layout and its
limits are documented in the increment report and in the roadmap.

## 13. The version 10

The version 10 is **additive**. It adds the call 19, `display_info`, and the
error 22, `no_display`, and it does not change the number nor the meaning of
any existing call. A program compiled against the version 9 keeps working
without a change.

The call is the first user-facing part of the graphics service. It returns
the visible geometry and the pixel layout, but not the framebuffer base or
mapping size. The user mode therefore learns how large the display is
without receiving a way to write it. The decision, including the display
capability and the presentation call, is in
[`ADR-0015`](../adr/ADR-0015-user-space-graphics-service.md).

## 14. The version 11

The version 11 is **additive**. It adds the call 20, `present`, the
capability of the display (kind 2, subject 0) and the errors 23,
`invalid_geometry`, and 24, `invalid_format`. It does not change the number
nor the meaning of any existing call. A program compiled against the
version 10 keeps working without a change.

The call copies a rectangle of pixels from a buffer of the user mode into
the visible framebuffer. The framebuffer base and the mapping size remain
private to the kernel; the capability carries the right to present, not the
right to touch the device. The copy is synchronous, and the request is
validated before any pixel is written. The contract has no double
buffering, no vsync, no surface allocation and no input event yet.

The design of the user-space graphics service is in
[`ADR-0015`](../adr/ADR-0015-user-space-graphics-service.md). At the time
of version 11, the compositor and the input events remained proposed; the
display metadata and the presentation were the implemented part. Version
12 adds the first input event call.

## 15. The version 12

The version 12 is **additive**. It adds the call 21, `input_poll`, the
capability of the input (kind 3, subject 0, right `read` value 16) and the
error 25, `no_input`. It does not change the number nor the meaning of any
existing call. A program compiled against the version 11 keeps working
without a change.

The call takes one event from the user input queue, which the PS/2 interrupt
fills. The kernel keeps its diagnostic keyboard queue separate, so the user
reader cannot steal the key that selects the interactive mode. The call is
non-blocking and returns 1 when it wrote an event and 0 when the queue is
empty; the output is validated before an event is popped.

The version has no blocking input wait, no per-process input queue, no
pointer or mouse event, no focus and no window manager. The full compositor
and window manager remain proposed in
[`ADR-0015`](../adr/ADR-0015-user-space-graphics-service.md).
