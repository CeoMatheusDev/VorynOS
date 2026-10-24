//************************************************************************//
//  main.zig                                                              //
//************************************************************************//
//                         This file is part of:                          //
//                               VorynOS                                  //
//              https://github.com/CeoMatheusDev/VorynOS                  //
//************************************************************************//
// Copyright (C) 2026 VorynOS contributors.                               //
//                                                                        //
// SPDX-License-Identifier: GPL-3.0-only                                  //
//************************************************************************//

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
const compositor_abi = voryn.compositor;

const cpu = @import("arch/x86_64/cpu.zig");
const interrupt = @import("arch/x86_64/interrupt.zig");
const paging = @import("arch/x86_64/paging.zig");
const segment = @import("arch/x86_64/segment.zig");
const syscall = @import("arch/x86_64/syscall.zig");
const timer = @import("arch/x86_64/timer.zig");

const heap = @import("memory/heap.zig");
const capability = @import("security/capability.zig");
const physical = @import("memory/physical.zig");
const scheduler = @import("task/scheduler.zig");
const fs = @import("fs/fs.zig");
const elf_loader = @import("elf_loader.zig");
const elf_materializer = @import("elf_materializer.zig");
const native_image = @import("native_image.zig");
const toolchain_app = @import("native_app");
const client_app = @import("client_app");
const compositor = @import("graphics/compositor.zig");
const display = @import("graphics/display.zig");
const framebuffer_bridge = @import("graphics/framebuffer_bridge.zig");
const desktop_mod = @import("graphics/desktop.zig");
const ps2 = @import("input/ps2.zig");
const keyboard_motion = @import("graphics/keyboard_motion.zig");
const keyboard = @import("voryn_keyboard");

var graphics_front_x: usize = 0;
var graphics_front_y: usize = 0;
var graphics_ready: bool = false;
var graphics_desktop: desktop_mod.Desktop = undefined;
// F6.11: tecla I (Set 1, 0x17) seleciona o modo interativo durante o boot.
var interactive_requested: bool = false;

/// F6.23: janela de medição do caminho de uma seta.
///
/// O relógio do processador mede apenas intervalos; a calibração contra o
/// PIT converte os ciclos em microssegundos. O custo do próprio relatório
/// não entra no total, e a escrita serial de cada fase é contabilizada
/// separadamente para não ser confundida com a composição.
const perf_window_events = 8;

const PerfWindow = struct {
    events: usize = 0,
    setup_cycles: u64 = 0,
    motion_cycles: u64 = 0,
    ack_cycles: u64 = 0,
    render_cycles: u64 = 0,
    log_cycles: u64 = 0,
    total_cycles: u64 = 0,
    pixels: u64 = 0,
};

var perf_tsc_hz: u64 = 0;
var perf_window: PerfWindow = .{};

fn cyclesToMicroseconds(cycles: u64) u64 {
    if (perf_tsc_hz == 0) return 0;
    return @intCast(@as(u128, cycles) * 1_000_000 / perf_tsc_hz);
}

/// Registra uma seta confirmada e publica o resumo a cada janela.
/// O chamador executa com interrupções habilitadas; o snapshot do custo da
/// IRQ1 é feito com elas desabilitadas, porque o produtor é a própria IRQ1.
fn recordArrowPerf(
    start: u64,
    setup_done: u64,
    motion_done: u64,
    ack_done: u64,
    render_done: u64,
    end: u64,
    pixels: usize,
) void {
    perf_window.events += 1;
    perf_window.setup_cycles +|= setup_done - start;
    perf_window.motion_cycles +|= motion_done - setup_done;
    perf_window.ack_cycles +|= ack_done - motion_done;
    perf_window.render_cycles +|= render_done - ack_done;
    perf_window.log_cycles +|= end - render_done;
    perf_window.total_cycles +|= end - start;
    perf_window.pixels +|= pixels;
    if (perf_window.events < perf_window_events) return;

    cpu.disableInterrupts();
    const irq = ps2.takeIrqStatsIrqsDisabled();
    cpu.enableInterrupts();

    serial.printLine(
        "[VNK] perf: {d} arrows total={d}us setup={d}us motion={d}us ack={d}us render={d}us log={d}us pixels={d} irq_interrupts={d} irq_bytes={d} irq={d}us",
        .{
            perf_window.events,
            cyclesToMicroseconds(perf_window.total_cycles),
            cyclesToMicroseconds(perf_window.setup_cycles),
            cyclesToMicroseconds(perf_window.motion_cycles),
            cyclesToMicroseconds(perf_window.ack_cycles),
            cyclesToMicroseconds(perf_window.render_cycles),
            cyclesToMicroseconds(perf_window.log_cycles),
            perf_window.pixels,
            irq.interrupts,
            irq.bytes,
            cyclesToMicroseconds(irq.cycles),
        },
    );
    perf_window = .{};
}

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
const process_count = 3;

/// The address space of the process of the user mode.
var user_space: ?*paging.AddressSpace = null;

/// The address space of the second process.
var second_space: ?*paging.AddressSpace = null;

/// The address space of the third process.
///
/// The third process provokes a page fault, and it exists to prove that an
/// exception of a process does not bring the kernel down.
var third_space: ?*paging.AddressSpace = null;

/// The stack of the kernel of the second process.
var second_task_stack: [task_stack_size]u8 align(16) = undefined;

/// The stack of the kernel of the third process.
var third_task_stack: [task_stack_size]u8 align(16) = undefined;

/// The address space of the native process loaded from the RamFS.
var native_space: ?*paging.AddressSpace = null;

/// The entry point of the native process, already in the window.
var native_entry: u64 = 0;

/// The task of the native process.
var native_task: ?*scheduler.Task = null;

/// The address space of the toolchain process.
var toolchain_space: ?*paging.AddressSpace = null;

/// The entry point of the toolchain process.
var toolchain_entry: u64 = 0;

/// The task of the toolchain process.
var toolchain_task: ?*scheduler.Task = null;

/// The stack of the kernel of the toolchain task.
var toolchain_task_stack: [task_stack_size]u8 align(16) = undefined;

/// The address space of the client of the compositor.
var client_space: ?*paging.AddressSpace = null;

/// The entry point of the client, already in the window.
var client_entry: u64 = 0;

/// The task of the client.
var client_task: ?*scheduler.Task = null;

/// The stack of the kernel of the client task.
var client_task_stack: [task_stack_size]u8 align(16) = undefined;

/// The stack of the kernel of the native task.
var native_task_stack: [task_stack_size]u8 align(16) = undefined;

/// The buffer that receives the native image read from the RamFS.
var native_image_buffer: [native_image.max_image_size]u8 = undefined;

/// The buffer that receives the toolchain image read from the RamFS.
var toolchain_image_buffer: [toolchain_app.bytes.len]u8 = undefined;

/// The buffer that receives the client image read from the RamFS.
var client_image_buffer: [client_app.bytes.len]u8 = undefined;

/// The number of bytes of the native image.
var native_image_length: usize = 0;

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

/// The virtual address of the data segment of the native image.
fn nativeDataAddress() u64 {
    return user_window_base + native_image.data_virtual_address;
}

/// The virtual address of the marker that the native program writes.
fn nativeMarkerAddress() u64 {
    return nativeDataAddress() + native_image.data_marker_offset;
}

/// The virtual address of the word that the relative relocation fills.
fn nativeRelocationAddress() u64 {
    return nativeDataAddress() + native_image.relocation_target_offset;
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
/// channel, and the value proves that the message of the kernel reached
/// the user.
fn userAnswerAddress() u64 {
    return userDataAddress() + usermode.data_answer;
}

/// The address of the ninth word of the page of data of the user mode.
///
/// The program of the user mode writes there the answer of the call that
/// copies a block whose ranges overlap. The value proves that the kernel
/// copied the block, and that the task of the user mode did not bring the
/// machine down.
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

/// The address of the word that holds the result of the call that a
/// process without the capability made.
fn userCapabilityRefusedAddress() u64 {
    return userDataAddress() + usermode.data_capability_refused;
}

/// The address of the word that holds the result of the revocation of a
/// capability.
fn userCapabilityRevokedAddress() u64 {
    return userDataAddress() + usermode.data_capability_revoked;
}

/// The address of the word that holds the result of the delegation of a
/// capability.
fn userCapabilityGrantedAddress() u64 {
    return userDataAddress() + usermode.data_capability_granted;
}

/// The address of the word that holds the result of the copy that a process
/// without the capability of the address space made.
fn userCopyRefusedAddress() u64 {
    return userDataAddress() + usermode.data_copy_refused;
}

/// The address of the word that holds the result of the delegation of the
/// capability of an address space through the call.
fn userProcessGrantedAddress() u64 {
    return userDataAddress() + usermode.data_process_granted;
}

/// The address of the word that holds the result of the revocation of the
/// capability of an address space through the call.
fn userProcessRevokedAddress() u64 {
    return userDataAddress() + usermode.data_process_revoked;
}

/// The address of the word that holds the result of the grant with a kind
/// that the kernel does not know.
fn userKindRefusedAddress() u64 {
    return userDataAddress() + usermode.data_kind_refused;
}

/// The address of the word that holds the result of the grant with a right
/// that does not apply to the kind.
fn userRightsRefusedAddress() u64 {
    return userDataAddress() + usermode.data_rights_refused;
}

/// The address of the word that holds the result of the wait with a
/// timeout.
fn userTimeoutAddress() u64 {
    return userDataAddress() + usermode.data_timeout;
}

/// The address of the word that holds the result of the presentation that
/// a process without the display capability made.
fn userPresentRefusedAddress() u64 {
    return userDataAddress() + usermode.data_present_refused;
}

/// The address of the word that holds the result of the input call that a
/// process without the input capability made.
fn userInputRefusedAddress() u64 {
    return userDataAddress() + usermode.data_input_refused;
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
/// The answer is the value of the message with the bytes inverted, and the
/// kernel checks the value in the page of data of the user.
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

    // The pages of data and of the stack are marked as not executable in
    // the page tables. The bit is reserved until the processor enables it,
    // therefore the feature is turned on before the first user page is
    // mapped, and the kernel does not boot without it: W^X would be a
    // promise of the planner that the hardware would not enforce.
    if (!cpu.enableNoExecute()) {
        serial.printLine("[VNK] FATAL: the processor does not support the no-execute bit", .{});
        port.haltForever();
    }
    serial.printLine("[VNK] paging: no-execute enabled", .{});

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

    // The RamFS is initialized before the processes: the native process is
    // loaded from `/apps/hello.elf`, and the file has to exist when the
    // materializer reads it.
    installFs();

    // The task of the user mode is prepared after the tables are active:
    // the program is copied through them, and the tables of the firmware
    // would place the copy in another physical page.
    installUserTask();
    installNativeProcess();
    installToolchainProcess();
    installClientProcess();
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

    // The kernel is the root authority of the capabilities: it creates the
    // capability of the channel of the VNX and gives it to the process
    // that owns it. The other processes only use the channel after the
    // owner gives them the capability, and the process that does not hold
    // it is refused.
    installCapabilities();
    prepareFsLifecycleProbe();

    installScheduler();
    installTimer();

    // The main task waits until the workers have been scheduled a few
    // times, which proves that the scheduler works.
    while (scheduler.scheduler.statisticsOf().switches < 20) {
        cpu.halt();
    }
    reportScheduler();
    reportUserTask();
    reportNativeTask();
    reportToolchainTask();
    reportClientTask();
    verifyFsLifecycleProbe();

    // F6.26: the toolchain application presents a probe rectangle during
    // its test. The diagnostic scene is drawn again after the task has
    // terminated, so the interactive screenshot test starts from the scene
    // that the kernel owns; the presentation itself is proven by the
    // serial read-back of the first pixel.
    presentGraphicsDemo();

    reportCapabilities();

    // Sentinel consumed by the automated boot test.
    serial.printLine("VORYN-KERNEL-READY", .{});

    // The self test of the system call runs first, from the kernel itself:
    // it separates a broken gate from a broken transition of privilege.
    syscallSelfTest();

    // F6.11: a tecla I durante a janela PS/2 seleciona o modo interativo.
    // O boot automatizado nao envia I, preservando o autoteste fatal UD2.
    if (interactive_requested) runInteractiveEventLoop();

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
        display.clear();
        serial.printLine("[VNK] framebuffer: none", .{});
        return;
    }

    const framebuffer = boot.framebuffer;
    display.install(framebuffer);
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
    // F6.2: cena inicial diretamente no framebuffer GOP mapeado.
    // A integração ocorre antes da ativação do timer e das tarefas.
    presentGraphicsDemo();
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

/// F6.2: desenha uma cena de diagnóstico no framebuffer fornecido pelo UEFI.
/// Não altera o contrato do boot nem expõe MMIO a processos de usuário.
fn presentGraphicsDemo() void {
    const framebuffer = boot_info.framebuffer;
    if (boot_info.flags & handoff.flag_framebuffer == 0) return;
    if (framebuffer.base == 0 or framebuffer.bits_per_pixel != 32) return;
    if (framebuffer.width == 0 or framebuffer.height == 0) return;
    if (framebuffer.size > std.math.maxInt(usize)) return;
    if (framebuffer.base >= handoff.identity_mapped_limit) return;
    if (framebuffer.size > handoff.identity_mapped_limit - framebuffer.base) return;

    const size: usize = @intCast(framebuffer.size);
    const width: usize = @intCast(framebuffer.width);
    const height: usize = @intCast(framebuffer.height);
    const pitch: usize = @intCast(framebuffer.pitch);
    const ptr: [*]u8 = @ptrFromInt(framebuffer.base);
    // GOP descreve layouts RGB/BGR também pelo enum. Alguns firmwares
    // deixam as máscaras zeradas nos modos predefinidos.
    const masks_absent = framebuffer.red_mask == 0 and
        framebuffer.green_mask == 0 and framebuffer.blue_mask == 0;
    const is_bgr = if (masks_absent)
        framebuffer.pixel_format == .bgr32
    else
        framebuffer.red_mask == 0x00ff0000 and
            framebuffer.green_mask == 0x0000ff00 and
            framebuffer.blue_mask == 0x000000ff;
    const is_rgb = if (masks_absent)
        framebuffer.pixel_format == .rgb32
    else
        framebuffer.red_mask == 0x000000ff and
            framebuffer.green_mask == 0x0000ff00 and
            framebuffer.blue_mask == 0x00ff0000;
    if (!is_bgr and !is_rgb) {
        serial.printLine("[VNK] graphics: unsupported pixel layout format={d} masks=0x{x}/0x{x}/0x{x}", .{
            @intFromEnum(framebuffer.pixel_format),
            framebuffer.red_mask,
            framebuffer.green_mask,
            framebuffer.blue_mask,
        });
        return;
    }
    const background: [4]u8 = if (is_bgr) .{ 0x20, 0x17, 0x10, 0 } else .{ 0x10, 0x17, 0x20, 0 };
    const front: [4]u8 = if (is_bgr) .{ 0xb0, 0x86, 0x30, 0 } else .{ 0x30, 0x86, 0xb0, 0 };
    const back: [4]u8 = if (is_bgr) .{ 0x70, 0x36, 0x1e, 0 } else .{ 0x1e, 0x36, 0x70, 0 };
    // F10: the boot scene now uses the managed window session and bridge.
    // Keep the legacy keyboard redraw path until it is migrated separately.
    graphics_desktop.initInPlace(width, height, .{
        .background = background,
        .active = front,
        .inactive = back,
    }) catch |err| {
        serial.printLine("[VNK] graphics: desktop initialization failed: {s}", .{@errorName(err)});
        return;
    };
    const mapping: framebuffer_bridge.Mapping = .{
        .bytes = ptr[0..size], .width = width, .height = height,
        .pitch = pitch, .bits_per_pixel = framebuffer.bits_per_pixel,
    };
    _ = graphics_desktop.present(mapping) catch |err| {
        serial.printLine("[VNK] graphics: desktop presentation failed: {s}", .{@errorName(err)});
        return;
    };
    serial.printLine("[VNK] graphics: managed desktop presented ({d}x{d})", .{ width, height });
    graphics_front_x = width / 4;
    graphics_front_y = height / 4;
    graphics_ready = true;
}


fn applyKeyboardGraphics(event: keyboard.KeyEvent) void {
    if (!graphics_ready) return;
    // Acknowledge every pressed arrow, including clamped no-op events.
    // This is distinct from the movement log, which reports actual redraws.
    // The filter runs before the setup so a key release does not rebuild the
    // surface and the window list for nothing.
    if (!event.pressed or !event.extended) return;
    switch (event.scancode) {
        0x4b, 0x4d, 0x48, 0x50 => {},
        else => return,
    }

    const start = cpu.readTimestamp();
    const framebuffer = boot_info.framebuffer;
    const width: usize = @intCast(framebuffer.width);
    const height: usize = @intCast(framebuffer.height);
    const pitch: usize = @intCast(framebuffer.pitch);
    const size: usize = @intCast(framebuffer.size);
    const ptr: [*]u8 = @ptrFromInt(framebuffer.base);
    const desktop = &graphics_desktop;
    const slot = desktop.frame.session_state.windows.slots[desktop.front.slot];
    if (!slot.occupied or slot.generation != desktop.front.generation) return;
    const current = slot.window;
    var next: compositor.Window = .{
        .x = current.x, .y = current.y,
        .width = current.width, .height = current.height,
        .color = .{ 0, 0, 0, 0 },
    };
    const bounds: compositor.Rect = .{ .x = 0, .y = 0, .width = width, .height = height };
    const setup_done = cpu.readTimestamp();
    const moved = keyboard_motion.move(&next, bounds, event, @max(@as(usize, 1), width / 32));
    const motion_done = cpu.readTimestamp();
    serial.printLine("[VNK] graphics: arrow ack scancode=0x{x} moved={d} x={d} y={d}", .{
        event.scancode, @intFromBool(moved), next.x, next.y,
    });
    const ack_done = cpu.readTimestamp();
    if (!moved) {
        recordArrowPerf(start, setup_done, motion_done, ack_done, ack_done, ack_done, 0);
        return;
    }
    const pixels = desktop.moveFrontAndPresent(.{
        .bytes = ptr[0..size], .width = width, .height = height,
        .pitch = pitch, .bits_per_pixel = framebuffer.bits_per_pixel,
    }, next.x, next.y) catch |err| {
        serial.printLine("[VNK] graphics: incremental redraw failed: {s}", .{@errorName(err)});
        return;
    };
    const render_done = cpu.readTimestamp();
    graphics_front_x = next.x;
    graphics_front_y = next.y;
    serial.printLine("[VNK] graphics: keyboard move x={d} y={d} redraw={d} pixels", .{ next.x, next.y, pixels });
    const end = cpu.readTimestamp();
    recordArrowPerf(start, setup_done, motion_done, ack_done, render_done, end, pixels);
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
    const tsc_start = cpu.readTimestamp();
    var attempts: u64 = 0;
    while (timer.ticks() - start < 5 and attempts < 100_000_000) : (attempts += 1) {
        cpu.halt();
    }

    // F6.23: calibra o contador de carimbo de tempo contra o PIT. O
    // intervalo de cinco ticks é curto o bastante para não atrasar o boot e
    // longo o bastante para que o erro de leitura seja desprezível.
    const elapsed_ticks = timer.ticks() - start;
    if (elapsed_ticks != 0) {
        const elapsed_tsc = cpu.readTimestamp() - tsc_start;
        perf_tsc_hz = @intCast(@as(u128, elapsed_tsc) * timer.ticksPerSecond() / elapsed_ticks);
    }

    serial.printLine("[VNK] timer: {d} Hz, {d} ticks", .{ timer.ticksPerSecond(), timer.ticks() });
    serial.printLine("[VNK] perf: timestamp counter {d} Hz", .{perf_tsc_hz});

    // F6.9: event pump por 50 ticks, em vez de consumir toda a fila
    // apenas no final. O trabalho de composição ocorre com IRQs habilitadas.
    // CLI protege somente a retirada de um evento da fila SPSC de IRQ1.
    serial.printLine("[VNK] keyboard: ready for PS/2 input", .{});
    const input_start = timer.ticks();
    var key_count: usize = 0;
    var pressed: usize = 0;
    var released: usize = 0;
    var graphics_updates: usize = 0;
    while (timer.ticks() - input_start < 50) {
        cpu.disableInterrupts();
        const maybe_event = ps2.popIrqsDisabled();
        cpu.enableInterrupts();
        if (maybe_event) |event| {
            key_count += 1;
            if (event.pressed) {
                pressed += 1;
                if (event.extended and (event.scancode == 0x4b or event.scancode == 0x4d or event.scancode == 0x48 or event.scancode == 0x50))
                    graphics_updates += 1;
            } else {
                released += 1;
            }
            if (event.pressed and !event.extended and event.scancode == 0x17)
                interactive_requested = true;
            applyKeyboardGraphics(event);
            serial.printLine("[VNK] keyboard: key scancode=0x{x} extended={d} pressed={d}", .{
                event.scancode, @intFromBool(event.extended), @intFromBool(event.pressed),
            });
        } else {
            // HLT acorda na próxima IRQ; não realiza busy polling.
            cpu.halt();
        }
    }
    // Drena os eventos que chegaram no último tick da janela.
    while (true) {
        cpu.disableInterrupts();
        const maybe_event = ps2.popIrqsDisabled();
        cpu.enableInterrupts();
        const event = maybe_event orelse break;
        key_count += 1;
        if (event.pressed) {
            pressed += 1;
            if (event.extended and (event.scancode == 0x4b or event.scancode == 0x4d or event.scancode == 0x48 or event.scancode == 0x50))
                graphics_updates += 1;
        } else {
            released += 1;
        }
        if (event.pressed and !event.extended and event.scancode == 0x17)
            interactive_requested = true;
        applyKeyboardGraphics(event);
        serial.printLine("[VNK] keyboard: key scancode=0x{x} extended={d} pressed={d}", .{
            event.scancode, @intFromBool(event.extended), @intFromBool(event.pressed),
        });
    }
    cpu.disableInterrupts();
    const bytes = ps2.receivedIrqsDisabled();
    const dropped = ps2.droppedIrqsDisabled();
    cpu.enableInterrupts();
    serial.printLine("[VNK] keyboard: {d} events, {d} pressed, {d} released, {d} bytes, {d} dropped", .{
        key_count, pressed, released, bytes, dropped,
    });
    serial.printLine("[VNK] graphics: event pump {d} arrow presses over {d} ticks", .{
        graphics_updates, timer.ticks() - input_start,
    });
}

/// F6.11: loop de eventos permanente, selecionado pela tecla I no boot.
/// Retira um evento com IRQs desabilitadas; compoe com IRQs habilitadas.
fn runInteractiveEventLoop() noreturn {
    serial.printLine("[VNK] graphics: interactive event loop ready", .{});
    while (true) {
        cpu.disableInterrupts();
        const maybe_event = ps2.popIrqsDisabled();
        cpu.enableInterrupts();
        if (maybe_event) |event| {
            applyKeyboardGraphics(event);
        } else {
            // O timer de 100 Hz garante novo despertar mesmo se IRQ1
            // chegar entre a leitura da fila e HLT.
            cpu.halt();
        }
    }
}

/// Initializes the file system.
///
/// The RamFS lives in the image of the kernel. The initialization creates
/// the first directory and a file, writes the file, reads it back and
/// compares the content: a file system that reports success without the
/// round trip would be a claim, and not a verification.
fn installFs() void {
    fs.init();

    _ = fs.mkdir("/apps") catch |err| {
        serial.printLine("[VNK] FATAL: the directory /apps could not be created: {s}", .{@errorName(err)});
        port.haltForever();
    };

    const descriptor = fs.create(0, "/apps/hello.txt", 0o644) catch |err| {
        serial.printLine("[VNK] FATAL: the file /apps/hello.txt could not be created: {s}", .{@errorName(err)});
        port.haltForever();
    };

    const payload = "VorynOS";

    const written = fs.write(0, descriptor, payload) catch |err| {
        serial.printLine("[VNK] FATAL: the file /apps/hello.txt could not be written: {s}", .{@errorName(err)});
        port.haltForever();
    };
    if (written != payload.len) {
        serial.printLine("[VNK] FATAL: the file /apps/hello.txt accepted {d} bytes", .{written});
        port.haltForever();
    }

    fs.close(0, descriptor) catch |err| {
        serial.printLine("[VNK] FATAL: the file /apps/hello.txt could not be closed: {s}", .{@errorName(err)});
        port.haltForever();
    };

    var buffer: [8]u8 = undefined;
    const count = fs.readFile("/apps/hello.txt", &buffer) catch |err| {
        serial.printLine("[VNK] FATAL: the file /apps/hello.txt could not be read: {s}", .{@errorName(err)});
        port.haltForever();
    };
    if (count != payload.len or !std.mem.eql(u8, buffer[0..count], payload)) {
        serial.printLine("[VNK] FATAL: the file /apps/hello.txt did not survive the round trip", .{});
        port.haltForever();
    }

    // The native image. The bytes are built here, written into the RamFS
    // and read back by the loader: the file system is part of the verified
    // path, and not a decoration around an array of the kernel.
    const image = native_image.build(&native_image_buffer) catch |err| {
        serial.printLine("[VNK] FATAL: the native image could not be built: {s}", .{@errorName(err)});
        port.haltForever();
    };
    native_image_length = image.len;

    const elf_descriptor = fs.create(0, "/apps/hello.elf", 0o755) catch |err| {
        serial.printLine("[VNK] FATAL: the file /apps/hello.elf could not be created: {s}", .{@errorName(err)});
        port.haltForever();
    };
    const elf_written = fs.write(0, elf_descriptor, image) catch |err| {
        serial.printLine("[VNK] FATAL: the file /apps/hello.elf could not be written: {s}", .{@errorName(err)});
        port.haltForever();
    };
    if (elf_written != image.len) {
        serial.printLine("[VNK] FATAL: the file /apps/hello.elf accepted {d} bytes", .{elf_written});
        port.haltForever();
    }
    fs.close(0, elf_descriptor) catch |err| {
        serial.printLine("[VNK] FATAL: the file /apps/hello.elf could not be closed: {s}", .{@errorName(err)});
        port.haltForever();
    };

    serial.printLine("[VNK] fs: ramfs ready, {d} blocks free", .{fs.freeBlockCount()});
    serial.printLine("[VNK] fs: /apps/hello.txt round trip ok ({d} bytes)", .{count});
    serial.printLine("[VNK] fs: /apps/hello.elf installed ({d} bytes)", .{image.len});

    // The application produced by the toolchain. Its bytes come from the
    // module generated during the build, and the file goes through the same
    // RamFS as the bootstrap image.
    const toolchain_descriptor = fs.create(0, "/apps/toolchain.elf", 0o755) catch |err| {
        serial.printLine("[VNK] FATAL: the file /apps/toolchain.elf could not be created: {s}", .{@errorName(err)});
        port.haltForever();
    };
    const toolchain_written = fs.write(0, toolchain_descriptor, toolchain_app.bytes[0..]) catch |err| {
        serial.printLine("[VNK] FATAL: the file /apps/toolchain.elf could not be written: {s}", .{@errorName(err)});
        port.haltForever();
    };
    if (toolchain_written != toolchain_app.bytes.len) {
        serial.printLine("[VNK] FATAL: the file /apps/toolchain.elf accepted {d} bytes", .{toolchain_written});
        port.haltForever();
    }
    fs.close(0, toolchain_descriptor) catch |err| {
        serial.printLine("[VNK] FATAL: the file /apps/toolchain.elf could not be closed: {s}", .{@errorName(err)});
        port.haltForever();
    };
    serial.printLine("[VNK] fs: /apps/toolchain.elf installed ({d} bytes)", .{toolchain_app.bytes.len});

    const client_descriptor = fs.create(0, "/apps/client.elf", 0o755) catch |err| {
        serial.printLine("[VNK] FATAL: the file /apps/client.elf could not be created: {s}", .{@errorName(err)});
        port.haltForever();
    };
    const client_written = fs.write(0, client_descriptor, client_app.bytes[0..]) catch |err| {
        serial.printLine("[VNK] FATAL: the file /apps/client.elf could not be written: {s}", .{@errorName(err)});
        port.haltForever();
    };
    if (client_written != client_app.bytes.len) {
        serial.printLine("[VNK] FATAL: the file /apps/client.elf accepted {d} bytes", .{client_written});
        port.haltForever();
    }
    fs.close(0, client_descriptor) catch |err| {
        serial.printLine("[VNK] FATAL: the file /apps/client.elf could not be closed: {s}", .{@errorName(err)});
        port.haltForever();
    };
    serial.printLine("[VNK] fs: /apps/client.elf installed ({d} bytes)", .{client_app.bytes.len});
}

/// Creates the capability of the channel of the VNX and gives it to the
/// process that owns it.
///
/// The kernel is the root authority: it is the only one that creates a
/// capability. The capability of the channel belongs to the process of role
/// zero, which is the process that starts the conversation, and the other
/// processes receive it only when the owner gives it to them.
///
/// The owner of the channel holds the right of delegation, and the process
/// that answers holds the use of the channel and **not** the right of
/// delegation: the process that receives the capability can use the
/// channel, and cannot give it to a third process. The chain of delegation
/// is the property that the model has to keep, and it is verified by the
/// unit tests of the module.
fn installCapabilities() void {
    capability.init();

    const owner = user_space orelse {
        serial.printLine("[VNK] FATAL: the process that owns the channel does not exist", .{});
        port.haltForever();
    };
    const answerer = second_space orelse {
        serial.printLine("[VNK] FATAL: the process that answers does not exist", .{});
        port.haltForever();
    };

    const channel_rights = capability.Rights.use | capability.Rights.delegate;
    const handle = capability.create(.channel, 0, channel_rights) orelse {
        serial.printLine("[VNK] FATAL: the table of capabilities is full", .{});
        port.haltForever();
    };

    if (!capability.give(owner.id, handle, channel_rights)) {
        serial.printLine("[VNK] FATAL: the capability of the channel could not be given", .{});
        port.haltForever();
    }

    // The kernel is the root authority, and it gives the use of the channel
    // to the process that answers. The process that answers cannot give it
    // to a third process, because the right of delegation was not given to
    // it.
    if (!capability.give(answerer.id, handle, capability.Rights.use)) {
        serial.printLine("[VNK] FATAL: the capability of the channel could not be given", .{});
        port.haltForever();
    }

    // The channel of the wait with a timeout. The process that answers
    // waits for a message that nobody sends, and the timer expires the
    // wait. The process holds the use of the channel, and not the right of
    // delegation.
    const timeout_handle = capability.create(.channel, 1, capability.Rights.use) orelse {
        serial.printLine("[VNK] FATAL: the table of capabilities is full", .{});
        port.haltForever();
    };

    if (!capability.give(answerer.id, timeout_handle, capability.Rights.use)) {
        serial.printLine("[VNK] FATAL: the capability of the channel of the timeout could not be given", .{});
        port.haltForever();
    }

    // The capability of the address space of the process that answers.
    // The process of role zero starts the others and is the only one that
    // may write in their spaces: it receives the right to write in the
    // space of the process that answers, and the right to delegate it. The
    // kernel is the root authority, and the capability of the space is
    // created here, when the processes already exist.
    const process_rights = capability.Rights.write | capability.Rights.delegate;
    const process_handle = capability.create(.process, answerer.id, process_rights) orelse {
        serial.printLine("[VNK] FATAL: the table of capabilities is full", .{});
        port.haltForever();
    };

    if (!capability.give(owner.id, process_handle, process_rights)) {
        serial.printLine("[VNK] FATAL: the capability of the address space could not be given", .{});
        port.haltForever();
    }

    // The display capability. The toolchain process is the first
    // compositor stand-in: it holds the right to present, and no other
    // process does. The kernel is still the root authority; the process
    // cannot present until it receives the capability.
    const display_rights = capability.Rights.write | capability.Rights.delegate;
    const display_handle = capability.create(.display, 0, display_rights) orelse {
        serial.printLine("[VNK] FATAL: the table of capabilities is full", .{});
        port.haltForever();
    };
    const presenter = toolchain_space orelse {
        serial.printLine("[VNK] FATAL: the process that presents does not exist", .{});
        port.haltForever();
    };
    if (!capability.give(presenter.id, display_handle, display_rights)) {
        serial.printLine("[VNK] FATAL: the capability of the display could not be given", .{});
        port.haltForever();
    }

    // The input capability. The same process that presents is the first
    // reader of the input queue; the kernel's diagnostic queue remains
    // separate, so the user probe cannot steal the key that selects the
    // interactive mode.
    const input_rights = capability.Rights.read | capability.Rights.delegate;
    const input_handle = capability.create(.input, 0, input_rights) orelse {
        serial.printLine("[VNK] FATAL: the table of capabilities is full", .{});
        port.haltForever();
    };
    if (!capability.give(presenter.id, input_handle, input_rights)) {
        serial.printLine("[VNK] FATAL: the capability of the input could not be given", .{});
        port.haltForever();
    }

    // O canal 2 liga o cliente ao compositor. O cliente só envia, e o
    // compositor só recebe: o direito de delegação não é dado a nenhum dos
    // dois. O cliente não recebe o canal para uma resposta, porque o
    // contrato do F6.29 é de uma via.
    const client = client_space orelse {
        serial.printLine("[VNK] FATAL: the client process does not exist", .{});
        port.haltForever();
    };
    const frame_channel_rights = capability.Rights.send | capability.Rights.receive;
    const frame_channel = capability.create(.channel, compositor_abi.channel_id, frame_channel_rights) orelse {
        serial.printLine("[VNK] FATAL: the table of capabilities is full", .{});
        port.haltForever();
    };
    if (!capability.give(client.id, frame_channel, capability.Rights.send)) {
        serial.printLine("[VNK] FATAL: the capability of the frame channel could not be given to the client", .{});
        port.haltForever();
    }
    if (!capability.give(presenter.id, frame_channel, capability.Rights.receive)) {
        serial.printLine("[VNK] FATAL: the capability of the frame channel could not be given to the compositor", .{});
        port.haltForever();
    }

    // O cliente escreve na superfície do compositor por copy_to. A
    // capability é sobre o processo do compositor, com o direito de
    // escrita, e não sobre uma página de memória compartilhada.
    const surface_process_rights = capability.Rights.write;
    const surface_process = capability.create(.process, presenter.id, surface_process_rights) orelse {
        serial.printLine("[VNK] FATAL: the table of capabilities is full", .{});
        port.haltForever();
    };
    if (!capability.give(client.id, surface_process, capability.Rights.write)) {
        serial.printLine("[VNK] FATAL: the capability of the compositor surface could not be given", .{});
        port.haltForever();
    }

    serial.printLine("[VNK] capabilities: the channel 0 belongs to the process {d}", .{owner.id});
    serial.printLine("[VNK] capabilities: the channel 1 belongs to the process {d}", .{answerer.id});
    serial.printLine("[VNK] capabilities: the address space of the process {d} belongs to the process {d}", .{
        answerer.id,
        owner.id,
    });
    serial.printLine("[VNK] capabilities: the display belongs to the process {d}", .{presenter.id});
    serial.printLine("[VNK] capabilities: the input belongs to the process {d}", .{presenter.id});
    serial.printLine("[VNK] capabilities: the channel {d} carries frames from the client {d} to the compositor {d}", .{
        compositor_abi.channel_id,
        client.id,
        presenter.id,
    });
    serial.printLine("[VNK] capabilities: the client {d} may write the surface of the compositor {d}", .{
        client.id,
        presenter.id,
    });
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
        } else if (role == 1) {
            second_space = space;
        } else {
            third_space = space;
        }
    }
}

/// Creates the process that runs the native ELF image from the RamFS.
///
/// The file is read back from the file system and planned with the window
/// of the user mode as the load bias. The materializer copies the segments,
/// applies the relocations and maps the stack. The process is created
/// before the scheduler starts, so that no other task sees a half-built
/// address space.
fn installNativeProcess() void {
    if (!enable_user_task) return;

    const window = user_window_base;
    const plan = elf_loader.planFromRamFs(
        "/apps/hello.elf",
        &native_image_buffer,
        window,
        window,
        usermode.window_size,
    ) catch |err| {
        serial.printLine("[VNK] FATAL: the native image could not be planned: {s}", .{@errorName(err)});
        port.haltForever();
    };

    const space = paging.createAddressSpace(window) orelse {
        serial.printLine("[VNK] FATAL: the native address space could not be created", .{});
        port.haltForever();
    };

    const stack_base = window + usermode.stack_offset;
    elf_materializer.materialize(
        space,
        &plan,
        native_image_buffer[0..native_image_length],
        window,
        usermode.window_size,
        stack_base,
        usermode.stack_pages,
    ) catch |err| {
        serial.printLine("[VNK] FATAL: the native image could not be materialized: {s}", .{@errorName(err)});
        port.haltForever();
    };

    native_space = space;
    native_entry = plan.entry;

    verifyNativePermissions(space);

    serial.printLine("[VNK] native: /apps/hello.elf entry=0x{x} base=0x{x} end=0x{x}, {d} segments", .{
        plan.entry,
        plan.base,
        plan.end,
        plan.segment_count,
    });
    serial.printLine("[VNK] native: process {d}, code R+X, data and stack R+W+NX, stack top 0x{x}", .{
        space.id,
        stack_base + usermode.stack_pages * handoff.page_size,
    });
    serial.printLine("[VNK] native: {d} relative relocation(s) applied", .{plan.relocation_count});
}

/// Creates the process that runs the ELF produced by the toolchain.
fn installToolchainProcess() void {
    if (!enable_user_task) return;

    const window = user_window_base;
    const plan = elf_loader.planFromRamFs(
        "/apps/toolchain.elf",
        &toolchain_image_buffer,
        window,
        window,
        usermode.window_size,
    ) catch |err| {
        serial.printLine("[VNK] FATAL: the toolchain image could not be planned: {s}", .{@errorName(err)});
        port.haltForever();
    };

    const space = paging.createAddressSpace(window) orelse {
        serial.printLine("[VNK] FATAL: the toolchain address space could not be created", .{});
        port.haltForever();
    };

    const stack_base = window + usermode.stack_offset;
    elf_materializer.materialize(
        space,
        &plan,
        toolchain_image_buffer[0..toolchain_app.bytes.len],
        window,
        usermode.window_size,
        stack_base,
        usermode.stack_pages,
    ) catch |err| {
        serial.printLine("[VNK] FATAL: the toolchain image could not be materialized: {s}", .{@errorName(err)});
        port.haltForever();
    };

    verifyToolchainPermissions(space, &plan, stack_base);

    toolchain_space = space;
    toolchain_entry = plan.entry;

    serial.printLine("[VNK] toolchain: /apps/toolchain.elf entry=0x{x} base=0x{x} end=0x{x}, {d} segments, {d} relocation(s)", .{
        plan.entry,
        plan.base,
        plan.end,
        plan.segment_count,
        plan.relocation_count,
    });

    const surface = mapCompositorSurface(space);
    serial.printLine("[VNK] compositor: surface page at 0x{x} R+W+NX, {d}x{d}, process {d}", .{
        surface,
        compositor_abi.surface_width,
        compositor_abi.surface_height,
        space.id,
    });
}

/// Creates the process that runs the client of the compositor.
fn installClientProcess() void {
    if (!enable_user_task) return;

    const window = user_window_base;
    const plan = elf_loader.planFromRamFs(
        "/apps/client.elf",
        &client_image_buffer,
        window,
        window,
        usermode.window_size,
    ) catch |err| {
        serial.printLine("[VNK] FATAL: the client image could not be planned: {s}", .{@errorName(err)});
        port.haltForever();
    };

    const space = paging.createAddressSpace(window) orelse {
        serial.printLine("[VNK] FATAL: the client address space could not be created", .{});
        port.haltForever();
    };

    const stack_base = window + usermode.stack_offset;
    elf_materializer.materialize(
        space,
        &plan,
        client_image_buffer[0..client_app.bytes.len],
        window,
        usermode.window_size,
        stack_base,
        usermode.stack_pages,
    ) catch |err| {
        serial.printLine("[VNK] FATAL: the client image could not be materialized: {s}", .{@errorName(err)});
        port.haltForever();
    };

    verifyClientPermissions(space, &plan, stack_base);

    client_space = space;
    client_entry = plan.entry;

    const contract = mapClientContract(space);
    serial.printLine("[VNK] client: /apps/client.elf entry=0x{x} base=0x{x} end=0x{x}, {d} segments, {d} relocation(s)", .{
        plan.entry,
        plan.base,
        plan.end,
        plan.segment_count,
        plan.relocation_count,
    });
    serial.printLine("[VNK] client: process {d}, contract page at 0x{x} R+NX, compositor={d}, channel={d}", .{
        space.id,
        contract,
        toolchain_space.?.id,
        compositor_abi.channel_id,
    });
}

/// Maps the surface of the compositor below its window and verifies W^X.
fn mapCompositorSurface(space: *paging.AddressSpace) u64 {
    if (user_window_base <= usermode.surface_below) {
        serial.printLine("[VNK] FATAL: there is no room for the compositor surface", .{});
        port.haltForever();
    }

    const address = user_window_base - usermode.surface_below;
    const page = physical.manager.allocate() orelse reportOutOfMemory();
    paging.mapUserPageInFlags(space, address, page, .{
        .writable = true,
        .executable = false,
    }) catch |err| {
        serial.printLine("[VNK] FATAL: the compositor surface could not be mapped: {s}", .{@errorName(err)});
        port.haltForever();
    };

    const saved_cr3 = cpu.readCr3();
    const saved_space = paging.activeSpace();
    paging.activateSpace(space);
    const destination: [*]u8 = @ptrFromInt(@as(usize, @intCast(address)));
    @memset(destination[0..@intCast(paging.page_size)], 0);
    cpu.writeCr3(saved_cr3);
    paging.setActiveSpace(saved_space);

    const permissions = paging.permissionsIn(space, address) orelse {
        serial.printLine("[VNK] FATAL: the compositor surface is not mapped", .{});
        port.haltForever();
    };
    if (!permissions.writable or permissions.executable) {
        serial.printLine("[VNK] FATAL: the compositor surface is not R+W+NX", .{});
        port.haltForever();
    }

    return address;
}

/// Maps the read-only contract of the client below its window.
fn mapClientContract(space: *paging.AddressSpace) u64 {
    if (user_window_base <= usermode.contract_below) {
        serial.printLine("[VNK] FATAL: there is no room for the client contract", .{});
        port.haltForever();
    }

    const presenter = toolchain_space orelse {
        serial.printLine("[VNK] FATAL: the compositor process does not exist", .{});
        port.haltForever();
    };

    const address = user_window_base - usermode.contract_below;
    const page = physical.manager.allocate() orelse reportOutOfMemory();
    paging.mapUserPageInFlags(space, address, page, .{
        .writable = true,
        .executable = false,
    }) catch |err| {
        serial.printLine("[VNK] FATAL: the client contract could not be mapped: {s}", .{@errorName(err)});
        port.haltForever();
    };

    const contract = compositor_abi.Contract{
        .version = compositor_abi.contract_version,
        .compositor_process = presenter.id,
        .channel_id = compositor_abi.channel_id,
        .surface_address = user_window_base - usermode.surface_below,
        .surface_width = compositor_abi.surface_width,
        .surface_height = compositor_abi.surface_height,
        .surface_stride = compositor_abi.surface_stride,
        .surface_bytes = compositor_abi.surface_size,
        .frame_ready_kind = compositor_abi.frame_ready_kind,
    };

    const saved_cr3 = cpu.readCr3();
    const saved_space = paging.activeSpace();
    paging.activateSpace(space);
    const destination: *volatile compositor_abi.Contract =
        @ptrFromInt(@as(usize, @intCast(address)));
    destination.* = contract;
    paging.protectUserPageIn(space, address, .{
        .writable = false,
        .executable = false,
    }) catch |err| {
        serial.printLine("[VNK] FATAL: the client contract could not be protected: {s}", .{@errorName(err)});
        port.haltForever();
    };
    cpu.writeCr3(saved_cr3);
    paging.setActiveSpace(saved_space);

    const permissions = paging.permissionsIn(space, address) orelse {
        serial.printLine("[VNK] FATAL: the client contract is not mapped", .{});
        port.haltForever();
    };
    if (permissions.writable or permissions.executable) {
        serial.printLine("[VNK] FATAL: the client contract is not R+NX", .{});
        port.haltForever();
    }

    return address;
}

/// Verifies W^X for every page that an ELF image uses.
fn verifyImagePermissions(
    space: *paging.AddressSpace,
    plan: *const elf_loader.LoadPlan,
    stack_base: u64,
    label: []const u8,
) void {
    for (plan.segmentList()) |planned_segment| {
        var page = planned_segment.page_start;
        while (page < planned_segment.page_end) : (page += handoff.page_size) {
            const permissions = paging.permissionsIn(space, page) orelse {
                serial.printLine("[VNK] FATAL: a page of the {s} image is not mapped", .{label});
                port.haltForever();
            };
            if (permissions.writable != planned_segment.isWritable() or
                permissions.executable != planned_segment.isExecutable())
            {
                serial.printLine("[VNK] FATAL: a page of the {s} image has the wrong permissions", .{label});
                port.haltForever();
            }
        }
    }

    var page = stack_base;
    const stack_end = stack_base + usermode.stack_pages * handoff.page_size;
    while (page < stack_end) : (page += handoff.page_size) {
        const permissions = paging.permissionsIn(space, page) orelse {
            serial.printLine("[VNK] FATAL: a page of the {s} stack is not mapped", .{label});
            port.haltForever();
        };
        if (!permissions.writable or permissions.executable) {
            serial.printLine("[VNK] FATAL: the {s} stack is not R+W+NX", .{label});
            port.haltForever();
        }
    }

    serial.printLine("[VNK] {s}: page permissions verified", .{label});
}

/// Verifies W^X for every page that the toolchain image uses.
fn verifyToolchainPermissions(
    space: *paging.AddressSpace,
    plan: *const elf_loader.LoadPlan,
    stack_base: u64,
) void {
    verifyImagePermissions(space, plan, stack_base, "toolchain");
}

/// Verifies W^X for every page that the client image uses.
fn verifyClientPermissions(
    space: *paging.AddressSpace,
    plan: *const elf_loader.LoadPlan,
    stack_base: u64,
) void {
    verifyImagePermissions(space, plan, stack_base, "client");
}

/// Reads the page tables of the native process and verifies W^X.
///
/// The materializer asks for the permissions, but the boot does not trust
/// the request: the report reads the entries that the processor will walk.
/// A page of code that is writable, or a page of data that is executable,
/// is a fatal error.
fn verifyNativePermissions(space: *paging.AddressSpace) void {
    const code = paging.permissionsIn(space, user_window_base + native_image.code_virtual_address) orelse {
        serial.printLine("[VNK] FATAL: the code page of the native process is not mapped", .{});
        port.haltForever();
    };
    const data = paging.permissionsIn(space, nativeDataAddress()) orelse {
        serial.printLine("[VNK] FATAL: the data page of the native process is not mapped", .{});
        port.haltForever();
    };
    const stack_low = paging.permissionsIn(space, userStackAddress()) orelse {
        serial.printLine("[VNK] FATAL: the stack of the native process is not mapped", .{});
        port.haltForever();
    };
    const stack_high = paging.permissionsIn(space, userStackAddress() + handoff.page_size) orelse {
        serial.printLine("[VNK] FATAL: the stack of the native process is not mapped", .{});
        port.haltForever();
    };

    if (code.writable or !code.executable) {
        serial.printLine("[VNK] FATAL: the code page is not R+X", .{});
        port.haltForever();
    }
    if (!data.writable or data.executable) {
        serial.printLine("[VNK] FATAL: the data page is not R+W+NX", .{});
        port.haltForever();
    }
    if (!stack_low.writable or stack_low.executable or
        !stack_high.writable or stack_high.executable)
    {
        serial.printLine("[VNK] FATAL: the stack is not R+W+NX", .{});
        port.haltForever();
    }

    serial.printLine("[VNK] native: page permissions verified, code R+X, data and stack R+W+NX", .{});
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
    // The window of the user mode is placed below the **block of two
    // megabytes** that holds the image of the kernel, and not right below
    // the image itself.
    //
    // The reason is the table of the second level of the space of the
    // process: the window needs a table of the first level of its own, and
    // the entry of the second level that holds the window is replaced by
    // that table. The entry covers the whole block of two megabytes, and
    // therefore the pages of the kernel that the block holds would be lost
    // in the space of the process.
    //
    // The block below the block of the kernel holds no page of the kernel,
    // whatever the alignment of the image is: the loader falls back to an
    // address that is aligned to the page when the machine has no region
    // that is aligned to two megabytes, and in that case the block that
    // holds the image also holds the window.
    const kernel_block = boot_info.kernel_base & ~(paging.large_page_size - 1);
    const window = kernel_block - usermode.window_size;
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
    // The pages of the user mode. The page of the program starts writable
    // and **not** executable, because the kernel copies the program into it;
    // it becomes read-only and executable before the task runs. The data
    // and the stack are writable and not executable from the first moment.
    paging.mapUserPageInFlags(space, userCodeAddress(), code_page, .{
        .writable = true,
        .executable = false,
    }) catch |err| {
        serial.printLine("[VNK] FATAL: the page of the program could not be mapped: {s}", .{@errorName(err)});
        port.haltForever();
    };
    paging.mapUserPageInFlags(space, userDataAddress(), data_page, .{
        .writable = true,
        .executable = false,
    }) catch |err| {
        serial.printLine("[VNK] FATAL: the page of data could not be mapped: {s}", .{@errorName(err)});
        port.haltForever();
    };
    paging.mapUserPageInFlags(space, userStackAddress(), user_stack_low, .{
        .writable = true,
        .executable = false,
    }) catch |err| {
        serial.printLine("[VNK] FATAL: the stack could not be mapped: {s}", .{@errorName(err)});
        port.haltForever();
    };
    paging.mapUserPageInFlags(space, userStackAddress() + handoff.page_size, user_stack_high, .{
        .writable = true,
        .executable = false,
    }) catch |err| {
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
    @memset(destination[0..@intCast(paging.page_size)], 0);
    @memcpy(destination[0..program_length], @as([*]const u8, @ptrFromInt(program_start))[0..program_length]);

    // The copy is complete: the page becomes read-only and executable. A
    // page that stayed writable would be a W^X violation that no check of
    // the planner can see, because the planner does not own the mapping.
    paging.protectUserPageIn(space, userCodeAddress(), .{
        .writable = false,
        .executable = true,
    }) catch |err| {
        serial.printLine("[VNK] FATAL: the page of the program could not be protected: {s}", .{@errorName(err)});
        port.haltForever();
    };

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

    _ = scheduler.scheduler.spawn(&workerOne, &task_stacks[1], &kernel_stacks[1], 0);
    _ = scheduler.scheduler.spawn(&workerTwo, &task_stacks[2], &kernel_stacks[2], 0);

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

        // The third process is the one that provokes the page fault, and
        // it exists to prove that an exception of a process does not bring
        // the kernel down.
        const third_task = scheduler.scheduler.spawnUser(
            userCodeAddress(),
            userStackAddress(),
            usermode.stack_pages * handoff.page_size,
            &third_task_stack,
            user_window_base,
            third_space,
            2,
        ) orelse return reportOutOfMemory();
        serial.printLine("[VNK] user: task {d} cs=0x{x} ss=0x{x} rip=0x{x} rsp=0x{x}", .{
            third_task.id,
            third_task.context.cs,
            third_task.context.ss,
            third_task.context.rip,
            third_task.context.rsp,
        });

        // The native task runs the ELF image of the RamFS. Its entry comes
        // from the plan, and the stack lives in the same window as the
        // segments that the materializer mapped.
        const native = scheduler.scheduler.spawnUser(
            native_entry,
            userStackAddress(),
            usermode.stack_pages * handoff.page_size,
            &native_task_stack,
            user_window_base,
            native_space,
            3,
        ) orelse return reportOutOfMemory();
        native_task = native;
        serial.printLine("[VNK] native: task {d} cs=0x{x} ss=0x{x} rip=0x{x} rsp=0x{x}", .{
            native.id,
            native.context.cs,
            native.context.ss,
            native.context.rip,
            native.context.rsp,
        });

        const toolchain = scheduler.scheduler.spawnUser(
            toolchain_entry,
            userStackAddress(),
            usermode.stack_pages * handoff.page_size,
            &toolchain_task_stack,
            user_window_base,
            toolchain_space,
            4,
        ) orelse return reportOutOfMemory();
        toolchain_task = toolchain;
        serial.printLine("[VNK] toolchain: task {d} cs=0x{x} ss=0x{x} rip=0x{x} rsp=0x{x}", .{
            toolchain.id,
            toolchain.context.cs,
            toolchain.context.ss,
            toolchain.context.rip,
            toolchain.context.rsp,
        });

        const client = scheduler.scheduler.spawnUser(
            client_entry,
            userStackAddress(),
            usermode.stack_pages * handoff.page_size,
            &client_task_stack,
            user_window_base,
            client_space,
            5,
        ) orelse return reportOutOfMemory();
        client_task = client;
        serial.printLine("[VNK] client: task {d} cs=0x{x} ss=0x{x} rip=0x{x} rsp=0x{x}", .{
            client.id,
            client.context.cs,
            client.context.ss,
            client.context.rip,
            client.context.rsp,
        });
    }

    serial.printLine("[VNK] tasks: {d} created", .{scheduler.scheduler.count});
}

/// Waits for the task of the user mode and reports what it wrote.
///
/// The two values of the page of data of the user mode prove two different
/// things. The first one proves that the task ran in the third level of
/// Reports the state of the capabilities of the VNC.
///
/// The report verifies four properties of the model, and the four are
/// read from the processes that use the channel:
///
///   * the process that holds **no** capability is refused when it uses a
///     channel, and the refusal is the error of the missing capability;
///   * the process without the capability of an address space is refused
///     when it copies a block into that space;
///   * the delegation of the owner reaches the process that the owner
///     chose, and the process holds the capability of the channel after
///     it;
///   * the revocation of the owner takes the capability back, and the
///     process that answered does not hold it any more.
///
/// The report waits for the processes, because they run at the same time
/// as the kernel and the values appear when they are written.
fn reportCapabilities() void {
    const owner = user_space orelse return;
    const answerer = second_space orelse return;
    const stranger = third_space orelse return;

    // The refusal of the process that holds no capability.
    var attempts: u64 = 0;
    var refused: u64 = 0;
    while (attempts < 10_000_000) : (attempts += 1) {
        refused = userWord(stranger, userCapabilityRefusedAddress());
        if (refused != 0) break;
        cpu.halt();
    }

    const expected = syscall.failure(syscall.Error.not_authorized);
    if (refused == expected) {
        serial.printLine("[VNK] user: the process without the capability was refused with the error {d}", .{
            syscall.Error.not_authorized,
        });
    } else {
        serial.printLine("[VNK] user: the process without the capability was not refused, the result is 0x{x}", .{
            refused,
        });
    }

    // The refusal of the copy into the space of a process without the
    // capability of that space.
    attempts = 0;
    var copy_refused: u64 = 0;
    while (attempts < 10_000_000) : (attempts += 1) {
        copy_refused = userWord(stranger, userCopyRefusedAddress());
        if (copy_refused != 0) break;
        cpu.halt();
    }

    if (copy_refused == expected) {
        serial.printLine("[VNK] user: the copy without the capability of the address space was refused with the error {d}", .{
            syscall.Error.not_authorized,
        });
    } else {
        serial.printLine("[VNK] user: the copy without the capability was not refused, the result is 0x{x}", .{
            copy_refused,
        });
    }

    // The delegation of the owner.
    attempts = 0;
    var granted: u64 = 1;
    while (attempts < 10_000_000) : (attempts += 1) {
        granted = userWord(owner, userCapabilityGrantedAddress());
        if (granted == 0) break;
        cpu.halt();
    }

    if (granted == 0) {
        serial.printLine("[VNK] capabilities: the process {d} holds the capability of the channel 0", .{
            stranger.id,
        });
    } else {
        serial.printLine("[VNK] capabilities: the delegation of the process {d} failed with 0x{x}", .{
            owner.id,
            granted,
        });
    }

    // The revocation of the owner.
    attempts = 0;
    var revoked: u64 = 1;
    while (attempts < 10_000_000) : (attempts += 1) {
        revoked = userWord(owner, userCapabilityRevokedAddress());
        if (revoked == 0) break;
        cpu.halt();
    }

    if (revoked == 0) {
        const holds = capability.holdsSubject(answerer.id, .channel, 0, capability.Rights.use);
        if (holds) {
            serial.printLine("[VNK] capabilities: the process {d} still holds the capability of the channel 0", .{
                answerer.id,
            });
        } else {
            serial.printLine("[VNK] capabilities: the process {d} does not hold the capability of the channel 0 any more", .{
                answerer.id,
            });
        }
    } else {
        serial.printLine("[VNK] capabilities: the revocation of the process {d} failed with 0x{x}", .{
            owner.id,
            revoked,
        });
    }

    // The delegation of the capability of the address space through the
    // calls. The owner lends the space of the process that answers to the
    // third process and takes it back; the two results and the final state
    // of the set prove that the calls carry the kind of the capability.
    attempts = 0;
    var process_revoked: u64 = 1;
    while (attempts < 10_000_000) : (attempts += 1) {
        process_revoked = userWord(owner, userProcessRevokedAddress());
        if (process_revoked == 0) break;
        cpu.halt();
    }

    const process_granted = userWord(owner, userProcessGrantedAddress());
    const process_holds = capability.holdsSubject(
        stranger.id,
        .process,
        answerer.id,
        capability.Rights.write,
    );

    if (process_granted == 0 and process_revoked == 0 and !process_holds) {
        serial.printLine("[VNK] capabilities: the calls delegated the address space of the process {d} to the process {d} and took it back", .{
            answerer.id,
            stranger.id,
        });
    } else {
        serial.printLine("[VNK] capabilities: the delegation of the address space through the calls failed: 0x{x} 0x{x}", .{
            process_granted,
            process_revoked,
        });
    }

    // The refusals of the calls that carry the kind of the capability. The
    // values are written by the third process, which holds no capability:
    // the refusal has to come from the kind and from the rights, and not
    // from the missing capability.
    attempts = 0;
    var kind_refused: u64 = 0;
    while (attempts < 10_000_000) : (attempts += 1) {
        kind_refused = userWord(stranger, userKindRefusedAddress());
        if (kind_refused != 0) break;
        cpu.halt();
    }

    attempts = 0;
    var rights_refused: u64 = 0;
    while (attempts < 10_000_000) : (attempts += 1) {
        rights_refused = userWord(stranger, userRightsRefusedAddress());
        if (rights_refused != 0) break;
        cpu.halt();
    }

    if (kind_refused == syscall.failure(syscall.Error.unknown_kind)) {
        serial.printLine("[VNK] user: the grant with an unknown kind was refused with the error {d}", .{
            syscall.Error.unknown_kind,
        });
    } else {
        serial.printLine("[VNK] user: the grant with an unknown kind was not refused, the result is 0x{x}", .{
            kind_refused,
        });
    }

    if (rights_refused == syscall.failure(syscall.Error.invalid_rights)) {
        serial.printLine("[VNK] user: the grant with the rights of another kind was refused with the error {d}", .{
            syscall.Error.invalid_rights,
        });
    } else {
        serial.printLine("[VNK] user: the grant with the rights of another kind was not refused, the result is 0x{x}", .{
            rights_refused,
        });
    }

    // F6.28: the third process holds no display capability. The
    // presentation call has to answer with the error of the missing
    // capability, even though the request address and length are invalid:
    // the capability check comes before the request is read.
    attempts = 0;
    var present_refused: u64 = 0;
    while (attempts < 10_000_000) : (attempts += 1) {
        present_refused = userWord(stranger, userPresentRefusedAddress());
        if (present_refused != 0) break;
        cpu.halt();
    }

    if (present_refused == expected) {
        serial.printLine("[VNK] user: the presentation without the display capability was refused with the error {d}", .{
            syscall.Error.not_authorized,
        });
    } else {
        serial.printLine("[VNK] user: the presentation without the display capability was not refused, the result is 0x{x}", .{
            present_refused,
        });
    }

    // The input call of the same process: the capability is checked before
    // the output range and before an event is popped.
    attempts = 0;
    var input_refused: u64 = 0;
    while (attempts < 10_000_000) : (attempts += 1) {
        input_refused = userWord(stranger, userInputRefusedAddress());
        if (input_refused != 0) break;
        cpu.halt();
    }

    if (input_refused == expected) {
        serial.printLine("[VNK] user: the input without the input capability was refused with the error {d}", .{
            syscall.Error.not_authorized,
        });
    } else {
        serial.printLine("[VNK] user: the input without the input capability was not refused, the result is 0x{x}", .{
            input_refused,
        });
    }

    // The wait with a timeout. The process that answers waits for a
    // message of the channel 1 that nobody sends, and the timer expires
    // the wait. The result proves that the call answered with the error of
    // the timeout, and the counter of the queue proves that the wait was
    // removed from the queue by the timer.
    attempts = 0;
    var timed_out: u64 = 0;
    while (attempts < 10_000_000) : (attempts += 1) {
        timed_out = userWord(answerer, userTimeoutAddress());
        if (timed_out != 0) break;
        cpu.halt();
    }

    if (timed_out == syscall.failure(syscall.Error.timeout)) {
        serial.printLine("[VNK] user: the wait with a timeout expired with the error {d}", .{
            syscall.Error.timeout,
        });
    } else {
        serial.printLine("[VNK] user: the wait with a timeout answered 0x{x}, expected 0x{x}", .{
            timed_out,
            syscall.failure(syscall.Error.timeout),
        });
    }

    const expired = syscall.channelExpirations(1, syscall.Side.user);
    serial.printLine("[VNK] channel: {d} waits expired with the timeout", .{expired});
}

/// Waits for the task of the user mode and reports what it wrote.
///
/// The values of the page of data of the user mode prove, among other
/// things, that the task ran in the third level of privilege with access
/// to its own pages, and that the call reached the handler of the kernel
/// and the answer came back to the user mode.
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

    // The channel: the process of role zero sends a message, and the
    // process of role one answers it. The value in the page of data of the
    // process of role zero proves that the message came back through the
    // channel, and the latency that the channel reports is the interval
    // between the message leaving and the message arriving, and not the
    // wait of the scheduler.
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

    const latency = syscall.channelDeliveryLatency(0, syscall.Side.user);
    if (latency == 0) {
        serial.printLine("[VNK] channel: the latency of the delivery was not measured", .{});
    } else {
        serial.printLine("[VNK] channel: the message arrived in {d} cycles", .{latency});
    }

    // The delivery to a task that was waiting is what proves that the
    // blocking works: the task was waiting, and the message woke it up.
    const deliveries = syscall.channelDeliveries(0, syscall.Side.user);
    serial.printLine("[VNK] channel: {d} deliveries to a task that was waiting", .{deliveries});

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

    // The copy between the two processes: the process of role zero copied
    // a block of its page into the page of the process of role one. The
    // page of the process of role zero has to keep the original block, and
    // the page of the process of role one has the copied block.
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

/// Reports that the native ELF image ran and terminated.
///
/// The report waits for two independent facts: the marker that the program
/// wrote in its own data page, which proves that the user code executed,
/// and the state of the task, which proves that the call of exit reached
/// the scheduler. A task that wrote the marker and did not terminate is a
/// failure, and the boot test refuses to pass.
fn reportNativeTask() void {
    const space = native_space orelse {
        serial.printLine("[VNK] native: the process does not exist", .{});
        return;
    };
    const task = native_task orelse {
        serial.printLine("[VNK] native: the task does not exist", .{});
        return;
    };

    var attempts: u64 = 0;
    var marker: u64 = 0;
    while (attempts < 10_000_000) : (attempts += 1) {
        marker = userWord(space, nativeMarkerAddress());
        if (marker == native_image.marker and task.state == .terminated) break;
        cpu.halt();
    }

    if (marker != native_image.marker) {
        serial.printLine("[VNK] native: the data page holds 0x{x}, expected 0x{x}", .{
            marker,
            native_image.marker,
        });
    } else {
        serial.printLine("[VNK] native: the ELF task wrote 0x{x} in its data page", .{marker});
    }

    // A realocação relativa vale `load_bias + addend`; com o addend zero do
    // arquivo, o alvo tem de conter a base da janela. O valor foi escrito
    // pelo materializador, e não pelo programa.
    const relocated = userWord(space, nativeRelocationAddress());
    if (relocated != user_window_base) {
        serial.printLine("[VNK] native: the relocation holds 0x{x}, expected 0x{x}", .{
            relocated,
            user_window_base,
        });
    } else {
        serial.printLine("[VNK] native: the relative relocation holds the load bias 0x{x}", .{relocated});
    }

    if (task.state != .terminated) {
        serial.printLine("[VNK] native: the task did not terminate", .{});
    } else if (task.exit_code != 0) {
        serial.printLine("[VNK] native: the task terminated with code 0x{x}", .{task.exit_code});
    } else {
        serial.printLine("[VNK] native: the ELF task terminated with code 0", .{});
    }

    if (marker == native_image.marker and task.state == .terminated and task.exit_code == 0 and
        relocated == user_window_base)
    {
        serial.printLine("[VNK] native: /apps/hello.elf ran from the RamFS", .{});
    }
}

/// Reports that the application produced by the toolchain ran.
fn reportToolchainTask() void {
    const task = toolchain_task orelse {
        serial.printLine("[VNK] toolchain: the task does not exist", .{});
        return;
    };

    var attempts: u64 = 0;
    while (attempts < 10_000_000) : (attempts += 1) {
        if (task.state == .terminated) break;
        cpu.halt();
    }

    if (task.state != .terminated) {
        serial.printLine("[VNK] toolchain: the task did not terminate", .{});
    } else if (task.exit_code != 0) {
        serial.printLine("[VNK] toolchain: the task terminated with code 0x{x}", .{task.exit_code});
    } else {
        serial.printLine("[VNK] toolchain: /apps/toolchain.elf ran from the toolchain", .{});
    }
}

/// Reports that the client of the compositor ran.
fn reportClientTask() void {
    const task = client_task orelse {
        serial.printLine("[VNK] client: the task does not exist", .{});
        return;
    };

    var attempts: u64 = 0;
    while (attempts < 10_000_000) : (attempts += 1) {
        if (task.state == .terminated) break;
        cpu.halt();
    }

    if (task.state != .terminated) {
        serial.printLine("[VNK] client: the task did not terminate", .{});
    } else if (task.exit_code != 0) {
        serial.printLine("[VNK] client: the task terminated with code 0x{x}", .{task.exit_code});
    } else {
        serial.printLine("[VNK] client: /apps/client.elf ran from the toolchain", .{});
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

/// Baseline for a real exit/fault cleanup probe in QEMU.
var lifecycle_blocks_before: usize = 0;
var lifecycle_inodes_before: usize = 0;
var lifecycle_probe_ready: bool = false;

fn prepareFsLifecycleProbe() void {
    const normal = native_space orelse return;
    const fault = client_space orelse return;
    lifecycle_blocks_before = fs.freeBlockCount();
    lifecycle_inodes_before = fs.freeInodeCount();
    const normal_fd = fs.create(normal.id, "/apps/lifecycle-normal.tmp", 0o600) catch |err| {
        serial.printLine("[VNK] FATAL: lifecycle normal create: {s}", .{@errorName(err)});
        port.haltForever();
    };
    _ = fs.write(normal.id, normal_fd, "normal") catch |err| {
        serial.printLine("[VNK] FATAL: lifecycle normal write: {s}", .{@errorName(err)});
        port.haltForever();
    };
    fs.unlink("/apps/lifecycle-normal.tmp") catch unreachable;

    const fault_fd = fs.create(fault.id, "/apps/lifecycle-fault.tmp", 0o600) catch |err| {
        serial.printLine("[VNK] FATAL: lifecycle fault create: {s}", .{@errorName(err)});
        port.haltForever();
    };
    _ = fs.write(fault.id, fault_fd, "fault") catch |err| {
        serial.printLine("[VNK] FATAL: lifecycle fault write: {s}", .{@errorName(err)});
        port.haltForever();
    };
    fs.unlink("/apps/lifecycle-fault.tmp") catch unreachable;
    lifecycle_probe_ready = true;
}

fn verifyFsLifecycleProbe() void {
    if (!lifecycle_probe_ready) return;

    // The ring-3 truncate integration probe intentionally creates a persistent
    // file after the lifecycle baseline. Remove only that known test artifact
    // after the native task exits, before comparing resource counters.
    // Unexpected files or leaked descriptors still fail the strict baseline.
    fs.unlink("/apps/truncate-probe.txt") catch |err| {
        serial.printLine("[VNK] FATAL: truncate probe cleanup: {s}", .{@errorName(err)});
        port.haltForever();
    };
    if (fs.freeBlockCount() != lifecycle_blocks_before or
        fs.freeInodeCount() != lifecycle_inodes_before)
    {
        serial.printLine("[VNK] FATAL: fs lifecycle descriptors were not reclaimed", .{});
        port.haltForever();
    }
    serial.printLine("[VNK] fs: lifecycle cleanup normal exit and user fault ok", .{});
}

/// Reports the state of the scheduler and the cost of the switches.
fn reportScheduler() void {
    const statistics = scheduler.scheduler.statisticsOf();

    const average = if (statistics.switches != 0)
        statistics.switch_cycles / statistics.switches
    else
        0;

    serial.printLine("[VNK] tasks: {d} ready, {d} blocked, {d} ticks, {d} switches", .{
        statistics.ready,
        statistics.blocked,
        statistics.ticks,
        statistics.switches,
    });
    serial.printLine("[VNK] tasks: {d} blocks, {d} killed, switch cost {d} cycles average, {d} minimum, {d} last", .{
        statistics.blocks,
        statistics.killed,
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
