// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 VorynOS contributors

//! Voryn Nucleus Kernel (VNK).
//!
//! The kernel owns the processor structures of the machine: the segment
//! table, the interrupt table, the page tables and the memory managers. The
//! sequence of the initialisation is:
//!
//!   1. validation of the boot handoff contract;
//!   2. a copy of the handoff in the memory of the kernel, so that the
//!      information survives the replacement of the page tables;
//!   3. the segment table and the task state segment;
//!   4. the interrupt table;
//!   5. the physical memory manager;
//!   6. the page tables of the kernel, which replace the ones of the
//!      firmware;
//!   7. the heap of the kernel;
//!   8. the timer and the interrupt controllers.

const std = @import("std");
const voryn = @import("voryn_shared");

const handoff = voryn.handoff;
const memmap = voryn.memmap;
const port = voryn.port;
const serial = voryn.serial;
const usermode = voryn.usermode;

const cpu = @import("arch/x86_64/cpu.zig");
const interrupt = @import("arch/x86_64/interrupt.zig");
const paging = @import("arch/x86_64/paging.zig");
const segment = @import("arch/x86_64/segment.zig");
const syscall = @import("arch/x86_64/syscall.zig");
const timer = @import("arch/x86_64/timer.zig");

const heap = @import("memory/heap.zig");
const physical = @import("memory/physical.zig");
const scheduler = @import("task/scheduler.zig");

/// Version of the kernel, reported on the console.
const kernel_version = "0.1.0-dev.1";

/// The handler of a panic of the kernel.
///
/// The default handler of the standard library writes to the error stream of
/// the host, which does not exist in the kernel. The handler of the kernel
/// writes to the serial port and stops the machine.
pub const panic = std.debug.FullPanic(kernelPanic);

/// Reports a panic of the kernel.
fn kernelPanic(message: []const u8, return_address: ?usize) noreturn {
    serial.printLine("[VNK] PANIC: {s}", .{message});
    if (return_address) |address| {
        serial.printLine("[VNK] PANIC: at 0x{x}", .{address});
    }
    port.haltForever();
}

/// Number of memory descriptors that the kernel keeps a copy of.
const max_memory_descriptors = 1024;

/// Size of the region that the heap of the kernel manages.
const heap_size = 256 * 1024;

/// Frequency of the timer, in interrupts per second.
const timer_frequency = 100;

/// Size of the stack of a task of the kernel.
const task_stack_size = 16 * 1024;

/// Number of tasks of the kernel: the main task and two workers.
const task_count = 3;

/// The stacks of the tasks of the kernel.
///
/// The stacks live in the image of the kernel because the region has to
/// stay mapped after the replacement of the page tables.
var task_stacks: [task_count][task_stack_size]u8 align(16) = undefined;

/// The stacks of the kernel of the tasks of the kernel.
///
/// Every task has two stacks: the one where its own code runs, and the one
/// of the kernel, which receives the frames of the interrupts and of the
/// calls. The two are never the same memory, because the frame of the
/// interrupt is built on the stack of the kernel, and the frame of a task
/// that runs in the user mode would otherwise live in a page that the user
/// owns.
var kernel_stacks: [task_count][task_stack_size]u8 align(16) = undefined;

/// The stack of the kernel of the task of the user mode.
///
/// The handlers of the calls and of the interrupts of the task run on it,
/// and not on the stack of the user, which the user could rewrite.
var user_task_stack: [task_stack_size]u8 align(16) = undefined;

/// The base of the window of the user mode.
///
/// The window has no fixed address. The image of the kernel is mapped by
/// identity, and a window inside the image would overwrite the code and the
/// data of the kernel with the pages of the user. The window is therefore
/// placed right below the image, and the address is handed to the task in
/// the first register when the task starts.
var user_window_base: u64 = 0;

/// The number of processes that the kernel creates.
const process_count = 2;

/// The address space of the process of the usuário mode.
var user_space: ?*paging.AddressSpace = null;

/// The address space of the segundo processo.
var second_space: ?*paging.AddressSpace = null;

/// The stack of the kernel do segundo processo.
var second_task_stack: [task_stack_size]u8 align(16) = undefined;

/// The virtual address of the program of the task that runs in user mode.
fn userCodeAddress() u64 {
    return user_window_base + usermode.code_offset;
}

/// The virtual address of the data of the task that runs in user mode.
fn userDataAddress() u64 {
    return user_window_base + usermode.data_offset;
}

/// The virtual address of the stack of the task that runs in user mode.
fn userStackAddress() u64 {
    return user_window_base + usermode.stack_offset;
}

/// The value that the program of the user mode writes in its page of data.
///
/// The value proves that the task ran in the third level of privilege with
/// access to its own pages.
const user_program_value: u64 = 0x5A5A_1234;

/// The address of the second word of the page of data of the user mode.
///
/// The program of the user mode writes there the result of the system call,
/// and the value proves that the call reached the handler of the kernel and
/// that the answer came back.
fn userResultAddress() u64 {
    return userDataAddress() + usermode.data_result;
}

/// The address of the third word of the page of data of the user mode.
///
/// The program of the user mode writes there the result of the call that
/// writes in the console.
fn userWriteAddress() u64 {
    return userDataAddress() + usermode.data_write;
}

/// The address of the fourth word of the page of data of the user mode.
///
/// The program of the user mode writes there the result of the call that
/// copies a block of memory.
fn userCopyAddress() u64 {
    return userDataAddress() + usermode.data_copy;
}

/// The address of the fifth word of the page of data of the user mode.
///
/// The kernel compares the content with the page of code, and the equality
/// proves that the copy happened.
fn userCopyContentAddress() u64 {
    return userDataAddress() + usermode.data_content;
}

/// The address of the seventh word of the page of data of the user mode.
///
/// The program of the user mode writes there the answer of a call with an
/// address that is not of the user, and the value proves that the kernel
/// refused the call.
fn userRefusedAddress() u64 {
    return userDataAddress() + usermode.data_refused;
}

/// The address of the eighth word of the page of data of the user mode.
///
/// The program of the user mode writes there the value of the answer of the
/// channel, e o valor prova que a mensagem do núcleo chegou ao usuário.
fn userAnswerAddress() u64 {
    return userDataAddress() + usermode.data_answer;
}

/// The address of the ninth word of the page of data of the user mode.
///
/// The program of the user mode writes there the answer of the call that
/// copies a block whose ranges overlap. The value proves that the kernel
/// copied the block, e que a tarefa do usuário mode não derrubou a máquina.
fn userOverlapAddress() u64 {
    return userDataAddress() + usermode.data_overlap_result;
}

/// The address of the tenth word of the page of data of the user mode.
///
/// The program of the user mode writes there the block that the copy with
/// the overlapping ranges takes as its origin. The value proves that the
/// copy did not destroy the origin.
fn userOverlapOriginAddress() u64 {
    return userDataAddress() + usermode.data_overlap_origin;
}

/// The address of the eleventh word of the page of data of the user mode.
///
/// The program of the user mode writes there the block that the copy with
/// the overlapping ranges writes in the destination. The value proves that
/// the copy moved the block in the right direction.
fn userOverlapDestinationAddress() u64 {
    return userDataAddress() + usermode.data_overlap_destination;
}

/// The block that the program of the user mode writes for the copy with
/// the overlapping ranges.
const user_overlap_pattern: u64 = usermode.overlap_pattern;

/// The address of the twelfth word of the page of data of the user mode.
///
/// The program of the user mode writes there the result of the copy to the
/// other process.
fn userCopyResultAddress() u64 {
    return userDataAddress() + usermode.data_copy_result;
}

/// The address of the thirteenth word of the page of data of the user mode.
///
/// The copy to the other process writes there the block that it copied.
fn userCopyTargetAddress() u64 {
    return userDataAddress() + usermode.data_copy_target;
}

/// The bytes of the block that the program of the user mode writes.
///
/// The block is compared byte by byte, because the destination of the copy
/// is four bytes above the origin.
const pattern_bytes: [8]u8 = @bitCast(user_overlap_pattern);


/// The value that the kernel answers to the message of the user mode.
///
/// The answer é o valor da mensagem com os bytes invertidos, e o núcleo
/// confere o valor na página de dados do usuário.
const user_answer_value: u64 = 0x5A5A_1234 ^ 0xFFFF_FFFF_FFFF_FFFF;

/// The number of bytes that the program of the user mode writes.
const user_write_length: u64 = 8;

/// The number of bytes that the program of the user mode copies.
const user_copy_length: u64 = 8;

/// The result that the kernel answers to the call of the probe.
const user_result_value: u64 = syscall.ping_result;

/// Whether the task of the user mode is scheduled.
///
/// The task exists and its pages are mapped, and the call of the user mode
/// goes through the instruction `syscall`, which is the path that the
/// architecture provides for the mode of 64 bits. The switch is verified by
/// the automated boot test.
const enable_user_task = true;

/// The program of the task that runs in user mode, and its end.
///
/// The symbols are declared as variables because the address of the program
/// is what the kernel needs, and the address of a constant of the standard
/// library would be the address of a copy.
extern var voryn_user_program: u8;
extern var voryn_user_program_end: u8;

/// Address of the kernel entry point, provided by the assembly trampoline.
extern const voryn_kernel_entry_address: u64;

/// Top of the boot stack of the kernel, provided by the assembly trampoline.
extern const voryn_boot_stack_end: u8;

/// A copy of the handoff structure in the memory of the kernel.
var boot_info: handoff.BootHandoff = .{};

/// A copy of the memory map in the memory of the kernel.
var memory_map: [max_memory_descriptors]handoff.MemoryDescriptor = undefined;

/// The region of memory that the heap of the kernel manages.
var heap_region: [heap_size]u8 align(4096) = undefined;

/// Kernel entry point, called by the assembly trampoline.
///
/// `boot` points to the handoff structure that the loader filled in.
export fn voryn_kmain(boot: *const handoff.BootHandoff) callconv(.c) noreturn {
    serial.init();

    serial.printLine("[VNK] Voryn Nucleus Kernel {s}", .{kernel_version});

    handoff.validate(boot) catch |err| {
        serial.printLine("[VNK] FATAL: invalid handoff: {s}", .{@errorName(err)});
        port.haltForever();
    };

    serial.printLine("[VNK] handoff ok: version={d} flags=0x{x}", .{
        boot.version,
        boot.flags,
    });

    // The entry point the loader used has to match the one of this image,
    // otherwise the kernel is not running where the contract says it is.
    if (voryn_kernel_entry_address != boot.kernel_entry) {
        serial.printLine("[VNK] FATAL: entry mismatch: image=0x{x} handoff=0x{x}", .{
            voryn_kernel_entry_address,
            boot.kernel_entry,
        });
        port.haltForever();
    }

    serial.printLine("[VNK] kernel: base=0x{x} end=0x{x} entry=0x{x}", .{
        boot.kernel_base,
        boot.kernel_end,
        boot.kernel_entry,
    });

    // The firmware leaves the coprocessor disabled, the kernel needs it.
    cpu.enableFloatingPoint();

    reportProcessor();

    // The information of the firmware is copied into the memory of the
    // kernel, because the page tables of the firmware are replaced later and
    // the structures that they describe are not mapped anymore.
    copyBootInformation(boot);

    reportMemory();
    reportFramebuffer(boot);

    installSegments();
    installInterrupts();
    installTaskState();

    installMemoryManager();
    buildPageTables(boot);
    activatePageTables();
    installHeap();
    // The task of the user mode is prepared after the tables are active:
    // the program is copied through them, and the tables of the firmware
    // would place the copy in another physical page.
    installUserTask();
    // The system call of the user mode does not go through the interrupt
    // table: the instruction `syscall` reads the entry point and the
    // segments from the registers of model.
    installSystemCall();

    // The channels of the VNX.
    //
    // The channels have to exist before the timer starts the tasks: the
    // timer enables the interrupts, and the task of the user mode sends a
    // message in its first turn. An initialization after the timer would
    // wipe the message that the task had already sent.
    syscall.initChannels();

    installScheduler();
    installTimer();

    // The main task waits until the workers have been scheduled a few
    // times, which proves that the scheduler works.
    while (scheduler.scheduler.statisticsOf().switches < 20) {
        cpu.halt();
    }
    reportScheduler();
    reportUserTask();

    // Sentinel consumed by the automated boot test.
    serial.printLine("VORYN-KERNEL-READY", .{});

    // The self test of the system call runs first, from the kernel itself:
    // it separates a broken gate from a broken transition of privilege.
    syscallSelfTest();

    // The self test of the exception handling runs at the very end, because
    // an exception stops the kernel.
    selfTest();

    port.haltForever();
}

/// Copies the handoff and the memory map into the memory of the kernel.
fn copyBootInformation(boot: *const handoff.BootHandoff) void {
    boot_info = boot.*;

    const count = @min(boot.memory_map_entries, max_memory_descriptors);
    if (count == 0) return;
    if (boot.memory_map_address >= handoff.identity_mapped_limit) return;

    const source = @as([*]const handoff.MemoryDescriptor, @ptrFromInt(boot.memory_map_address))[0..count];
    @memcpy(memory_map[0..count], source);
}

/// Reports the processor the kernel is running on.
fn reportProcessor() void {
    const info = cpu.detectProcessor();

    var brand: [48]u8 = @splat(0);
    var length: usize = 0;
    while (length < brand.len and info.brand[length] != 0) : (length += 1) {}
    brand[length] = 0;

    serial.printLine("[VNK] cpu: family={d} model={d} stepping={d} cores={d} phys_bits={d} virt_bits={d}", .{
        info.family,
        info.model,
        info.stepping,
        info.logical_processors,
        info.physical_address_bits,
        info.linear_address_bits,
    });

    if (length > 0) {
        serial.printLine("[VNK] cpu: brand=\"{s}\"", .{std.mem.sliceTo(&brand, 0)});
    }
}

/// Reports the memory map that the firmware handed over.
fn reportMemory() void {
    const count = @min(boot_info.memory_map_entries, max_memory_descriptors);
    if (count == 0) {
        serial.printLine("[VNK] memory: no map provided", .{});
        return;
    }

    const map = memory_map[0..count];
    const summary = memmap.summarize(map);

    serial.printLine("[VNK] memory: {d} regions, {d} MiB RAM", .{
        summary.entries,
        summary.total_ram / (1024 * 1024),
    });

    // The largest region that is not ordinary RAM is usually the hole of
    // the address space reserved for the PCI bus, it is reported so that a
    // reader does not mistake it for usable memory.
    var largest: ?handoff.MemoryDescriptor = null;
    for (map) |descriptor| {
        if (descriptor.isUsableRam()) continue;
        if (largest == null or descriptor.byteSize() > largest.?.byteSize()) {
            largest = descriptor;
        }
    }
    if (largest) |descriptor| {
        serial.printLine("[VNK] memory: largest reserved region is {s}, {d} MiB at 0x{x}", .{
            descriptor.memory_type.name(),
            descriptor.byteSize() / (1024 * 1024),
            descriptor.physical_start,
        });
    }

    // The kernel image itself has to be covered by ordinary RAM.
    if (!memmap.isUsableRange(map, boot_info.kernel_base, boot_info.kernel_end - boot_info.kernel_base)) {
        serial.printLine("[VNK] FATAL: kernel image is not backed by RAM", .{});
        port.haltForever();
    }
}

/// Reports the framebuffer.
fn reportFramebuffer(boot: *const handoff.BootHandoff) void {
    if (boot.flags & handoff.flag_framebuffer == 0) {
        serial.printLine("[VNK] framebuffer: none", .{});
        return;
    }

    const framebuffer = boot.framebuffer;
    serial.printLine("[VNK] framebuffer: {d}x{d} bpp={d} pitch={d} base=0x{x}", .{
        framebuffer.width,
        framebuffer.height,
        framebuffer.bits_per_pixel,
        framebuffer.pitch,
        framebuffer.base,
    });
}

/// Installs the segment table and the task state segment of the kernel.
fn installSegments() void {
    const stack_top = @intFromPtr(&voryn_boot_stack_end);

    segment.install(stack_top);

    if (!segment.verify()) {
        serial.printLine("[VNK] FATAL: the segment table was not installed", .{});
        port.haltForever();
    }

    serial.printLine("[VNK] segments: gdt installed and verified", .{});
}

/// Installs the interrupt descriptor table of the kernel.
fn installInterrupts() void {
    interrupt.install();

    if (!interrupt.verify()) {
        serial.printLine("[VNK] FATAL: the interrupt table was not installed", .{});
        port.haltForever();
    }

    serial.printLine("[VNK] interrupts: idt installed and verified", .{});
}

/// Loads the task state segment of the kernel.
fn installTaskState() void {
    segment.loadTaskState();
    serial.printLine("[VNK] segments: task state segment loaded", .{});
}

/// Prepares the physical memory manager.
fn installMemoryManager() void {
    const count = @min(boot_info.memory_map_entries, max_memory_descriptors);
    physical.manager.init(memory_map[0..count]);

    // The memory that the kernel occupies is not available to the manager.
    physical.manager.reserve(boot_info.kernel_base, boot_info.kernel_end - boot_info.kernel_base);
    physical.manager.reserve(@intFromPtr(&memory_map), @sizeOf(@TypeOf(memory_map)));
    physical.manager.reserve(@intFromPtr(&heap_region), heap_region.len);
    physical.manager.reserve(@intFromPtr(&physical.manager.bitmap), physical.manager.bitmap.len);

    const statistics = physical.manager.statistics;
    serial.printLine("[VNK] memory: {d} pages, {d} used, {d} free", .{
        statistics.total_pages,
        statistics.used_pages,
        statistics.free_pages,
    });
}

/// Builds the page tables of the kernel.
///
/// The tables are not active yet, so that the pages of the tasks that run in
/// user mode can be mapped and prepared before the switch.
fn buildPageTables(boot: *const handoff.BootHandoff) void {
    paging.setup(
        boot_info.kernel_base,
        boot_info.kernel_end,
        boot.framebuffer.base,
        boot.framebuffer.size,
    ) catch |err| {
        serial.printLine("[VNK] FATAL: the page tables could not be built: {s}", .{@errorName(err)});
        port.haltForever();
    };
}

/// Makes the page tables of the kernel the active ones.
fn activatePageTables() void {
    const previous = cpu.readCr3();
    paging.activate();

    serial.printLine("[VNK] paging: cr3 0x{x} -> 0x{x}", .{ previous, paging.rootAddress() });

    // The framebuffer is written after the new tables are active, which
    // proves that the mapping of the device memory works.
    probeFramebuffer();
}

/// Writes a value into the first pixel of the framebuffer and reads it back.
///
/// The probe only runs when the framebuffer is mapped by the tables of the
/// kernel, which proves that the device memory is reachable.
fn probeFramebuffer() void {
    const framebuffer = boot_info.framebuffer;
    if (framebuffer.base == 0 or framebuffer.size < 4) return;
    if (framebuffer.base >= handoff.identity_mapped_limit) return;

    const pixel: *volatile u32 = @ptrFromInt(framebuffer.base);
    const original = pixel.*;
    pixel.* = 0x00C0_FFEE;
    const readback = pixel.*;
    pixel.* = original;

    if (readback == 0x00C0_FFEE) {
        serial.printLine("[VNK] framebuffer: write probe succeeded", .{});
    } else {
        serial.printLine("[VNK] framebuffer: write probe failed (readback=0x{x})", .{readback});
    }
}

/// Prepares the heap of the kernel and verifies that it works.
fn installHeap() void {
    heap.heap.init(&heap_region);

    // The heap is exercised with a few blocks, which proves that the
    // allocator and its bookkeeping work.
    const block_size = 64;
    var blocks: [4][*]u8 = undefined;
    for (&blocks) |*block| {
        const memory = heap.heap.alloc(block_size) orelse {
            serial.printLine("[VNK] FATAL: the heap is exhausted", .{});
            port.haltForever();
        };
        @memset(memory[0..block_size], 0xA5);
        block.* = memory;
    }
    for (blocks) |block| {
        heap.heap.free(block);
    }

    const statistics = heap.heap.statistics();
    serial.printLine("[VNK] heap: {d} KiB region, {d} allocations, {d} bytes used", .{
        statistics.total_bytes / 1024,
        statistics.allocations,
        statistics.used_bytes,
    });
}

/// Prepares the timer and enables the interrupts.
fn installTimer() void {
    timer.init(timer_frequency);
    timer.enableInterrupts();

    // The kernel waits for a few ticks, which proves that the timer and the
    // interrupt controllers work.
    const start = timer.ticks();
    var attempts: u64 = 0;
    while (timer.ticks() - start < 5 and attempts < 100_000_000) : (attempts += 1) {
        cpu.halt();
    }

    serial.printLine("[VNK] timer: {d} Hz, {d} ticks", .{ timer.ticksPerSecond(), timer.ticks() });
}

/// Creates the task that runs in the third level of privilege.
///
/// The task has a program, a page of data and a stack of its own, all in
/// pages that the kernel maps with the bit that allows the access from the
/// user mode. The pages of the kernel are not accessible from there.
///
/// The task is a process: it has an address space of its own, and the
/// window of the user mode lives in that space and in no other. The page of
/// the program is therefore not mapped in the space of the kernel, and the
/// kernel activates the space of the process to copy the program into it.
fn installUserTask() void {
    for (0..process_count) |role| {
        const space = installProcess(role) orelse {
            serial.printLine("[VNK] FATAL: the process {d} could not be created", .{role});
            port.haltForever();
        };

        if (role == 0) {
            user_space = space;
        } else {
            second_space = space;
        }
    }
}

/// Creates a process and returns its address space.
///
/// The process has an address space of its own, a program, a page of data
/// and a stack. The pages of the user mode live in the space of the process
/// and in no other, and two processes that use the same virtual addresses
/// therefore never see the same pages.
///
/// The role of the process tells the program what it has to do: the process
/// of role zero starts the conversation on the channel, and the process of
/// role one answers it.
fn installProcess(role: u64) ?*paging.AddressSpace {
    _ = role;
    // The window of the user mode is placed right below the image of the
    // kernel. The image is mapped by identity, and a window inside the
    // image would replace the pages of the kernel with the pages of the
    // user.
    const window = boot_info.kernel_base - usermode.window_size;
    if (window < handoff.page_size) {
        serial.printLine("[VNK] FATAL: there is no room for the window of the user mode", .{});
        port.haltForever();
    }
    user_window_base = window;

    const space = paging.createAddressSpace(window) orelse return null;

    const code_page = physical.manager.allocate() orelse return null;
    const data_page = physical.manager.allocate() orelse return null;
    const user_stack_low = physical.manager.allocate() orelse return null;
    const user_stack_high = physical.manager.allocate() orelse return null;
    // The pages of the user mode. The pages are mapped before the program is
    // copied, because the tables are already the active ones.
    paging.mapUserPageIn(space, userCodeAddress(), code_page) catch |err| {
        serial.printLine("[VNK] FATAL: the page of the program could not be mapped: {s}", .{@errorName(err)});
        port.haltForever();
    };
    paging.mapUserPageIn(space, userDataAddress(), data_page) catch |err| {
        serial.printLine("[VNK] FATAL: the page of data could not be mapped: {s}", .{@errorName(err)});
        port.haltForever();
    };
    paging.mapUserPageIn(space, userStackAddress(), user_stack_low) catch |err| {
        serial.printLine("[VNK] FATAL: the stack could not be mapped: {s}", .{@errorName(err)});
        port.haltForever();
    };
    paging.mapUserPageIn(space, userStackAddress() + handoff.page_size, user_stack_high) catch |err| {
        serial.printLine("[VNK] FATAL: the stack could not be mapped: {s}", .{@errorName(err)});
        port.haltForever();
    };

    // The program is copied into the page that the user mode sees, and the
    // copy runs with the space of the process active, because the page of
    // the program is not mapped in the space of the kernel.
    const program_start = @intFromPtr(&voryn_user_program);
    const program_end = @intFromPtr(&voryn_user_program_end);
    const program_length = program_end - program_start;

    const saved_cr3 = cpu.readCr3();
    paging.activateSpace(space);
    const destination: [*]u8 = @ptrFromInt(userCodeAddress());
    @memcpy(destination[0..program_length], @as([*]const u8, @ptrFromInt(program_start))[0..program_length]);
    cpu.writeCr3(saved_cr3);
    paging.setActiveSpace(null);

    serial.printLine("[VNK] user: process {d}, program at 0x{x}, data at 0x{x}, stack at 0x{x}", .{
        space.id,
        userCodeAddress(),
        userDataAddress(),
        userStackAddress(),
    });

    return space;
}

/// Reports that the kernel does not have enough memory.
fn reportOutOfMemory() noreturn {
    serial.printLine("[VNK] FATAL: out of memory", .{});
    port.haltForever();
}

/// Programs the registers of model of the system call.
///
/// The call of the user mode goes through the instruction `syscall`, and the
/// instruction only works when the registers of model hold the right values.
fn installSystemCall() void {
    syscall.install();

    if (!syscall.verify()) {
        serial.printLine("[VNK] FATAL: the registers of the system call were not installed", .{});
        port.haltForever();
    }

    serial.printLine("[VNK] syscall: instruction installed and verified, star=0x{x}", .{syscall.readStar()});
}

/// Creates the tasks of the kernel.
fn installScheduler() void {
    scheduler.scheduler.init(@intFromPtr(&voryn_boot_stack_end), &kernel_stacks[0]);

    _ = scheduler.scheduler.spawn(&workerOne, &task_stacks[1], &kernel_stacks[1]);
    _ = scheduler.scheduler.spawn(&workerTwo, &task_stacks[2], &kernel_stacks[2]);

    // The tasks of the user mode have a stack of their own for the user and
    // another for the kernel, where the handlers run. Each process runs in
    // the address space of its own.
    if (enable_user_task) {
        const user_task = scheduler.scheduler.spawnUser(
            userCodeAddress(),
            userStackAddress(),
            usermode.stack_pages * handoff.page_size,
            &user_task_stack,
            user_window_base,
            user_space,
            0,
        ) orelse return reportOutOfMemory();
        serial.printLine("[VNK] user: task {d} cs=0x{x} ss=0x{x} rip=0x{x} rsp=0x{x}", .{
            user_task.id,
            user_task.context.cs,
            user_task.context.ss,
            user_task.context.rip,
            user_task.context.rsp,
        });

        const second_task = scheduler.scheduler.spawnUser(
            userCodeAddress(),
            userStackAddress(),
            usermode.stack_pages * handoff.page_size,
            &second_task_stack,
            user_window_base,
            second_space,
            1,
        ) orelse return reportOutOfMemory();
        serial.printLine("[VNK] user: task {d} cs=0x{x} ss=0x{x} rip=0x{x} rsp=0x{x}", .{
            second_task.id,
            second_task.context.cs,
            second_task.context.ss,
            second_task.context.rip,
            second_task.context.rsp,
        });
    }

    serial.printLine("[VNK] tasks: {d} created", .{scheduler.scheduler.count});
}

/// Waits for the task of the user mode and reports what it wrote.
///
/// The two values of the page of data of the user mode prove two different
/// things. The first one proves that the task ran in the third level of
/// privilege with access to its own pages, and the second one proves that
/// the call reached the handler of the kernel and that the answer came
/// back to the user mode.
fn reportUserTask() void {
    const space = user_space orelse return;

    // The pages of the user mode live in the space of the process and in no
    // other, therefore every read of them runs with the space of the
    // process active.
    const marker = userWord(space, userDataAddress());
    const result = userWord(space, userResultAddress());
    const written = userWord(space, userWriteAddress());
    const copied = userWord(space, userCopyAddress());
    const content = userWord(space, userCopyContentAddress());
    const code = userWord(space, userCodeAddress());

    // The task of the user mode is scheduled by the timer, therefore the
    // kernel waits for it instead of assuming that it already ran.
    var attempts: u64 = 0;
    while (result != user_result_value and attempts < 10_000_000) : (attempts += 1) {
        cpu.halt();
    }

    if (marker != user_program_value) {
        serial.printLine("[VNK] user: the page of the user mode holds 0x{x}, expected 0x{x}", .{
            marker,
            user_program_value,
        });
    } else {
        serial.printLine("[VNK] user: the program of the user mode wrote 0x{x} in its page", .{marker});
    }

    if (result != user_result_value) {
        serial.printLine("[VNK] user: the result of the call is 0x{x}, expected 0x{x}", .{
            result,
            user_result_value,
        });
    } else {
        serial.printLine("[VNK] user: the result of the call came back, 0x{x}", .{result});
    }

    // The write reads a buffer of the user after checking the range in the
    // page tables, and the answer is the number of bytes written.
    if (written != user_write_length) {
        serial.printLine("[VNK] user: the write wrote 0x{x} bytes, expected {d}", .{
            written,
            user_write_length,
        });
    } else {
        serial.printLine("[VNK] user: the write of the user mode wrote {d} bytes", .{written});
    }

    // A call with an address that is not of the user has to be refused,
    // and the answer is the negative value of the error.
    const refused = userWord(space, userRefusedAddress());
    if (refused != syscall.failure(syscall.Error.invalid_address)) {
        serial.printLine("[VNK] user: the refused call answered 0x{x}, expected 0x{x}", .{
            refused,
            syscall.failure(syscall.Error.invalid_address),
        });
    } else {
        serial.printLine("[VNK] user: the kernel refused the call of an address of the kernel", .{});
    }

    // O canal: o processo de papel zero manda uma mensagem, e o processo
    // de papel um a responde. O valor na página de dados do processo de
    // papel zero prova que a mensagem voltou pelo canal, e a latência que
    // o canal relata é o intervalo entre a mensagem sair e a mensagem
    // chegar, e não a espera do escalonador.
    var answer: u64 = 0;
    attempts = 0;
    while (attempts < 10_000_000) : (attempts += 1) {
        answer = userWord(space, userAnswerAddress());
        if (answer == user_answer_value) break;
        cpu.halt();
    }

    if (answer != user_answer_value) {
        serial.printLine("[VNK] channel: the answer of the user mode is 0x{x}, expected 0x{x}", .{
            answer,
            user_answer_value,
        });
    } else {
        serial.printLine("[VNK] channel: the answer of the other process came back, 0x{x}", .{answer});
    }

    const latency = syscall.channelLatency(0, syscall.Side.user);
    if (latency == 0) {
        serial.printLine("[VNK] channel: the latency of the delivery was not measured", .{});
    } else {
        serial.printLine("[VNK] channel: the message arrived in {d} cycles", .{latency});
    }

    // The copy moves a block of the page of code to the page of data, and
    // the content proves that the copy happened.
    if (copied != user_copy_length) {
        serial.printLine("[VNK] user: the copy copied 0x{x} bytes, expected {d}", .{
            copied,
            user_copy_length,
        });
    } else if (content != code) {
        serial.printLine("[VNK] user: the copy holds 0x{x}, expected 0x{x}", .{ content, code });
    } else {
        serial.printLine("[VNK] user: the copy of the user mode moved {d} bytes", .{copied});
    }

    // The second process: it has an address space of its own, and the
    // marker of its page of data carries its role. Two processes that write
    // different values in the same virtual address prove that the pages of
    // the two processes are not the same pages.
    const second = second_space orelse return;
    const second_marker = userWord(second, userDataAddress());
    if (second_marker != user_program_value + 1) {
        serial.printLine("[VNK] user: the page of the second process holds 0x{x}, expected 0x{x}", .{
            second_marker,
            user_program_value + 1,
        });
    } else {
        serial.printLine("[VNK] user: the second process wrote 0x{x} in its own page", .{second_marker});
    }

    // The copy between the dois processos: o processo de papel zero copiou
    // um bloco da sua página para a página do processo de papel um. A
    // página do processo de papel zero tem de continuar com o bloco
    // original, e a página do processo de papel um tem o bloco copiado.
    const copy_result = userWord(space, userCopyResultAddress());
    const target = userWord(second, userCopyTargetAddress());
    const origin_target = userWord(space, userCopyTargetAddress());
    if (copy_result != user_copy_length) {
        serial.printLine("[VNK] user: the copy to the other process copied 0x{x} bytes, expected {d}", .{
            copy_result,
            user_copy_length,
        });
    } else if (target != user_program_value) {
        serial.printLine("[VNK] user: the copy to the other process wrote 0x{x}, expected 0x{x}", .{
            target,
            user_program_value,
        });
    } else if (origin_target != 0) {
        serial.printLine("[VNK] user: the copy to the other process wrote 0x{x} in the space of the caller", .{
            origin_target,
        });
    } else {
        serial.printLine("[VNK] user: the copy between the two processes moved {d} bytes", .{copy_result});
    }

    // A copy whose ranges overlap has to be answered with the length of the
    // block. The answer proves that a task of the user mode cannot stop
    // the machine with two arguments. The content proves that the copy
    // happened in the right direction: the destination holds the whole
    // block, and the origin keeps its first half, because a copy whose
    // ranges overlap necessarily writes over the tail of the origin.
    //
    // The two blocks are compared byte by byte, because the destination is
    // four bytes above the origin and a word of eight bytes would not be
    // aligned there.
    const overlap = userWord(space, userOverlapAddress());
    const origin = userBytes(space, userOverlapOriginAddress());
    const destination = userBytes(space, userOverlapDestinationAddress());
    if (overlap != user_copy_length) {
        serial.printLine("[VNK] user: the copy that overlaps copied 0x{x} bytes, expected {d}", .{
            overlap,
            user_copy_length,
        });
    } else if (!std.mem.eql(u8, &destination, &pattern_bytes) or
        !std.mem.eql(u8, origin[0..4], pattern_bytes[0..4]))
    {
        serial.printLine("[VNK] user: the copy that overlaps moved {x} and {x}, expected {x}", .{
            origin,
            destination,
            pattern_bytes,
        });
    } else {
        serial.printLine("[VNK] user: the copy of the user mode with overlapping ranges moved {d} bytes", .{
            overlap,
        });
    }
}

/// Reads a word of the memory of a process.
///
/// The pages of the user mode live in the space of the process and in no
/// other, therefore the kernel activates the space of the process to read
/// them, and restores the space that was active afterwards.
fn userWord(space: *paging.AddressSpace, address: u64) u64 {
    const saved_cr3 = cpu.readCr3();
    const saved_space = paging.activeSpace();

    paging.activateSpace(space);
    const value = @as(*volatile u64, @ptrFromInt(address)).*;

    cpu.writeCr3(saved_cr3);
    paging.setActiveSpace(saved_space);

    return value;
}

/// Reads eight bytes of the memory of a process.
fn userBytes(space: *paging.AddressSpace, address: u64) [8]u8 {
    const saved_cr3 = cpu.readCr3();
    const saved_space = paging.activeSpace();

    var bytes: [8]u8 = undefined;
    paging.activateSpace(space);
    const source: [*]const u8 = @ptrFromInt(address);
    @memcpy(&bytes, source[0..8]);

    cpu.writeCr3(saved_cr3);
    paging.setActiveSpace(saved_space);

    return bytes;
}

/// Reads eight bytes of the page of data of the user mode.
fn readUserBytes(address: u64) [8]u8 {
    var bytes: [8]u8 = undefined;
    const source: [*]const u8 = @ptrFromInt(address);
    @memcpy(&bytes, source[0..8]);
    return bytes;
}

/// Reports the state of the scheduler and the cost of the switches.
fn reportScheduler() void {
    const statistics = scheduler.scheduler.statisticsOf();

    const average = if (statistics.switches != 0)
        statistics.switch_cycles / statistics.switches
    else
        0;

    serial.printLine("[VNK] tasks: {d} ready, {d} ticks, {d} switches", .{
        statistics.ready,
        statistics.ticks,
        statistics.switches,
    });
    serial.printLine("[VNK] tasks: switch cost {d} cycles average, {d} minimum, {d} last", .{
        average,
        statistics.minimum_switch_cycles,
        statistics.last_switch_cycles,
    });
}

/// A worker of the kernel, it runs until the machine stops.
fn workerOne() void {
    worker(1);
}

/// A worker of the kernel, it runs until the machine stops.
fn workerTwo() void {
    worker(2);
}

/// The body of a worker.
///
/// The task reports its progress from time to time, so that the serial
/// console shows that the tasks alternate.
fn worker(id: u32) void {
    var turns: u64 = 0;
    while (true) {
        turns += 1;
        if (turns % 10 == 0) {
            serial.printLine("[VNK] task {d}: {d} turns", .{ id, turns });
        }
        cpu.halt();
    }
}

/// Invokes the handler of the system call from the kernel, to verify it.
///
/// The test separates a broken handler from a broken transition of
/// privilege. The instruction `syscall` is the way from the user mode to
/// the kernel, and the kernel does not use it for its own calls: the
/// processor loads the segments of the kernel before the entry point runs,
/// therefore the entry point cannot tell the privilege level of the caller
/// and the way back is always the interrupt return.
fn syscallSelfTest() void {
    serial.printLine("[VNK] self test: invoking the handler of the system call", .{});

    var frame = syscall.SyscallFrame{
        .rax = syscall.Number.ping,
        .rdi = 0xF00D,
        .r11 = 0x202,
    };

    syscall.voryn_syscall_handler(&frame, syscall.Privilege.kernel);

    if (frame.rax != syscall.ping_result) {
        serial.printLine("[VNK] FATAL: the handler returned 0x{x}, expected 0x{x}", .{
            frame.rax,
            syscall.ping_result,
        });
        port.haltForever();
    }

    serial.printLine("[VNK] self test: the handler returned 0x{x}", .{frame.rax});
}

/// Verifies that the exception handling works.
///
/// The test provokes an invalid opcode and the handler of the kernel
/// reports it and stops the machine. The automated boot test looks for the
/// report.
fn selfTest() void {
    serial.printLine("[VNK] self test: provoking an invalid opcode", .{});
    asm volatile ("ud2");
    serial.printLine("[VNK] FATAL: the exception handling did not stop the kernel", .{});
    port.haltForever();
}
