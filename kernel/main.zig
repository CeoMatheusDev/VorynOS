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
const kernel_version = "0.1.0-dev.3";

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

/// Number of processes that the kernel runs in address spaces of their own.
const process_count = 2;

/// The stacks of the tasks of the kernel.
///
/// The stacks live in the image of the kernel because the region has to
/// stay mapped after the replacement of the page tables.
var task_stacks: [task_count][task_stack_size]u8 align(16) = undefined;

/// The stack of the kernel of the task of the user mode.
///
/// The handlers of the calls and of the interrupts of the task run on it,
/// and not on the stack of the user, which the user could rewrite.
var user_task_stack: [task_stack_size]u8 align(16) = undefined;

/// The stack of the kernel of each demo process.
var process_kernel_stacks: [process_count][task_stack_size]u8 align(16) = undefined;

/// The virtual address of the program of the task that runs in user mode.
const user_code_address: u64 = 0x40_0000;

/// The virtual address of the data of the task that runs in user mode.
const user_data_address: u64 = 0x40_1000;

/// The virtual address of the stack of the task that runs in user mode.
const user_stack_address: u64 = 0x40_2000;

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
const user_result_address: u64 = user_data_address + 8;

/// The address of the third word of the page of data of the user mode.
///
/// The program of the user mode writes there the result of the call that
/// writes in the console.
const user_write_address: u64 = user_data_address + 16;

/// The address of the fourth word of the page of data of the user mode.
///
/// The program of the user mode writes there the result of the call that
/// copies a block of memory.
const user_copy_address: u64 = user_data_address + 24;

/// The address of the fifth word of the page of data of the user mode.
///
/// The kernel compares the content with the page of code, and the equality
/// proves that the copy happened.
const user_copy_content_address: u64 = user_data_address + 32;

/// The address of the seventh word of the page of data of the user mode.
///
/// The program of the user mode writes there the answer of a call with an
/// address that is not of the user, and the value proves that the kernel
/// refused the call.
const user_refused_address: u64 = user_data_address + 48;

/// The number of bytes that the program of the user mode writes.
const user_write_length: u64 = 8;

/// The number of bytes that the program of the user mode copies.
const user_copy_length: u64 = 8;

/// The result that the kernel answers to the call of the probe.
const user_result_value: u64 = syscall.ping_result;

/// The virtual address of the page of code of a demo process.
///
/// Both processes start at the same virtual address: each one reaches it
/// through its own private chain of page tables, and the two chains name
/// different physical frames. This is exactly what makes the isolation
/// verifiable — if the spaces shared a mapping, the second process would
/// read the program of the first one and the signatures below would never
/// both appear.
///
/// The window does not have a fixed address: `paging.setup` places it
/// where the handoff left room, so the addresses of the pages of a process
/// are variables that the boot fills after the tables are built and
/// before any process exists.
var process_code_address: u64 = undefined;

/// The virtual address of the page of data of a demo process.
///
/// The programs of the demo write their signature in this page, which sits
/// inside the window of the user mode of each space.
var process_data_address: u64 = undefined;

/// The virtual address of the stack of a demo process.
///
/// One page is enough for the program of the demo, which calls the kernel
/// without pushing anything of its own; the address stays inside the
/// window of the user mode of the space, like the other pages.
var process_stack_address: u64 = undefined;

/// Fills the addresses of the pages of a process from the placed window.
///
/// Runs right after the page tables of the kernel, which is where the
/// paging module decides the final position of the window. The programs of
/// the demo reach their page of data through an absolute address that the
/// assembly takes from the kernel (`voryn_process_data_address`), so the
/// assignment happens before any copy of a program into a page of code.
fn prepareProcessWindow() void {
    process_code_address = paging.user_window_base;
    process_data_address = paging.user_window_base + 0x1000;
    process_stack_address = paging.user_window_base + 0x2000;
}

/// The value that the first process writes in its page of data.
const proc_a_signature: u64 = 0xA1A1_A1A1;

/// The value that the second process writes in its page of data.
const proc_b_signature: u64 = 0xB2B2_B2B2;

/// The length of the program of a demo process, in bytes.
///
/// The two programs have the same length by construction, and the kernel
/// refuses to build an image that breaks the assumption: the copy of the
/// program uses this constant as its length, and the assembly of the
/// programs pads itself to exactly this size.
const demo_program_length: usize = 49;

/// The programs of the demo processes, provided by `task.s`.
///
/// Each symbol marks the beginning of a program, and the matching `_end`
/// symbol marks the byte after its last instruction. The addresses are
/// taken with `@intFromPtr`, so only the symbols themselves are referenced.
extern var voryn_demo_program_a: u8;
extern var voryn_demo_program_a_end: u8;
extern var voryn_demo_program_b: u8;
extern var voryn_demo_program_b_end: u8;

// Guards that the programs of the demo keep the length that the kernel
// assumes when it copies them into the pages of the processes. The copy
// uses `demo_program_length` as its length, and the assembly pads each
// program to exactly this size. The addresses of external symbols only
// exist at runtime, so the guard runs when the kernel boots: a program of
// an unexpected length is reported on the console before any process is
// created, and the automated boot test refuses a log that carries it.
fn verifyDemoPrograms() void {
    const a_length = @intFromPtr(&voryn_demo_program_a_end) -% @intFromPtr(&voryn_demo_program_a);
    const b_length = @intFromPtr(&voryn_demo_program_b_end) -% @intFromPtr(&voryn_demo_program_b);

    if (a_length != demo_program_length or b_length != demo_program_length) {
        serial.printLine("[VNK] FATAL: the programs of the demo have an unexpected length: {d} {d}, expected {d}", .{
            a_length,
            b_length,
            demo_program_length,
        });
        port.haltForever();
    }
}

/// The address spaces of the two demo processes.
///
/// The spaces live in the static pool of the paging module, so the tasks
/// can point at them for as long as the machine runs. The kernel keeps the
/// only handles through which it reads the memory of a process while the
/// other space is active — the borrow of a page goes through these tables.
var process_spaces: [process_count]paging.AddressSpace = undefined;

/// Whether the demo processes were installed.
///
/// The reporting and the copy run only when the installation succeeded; a
/// kernel without enough memory stops before any of them, so the flag is
/// a guard against a silent half state, not against a recovery path.
var processes_installed = false;

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
    prepareProcessWindow();
    activatePageTables();
    installHeap();
    // The task of the user mode is prepared after the tables are active:
    // the program is copied through them, and the tables of the firmware
    // would place the copy in another physical page.
    installUserTask();
    // The demo processes live in address spaces of their own, prepared the
    // same way as the task of the user mode: pages from the physical
    // manager, mapped through the private chain of each space.
    installProcesses();
    // The system call of the user mode does not go through the interrupt
    // table: the instruction `syscall` reads the entry point and the
    // segments from the registers of model.
    installSystemCall();

    installScheduler();
    installTimer();

    // The main task waits until the workers have been scheduled a few
    // times, which proves that the scheduler works.
    while (scheduler.scheduler.statisticsOf().switches < 20) {
        cpu.halt();
    }
    reportScheduler();
    reportUserTask();
    reportProcesses();

    // Sentinel consumed by the automated boot test.
    serial.printLine("VORYN-KERNEL-READY", .{});

    // The self test of the system call runs first, from the kernel itself:
    // it separates a broken gate from a broken transition of privilege.
    syscallSelfTest();

    // The copy between the two processes runs after the sentinel: the
    // destination belongs to another address space, and the walk through
    // the frames of each one is what the boot test verifies.
    processCopyDemo();

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
fn installUserTask() void {
    const code_page = physical.manager.allocate() orelse return reportOutOfMemory();
    const data_page = physical.manager.allocate() orelse return reportOutOfMemory();
    const user_stack_low = physical.manager.allocate() orelse return reportOutOfMemory();
    const user_stack_high = physical.manager.allocate() orelse return reportOutOfMemory();
    // The pages of the user mode. The pages are mapped before the program is
    // copied, because the tables are already the active ones.
    paging.mapUserPage(user_code_address, code_page) catch |err| {
        serial.printLine("[VNK] FATAL: the page of the program could not be mapped: {s}", .{@errorName(err)});
        port.haltForever();
    };
    paging.mapUserPage(user_data_address, data_page) catch |err| {
        serial.printLine("[VNK] FATAL: the page of data could not be mapped: {s}", .{@errorName(err)});
        port.haltForever();
    };
    paging.mapUserPage(user_stack_address, user_stack_low) catch |err| {
        serial.printLine("[VNK] FATAL: the stack could not be mapped: {s}", .{@errorName(err)});
        port.haltForever();
    };
    paging.mapUserPage(user_stack_address + handoff.page_size, user_stack_high) catch |err| {
        serial.printLine("[VNK] FATAL: the stack could not be mapped: {s}", .{@errorName(err)});
        port.haltForever();
    };

    // The program is copied into the page that the user mode sees.
    const program_start = @intFromPtr(&voryn_user_program);
    const program_end = @intFromPtr(&voryn_user_program_end);
    const program_length = program_end - program_start;
    const destination: [*]u8 = @ptrFromInt(user_code_address);
    @memcpy(destination[0..program_length], @as([*]const u8, @ptrFromInt(program_start))[0..program_length]);

    serial.printLine("[VNK] user: program at 0x{x}, data at 0x{x}, stack at 0x{x}", .{
        user_code_address,
        user_data_address,
        user_stack_address,
    });
}

/// Reports that the kernel does not have enough memory.
fn reportOutOfMemory() noreturn {
    serial.printLine("[VNK] FATAL: out of memory", .{});
    port.haltForever();
}

/// Prepares the bounce pages of the paging module.
///
/// The frames come from the physical manager, below the address where the
/// image of the kernel starts to be mapped by identity: a frame in that
/// range is not named by any other mapping of the kernel, so the identity
/// entry that the paging module adds for it cannot collide with anything,
/// and every address space carries the entry of the kernel, which makes
/// the page reachable without a switch of `CR3`.
fn allocateBounceFrame(limit: u64) ?u64 {
    return physical.manager.allocateBelow(limit);
}

/// Creates one demo process: an address space, three pages, and a task.
///
/// The program arrives in the page of code through the borrow of a bounce
/// page, never through the window itself: at this point no space is
/// active, and the contract of the window is that only its owner reaches
/// it while the owner is scheduled. The data page and the stack are left
/// empty — the program writes its signature into the page of data when it
/// runs, which is what the reporting reads back later.
fn installProcess(index: usize, program_start: u64, signature: u64) void {
    const space = paging.createAddressSpace() catch |err| {
        serial.printLine("[VNK] FATAL: the space of the process could not be created: {s}", .{@errorName(err)});
        port.haltForever();
    };
    process_spaces[index] = space;

    const code_frame = physical.manager.allocate() orelse reportOutOfMemory();
    const data_frame = physical.manager.allocate() orelse reportOutOfMemory();
    const stack_frame = physical.manager.allocate() orelse reportOutOfMemory();

    paging.mapUserPageIn(&space, process_code_address, code_frame) catch reportMappingFailure("the page of the program");
    paging.mapUserPageIn(&space, process_data_address, data_frame) catch reportMappingFailure("the page of data");
    paging.mapUserPageIn(&space, process_stack_address, stack_frame) catch reportMappingFailure("the stack");

    // The program is copied into the page of code through a borrowed view
    // over the frame: the kernel writes at the identity address of the
    // bounce page, and the entry of the window goes back to the frame of
    // the process when the view is released.
    var view = paging.borrowPage(&space, process_code_address) orelse {
        serial.printLine("[VNK] FATAL: the bounce pages are not ready", .{});
        port.haltForever();
    };
    defer paging.releasePage(&view);

    const destination: [*]u8 = @ptrFromInt(view.frame);
    const source: [*]const u8 = @ptrFromInt(program_start);
    @memcpy(destination[0..demo_program_length], source[0..demo_program_length]);

    serial.printLine("[VNK] processes: space {d}: code=0x{x} data=0x{x} signature=0x{x}", .{
        index,
        process_code_address,
        process_data_address,
        signature,
    });

    _ = scheduler.scheduler.spawnProcess(
        process_code_address,
        process_stack_address,
        handoff.page_size,
        &process_kernel_stacks[index],
        &process_spaces[index],
    ) orelse reportOutOfMemory();
}

/// Stops the kernel when a page of a process cannot be mapped.
fn reportMappingFailure(name: []const u8) noreturn {
    serial.printLine("[VNK] FATAL: {s} of a process could not be mapped", .{name});
    port.haltForever();
}

/// Creates the two demo processes, each one in an address space of its own.
///
/// The processes start at the same virtual address, in spaces whose private
/// chains name different physical frames: everything that separates them
/// is the table, not the code. The programs write their signature in the
/// page of data and ask the kernel to end the task, so after a few ticks
/// both signatures sit in the memory of the kernel's choosing and nowhere
/// else.
fn installProcesses() void {
    if (process_count != 2) {
        serial.printLine("[VNK] FATAL: the demo expects exactly two processes", .{});
        port.haltForever();
    }

    // The contract between the assembly and the kernel is checked before
    // any copy happens: a program of an unexpected length would be copied
    // with the wrong number of bytes, and the process would run garbage.
    verifyDemoPrograms();

    // The bounce pages have to exist before any space is created: the copy
    // of the program into the page of code goes through them, and a space
    // made afterwards inherits the entry of the kernel that carries them.
    paging.prepareBouncePages(allocateBounceFrame) catch |err| {
        serial.printLine("[VNK] FATAL: the bounce pages could not be prepared: {s}", .{@errorName(err)});
        port.haltForever();
    };

    installProcess(0, @intFromPtr(&voryn_demo_program_a), proc_a_signature);
    installProcess(1, @intFromPtr(&voryn_demo_program_b), proc_b_signature);

    processes_installed = true;
}

/// Reads the page of data of a process through the tables of its space.
///
/// The value lives in the frame that the private chain of the space names
/// for the virtual address of the page of data, reached through a borrowed
/// bounce page: the read works whichever space the processor is running,
/// and it can only ever see the memory of the process that owns the space.
fn readProcessData(index: usize) ?u64 {
    var view = paging.borrowPage(&process_spaces[index], process_data_address) orelse return null;
    defer paging.releasePage(&view);

    const word: *volatile u64 = @ptrFromInt(view.frame + (process_data_address % handoff.page_size));
    return word.*;
}

/// Waits until both processes wrote their signature, and reports the proof.
///
/// Two things are verified here. The first one is that each process ran in
/// its own space: the signature of each one appears in the frame that the
/// tables of its own space name, and the frames are different — the same
/// virtual address reaching two different pieces of memory is the
/// isolation, seen from the side of the kernel. The second one is that no
/// process saw the memory of the other: the signature of A never appears
/// in the frame of B, and the other way around.
fn reportProcesses() void {
    if (!processes_installed) return;

    var a_value: u64 = 0;
    var b_value: u64 = 0;
    var attempts: u64 = 0;
    while (attempts < 50_000_000) : (attempts += 1) {
        a_value = readProcessData(0) orelse 0;
        b_value = readProcessData(1) orelse 0;
        if (a_value == proc_a_signature and b_value == proc_b_signature) break;
        cpu.halt();
    }

    if (a_value != proc_a_signature or b_value != proc_b_signature) {
        serial.printLine("[VNK] processes: the signatures did not appear: a=0x{x} b=0x{x}", .{
            a_value,
            b_value,
        });
        return;
    }

    const a_frame = paging.frameOf(&process_spaces[0], process_data_address) orelse 0;
    const b_frame = paging.frameOf(&process_spaces[1], process_data_address) orelse 0;

    const statistics = paging.spaceStatistics();
    serial.printLine("[VNK] processes: {d} spaces, {d} pages mapped, {d} switches", .{
        statistics.spaces_created,
        statistics.pages_mapped,
        statistics.switches,
    });
    serial.printLine("[VNK] processes: same address 0x{x}, frames 0x{x} and 0x{x}", .{
        process_data_address,
        a_frame,
        b_frame,
    });

    if (statistics.spaces_created < process_count or a_frame == 0 or b_frame == 0 or a_frame == b_frame) {
        serial.printLine("[VNK] processes: the spaces do not isolate the pages", .{});
        return;
    }

    serial.printLine("[VNK] processes: isolation proven, each space holds its own signature", .{});
}

/// Copies a block from the memory of one process into the memory of the
/// other, through the kernel, and verifies the result.
///
/// The source belongs to the first space and the destination to the
/// second: neither address is reachable through the tables of the other
/// process, and the copy walks the private chain of each one, borrowing a
/// bounce page per side. After the copy, the page of data of the second
/// process holds the signature of the first one — the value crossed the
/// boundary because the kernel moved it, and only because the kernel
/// checked both ranges against the right tables.
fn processCopyDemo() void {
    if (!processes_installed) return;

    syscall.copyBetweenProcesses(
        &process_spaces[0],
        process_data_address,
        &process_spaces[1],
        process_data_address,
        8,
    ) catch |err| {
        serial.printLine("[VNK] processes: the copy between the spaces failed: {s}", .{@errorName(err)});
        return;
    };

    const moved = readProcessData(1) orelse {
        serial.printLine("[VNK] processes: the destination could not be read", .{});
        return;
    };

    if (moved != proc_a_signature) {
        serial.printLine("[VNK] processes: the copy moved 0x{x}, expected 0x{x}", .{ moved, proc_a_signature });
        return;
    }

    serial.printLine("[VNK] processes: copy between spaces ok, 0x{x} moved to the other process", .{moved});
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
    scheduler.scheduler.init(@intFromPtr(&voryn_boot_stack_end));

    _ = scheduler.scheduler.spawn(&workerOne, &task_stacks[1]);
    _ = scheduler.scheduler.spawn(&workerTwo, &task_stacks[2]);

    // The task of the user mode has a stack of its own for the user and
    // another for the kernel, where the handlers run.
    if (enable_user_task) {
        const user_task = scheduler.scheduler.spawnUser(
            user_code_address,
            user_stack_address,
            2 * handoff.page_size,
            &user_task_stack,
        ) orelse return reportOutOfMemory();
        serial.printLine("[VNK] user: task {d} cs=0x{x} ss=0x{x} rip=0x{x} rsp=0x{x}", .{
            user_task.id,
            user_task.context.cs,
            user_task.context.ss,
            user_task.context.rip,
            user_task.context.rsp,
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
    const marker: *volatile u64 = @ptrFromInt(user_data_address);
    const result: *volatile u64 = @ptrFromInt(user_result_address);
    const written: *volatile u64 = @ptrFromInt(user_write_address);
    const copied: *volatile u64 = @ptrFromInt(user_copy_address);
    const content: *volatile u64 = @ptrFromInt(user_copy_content_address);
    const code: *volatile u64 = @ptrFromInt(user_code_address);

    // The task of the user mode is scheduled by the timer, therefore the
    // kernel waits for it instead of assuming that it already ran.
    var attempts: u64 = 0;
    while (result.* != user_result_value and attempts < 10_000_000) : (attempts += 1) {
        cpu.halt();
    }

    if (marker.* != user_program_value) {
        serial.printLine("[VNK] user: the page of the user mode holds 0x{x}, expected 0x{x}", .{
            marker.*,
            user_program_value,
        });
    } else {
        serial.printLine("[VNK] user: the program of the user mode wrote 0x{x} in its page", .{marker.*});
    }

    if (result.* != user_result_value) {
        serial.printLine("[VNK] user: the result of the call is 0x{x}, expected 0x{x}", .{
            result.*,
            user_result_value,
        });
    } else {
        serial.printLine("[VNK] user: the result of the call came back, 0x{x}", .{result.*});
    }

    // The write reads a buffer of the user after checking the range in the
    // page tables, and the answer is the number of bytes written.
    if (written.* != user_write_length) {
        serial.printLine("[VNK] user: the write wrote 0x{x} bytes, expected {d}", .{
            written.*,
            user_write_length,
        });
    } else {
        serial.printLine("[VNK] user: the write of the user mode wrote {d} bytes", .{written.*});
    }

    // A call with an address that is not of the user has to be refused,
    // and the answer is the negative value of the error.
    const refused: *volatile u64 = @ptrFromInt(user_refused_address);
    if (refused.* != syscall.failure(syscall.Error.invalid_address)) {
        serial.printLine("[VNK] user: the refused call answered 0x{x}, expected 0x{x}", .{
            refused.*,
            syscall.failure(syscall.Error.invalid_address),
        });
    } else {
        serial.printLine("[VNK] user: the kernel refused the call of an address of the kernel", .{});
    }

    // The copy moves a block of the page of code to the page of data, and
    // the content proves that the copy happened.
    if (copied.* != user_copy_length) {
        serial.printLine("[VNK] user: the copy copied 0x{x} bytes, expected {d}", .{
            copied.*,
            user_copy_length,
        });
    } else if (content.* != code.*) {
        serial.printLine("[VNK] user: the copy holds 0x{x}, expected 0x{x}", .{ content.*, code.* });
    } else {
        serial.printLine("[VNK] user: the copy of the user mode moved {d} bytes", .{copied.*});
    }
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
