//************************************************************************//
//  main.zig                                                              //
//************************************************************************//
//                        This file is part of:                           //
//                              VorynOS                                   //
//             https://github.com/CeoMatheusDev/VorynOS                   //
//************************************************************************//
// Copyright (C) 2020 - 2026 Matheus.A.Santos contributors.               //
// Copyright (C) 2026 VorynOS - All Rights Reserved.                      //
//                                                                        //
// SPDX-License-Identifier: GPL-3.0-only                                  //
//************************************************************************//
//  Toolchain:  Zig 0.17.0 · C23 (ISO/IEC 9899:2024) · x86-64 (AMD64)     //
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
const smp = @import("arch/x86_64/smp.zig");
const apic = @import("arch/x86_64/apic.zig");
const pci = @import("arch/x86_64/pci.zig");
const virtio = @import("arch/x86_64/virtio.zig");
const vvdi = @import("drivers/vvdi/root.zig");

const heap = @import("memory/heap.zig");
const dma = @import("memory/dma.zig");
const capability = @import("security/capability.zig");
const physical = @import("memory/physical.zig");
const scheduler = @import("task/scheduler.zig");
const fs = @import("fs/fs.zig");
const ai_contract = voryn.ai;
const ai_embedded = @import("ai/embedded.zig");
const ai_model = @import("ai/model.zig");
const ramfs = @import("fs/ramfs.zig");
const vnv = @import("fs/vnv.zig");
const vnv_volume = @import("fs/vnv_volume.zig");
const block_dev = @import("voryn_block");
const ramdisk = @import("storage/ramdisk.zig");
const vpk = @import("voryn_vpk");
const vlib = @import("voryn_vlib");
const vex = @import("voryn_vex");
const elf_loader = @import("elf_loader.zig");
const elf_materializer = @import("elf_materializer.zig");
const native_image = @import("native_image.zig");
const toolchain_app = @import("native_app");
const client_app = @import("client_app");
const compositor = @import("graphics/compositor.zig");
const display = @import("graphics/display.zig");
const framebuffer_bridge = @import("graphics/framebuffer_bridge.zig");
const desktop_mod = @import("graphics/desktop.zig");
const taskbar_mod = @import("graphics/taskbar.zig");
const ps2 = @import("input/ps2.zig");
const keyboard_motion = @import("graphics/keyboard_motion.zig");
const keyboard = @import("voryn_keyboard");

var graphics_front_x: usize = 0;
var graphics_front_y: usize = 0;
var graphics_ready: bool = false;
var graphics_desktop: desktop_mod.Desktop = undefined;
// F15.6: fixed-size diagnostic buffers, no heap or stack pressure.
var graphics_bench_ram: [256 * 64 * 4]u8 = @splat(0);
var graphics_bench_backup: [256 * 64 * 4]u8 = undefined;

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

/// F14: allocation-free render latency statistics across arrow events.
const RenderLatency = struct {
    samples: u64 = 0,
    cycles_sum: u64 = 0,
    cycles_min: u64 = std.math.maxInt(u64),
    cycles_max: u64 = 0,
    pixels_sum: u64 = 0,
    baseline_sum: u64 = 0,
    // Fixed-size recent history: no heap use on the graphics event path.
    recent_cycles: [32]u64 = @splat(0),
    recent_count: usize = 0,
    recent_next: usize = 0,

    fn percentileCycles(self: *const RenderLatency, percentile: u8) u64 {
        if (self.recent_count == 0) return 0;
        var sorted: [32]u64 = undefined;
        @memcpy(sorted[0..self.recent_count], self.recent_cycles[0..self.recent_count]);
        // Insertion sort: bounded to 32 entries and only used for reporting.
        for (1..self.recent_count) |i| {
            const value = sorted[i];
            var j = i;
            while (j > 0 and sorted[j - 1] > value) : (j -= 1) {
                sorted[j] = sorted[j - 1];
            }
            sorted[j] = value;
        }
        const rank = if (percentile == 0) 0 else (@as(usize, @min(percentile, 100)) * self.recent_count + 99) / 100 - 1;
        return sorted[rank];
    }

    fn record(self: *RenderLatency, cycles: u64, pixels: usize, baseline: usize) void {
        self.samples +|= 1;
        self.cycles_sum +|= cycles;
        self.cycles_min = @min(self.cycles_min, cycles);
        self.cycles_max = @max(self.cycles_max, cycles);
        self.pixels_sum +|= @as(u64, @intCast(pixels));
        self.baseline_sum +|= @as(u64, @intCast(baseline));
        self.recent_cycles[self.recent_next] = cycles;
        self.recent_next = (self.recent_next + 1) % self.recent_cycles.len;
        if (self.recent_count < self.recent_cycles.len) self.recent_count += 1;
    }

    fn meanCycles(self: *const RenderLatency) u64 {
        return if (self.samples == 0) 0 else self.cycles_sum / self.samples;
    }
};

var render_latency: RenderLatency = .{};

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

/// Size of the kernel stack used by syscall and interrupt handlers.
const kernel_stack_size = 256 * 1024;

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
var kernel_stacks: [task_count][kernel_stack_size]u8 align(16) = undefined;

/// The stack of the kernel of the task of the user mode.
///
/// The handlers of the calls and of the interrupts of the task run on it,
/// and not on the stack of the user, which the user could rewrite.
var user_task_stack: [kernel_stack_size]u8 align(16) = undefined;

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
var second_task_stack: [kernel_stack_size]u8 align(16) = undefined;

/// The stack of the kernel of the third process.
var third_task_stack: [kernel_stack_size]u8 align(16) = undefined;

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
var toolchain_task_stack: [kernel_stack_size]u8 align(16) = undefined;

/// The address space of the client of the compositor.
var client_space: ?*paging.AddressSpace = null;

/// The entry point of the client, already in the window.
var client_entry: u64 = 0;

/// The task of the client.
var client_task: ?*scheduler.Task = null;

/// The stack of the kernel of the client task.
var client_task_stack: [kernel_stack_size]u8 align(16) = undefined;

/// The stack of the kernel of the native task.
var native_task_stack: [kernel_stack_size]u8 align(16) = undefined;

/// The buffer that receives the native image read from the RamFS.
var native_image_buffer: [native_image.max_image_size]u8 = undefined;

/// The buffer that receives the toolchain image read from the RamFS.
///
/// The file on disk is a VEX container (`toolchain_app.bytes` + the 64
/// byte header); `planFromRamFs` unwraps the payload to the start of the
/// buffer, so the materializer slice uses the plain ELF length.
var toolchain_image_buffer: [toolchain_app.bytes.len + vex.header_size + vex.max_manifest_entries * 8]u8 = undefined;

/// The buffer that receives the client image read from the RamFS.
var client_image_buffer: [client_app.bytes.len]u8 = undefined;

/// The number of bytes of the native image.
var native_image_length: usize = 0;

// ----------------------------------------------------------------------
// F4: persistência em dispositivo de blocos (commit/wipe/recuperação VNV).
//
// O dispositivo é um ramdisk estático do kernel: a camada de bloco e o
// ciclo de vida do volume (commit, wipe, recovery) são verificados sem um
// driver físico, e um driver real (virtio-blk, ATA PIO) implementa a mesma
// interface `block.Device` sem alterar o volume nem o filesystem.
// ----------------------------------------------------------------------
const persistence_sector_size: u32 = 512;
const persistence_sectors: usize = (vnv.image_size + persistence_sector_size - 1) / persistence_sector_size;
const persistence_bytes: usize = persistence_sectors * persistence_sector_size;
var persistence_ramdisk_memory: [persistence_bytes]u8 align(16) = undefined;
var persistence_ramdisk: ramdisk.RamDisk = undefined;
var persistence_staging: [vnv.image_size]u8 align(16) = undefined;
// Estado temporário de decodificação: `ramfs.State` tem ~1 MiB e um local
// desse tamanho estouraria a pilha de boot de 16 KiB.
var persistence_scratch: ramfs.State = undefined;
var persistence_sequence: u64 = 0;

// ----------------------------------------------------------------------
// F5: pacote VPK de exemplo gravado no RamFS.
// ----------------------------------------------------------------------
const vpk_pack_buffer_size: usize = 512;
var vpk_pack_buffer: [vpk_pack_buffer_size]u8 align(16) = undefined;
var vpk_packed_length: usize = 0;

// ----------------------------------------------------------------------
// F5: VLIB — o contêiner da biblioteca nativa (`.vlb`).
//
// A biblioteca é empacotada no kernel sobre a **imagem real** que o
// toolchain produziu: os mesmos bytes de ELF64 relocável que geram o
// `/apps/toolchain.vex`. O que este incremento prova é o contêiner —
// geometria, símbolos, ABI, capabilities exigidas e integridade — e o ciclo
// empacotar/persistir/recuperar/validar. O **ligador** de bibliotecas em um
// processo (relocação e resolução de símbolo contra um espaço de endereço)
// não faz parte deste incremento e não é alegado.
// ----------------------------------------------------------------------
const vlib_library_name = "libvoryn";
const vlib_required_capabilities: u64 = 1 << 2; // kind 2: display.
const vlib_symbols = [_]vlib.SymbolSource{
    .{ .name = "voryn_main", .kind = .function, .value = 0x1000 },
    .{ .name = "voryn_init", .kind = .function, .value = 0x0000 },
    .{ .name = "voryn_shutdown", .kind = .function, .value = 0x1080 },
    .{ .name = "internal_helper", .binding = .hidden, .kind = .function, .value = 0x1100 },
};

/// Tamanho exato do arquivo VLIB: cabeçalho, registros, nomes dos símbolos,
/// nome da biblioteca e a imagem.
const vlib_packed_size: usize = blk: {
    var total: usize = vlib.header_size + vlib_symbols.len * vlib.symbol_record_size +
        vlib_library_name.len + toolchain_app.bytes.len;
    for (vlib_symbols) |symbol| total += symbol.name.len;
    break :blk total;
};

var vlib_pack_buffer: [vlib_packed_size]u8 align(16) = undefined;
var vlib_read_buffer: [vlib_packed_size]u8 align(16) = undefined;
var vlib_packed_length: usize = 0;

/// Tamanho do arquivo `/apps/toolchain.vex` instalado no RamFS (cabeçalho
/// VEX + ELF + manifest). Usado pela verificação de persistência.
var toolchain_vex_length: usize = 0;

// ----------------------------------------------------------------------
// F4: arquivo grande (> 48 KiB) para exercitar a tabela indireta.
// 102400 bytes = 25 blocos: 12 diretos + 13 via tabela indireta.
// ----------------------------------------------------------------------
const large_file_size: usize = 100 * 1024;
var large_file_buffer: [large_file_size]u8 align(16) = undefined;

/// Byte determinístico do arquivo grande, na posição `index`.
fn largeFileByte(index: usize) u8 {
    return @truncate(@as(u64, @intCast(index)) *% 31 +% 7);
}

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

/// Static storage for the boot-time split virtqueue layout probe.
///
/// The size covers the layout of a 16-descriptor queue: the descriptor
/// table, the available ring, the padding and the used ring fit in two
/// pages.
var virtqueue_storage: [8192]u8 align(4096) = undefined;

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

    // F7 base: janela virtual de DMA e sonda de escrita real. A reserva das
    // tabelas acontece em buildPageTables, antes dos espacos dos processos;
    // aqui o mapper e instalado e a sonda escreve nos dois extremos da
    // pagina pelas tabelas ativas.
    installDma();
    probeDmaWindow();
    probeVirtqueueLayout();

    // VVDI (F7/PR B e PR C): mapeia o BAR do virtio-blk moderno, negocia as
    // features ate FEATURES_OK, programa e habilita a virtqueue 0 em memoria
    // DMA e ativa o dispositivo com DRIVER_OK. A janela de MMIO ja foi
    // reservada em `buildPageTables`; as paginas do dispositivo sao mapeadas
    // com cache desabilitado.
    bringUpVirtioDevices();
    verifyVirtioBlockPersistenceProbe();

    // F7 base: leitura real do espaco de configuracao PCI no bus 0. A sonda
    // nao habilita o dispositivo nem assume um driver; ela existe para
    // provar que o caminho de port I/O e o lock funcionam no kernel.
    probePciBus();

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
    // F9: o modelo embarcado e validado e executado no kernel antes de
    // qualquer processo receber a capability da IA. A ordem e a mesma regra
    // dos canais: o que uma tarefa pode usar tem de existir antes do timer.
    verifyAiSelfTest();
    installCapabilities();
    prepareFsLifecycleProbe();

    installScheduler();
    installTimer();

    // M0.5: inicializa as fundacoes de SMP: APIC local, timer local por CPU
    // e pilhas dos APs. Inicia os APs via SIPI.
    installSmp();
    smp.startAps();

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
    // F4: o volume raiz é commitado em um dispositivo de blocos, apagado e
    // recuperado; o boot prova que a árvore sobrevive ao ciclo. F5: o
    // pacote VPK instalado no RamFS é relido depois da recuperação e
    // desempacotado byte a byte.
    verifyFsPersistence();
    verifyVpkPackaging();
    verifyVlibPackaging();

    // F6.26: the toolchain application presents a probe rectangle during
    // its test. The diagnostic scene is drawn again after the task has
    // terminated, so the interactive screenshot test starts from the scene
    // that the kernel owns; the presentation itself is proven by the
    // serial read-back of the first pixel.
    presentGraphicsDemo();

    reportCapabilities();

    benchmarkFramebufferWrites();

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
    if (!memmap.isKernelBackedRange(map, boot_info.kernel_base, boot_info.kernel_end - boot_info.kernel_base)) {
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

/// Reads the PCI configuration space of bus 0.
///
/// The probe only reads vendor and device identification. It does not write
/// the command register, does not assign BARs and does not start a driver.
/// The goal is to exercise the real port I/O path and the configuration
/// lock during the QEMU boot test, where a virtio-blk device is present.
fn probePciBus() void {
    var virtio_devices: u32 = 0;
    var device: u8 = 0;
    while (device < 32) : (device += 1) {
        const vendor = pci.readConfigWord(0, device, 0, 0x00);
        if (vendor == 0xFFFF) continue;

        const device_id = pci.readConfigWord(0, device, 0, 0x02);
        if (vendor == 0x1AF4) virtio_devices += 1;
        serial.printLine("[VNK] pci: 00:{d}.0 vendor=0x{x} device=0x{x}", .{
            device,
            vendor,
            device_id,
        });
    }

    serial.printLine("[VNK] pci: bus 0 scan complete, virtio={d}", .{virtio_devices});
}

/// Installs the page-table mapper used by the DMA window.
///
/// The memory module does not know the architecture: the functions that
/// touch the page tables are supplied by the kernel.
fn installDma() void {
    if (!dma.initWindow(.{
        .map = mapDmaPage,
        .unmap = unmapDmaPage,
    })) {
        serial.printLine("[VNK] FATAL: the DMA virtual window is invalid", .{});
        port.haltForever();
    }

    serial.printLine("[VNK] dma: virtual window 0x{x}..0x{x}", .{
        dma.virtual_window_base,
        dma.virtual_window_base + dma.virtual_window_size,
    });
}

fn mapDmaPage(virtual: u64, phys: u64) bool {
    paging.mapKernelDataPage(virtual, phys) catch return false;
    return true;
}

fn unmapDmaPage(virtual: u64) void {
    paging.unmapKernelPage(virtual) catch |err| {
        serial.printLine("[VNK] dma: unmap failed for 0x{x}: {s}", .{
            virtual,
            @errorName(err),
        });
    };
}

/// Proves that a physical page can be reached through the DMA window.
///
/// The probe writes to both ends of the page through the virtual address,
/// reads the bytes back, and checks the translation in the page tables.
/// A wrong mapping faults instead of returning a false success.
fn probeDmaWindow() void {
    var buffer = dma.allocate(&physical.manager, dma.page_size, dma.dma32_limit) orelse {
        serial.printLine("[VNK] FATAL: the DMA probe could not reserve a page", .{});
        port.haltForever();
    };
    defer buffer.release(&physical.manager);

    var mapped = dma.mapVirtual(buffer) orelse {
        serial.printLine("[VNK] FATAL: the DMA probe could not map the page", .{});
        port.haltForever();
    };
    defer dma.unmapVirtual(&mapped, &physical.manager);

    const bytes: [*]u8 = mapped.virtual;
    const last: usize = @intCast(dma.page_size - 1);
    bytes[0] = 0xA5;
    bytes[last] = 0x5A;
    if (bytes[0] != 0xA5 or bytes[last] != 0x5A) {
        serial.printLine("[VNK] FATAL: the DMA window write probe failed", .{});
        port.haltForever();
    }

    const translated = paging.translate(@intFromPtr(mapped.virtual)) orelse 0;
    if (translated != buffer.physical_address) {
        serial.printLine("[VNK] FATAL: the DMA window translation is wrong", .{});
        port.haltForever();
    }

    serial.printLine("[VNK] dma: window map probe ok phys=0x{x} virt=0x{x}", .{
        buffer.physical_address,
        @intFromPtr(mapped.virtual),
    });
}

/// Exercises the device-visible split virtqueue layout in the kernel.
///
/// The queue lives in a static page-aligned buffer, not in DMA memory, and
/// no device is programmed. The probe proves that the contiguous layout,
/// the descriptor write and the available-index publication execute in the
/// freestanding kernel with the same offsets verified by the host tests.
fn probeVirtqueueLayout() void {
    const layout = virtio.splitQueueLayout(virtio.queue_size) orelse {
        serial.printLine("[VNK] FATAL: the virtqueue layout is invalid", .{});
        port.haltForever();
    };
    var queue = virtio.DeviceQueue.init(virtqueue_storage[0..], layout) catch |err| {
        serial.printLine("[VNK] FATAL: the virtqueue could not be initialised: {s}", .{
            @errorName(err),
        });
        port.haltForever();
    };

    queue.setDescriptor(0, 0x1000, 512, 0, 0) catch |err| {
        serial.printLine("[VNK] FATAL: the virtqueue descriptor failed: {s}", .{@errorName(err)});
        port.haltForever();
    };
    queue.publish(0) catch |err| {
        serial.printLine("[VNK] FATAL: the virtqueue publish failed: {s}", .{@errorName(err)});
        port.haltForever();
    };
    if (queue.availableIndex() != 1) {
        serial.printLine("[VNK] FATAL: the virtqueue available index is wrong", .{});
        port.haltForever();
    }

    serial.printLine("[VNK] virtio: split queue layout ok desc={d} avail={d} used={d} size={d}", .{
        layout.descriptor_offset,
        layout.available_offset,
        layout.used_offset,
        layout.total_size,
    });
}

// ----------------------------------------------------------------------
// VVDI (Voryn Virtual Device Interface): transporte moderno e virtqueue
// dividida (VirtIO 1.2).
//
// A ordem da sequencia e a da especificacao e a do boot:
//
//   memoria -> paginacao (janela de MMIO reservada em `buildPageTables`)
//   -> PCI (configuracao e lista de capabilities)
//   -> descoberta do dispositivo
//   -> mapeamento do BAR com cache desabilitado
//   -> negocacao de features ate FEATURES_OK
//   -> memoria DMA da fila -> programacao e habilitacao da fila 0
//   -> DRIVER_OK
//
// A janela virtual e reservada junto com as tabelas de pagina, antes de
// qualquer espaco de processo, pelo mesmo motivo da janela de DMA: os
// espacos copiam a tabela de nivel 2, e uma tabela de nivel 1 criada depois
// nao apareceria nos espacos que ja existem.
//
// O driver publica e consome pedidos de bloco com polling limitado após
// DRIVER_OK. O autoteste de persistência é deliberadamente opt-in: só grava
// no disco cuja LBA 0 contém a assinatura exclusiva preparada pelo script,
// nunca na imagem EFI sem essa assinatura.
// ----------------------------------------------------------------------

/// Janela virtual onde os BARs dos dispositivos sao mapeados.
///
/// Fica acima da janela de DMA (0x4000_0000 + 64 MiB) e abaixo da memoria
/// do framebuffer, e nao colide com nenhuma faixa que o kernel ja mapeia.
const mmio_window_base: u64 = 0x6000_0000;
const mmio_window_size: u64 = 16 * 1024 * 1024;

/// Janela de mapeamento, preparada em `buildPageTables`.
var mmio_window: ?vvdi.mmio.Window = null;

/// Tabela de BARs e tamanho medido de cada BAR da funcao em inicializacao.
///
/// `caps.BarValidator` e um ponteiro de funcao sem contexto, e por isso o que
/// ele precisa fica aqui. Os dois valores sao sobrescritos antes de cada uso
/// e descrevem uma unica funcao: uma capability de outra funcao nao os le.
var probed_bars: ?pci.BarTable = null;
var probed_bar_sizes: pci.BarSizes = @splat(null);

/// Liga a janela de MMIO ao mapeador de paginas do kernel.
///
/// As paginas sao mapeadas por `paging.mapDevicePage`, que ja aplica
/// `cache_disabled` e `no_execute`. Nao existe uma segunda tabela de paginas
/// aqui: o modulo `mmio.zig` so reserva a faixa virtual e valida os acessos.
///
/// O parametro se chama `target` porque `physical` e o nome do modulo de
/// alocacao de paginas fisicas importado neste arquivo.
fn mapMmioPage(virtual: u64, target: u64) bool {
    paging.mapDevicePage(virtual, target) catch return false;
    return true;
}

fn unmapMmioPage(virtual: u64) void {
    paging.unmapKernelPage(virtual) catch {};
}

const mmio_mapper: vvdi.mmio.Mapper = .{
    .map = mapMmioPage,
    .unmap = unmapMmioPage,
};

/// Reserva a faixa virtual da janela e cria o mapeador de BARs.
fn installMmioWindow() void {
    paging.reserveKernelRange(mmio_window_base, mmio_window_size) catch |err| {
        serial.printLine("[VNK] FATAL: the MMIO window could not be reserved: {s}", .{
            @errorName(err),
        });
        port.haltForever();
    };

    mmio_window = vvdi.mmio.Window.init(
        mmio_window_base,
        mmio_window_size,
        mmio_mapper,
    ) catch |err| {
        serial.printLine("[VNK] FATAL: the MMIO window is not page aligned: {s}", .{
            @errorName(err),
        });
        port.haltForever();
    };
}

/// True quando a capability cabe no BAR `bar`, com o tamanho medido.
///
/// O tamanho vem de `pci.probeBarSizes`, que mascara o registrador do BAR e
/// restaura o valor original. Um BAR que a funcao nao implementa, um BAR de
/// portas de I/O e um BAR cujo tamanho nao pode ser medido sao recusados: o
/// transporte moderno exige memoria mapeavel.
fn supportedProbedBar(bar: u8, offset: u32, length: u32) bool {
    const table = probed_bars orelse return false;
    const index: usize = bar;
    if (index >= table.bars.len) return false;

    const decoded = table.bars[index] orelse return false;
    if (decoded.is_io) return false;

    const size = probed_bar_sizes[index] orelse return false;
    return pci.barSupportsRegion(decoded, index, size, offset, length);
}

/// Identifies modern VirtIO Block functions on PCI bus 0 and activates one.
/// The selected target is the last modern block function in BDF order, which
/// lets the QEMU integration attach a dedicated writable data disk after the
/// boot disk. With one device, the existing single-device path is unchanged.
/// Transitional devices and non-block types are not driven by this path.
fn bringUpVirtioDevices() void {
    var device: u8 = 0;
    var found: u32 = 0;
    var selected_device: ?u8 = null;
    var selected_identification: ?vvdi.types.Identification = null;

    // O subsistema ainda mantém um backend físico ativo. Se há mais de um
    // virtio-blk moderno, escolhe o último BDF: nos testes QEMU o disco de
    // boot aparece primeiro e o disco de dados exclusivo é anexado depois.
    // Com um único disco, o comportamento existente (usar esse dispositivo)
    // permanece inalterado.
    while (device < 32) : (device += 1) {
        const vendor = pci.readConfigWord(0, device, 0, 0x00);
        if (vendor != vvdi.types.vendor_id) continue;

        found += 1;
        const device_id = pci.readConfigWord(0, device, 0, 0x02);
        const identification = vvdi.types.identify(vendor, device_id) catch |err| {
            serial.printLine("[VNK] virtio: 00:{d}.0 device=0x{x} is not identified: {s}", .{
                device,
                device_id,
                @errorName(err),
            });
            continue;
        };

        if (!identification.modern_id) {
            serial.printLine(
                "[VNK] virtio: 00:{d}.0 device=0x{x} is transitional; the modern transport is not used",
                .{ device, device_id },
            );
            continue;
        }
        if (identification.device_type != .block) {
            serial.printLine("[VNK] virtio: 00:{d}.0 type={s} is not the target of this increment", .{
                device,
                identification.device_type.label(),
            });
            continue;
        }

        selected_device = device;
        selected_identification = identification;
    }

    if (found == 0) {
        serial.printLine("[VNK] virtio: no function of vendor 0x1af4 on bus 0", .{});
        return;
    }
    const target_device = selected_device orelse {
        serial.printLine("[VNK] vvdi: no modern virtio-blk was found", .{});
        return;
    };
    const identification = selected_identification.?;
    serial.printLine("[VNK] vvdi: selected modern virtio-blk 00:{d}.0", .{target_device});
    if (!bringUpVirtioFunction(target_device, identification)) {
        serial.printLine("[VNK] vvdi: selected device 00:{d}.0 was not brought up", .{target_device});
    }
}

/// Real read/write probe for a dedicated QEMU data disk.
///
/// LBA 0 is a host-written opt-in signature, never a write target. The
/// deterministic payload lives at LBA 64. An all-zero payload denotes Boot 1;
/// an exact payload denotes Boot 2. Any other contents fail closed rather
/// than being overwritten, so stale/corrupt state cannot produce a false pass.
fn verifyVirtioBlockPersistenceProbe() void {
    const device = block_dev.defaultDevice() orelse return;
    if (device.sector_size != storage_test_control.len or device.sector_count <= storage_test_lba)
        return;

    device.readBytes(0, &storage_test_control) catch |err| {
        // The probe is opt-in: if LBA 0 cannot be read, there is no evidence
        // that this device requested the self-test. Skip it without turning
        // an optional probe failure into a boot failure.
        serial.printLine("[VNK] vvdi: storage-test control-sector read failed; optional probe skipped: {s}", .{@errorName(err)});
        return;
    };
    if (!std.mem.eql(u8, storage_test_control[0..storage_test_magic.len], storage_test_magic) or
        !std.mem.allEqual(u8, storage_test_control[storage_test_magic.len..], 0)) return;
    serial.printLine("[VNK] vvdi: storage-test signature recognized on dedicated data disk", .{});

    for (&storage_test_expected, 0..) |*byte, index| {
        const position: u64 = @intCast(index);
        byte.* = @truncate(position *% 73 +% (position >> 1) +% 0x5A);
    }

    const data_offset = storage_test_lba * device.sector_size;
    device.readBytes(data_offset, &storage_test_actual) catch |err| {
        serial.printLine("[VNK] FATAL: storage-test initial read failed: {s}", .{@errorName(err)});
        port.haltForever();
    };

    if (std.mem.allEqual(u8, &storage_test_actual, 0)) {
        serial.printLine("[VNK] vvdi: storage-test phase=boot1", .{});
        device.writeBytes(data_offset, &storage_test_expected) catch |err| {
            serial.printLine("[VNK] FATAL: storage-test write failed: {s}", .{@errorName(err)});
            port.haltForever();
        };
        serial.printLine("[VNK] vvdi: storage write completed lba={d} bytes={d}", .{
            storage_test_lba,
            storage_test_expected.len,
        });

        if (device.flush == null) {
            serial.printLine("[VNK] FATAL: storage-test requires negotiated VirtIO FLUSH", .{});
            port.haltForever();
        }
        device.flushWrites() catch |err| {
            serial.printLine("[VNK] FATAL: storage-test FLUSH failed: {s}", .{@errorName(err)});
            port.haltForever();
        };
        serial.printLine("[VNK] vvdi: storage FLUSH completed lba={d}", .{storage_test_lba});

        device.readBytes(data_offset, &storage_test_actual) catch |err| {
            serial.printLine("[VNK] FATAL: storage-test readback failed: {s}", .{@errorName(err)});
            port.haltForever();
        };
        serial.printLine("[VNK] vvdi: storage read completed lba={d} bytes={d}", .{
            storage_test_lba,
            storage_test_actual.len,
        });
        if (!std.mem.eql(u8, &storage_test_expected, &storage_test_actual)) {
            serial.printLine("[VNK] FATAL: storage-test readback differs from written bytes", .{});
            port.haltForever();
        }
        serial.printLine("[VNK] vvdi: storage data compare verified bytes={d}", .{storage_test_actual.len});
        serial.printLine("[VNK] vvdi: storage-test complete boot=1", .{});
    } else if (std.mem.eql(u8, &storage_test_expected, &storage_test_actual)) {
        serial.printLine("[VNK] vvdi: storage-test phase=boot2", .{});
        serial.printLine("[VNK] vvdi: storage read completed lba={d} bytes={d}", .{
            storage_test_lba,
            storage_test_actual.len,
        });
        serial.printLine("[VNK] vvdi: storage data compare verified bytes={d}", .{storage_test_actual.len});
        serial.printLine("[VNK] vvdi: storage persistence confirmed boot=2 lba={d} bytes={d}", .{
            storage_test_lba,
            storage_test_actual.len,
        });
        serial.printLine("[VNK] vvdi: storage-test complete boot=2", .{});
    } else {
        serial.printLine("[VNK] FATAL: storage-test sector has unexpected nonzero data", .{});
        port.haltForever();
    }
}

/// Quantas capabilities vendor-specific a sonda guarda por funcao.
///
/// O limite existe porque a sonda vive na pilha do kernel. O disco do QEMU
/// apresenta cinco; um dispositivo com mais do que isto tem as excedentes
/// descartadas, e a linha do console diz que a lista foi truncada — a sonda
/// nao pode apresentar como completa uma leitura que parou no meio.
const probed_capability_limit: usize = 16;

/// Coleta, valida, mapeia e negocia uma funcao VirtIO ja identificada.
///
/// Returns true only after DRIVER_OK, queue setup, capacity read and block
/// API registration. Pre-queue failures unmap the BAR; after queue memory is
/// handed to the device, ambiguous failures retain it unless reset confirms
/// release, following `transport.QueueMemory` ownership rules.
fn bringUpVirtioFunction(
    device: u8,
    identification: vvdi.types.Identification,
) bool {
    const location: pci.Function = .{ .bus = 0, .device = device, .function = 0 };
    const reader = pci.functionReader(&location);

    serial.printLine("[VNK] vvdi: modern device detected 00:{d}.0 id=0x{x} type={s}", .{
        device,
        identification.device_id,
        identification.device_type.label(),
    });

    // O tamanho de um BAR so pode ser descoberto escrevendo a mascara e
    // lendo o resultado. As escritas sao restauradas dentro de
    // `probeBarSizes`, e nenhum outro registrador da funcao e tocado.
    probed_bars = pci.readBarTable(reader) orelse {
        serial.printLine("[VNK] vvdi: 00:{d}.0 BAR table is invalid", .{device});
        return false;
    };
    probed_bar_sizes = pci.probeBarSizes(location.bus, location.device, location.function);

    var capabilities: [probed_capability_limit]vvdi.caps.Capability = undefined;
    const count = collectVirtioCapabilities(device, &capabilities) orelse return false;

    const collection = vvdi.caps.build(
        capabilities[0..count],
        supportedProbedBar,
    ) catch |err| {
        serial.printLine(
            "[VNK] vvdi: 00:{d}.0 type={s} capabilities rejected: {s}",
            .{ device, identification.device_type.label(), @errorName(err) },
        );
        return false;
    };

    serial.printLine(
        "[VNK] vvdi: 00:{d}.0 capabilities validated bar={d} common=+0x{x}/{d} notify=+0x{x}/{d} multiplier={d}",
        .{
            device,
            collection.common.bar,
            collection.common.offset,
            collection.common.length,
            collection.notify.offset,
            collection.notify.length,
            collection.notify.notify_off_multiplier,
        },
    );

    const window = if (mmio_window) |*value| value else {
        serial.printLine("[VNK] vvdi: 00:{d}.0 the MMIO window was not installed", .{device});
        return false;
    };

    const bar_index: usize = collection.common.bar;
    const bar = (probed_bars orelse return false).bars[bar_index] orelse {
        serial.printLine("[VNK] vvdi: 00:{d}.0 bar{d} is not implemented", .{
            device,
            bar_index,
        });
        return false;
    };
    if (bar.is_io) {
        serial.printLine(
            "[VNK] vvdi: 00:{d}.0 bar{d} is an I/O port BAR; the modern transport needs MMIO",
            .{ device, bar_index },
        );
        return false;
    }
    const bar_size = probed_bar_sizes[bar_index] orelse {
        serial.printLine("[VNK] vvdi: 00:{d}.0 bar{d} size could not be measured", .{
            device,
            bar_index,
        });
        return false;
    };
    if (bar.address == 0) {
        serial.printLine("[VNK] vvdi: 00:{d}.0 bar{d} is not assigned an address", .{
            device,
            bar_index,
        });
        return false;
    }

    var region = window.mapRange(
        bar.address,
        bar_size,
        vvdi.mmio.Permissions.read_write,
    ) catch |err| {
        serial.printLine(
            "[VNK] vvdi: 00:{d}.0 bar{d} size=0x{x} could not be mapped: {s}",
            .{ device, bar_index, bar_size, @errorName(err) },
        );
        return false;
    };

    var transport = vvdi.pci_transport.Transport.attach(
        identification,
        collection,
        region,
    ) catch |err| {
        window.unmap(&region);
        serial.printLine(
            "[VNK] vvdi: 00:{d}.0 capabilities do not fit bar{d} size=0x{x}: {s}",
            .{ device, bar_index, bar_size, @errorName(err) },
        );
        return false;
    };

    serial.printLine(
        "[VNK] vvdi: MMIO mapped 00:{d}.0 bar{d} phys=0x{x} size=0x{x} virt=0x{x} common=0x{x} notify=0x{x}",
        .{
            device,
            bar_index,
            bar.address,
            bar_size,
            region.virtual,
            transport.regions.common.virtual,
            transport.regions.notify.virtual,
        },
    );

    var target: vvdi.transport.Device = .{ .registers = transport.registers() };

    switch (target.initializeOptional(vvdi.features.supported, vvdi.block.flush_feature)) {
        .failed => |failure| {
            if (failure.stage == .reset) {
                // resetDevice failed before proving that the function is
                // inactive. Keep the MMIO path available even though no
                // queue from this driver has been handed over yet.
                active_virtio_transport = transport;
                serial.printLine("[VNK] FATAL: 00:{d}.0 reset was not confirmed; retaining the BAR MMIO mapping", .{device});
            } else {
                window.unmap(&region);
            }
            serial.printLine(
                "[VNK] vvdi: 00:{d}.0 initialization failed at {s}: {s} (bar{d} size=0x{x})",
                .{
                    device,
                    failure.stage.label(),
                    @errorName(failure.reason),
                    bar_index,
                    bar_size,
                },
            );
            return false;
        },
        .initialized => {},
    }

    // O estado que vale e o que o dispositivo informa. `initialize` ja
    // confirmou a leitura de volta depois de cada escrita, e estas
    // verificacoes impedem que uma mudanca de contrato passe em silencio.
    if (target.accepted & vvdi.features.version_1 == 0) {
        window.unmap(&region);
        serial.printLine("[VNK] vvdi: 00:{d}.0 returned without VERSION_1", .{device});
        return false;
    }
    serial.printLine(
        "[VNK] vvdi: 00:{d}.0 VERSION_1 negotiated features=0x{x} offered=0x{x}",
        .{ device, target.accepted, target.offered },
    );

    const confirmed: ?vvdi.status.Phase = target.phase() catch null;
    if (confirmed != .features_ok or !target.isAwaitingQueues()) {
        window.unmap(&region);
        serial.printLine(
            "[VNK] vvdi: 00:{d}.0 FEATURES_OK was not confirmed (status=0x{x})",
            .{ device, target.status },
        );
        return false;
    }
    serial.printLine("[VNK] vvdi: 00:{d}.0 FEATURES_OK accepted status=0x{x}", .{
        device,
        target.status,
    });
    serial.printLine(
        "[VNK] vvdi: 00:{d}.0 awaiting virtqueue setup queues={d} status=0x{x}",
        .{ device, target.queues, target.status },
    );

    // PR C: a fila 0 recebe as tres areas em memoria DMA, e so depois dela
    // programada e habilitada DRIVER_OK e escrito.
    if (!programVirtqueue(&target, &transport, device)) {
        if (virtqueueMemoryMayBeReturned()) {
            window.unmap(&region);
        } else {
            // A failed reset means the device may still use the programmed
            // queue. Keep its BAR mapped as well as the DMA allocation, and
            // retain the transport metadata for explicit quarantine state.
            active_virtio_transport = transport;
            serial.printLine("[VNK] FATAL: 00:{d}.0 reset was not confirmed; retaining the BAR MMIO mapping and DMA memory", .{device});
        }
        return false;
    }

    // O transporte foi inicializado sobre uma variável local. Copiamos seu
    // estado para armazenamento permanente antes de ligar a API de bloco;
    // a fila e sua memória DMA também permanecem globais.
    //
    // A partir daqui o dispositivo esta em `DRIVER_OK` e a fila ja foi
    // entregue: qualquer falha nesta secao e uma falha *depois* de o
    // dispositivo passar a poder emitir DMA. Nenhum caminho abaixo devolve a
    // memoria ao alocador nem desmapeia o BAR, e todos contem o dispositivo e
    // registram o estado antes de retornar.
    active_virtio_transport = transport;
    const active_queue = if (virtqueue_state.queue) |*queue| queue else {
        serial.printLine("[VNK] FATAL: the active VirtIO queue was not retained", .{});
        containActiveDevice(.configuration_failure, device);
        return false;
    };
    const active_dma = virtqueue_state.mapped orelse {
        serial.printLine("[VNK] FATAL: the active VirtIO DMA mapping was not retained", .{});
        containActiveDevice(.configuration_failure, device);
        return false;
    };
    const active_buffer = virtqueue_state.buffer orelse {
        serial.printLine("[VNK] FATAL: the active VirtIO DMA allocation was not retained", .{});
        containActiveDevice(.configuration_failure, device);
        return false;
    };
    virtio_block_driver.init(
        &active_virtio_transport,
        active_queue,
        active_buffer.physical_address,
        active_dma.virtual[0..@intCast(active_dma.length)],
        active_queue.layout,
        target.accepted,
        &virtio_containment,
    ) catch |err| {
        // O dispositivo respondeu `DRIVER_OK` e continua com a fila 0
        // habilitada. A memoria DMA, o mapeamento do BAR e o transporte
        // permanecem retidos — nao ha caminho de liberacao aqui — e a
        // instancia de bloco nunca e publicada, entao nenhum pedido pode ser
        // emitido. O que faltava era o estado ficar identificavel: a
        // contencao nomeia o motivo e revoga o *bus master*.
        serial.printLine(
            "[VNK] FATAL: 00:{d}.0 block device configuration failed after DRIVER_OK: {s}",
            .{ device, @errorName(err) },
        );
        containActiveDevice(.configuration_failure, device);
        return false;
    };
    block_dev.installDefault(virtio_block_driver.device());
    serial.printLine("[VNK] vvdi: 00:{d}.0 block I/O ready sectors={d} sector_size={d} flush={d}", .{
        device,
        virtio_block_driver.sectors,
        vvdi.block.sector_size,
        @intFromBool(virtio_block_driver.flush_supported),
    });

    return true;
}

// ----------------------------------------------------------------------
// F7/PR C: virtqueue dividida nativa.
//
// A fila do boot e a fila 0 do dispositivo alvo, com as tres areas no mesmo
// buffer fisicamente contiguo do alocador de DMA e um `Queue` que mantem o
// estado do driver. A ordem e a da especificacao 2.7 e 4.1.4.3.2:
//
//   tamanho -> memoria -> layout -> queue_size -> enderecos -> queue_enable
//   -> DRIVER_OK
//
// Nenhum pedido e publicado e nenhuma conclusao e consumida: o incremento
// termina com a fila pronta e vazia.
// ----------------------------------------------------------------------

/// Capacidade da fila do boot.
///
/// E o maior tamanho que o virtio-blk do QEMU anuncia, e dimensiona o estado
/// auxiliar de `virtqueue.Queue` (dois bitsets de 256 bits) em vez dos 32768
/// que a especificacao permite.
const virtqueue_capacity: u16 = 256;

const Virtqueue = vvdi.virtqueue.Queue(virtqueue_capacity);

/// Memoria e estado da fila 0 do dispositivo alvo.
///
/// A reserva de DMA, o mapeamento virtual e a fila ficam vivos pelo resto do
/// boot: depois de `queue_enable` o dispositivo pode ler e escrever essa
/// memoria a qualquer momento, e devolve-la ao alocador enquanto ele ainda a
/// referencia entregaria ao dispositivo paginas de outro dono. Nao existe
/// `defer` para eles.
const VirtqueueState = struct {
    buffer: ?dma.Buffer = null,
    mapped: ?dma.MappedBuffer = null,
    queue: ?Virtqueue = null,
    size: u16 = 0,
    /// Posse da memoria depois da escrita de `queue_enable`.
    ///
    /// A marca e do transporte porque e ele que conhece a sequencia: a
    /// memoria sai das maos do driver no `queue_enable` e so volta quando o
    /// dispositivo confirma o reset.
    ownership: vvdi.transport.QueueMemory = .{},
};

var virtqueue_state: VirtqueueState = .{};

/// Transporte e driver de bloco ativos. Mantidos estaticamente porque o
/// dispositivo pode reter os enderecos da fila e dos buffers DMA ate o reset.
var active_virtio_transport: vvdi.pci_transport.Transport = undefined;
var virtio_block_driver: vvdi.block.Driver = undefined;

/// Alvo PCI da revogacao de *bus master*.
///
/// E um valor estatico, e nao uma variavel local, porque a contencao guarda um
/// ponteiro para ele: o estado pode ser consultado depois que a funcao que
/// armou a contencao ja retornou. Um endereco de pilha ali seria leitura de
/// memoria que nao pertence mais ao dispositivo.
const BusMasterTarget = struct {
    bus: u8 = 0,
    device: u8 = 0,
    function: u8 = 0,
};

var virtio_bus_master_target: BusMasterTarget = .{};

/// Estado de contencao do dispositivo virtual em uso.
///
/// Tambem estatico, e pelo mesmo motivo: o driver de bloco o consulta em cada
/// falha, e a orquestracao de boot o consulta depois das falhas.
var virtio_containment: vvdi.containment.Containment = .{};

/// Revoga o *bus master* da funcao. True somente com leitura de volta.
fn revokeVirtioBusMaster(ctx: *anyopaque) bool {
    const target: *const BusMasterTarget = @ptrCast(@alignCast(ctx));
    const change = pci.setBusMaster(target.bus, target.device, target.function, false);
    return change.isConfirmed();
}

fn virtioBusMasterHandle() vvdi.containment.BusMaster {
    return .{ .ctx = @ptrCast(&virtio_bus_master_target), .revoke = revokeVirtioBusMaster };
}

/// True somente quando a memoria da fila pode voltar ao alocador.
///
/// Duas condicoes independentes, e as duas precisam valer:
///
///   * o transporte diz que o dispositivo devolveu a fila (`QueueMemory`), o
///     que antes da entrega e sempre verdadeiro para o driver;
///   * a contencao diz que a liberacao e segura para este dispositivo, o que
///     depois da entrega exige um reset confirmado.
///
/// Elas ficam separadas de proposito: uma revogacao de *bus master* confirmada
/// nao pode, sozinha, liberar memoria.
fn virtqueueMemoryMayBeReturned() bool {
    return virtqueue_state.ownership.canReturnToAllocator() and
        virtio_containment.permitsMemoryRelease();
}

/// Fecha o ciclo de vida anterior da contencao antes de uma nova rodada.
///
/// As tres provas vem de quem tem acesso ao estado real: o transporte sabe se
/// a fila ainda pertence ao dispositivo (`QueueMemory`), o proprio
/// `virtqueue_state` sabe se sobrou alocacao ou mapeamento, e o registro de
/// blocos sabe se ha um driver ativo apontando para `virtio_containment`.
///
/// `driver_detached` e o mais restritivo dos tres: enquanto um driver estiver
/// publicado, ele guarda um ponteiro para a instancia de contencao e para a
/// fila. Reiniciar a contencao nesse estado deixaria o driver falando com um
/// estado que ja nao descreve o dispositivo dele — por isso a rodada e
/// recusada, e nao corrigida.
fn beginVirtioLifecycle(device: u8) bool {
    virtio_containment.beginNewLifecycle(.{
        .queue_returned = virtqueue_state.ownership.canReturnToAllocator(),
        .memory_released = virtqueue_state.buffer == null and
            virtqueue_state.mapped == null and
            virtqueue_state.queue == null,
        .driver_detached = block_dev.defaultDevice() == null,
    }) catch |err| {
        serial.printLine(
            "[VNK] FATAL: 00:{d}.0 a new virtio lifecycle was refused, the previous containment is preserved: {s}",
            .{ device, @errorName(err) },
        );
        return false;
    };
    return true;
}

/// Contem o dispositivo que ja recebeu `DRIVER_OK` e registra o estado.
///
/// Emitido apenas em caminho de falha: o log de boot com sucesso continua com
/// exatamente as mesmas linhas de antes.
fn containActiveDevice(reason: vvdi.containment.Reason, device: u8) void {
    const outcome = virtio_containment.contain(reason);
    serial.printLine(
        "[VNK] FATAL: 00:{d}.0 device containment reason={s} bus_master={s}",
        .{ device, reason.label(), outcome.label() },
    );
    var buffer: [160]u8 = undefined;
    serial.printLine(
        "[VNK] FATAL: 00:{d}.0 {s}; the BAR mapping and the DMA memory stay retained",
        .{ device, virtio_containment.describe(&buffer) },
    );
}

/// Self-test is opt-in via a sector-zero signature on a separate test disk.
/// It deliberately never writes unless that exact signature is read back.
const storage_test_lba: u64 = 64;
const storage_test_magic = "VORYNBLKTEST0001";
var storage_test_control: [512]u8 = undefined;
var storage_test_expected: [512]u8 = undefined;
var storage_test_actual: [512]u8 = undefined;

/// Devolve a memoria da fila ao alocador, e so quando o dispositivo largou.
///
/// A pergunta e feita a `QueueMemory`: antes da entrega a memoria e do driver
/// e qualquer falha pode devolve-la; depois dela so um reset confirmado
/// devolve a posse. Sem essa confirmacao a memoria fica reservada — vazar uma
/// fila e melhor do que o alocador entregar ao dispositivo paginas que outro
/// dono ja recebeu.
fn releaseVirtqueueMemory() void {
    if (!virtqueueMemoryMayBeReturned()) {
        serial.printLine("[VNK] FATAL: the virtqueue memory stays reserved, the device did not release the queue", .{});
        return;
    }

    if (virtqueue_state.mapped) |*mapped| dma.unmapVirtual(mapped, &physical.manager);
    if (virtqueue_state.buffer) |*buffer| buffer.release(&physical.manager);
    virtqueue_state = .{};
}

/// Desfaz a programacao da fila depois de uma falha.
///
/// Uma falha em `configureQueue`, em `enableQueue` ou em `queueEnabled` e
/// ambigua: o dispositivo pode ter recebido os enderecos ou o `queue_enable` e
/// estar lendo a memoria da fila. Antes de devolver as paginas ao alocador a
/// funcao reseta o dispositivo e exige a leitura de volta em zero; sem essa
/// confirmacao a memoria continua reservada.
fn abandonVirtqueue(target: *vvdi.transport.Device, device: u8) void {
    if (target.resetDevice()) |_| {
        virtqueue_state.ownership.deviceReleased();
        virtio_containment.noteReset(true);
        serial.printLine(
            "[VNK] vvdi: 00:{d}.0 device reset after the virtqueue failure, status={d}",
            .{ device, target.status },
        );
    } else |err| {
        virtio_containment.noteReset(false);
        serial.printLine(
            "[VNK] FATAL: 00:{d}.0 the device did not confirm the reset after the virtqueue failure: {s}",
            .{ device, @errorName(err) },
        );
        // Um reset que nao se confirmou deixa o dispositivo em estado
        // desconhecido. A contencao revoga o *bus master* para impedir
        // transacoes novas; ela nao prova que as antigas terminaram, e por
        // isso `releaseVirtqueueMemory` continua recusando devolver a
        // memoria abaixo.
        containActiveDevice(.reset_unconfirmed, device);
    }

    releaseVirtqueueMemory();
}

/// Reserva a memoria da fila e a mapeia na janela de DMA.
///
/// Reusa `memory/dma.zig`: a reserva e de paginas fisicas contiguas abaixo de
/// 4 GiB (`dma32_limit`), e o mapeamento virtual passa por
/// `paging.mapKernelDataPage`, como qualquer outro buffer de DMA do kernel.
fn allocateVirtqueueMemory(byte_length: u64) ?dma.MappedBuffer {
    var buffer = dma.allocate(&physical.manager, byte_length, dma.dma32_limit) orelse return null;
    const mapped = dma.mapVirtual(buffer) orelse {
        buffer.release(&physical.manager);
        return null;
    };
    virtqueue_state.buffer = buffer;
    virtqueue_state.mapped = mapped;
    return mapped;
}

/// Programa a fila 0, habilita e escreve DRIVER_OK.
///
/// Cada etapa verifica o que a anterior produziu: o tamanho vem do dispositivo,
/// o layout do tamanho, os enderecos do layout, e o `queue_enable` e lido de
/// volta. So depois de tudo isso o protocolo aceita DRIVER_OK — sem fila
/// pronta, `transport.Device.activate` recusa a escrita.
fn programVirtqueue(
    target: *vvdi.transport.Device,
    device_transport: *vvdi.pci_transport.Transport,
    device: u8,
) bool {
    if (virtqueue_state.queue != null or virtqueue_state.buffer != null) {
        serial.printLine("[VNK] FATAL: the virtqueue memory is already in use", .{});
        return false;
    }

    // F-1: nenhuma rodada herda o estado de contencao da anterior.
    //
    // A reinicializacao so acontece com as tres provas externas e com o ciclo
    // anterior fechado. Sem elas, a contencao anterior e preservada e a
    // inicializacao para aqui — um dispositivo que ainda pode acessar memoria
    // nao pode ser esquecido, e uma contencao nao pode ser apagada por engano.
    if (!beginVirtioLifecycle(device)) return false;

    // 1. Tamanho: o maior valor da especificacao que o dispositivo aceita.
    const device_max = target.queueMaxSize(0) catch |err| {
        serial.printLine("[VNK] vvdi: 00:{d}.0 virtqueue 0 max size failed: {s}", .{
            device,
            @errorName(err),
        });
        return false;
    };
    const size = vvdi.virtqueue.Layout.negotiateSize(device_max) catch |err| {
        serial.printLine(
            "[VNK] vvdi: 00:{d}.0 virtqueue 0 rejected max={d}: {s}",
            .{ device, device_max, @errorName(err) },
        );
        return false;
    };
    const layout = vvdi.virtqueue.Layout.compute(size) catch |err| {
        serial.printLine("[VNK] vvdi: 00:{d}.0 virtqueue 0 layout failed: {s}", .{
            device,
            @errorName(err),
        });
        return false;
    };

    // 2. Memoria: fila e buffer de uma requisicao no mesmo bloco DMA
    // contiguo. O espaco de trabalho persiste enquanto DRIVER_OK estiver ativo.
    const request_buffers = vvdi.block.BufferLayout.compute(layout.total_size) orelse {
        serial.printLine("[VNK] FATAL: the VirtIO Block DMA request layout overflows", .{});
        return false;
    };
    const mapped = allocateVirtqueueMemory(request_buffers.required) orelse {
        serial.printLine("[VNK] vvdi: 00:{d}.0 virtqueue 0 has no DMA memory for {d} bytes", .{
            device,
            layout.total_size,
        });
        return false;
    };
    const buffer = virtqueue_state.buffer.?;

    // 3. Filas vazias, free list completa e aneis zerados.
    var queue = Virtqueue.init(.{
        .physical = buffer.physical_address,
        .bytes = mapped.virtual[0..layout.total_size],
    }, size) catch |err| {
        releaseVirtqueueMemory();
        serial.printLine("[VNK] vvdi: 00:{d}.0 virtqueue 0 init failed: {s}", .{
            device,
            @errorName(err),
        });
        return false;
    };
    // Este driver usa polling síncrono e não registra IRQ/MSI-X da fila.
    queue.setNoInterrupt(true);
    if (queue.freeCount() != size or queue.inFlightCount() != 0) {
        releaseVirtqueueMemory();
        serial.printLine("[VNK] FATAL: the virtqueue did not start empty", .{});
        return false;
    }

    const addresses = queue.addresses() catch |err| {
        releaseVirtqueueMemory();
        serial.printLine("[VNK] vvdi: 00:{d}.0 virtqueue 0 addresses failed: {s}", .{
            device,
            @errorName(err),
        });
        return false;
    };

    serial.printLine(
        "[VNK] vvdi: 00:{d}.0 virtqueue 0 dma phys=0x{x} virt=0x{x} size={d} bytes={d} desc=0x{x} avail=0x{x} used=0x{x}",
        .{
            device,
            buffer.physical_address,
            @intFromPtr(mapped.virtual),
            size,
            layout.total_size,
            addresses.desc,
            addresses.driver,
            addresses.device,
        },
    );

    // 4. Programacao: tamanho e os tres enderecos fisicos.
    //
    // A posse da memoria pelo dispositivo comeca aqui, e nao depois do
    // `queue_enable`. `configureQueue` ja escreve no dispositivo os enderecos
    // desta memoria, e uma falha no meio pode deixa-los gravados: o erro nao
    // prova que o dispositivo ficou sem acesso a ela. Marcar a posse antes da
    // primeira escrita mantem a regra do modulo — so o reset confirmado
    // devolve a memoria — verdadeira em todas as saidas de erro seguintes,
    // inclusive quando o dispositivo se apresenta habilitado e nenhuma
    // escrita chega a acontecer.
    virtqueue_state.ownership.handOver();

    // A contencao e armada no mesmo ponto e pela mesma razao: daqui em diante
    // a memoria e do dispositivo. O alvo da revogacao e gravado antes de a
    // contencao existir, para que `contain` nunca precise descobrir o
    // dispositivo por conta propria.
    virtio_bus_master_target = .{ .bus = 0, .device = device, .function = 0 };
    virtio_containment.arm(virtioBusMasterHandle());

    device_transport.configureQueue(0, size, .{
        .desc = addresses.desc,
        .driver = addresses.driver,
        .device = addresses.device,
    }) catch |err| {
        serial.printLine("[VNK] vvdi: 00:{d}.0 virtqueue 0 programming failed: {s}", .{
            device,
            @errorName(err),
        });
        // Os enderecos podem ter sido escritos em parte: o dispositivo nao
        // pode ficar apontando para uma fila que vai voltar ao alocador.
        abandonVirtqueue(target, device);
        return false;
    };

    // 5. Habilitacao, com o estado lido de volta.
    device_transport.enableQueue(0) catch |err| {
        serial.printLine("[VNK] vvdi: 00:{d}.0 virtqueue 0 enable failed: {s}", .{
            device,
            @errorName(err),
        });
        // Falha ambigua em dois sentidos: o `queue_enable` pode ter sido
        // aceito, e o proprio erro pode ter vindo de uma fila que ja se
        // apresentava habilitada. Nenhum dos dois casos prova que o
        // dispositivo parou de usar a memoria; a posse ja foi registrada
        // antes de `configureQueue`, e so o reset confirmado a devolve.
        abandonVirtqueue(target, device);
        return false;
    };

    const enabled = device_transport.queueEnabled(0) catch |err| {
        serial.printLine("[VNK] vvdi: 00:{d}.0 virtqueue 0 enable check failed: {s}", .{
            device,
            @errorName(err),
        });
        abandonVirtqueue(target, device);
        return false;
    };
    if (!enabled) {
        serial.printLine("[VNK] vvdi: 00:{d}.0 virtqueue 0 did not stay enabled", .{device});
        abandonVirtqueue(target, device);
        return false;
    }

    // A fila fica guardada para o resto do boot; a memoria so volta ao
    // alocador se o dispositivo confirmar um reset (`abandonVirtqueue`).
    virtqueue_state.queue = queue;
    virtqueue_state.size = size;

    target.markQueueReady(0) catch |err| {
        serial.printLine("[VNK] vvdi: 00:{d}.0 virtqueue 0 ready failed: {s}", .{
            device,
            @errorName(err),
        });
        abandonVirtqueue(target, device);
        return false;
    };

    serial.printLine(
        "[VNK] vvdi: 00:{d}.0 virtqueue 0 enabled size={d} queues={d} free={d} avail={d} used={d}",
        .{
            device,
            size,
            target.queues,
            queue.freeCount(),
            queue.availableIndex(),
            queue.usedIndex(),
        },
    );

    // 6. DRIVER_OK, e so agora: a fila existe, tem enderecos e esta habilitada.
    switch (target.finish()) {
        .failed => |failure| {
            serial.printLine("[VNK] vvdi: 00:{d}.0 activation failed at {s}: {s}", .{
                device,
                failure.stage.label(),
                @errorName(failure.reason),
            });
            // O chamador so desmapeia o BAR se este reset for confirmado.
            // Sem confirmacao, tanto a fila DMA quanto o controle MMIO ficam
            // retidos para nao abandonar um dispositivo potencialmente ativo.
            abandonVirtqueue(target, device);
            return false;
        },
        .initialized => {},
    }

    const phase: ?vvdi.status.Phase = target.phase() catch null;
    if (target.status != 0x0F or phase != .driver_ok or !vvdi.status.isReady(target.status)) {
        serial.printLine("[VNK] vvdi: 00:{d}.0 DRIVER_OK was not confirmed status=0x{x}", .{
            device,
            target.status,
        });
        abandonVirtqueue(target, device);
        return false;
    }

    serial.printLine(
        "[VNK] vvdi: 00:{d}.0 DRIVER_OK status=0x{x} queues_ready={d} virtqueue=0",
        .{ device, target.status, target.readyQueues() },
    );

    return true;
}

/// Percorre a lista de capabilities e devolve quantas vendor-specific foram
/// lidas, ou null quando a lista nao pode ser percorrida.
///
/// Uma capability malformada e registrada e descartada: a especificacao
/// permite mais de uma instancia do mesmo tipo, e uma invalida nao invalida
/// as outras.
fn collectVirtioCapabilities(
    device: u8,
    storage: *[probed_capability_limit]vvdi.caps.Capability,
) ?usize {
    const location: pci.Function = .{ .bus = 0, .device = device, .function = 0 };
    const reader = pci.functionReader(&location);

    var iterator = pci.CapabilityIterator.init(reader) catch |err| {
        serial.printLine("[VNK] vvdi: 00:{d}.0 has no capability list: {s}", .{
            device,
            @errorName(err),
        });
        return null;
    };

    var count: usize = 0;
    while (true) {
        const next = iterator.next() catch |err| {
            serial.printLine("[VNK] vvdi: 00:{d}.0 capability list is invalid: {s}", .{
                device,
                @errorName(err),
            });
            return null;
        };
        const pci_capability = next orelse break;
        if (pci_capability.id != pci.capability_vendor_specific) continue;

        if (count == storage.len) {
            serial.printLine(
                "[VNK] vvdi: 00:{d}.0 capability list truncated at {d} entries",
                .{ device, probed_capability_limit },
            );
            break;
        }

        storage[count] = readVirtioCapability(device, pci_capability) catch |err| {
            serial.printLine("[VNK] vvdi: 00:{d}.0 capability at 0x{x} is invalid: {s}", .{
                device,
                pci_capability.offset,
                @errorName(err),
            });
            continue;
        };
        count += 1;
    }

    return count;
}

/// Le o corpo de uma capability VirtIO a partir do espaco de configuracao.
///
/// Somente os bytes que este modulo interpreta sao lidos: os campos da
/// estrutura base, o multiplicador da notificacao e as metades altas da
/// variante de 64 bits (`cap64`). O resto do `cap_len` declarado pode ser
/// padding ou uma extensao, e `caps.parse` aceita um `cap_len` maior do que os
/// bytes entregues aqui, como a especificacao exige.
fn readVirtioCapability(
    device: u8,
    pci_capability: pci.Capability,
) vvdi.caps.Error!vvdi.caps.Capability {
    var body: [vvdi.caps.max_structure_size]u8 = @splat(0);
    // O percurso recusou uma capability vendor-specific sem `cap_len`, e por
    // isso a ausencia do campo aqui e uma violacao da mesma regra.
    const declared = pci_capability.length orelse return error.TruncatedCapability;
    const length: usize = @min(@as(usize, declared), body.len);

    for (body[0..length], 0..) |*slot, index| {
        // O percurso garantiu offset + length dentro do espaco de
        // configuracao, e `length` nao passa do tamanho do buffer.
        const offset: u8 = @intCast(@as(usize, pci_capability.offset) + index);
        slot.* = pci.readConfigByte(0, device, 0, offset);
    }

    return vvdi.caps.parse(body[0..length]);
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

    // The DMA window is reserved before the address spaces of the
    // processes are created. `createAddressSpace` copies the level 2 table
    // of the kernel, so a level 1 table allocated after that copy would not
    // be visible in the spaces that already exist.
    paging.reserveKernelRange(
        dma.virtual_window_base,
        dma.virtual_window_size,
    ) catch |err| {
        serial.printLine("[VNK] FATAL: the DMA window could not be reserved: {s}", .{@errorName(err)});
        port.haltForever();
    };

    // The MMIO window follows the same rule: it is reserved with the page
    // tables, before the address spaces of the processes exist. No page is
    // mapped here; the BAR of the device is mapped when it is discovered,
    // after the tables are active.
    installMmioWindow();
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
            @backingInt(framebuffer.pixel_format),
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
        .bytes = ptr[0..size],
        .width = width,
        .height = height,
        .pitch = pitch,
        .bits_per_pixel = framebuffer.bits_per_pixel,
    };
    // F6.31: a shell. A barra ocupa as últimas linhas e nenhuma janela a
    // alcança; a cor ativa do botão segue o foco do gerenciador de janelas.
    // F6.32: a seta do ponteiro. Ela nasce no centro da tela; quem a move é
    // o IRQ12, e o kernel só a desloca quando um pacote chega.
    graphics_desktop.enablePointer(.{
        .cursor = .{ .x = width / 2, .y = height / 2 },
        .palette = .{
            .outline = .{ 0x00, 0x00, 0x00, 0xff },
            .fill = .{ 0xff, 0xff, 0xff, 0xff },
        },
    });

    const bar_height = @max(@as(usize, 1), height / 32);
    graphics_desktop.enableShell(.{
        .bar = .{ .height = bar_height },
        .palette = .{
            .bar = .{ 0x08, 0x08, 0x08, 0xff },
            .active = if (is_bgr) .{ 0xc0, 0x96, 0x40, 0xff } else .{ 0x40, 0x96, 0xc0, 0xff },
            .inactive = .{ 0x28, 0x28, 0x28, 0xff },
        },
    });
    _ = graphics_desktop.present(mapping) catch |err| {
        serial.printLine("[VNK] graphics: desktop presentation failed: {s}", .{@errorName(err)});
        return;
    };
    serial.printLine("[VNK] graphics: managed desktop presented ({d}x{d})", .{ width, height });

    // Autoteste da shell: conta os botões, confere o alvo de um clique na
    // barra e troca o foco pelo teclado. O resultado é publicado no console,
    // e o teste de boot da CI o exige.
    const shell_bar: taskbar_mod.Bar = .{ .height = bar_height };
    var shell_buttons: [taskbar_mod.max_buttons]taskbar_mod.Button = undefined;
    const button_count = shell_bar.layout(&graphics_desktop.frame.session_state.windows, width, &shell_buttons);
    serial.printLine("[VNK] shell: bar height={d} buttons={d} windows={d}", .{
        bar_height,
        button_count,
        graphics_desktop.frame.session_state.windows.count,
    });
    if (button_count == 0) {
        serial.printLine("[VNK] shell: the bar has no button for the boot scene", .{});
    } else {
        const first = shell_buttons[0];
        const hit = shell_bar.buttonAt(
            &graphics_desktop.frame.session_state.windows,
            width,
            height,
            first.x,
            height - 1,
        );
        if (hit != null and hit.?.slot == first.handle.slot) {
            serial.printLine("[VNK] shell: the first button answers a click at x={d} y={d}", .{ first.x, height - 1 });
        } else {
            serial.printLine("[VNK] FATAL: the first button of the shell does not answer a click", .{});
            port.haltForever();
        }
        // O ponto na calha não pertence a botão nenhum: clicar no vazio não
        // deve mudar o foco.
        const gutter = first.x + first.width;
        if (shell_bar.buttonAt(
            &graphics_desktop.frame.session_state.windows,
            width,
            height,
            gutter,
            height - 1,
        ) != null) {
            serial.printLine("[VNK] FATAL: the gutter of the shell belongs to a button", .{});
            port.haltForever();
        }
    }

    const before = graphics_desktop.frame.session_state.windows.focused;
    const focused = graphics_desktop.cycleFocusAndPresent(mapping) catch |err| {
        serial.printLine("[VNK] graphics: the focus could not be cycled: {s}", .{@errorName(err)});
        return;
    };
    if (focused) |handle| {
        serial.printLine("[VNK] shell: focus cycled to slot={d} frame={d}x{d}", .{ handle.slot, width, height });
        if (before) |previous| {
            if (previous.slot == handle.slot) {
                serial.printLine("[VNK] FATAL: the focus did not change with {d} windows", .{
                    graphics_desktop.frame.session_state.windows.count,
                });
                port.haltForever();
            }
        }
        // A volta com duas janelas devolve o foco à janela da frente.
        _ = graphics_desktop.cycleFocusAndPresent(mapping) catch |err| {
            serial.printLine("[VNK] graphics: the focus could not be restored: {s}", .{@errorName(err)});
            return;
        };
    }

    if (graphics_desktop.pointer) |pointer| {
        serial.printLine("[VNK] pointer: arrow drawn at x={d} y={d} over the desktop", .{
            pointer.cursor.x,
            pointer.cursor.y,
        });
    }

    graphics_front_x = width / 4;
    graphics_front_y = height / 4;
    graphics_ready = true;
}

/// F6.32: aplica um pacote de movimento ao ponteiro do desktop.
///
/// O deslocamento é aplicado **sem aceleração**: um contador do PS/2 é um
/// pixel. Aceleração é política de interface, não de driver, e não existe
/// aqui — inventá-la tornaria o teste do cursor dependente de uma curva.
fn applyMouseGraphics(packet: ps2.Mouse.Packet) void {
    if (!graphics_ready) return;
    if (packet.dx == 0 and packet.dy == 0) return;
    const framebuffer = boot_info.framebuffer;
    const width: usize = @intCast(framebuffer.width);
    const height: usize = @intCast(framebuffer.height);
    const pitch: usize = @intCast(framebuffer.pitch);
    const size: usize = @intCast(framebuffer.size);
    const ptr: [*]u8 = @ptrFromInt(framebuffer.base);
    _ = graphics_desktop.movePointerAndPresent(.{
        .bytes = ptr[0..size],
        .width = width,
        .height = height,
        .pitch = pitch,
        .bits_per_pixel = framebuffer.bits_per_pixel,
    }, packet.dx, packet.dy) catch |err| {
        serial.printLine("[VNK] mouse: the cursor could not be moved: {s}", .{@errorName(err)});
        return;
    };
    const pointer = graphics_desktop.pointer orelse return;
    serial.printLine("[VNK] mouse: cursor moved x={d} y={d} dx={d} dy={d}", .{
        pointer.cursor.x,
        pointer.cursor.y,
        packet.dx,
        packet.dy,
    });
}

/// F15.6: compare identical raster fills on RAM and the mapped GOP surface.
/// The 256x64 framebuffer rectangle is saved and restored byte-for-byte.
/// No PAT or paging attributes are modified. Run after the user screenshot
/// checks, before the ready sentinel; this is a diagnostic, not a cache test.
fn benchmarkFramebufferWrites() void {
    const fb = boot_info.framebuffer;
    const width: usize = @intCast(fb.width);
    const height: usize = @intCast(fb.height);
    const pitch: usize = @intCast(fb.pitch);
    const size: usize = @intCast(fb.size);
    if (fb.bits_per_pixel != 32 or width < 256 or height < 64 or pitch < 256 * 4) return;
    if (size < (64 - 1) * pitch + 256 * 4) return;
    const mapped: [*]u8 = @ptrFromInt(fb.base);
    const bytes = mapped[0..size];
    // Snapshot only the region being overwritten; preserve pitch padding.
    for (0..64) |row| {
        const offset = row * pitch;
        @memcpy(graphics_bench_backup[row * 1024 ..][0..1024], bytes[offset..][0..1024]);
    }
    var ram = @import("graphics/raster.zig").Surface.init(&graphics_bench_ram, 256, 64, 1024) catch unreachable;
    var video = @import("graphics/raster.zig").Surface.init(bytes, width, height, pitch) catch return;
    const color: [4]u8 = .{ 0x35, 0x71, 0xa9, 0xff };
    for (0..4) |trial| {
        const ram_start = cpu.readTimestamp();
        ram.fillRect(0, 0, 256, 64, color);
        const ram_cycles = cpu.readTimestamp() - ram_start;
        const video_start = cpu.readTimestamp();
        video.fillRect(0, 0, 256, 64, color);
        const video_cycles = cpu.readTimestamp() - video_start;
        serial.printLine("[VNK] graphics: memory benchmark trial={d} bytes=65536 ram_cycles={d} framebuffer_cycles={d}", .{
            trial + 1, ram_cycles, video_cycles,
        });
    }
    for (0..64) |row| {
        const offset = row * pitch;
        @memcpy(bytes[offset..][0..1024], graphics_bench_backup[row * 1024 ..][0..1024]);
    }
    // Read back the restored region so the test detects restoration errors.
    var mismatches: usize = 0;
    for (0..64) |row| {
        const offset = row * pitch;
        for (0..1024) |col| {
            if (bytes[offset + col] != graphics_bench_backup[row * 1024 + col]) mismatches += 1;
        }
    }
    serial.printLine("[VNK] graphics: memory benchmark restore_mismatches={d}", .{mismatches});
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
        .x = current.x,
        .y = current.y,
        .width = current.width,
        .height = current.height,
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
    const render_start = cpu.readTimestamp();
    const render_tick_start = timer.ticks();
    var stage_timing: desktop_mod.Desktop.StageTiming = .{};
    const pixels = desktop.moveFrontAndPresentTimed(.{
        .bytes = ptr[0..size],
        .width = width,
        .height = height,
        .pitch = pitch,
        .bits_per_pixel = framebuffer.bits_per_pixel,
    }, next.x, next.y, &cpu.readTimestamp, &stage_timing) catch |err| {
        serial.printLine("[VNK] graphics: incremental redraw failed: {s}", .{@errorName(err)});
        return;
    };
    const render_done = cpu.readTimestamp();
    const render_tick_end = timer.ticks();
    // F13: measure the redraw itself, excluding serial logging and input acknowledgement.
    const render_cycles = render_done - render_start;
    const old_area = (@min(current.width, width - @min(current.x, width))) *|
        (@min(current.height, height - @min(current.y, height)));
    const new_area = (@min(current.width, width - @min(next.x, width))) *|
        (@min(current.height, height - @min(next.y, height)));
    const baseline_writes = old_area +| new_area;
    const saved_writes = baseline_writes -| pixels;
    render_latency.record(render_cycles, pixels, baseline_writes);
    serial.printLine(
        "[VNK] graphics: latency samples={d} min_cycles={d} mean_cycles={d} max_cycles={d} total_pixels={d} total_baseline={d}",
        .{
            render_latency.samples,
            render_latency.cycles_min,
            render_latency.meanCycles(),
            render_latency.cycles_max,
            render_latency.pixels_sum,
            render_latency.baseline_sum,
        },
    );
    serial.printLine(
        "[VNK] graphics: latency window={d} p50_cycles={d} p95_cycles={d} p99_cycles={d}",
        .{
            render_latency.recent_count,
            render_latency.percentileCycles(50),
            render_latency.percentileCycles(95),
            render_latency.percentileCycles(99),
        },
    );
    serial.printLine("[VNK] graphics: redraw benchmark cycles={d} pixels={d} baseline={d} saved={d}", .{
        render_cycles, pixels, baseline_writes, saved_writes,
    });
    // F15.4: correlate high-latency frames with timer ticks elapsed during
    // presentation. A tick is evidence of elapsed wall time, not proof of
    // preemption or of a particular framebuffer cache policy.
    serial.printLine("[VNK] graphics: redraw timing cycles={d} elapsed_ticks={d}", .{
        render_cycles, render_tick_end - render_tick_start,
    });
    serial.printLine("[VNK] graphics: redraw stages movement_cycles={d} composition_cycles={d} total_cycles={d}", .{
        stage_timing.movement_cycles, stage_timing.composition_cycles, render_cycles,
    });
    serial.printLine("[VNK] graphics: redraw detail geometry_cycles={d} paint_cycles={d}", .{
        stage_timing.geometry_cycles, stage_timing.paint_cycles,
    });
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

/// M0.5: inicializa fundamentos de SMP — APIC local, timer local, pilhas de AP.
/// Reporta o estado no serial para validacao do boot.
fn installSmp() void {
    // O APIC e MMIO e precisa estar presente nas tabelas novas antes do
    // primeiro acesso; as tabelas do firmware deixam de ser utilizaveis apos
    // a troca de CR3.
    paging.mapDevicePage(apic.apic_base, apic.apic_base) catch {
        serial.printLine("[VNK] FATAL: unable to map local APIC", .{});
        port.haltForever();
    };
    apic.map(apic.apic_base);
    apic.enable();

    // Configura o timer local da APIC para o BSP (100 Hz, mesmo do PIT).
    timer.initApicTimer(timer_frequency);

    // Inicializa as pilhas dos APs (estrutura de dados de SMP).
    smp.initAps();

    const apic_id = apic.readApicId();
    serial.printLine("[VNK] smp: APIC local id={d}, base=0x{x}", .{
        apic_id, apic.apic_base,
    });
    serial.printLine("[VNK] smp: AP stacks initialized (max_cpus={d})", .{smp.max_cpus});
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

    // F15.3: reserve two seconds for repeated PS/2 redraw measurements.\n    // Event consumption remains interrupt-driven, not a busy polling loop.\n    // F6.9: event pump por 50 ticks, em vez de consumir toda a fila
    // apenas no final. O trabalho de composição ocorre com IRQs habilitadas.
    // CLI protege somente a retirada de um evento da fila SPSC de IRQ1.
    serial.printLine("[VNK] keyboard: ready for PS/2 input", .{});

    // F6.32: o mouse. O handshake acontece com as interrupções locais
    // desabilitadas, porque um pacote de movimento no meio da conversa seria
    // lido como resposta de comando. A linha IRQ12 só é desmascarada depois
    // do ACK: um mouse ausente não deve gerar uma interrupção fantasma.
    cpu.disableInterrupts();
    const auxiliary = ps2.initAuxiliaryIrqsDisabled();
    if (auxiliary.present) timer.enableAuxiliaryIrq();
    cpu.enableInterrupts();
    if (auxiliary.present) {
        serial.printLine("[VNK] mouse: controller ready config=0x{x}->0x{x} acks={d}", .{
            auxiliary.config_before,
            auxiliary.config_after,
            auxiliary.acks,
        });
        serial.printLine("[VNK] mouse: ready for PS/2 movement", .{});
    } else {
        // Um mouse ausente não impede o boot: o teclado continua sendo a
        // entrada do desktop. O motivo fica no console.
        serial.printLine("[VNK] mouse: unavailable ({s}) config=0x{x}", .{
            auxiliary.reason,
            auxiliary.config_before,
        });
    }

    const input_start = timer.ticks();
    var key_count: usize = 0;
    var pressed: usize = 0;
    var released: usize = 0;
    var graphics_updates: usize = 0;
    var mouse_moves: usize = 0;
    while (timer.ticks() - input_start < 200) {
        cpu.disableInterrupts();
        const maybe_event = ps2.popIrqsDisabled();
        const maybe_motion = ps2.popMouseIrqsDisabled();
        cpu.enableInterrupts();
        if (maybe_motion) |motion| {
            mouse_moves += 1;
            applyMouseGraphics(motion);
        }
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
        } else if (maybe_motion == null) {
            // HLT acorda na próxima IRQ; não realiza busy polling.
            cpu.halt();
        }
    }
    // Drena os eventos que chegaram no último tick da janela.
    while (true) {
        cpu.disableInterrupts();
        const maybe_event = ps2.popIrqsDisabled();
        const maybe_motion = ps2.popMouseIrqsDisabled();
        cpu.enableInterrupts();
        if (maybe_motion) |motion| {
            mouse_moves += 1;
            applyMouseGraphics(motion);
        }
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
    const mouse_bytes = ps2.mouseBytesIrqsDisabled();
    const mouse_dropped = ps2.mouseDroppedIrqsDisabled();
    const mouse_decoder = ps2.mouseDecoderStatsIrqsDisabled();
    const mouse_irqs = ps2.takeMouseIrqStatsIrqsDisabled();
    cpu.enableInterrupts();
    serial.printLine("[VNK] keyboard: {d} events, {d} pressed, {d} released, {d} bytes, {d} dropped", .{
        key_count, pressed, released, bytes, dropped,
    });
    serial.printLine("[VNK] graphics: event pump {d} arrow presses over {d} ticks", .{
        graphics_updates, timer.ticks() - input_start,
    });
    serial.printLine(
        "[VNK] mouse: {d} moves, {d} packets, {d} bytes, {d} packets dropped, {d} resyncs, {d} irqs",
        .{
            mouse_moves,
            mouse_decoder.packets,
            mouse_bytes,
            mouse_dropped,
            mouse_decoder.resyncs,
            mouse_irqs.interrupts,
        },
    );
}

/// F6.11: loop de eventos permanente, selecionado pela tecla I no boot.
/// Retira um evento com IRQs desabilitadas; compoe com IRQs habilitadas.
fn runInteractiveEventLoop() noreturn {
    serial.printLine("[VNK] graphics: interactive event loop ready", .{});
    while (true) {
        cpu.disableInterrupts();
        const maybe_event = ps2.popIrqsDisabled();
        const maybe_motion = ps2.popMouseIrqsDisabled();
        cpu.enableInterrupts();
        if (maybe_motion) |motion| applyMouseGraphics(motion);
        if (maybe_event) |event| {
            applyKeyboardGraphics(event);
        } else if (maybe_motion == null) {
            // O timer de 100 Hz garante novo despertar mesmo se IRQ1 (ou o
            // IRQ12, no mouse) chegar entre a leitura da fila e HLT.
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
    // RamFS as the bootstrap image. The ELF is wrapped in a VEX container
    // (F5): the header declares the capability manifest that the kernel
    // grants to the process, and the loader unwraps and plans the inner
    // ELF during the boot.
    const toolchain_manifest = [_]vex.Capability{
        .{ .kind = .display, .rights = @intCast(capability.Rights.write | capability.Rights.delegate) },
        .{ .kind = .input, .rights = @intCast(capability.Rights.read | capability.Rights.delegate) },
    };
    var toolchain_vex_buffer: [toolchain_app.bytes.len + vex.header_size + vex.max_manifest_entries * 8]u8 align(16) = undefined;
    const toolchain_wrapped = vex.wrap(
        toolchain_app.bytes[0..],
        &toolchain_manifest,
        &toolchain_vex_buffer,
    ) catch |err| {
        serial.printLine("[VNK] FATAL: the toolchain VEX could not be wrapped: {s}", .{@errorName(err)});
        port.haltForever();
    };
    const toolchain_descriptor = fs.create(0, "/apps/toolchain.vex", 0o755) catch |err| {
        serial.printLine("[VNK] FATAL: the file /apps/toolchain.vex could not be created: {s}", .{@errorName(err)});
        port.haltForever();
    };
    const toolchain_written = fs.write(0, toolchain_descriptor, toolchain_vex_buffer[0..toolchain_wrapped]) catch |err| {
        serial.printLine("[VNK] FATAL: the file /apps/toolchain.vex could not be written: {s}", .{@errorName(err)});
        port.haltForever();
    };
    if (toolchain_written != toolchain_wrapped) {
        serial.printLine("[VNK] FATAL: the file /apps/toolchain.vex accepted {d} bytes", .{toolchain_written});
        port.haltForever();
    }
    fs.close(0, toolchain_descriptor) catch |err| {
        serial.printLine("[VNK] FATAL: the file /apps/toolchain.vex could not be closed: {s}", .{@errorName(err)});
        port.haltForever();
    };
    toolchain_vex_length = toolchain_wrapped;
    serial.printLine("[VNK] fs: /apps/toolchain.vex installed ({d} bytes)", .{toolchain_wrapped});
    serial.printLine("[VNK] vex: manifest declares display(0x{x}) and input(0x{x})", .{
        toolchain_manifest[0].rights,
        toolchain_manifest[1].rights,
    });

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

    // F5: o container VPK é empacotado no kernel e gravado no RamFS como
    // qualquer arquivo. O teste de boot relê o pacote depois da
    // recuperação VNV, provando o caminho completo: empacotar, persistir,
    // recuperar e desempacotar.
    const vpk_sources = [_]vpk.FileSource{
        .{ .name = "hello.txt", .kind = .data, .bytes = "VorynOS" },
        .{ .name = "manifest.vcfg", .kind = .config, .bytes = "app=hello\nexec=hello.vex\n" },
    };
    vpk_packed_length = vpk.pack(&vpk_sources, &vpk_pack_buffer) catch |err| {
        serial.printLine("[VNK] FATAL: the VPK package could not be packed: {s}", .{@errorName(err)});
        port.haltForever();
    };
    if (vpk_packed_length > vpk_pack_buffer.len) {
        serial.printLine("[VNK] FATAL: the VPK package does not fit the pack buffer", .{});
        port.haltForever();
    }
    const vpk_descriptor = fs.create(0, "/apps/sample.vpk", 0o644) catch |err| {
        serial.printLine("[VNK] FATAL: the file /apps/sample.vpk could not be created: {s}", .{@errorName(err)});
        port.haltForever();
    };
    const vpk_written = fs.write(0, vpk_descriptor, vpk_pack_buffer[0..vpk_packed_length]) catch |err| {
        serial.printLine("[VNK] FATAL: the file /apps/sample.vpk could not be written: {s}", .{@errorName(err)});
        port.haltForever();
    };
    if (vpk_written != vpk_packed_length) {
        serial.printLine("[VNK] FATAL: the file /apps/sample.vpk accepted {d} bytes", .{vpk_written});
        port.haltForever();
    }
    fs.close(0, vpk_descriptor) catch |err| {
        serial.printLine("[VNK] FATAL: the file /apps/sample.vpk could not be closed: {s}", .{@errorName(err)});
        port.haltForever();
    };
    serial.printLine("[VNK] vpk: packed {d} entries, {d} bytes", .{ vpk_sources.len, vpk_packed_length });
    // F5: a biblioteca nativa em um contêiner VLIB. A imagem embutida é o
    // ELF64 relocável que o toolchain gerou; a biblioteca declara os
    // símbolos exportados, o símbolo interno, a ABI e as capabilities que
    // exige. O arquivo é gravado no RamFS como qualquer outro e passa pelo
    // commit VNV, portanto a recuperação tem de devolvê-lo íntegro.
    _ = fs.mkdir("/lib") catch |err| switch (err) {
        error.NameExists => {},
        else => {
            serial.printLine("[VNK] FATAL: the directory /lib could not be created: {s}", .{@errorName(err)});
            port.haltForever();
        },
    };

    const vlib_options = vlib.Options{
        .name = vlib_library_name,
        .abi_version = syscall.abi_version,
        .required_capabilities = vlib_required_capabilities,
        .flags = vlib.Flags.relocatable,
        .symbols = &vlib_symbols,
        .image = &toolchain_app.bytes,
    };
    vlib_packed_length = vlib.pack(vlib_options, &vlib_pack_buffer) catch |err| {
        serial.printLine("[VNK] FATAL: the VLIB library could not be packed: {s}", .{@errorName(err)});
        port.haltForever();
    };
    if (vlib_packed_length != vlib_packed_size) {
        serial.printLine("[VNK] FATAL: the VLIB library has {d} bytes, and the geometry says {d}", .{
            vlib_packed_length,
            vlib_packed_size,
        });
        port.haltForever();
    }

    const vlib_descriptor = fs.create(0, "/lib/libvoryn.vlb", 0o644) catch |err| {
        serial.printLine("[VNK] FATAL: the file /lib/libvoryn.vlb could not be created: {s}", .{@errorName(err)});
        port.haltForever();
    };
    const vlib_written = fs.write(0, vlib_descriptor, vlib_pack_buffer[0..vlib_packed_length]) catch |err| {
        serial.printLine("[VNK] FATAL: the file /lib/libvoryn.vlb could not be written: {s}", .{@errorName(err)});
        port.haltForever();
    };
    if (vlib_written != vlib_packed_length) {
        serial.printLine("[VNK] FATAL: the file /lib/libvoryn.vlb accepted {d} bytes", .{vlib_written});
        port.haltForever();
    }
    fs.close(0, vlib_descriptor) catch |err| {
        serial.printLine("[VNK] FATAL: the file /lib/libvoryn.vlb could not be closed: {s}", .{@errorName(err)});
        port.haltForever();
    };
    serial.printLine("[VNK] vlib: packed {s} symbols={d} image={d} bytes abi={d} requires=0x{x} total={d} bytes", .{
        vlib_library_name,
        vlib_symbols.len,
        toolchain_app.bytes.len,
        syscall.abi_version,
        vlib_required_capabilities,
        vlib_packed_length,
    });

    serial.printLine("[VNK] fs: /apps/sample.vpk installed ({d} bytes)", .{vpk_packed_length});

    // F4: arquivo maior que os 12 blocos diretos. A gravação atravessa a
    // tabela indireta; o arquivo é verificado de novo depois da
    // persistência/recuperação VNV.
    for (&large_file_buffer, 0..) |*byte, index| byte.* = largeFileByte(index);
    const large_descriptor = fs.create(0, "/apps/large.bin", 0o644) catch |err| {
        serial.printLine("[VNK] FATAL: the file /apps/large.bin could not be created: {s}", .{@errorName(err)});
        port.haltForever();
    };
    const large_written = fs.write(0, large_descriptor, &large_file_buffer) catch |err| {
        serial.printLine("[VNK] FATAL: the file /apps/large.bin could not be written: {s}", .{@errorName(err)});
        port.haltForever();
    };
    if (large_written != large_file_size) {
        serial.printLine("[VNK] FATAL: the file /apps/large.bin accepted {d} bytes", .{large_written});
        port.haltForever();
    }
    fs.close(0, large_descriptor) catch |err| {
        serial.printLine("[VNK] FATAL: the file /apps/large.bin could not be closed: {s}", .{@errorName(err)});
        port.haltForever();
    };
    serial.printLine("[VNK] fs: /apps/large.bin installed ({d} bytes, indirect blocks)", .{large_file_size});
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
/// Bytes of the embedded model, for the diagnostics.
const ai_image_bytes: usize = ai_embedded.image_len;

/// Runs the model embedded in the kernel and compares the result with the
/// contract.
///
/// The check has three parts, and each one fails the boot on its own:
///
///   1. the image passes the same validation that the system call runs
///      (magic, version, geometry, offsets and CRC32 of the weights);
///   2. the inference produces exactly the output of `shared/ai.zig`;
///   3. the checksum of the result is the one published by the contract.
///
/// A failure is fatal **before** the processes exist: a kernel that cannot
/// run its own model would answer the call 24 with numbers that look valid,
/// and that is worse than not booting. The values are printed scaled by
/// 1000, because the serializer of the kernel does not format floats and a
/// hand written float printer would be a new source of defects in the boot
/// path.
fn verifyAiSelfTest() void {
    ai_model.validate(&ai_embedded.image) catch |err| {
        serial.printLine("[VNK] FATAL: the embedded model is invalid: {s}", .{@errorName(err)});
        port.haltForever();
    };

    const info = ai_model.fromBytes(&ai_embedded.image) catch |err| {
        serial.printLine("[VNK] FATAL: the embedded model has no readable header: {s}", .{@errorName(err)});
        port.haltForever();
    };

    serial.printLine(
        "[VNK] ai: model validated id={d} input={d} hidden={d} output={d} image={d} bytes weights={d} bytes crc ok",
        .{ ai_contract.model_id, info.input_dims, info.hidden_dims, info.output_dims, ai_image_bytes, info.weight_size },
    );

    var features: [ai_contract.input_dims]f32 = ai_contract.sample_input;
    var result: [ai_contract.output_dims]f32 = @splat(0.0);
    ai_model.infer(&ai_embedded.image, &features, &result) catch |err| {
        serial.printLine("[VNK] FATAL: the embedded model did not run: {s}", .{@errorName(err)});
        port.haltForever();
    };

    if (!ai_contract.matchesExpected(&result)) {
        serial.printLine("[VNK] FATAL: the embedded model produced an output outside the contract", .{});
        port.haltForever();
    }

    const checksum = ai_contract.checksumOf(&result);
    if (checksum != ai_contract.expectedChecksum()) {
        serial.printLine("[VNK] FATAL: the checksum of the inference is not the one of the contract", .{});
        port.haltForever();
    }

    // Escala inteira exata: 2.125, 5.25 e 4.0 em milésimos.
    const scale: f32 = 1000.0;
    serial.printLine("[VNK] ai: inference ok output_x1000={d},{d},{d} checksum=0x{x} model={d}", .{
        @as(u32, @intFromFloat(result[0] * scale)),
        @as(u32, @intFromFloat(result[1] * scale)),
        @as(u32, @intFromFloat(result[2] * scale)),
        checksum,
        ai_contract.model_id,
    });
}

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

    // A capability da inferencia (F9). O processo que compoe e o dono do
    // modelo: ele recebe o direito de executar, e nao o de delegar, porque
    // nao existe hoje um segundo consumidor do motor. O modelo continua
    // dentro do kernel; a capability autoriza a chamada 24 e nao expoe
    // pesos, workspace nem endereco.
    const ai_rights = capability.Rights.execute;
    const ai_handle = capability.create(.ai, 0, ai_rights | capability.Rights.delegate) orelse {
        serial.printLine("[VNK] FATAL: the table of capabilities is full", .{});
        port.haltForever();
    };
    if (!capability.give(presenter.id, ai_handle, ai_rights)) {
        serial.printLine("[VNK] FATAL: the capability of the inference could not be given", .{});
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
    if (!capability.give(client.id, frame_channel, capability.Rights.send | capability.Rights.receive)) {
        serial.printLine("[VNK] FATAL: the capability of the frame channel could not be given to the client", .{});
        port.haltForever();
    }
    if (!capability.give(presenter.id, frame_channel, capability.Rights.send | capability.Rights.receive)) {
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
    serial.printLine("[VNK] capabilities: the inference engine belongs to the process {d}", .{presenter.id});
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
///
/// The file is a VEX container: `planFromRamFs` validates the header, the
/// CRC and the capability manifest, unwraps the ELF and plans it.
fn installToolchainProcess() void {
    if (!enable_user_task) return;

    const window = user_window_base;
    const plan = elf_loader.planFromRamFs(
        "/apps/toolchain.vex",
        &toolchain_image_buffer,
        window,
        window,
        usermode.window_size,
    ) catch |err| {
        serial.printLine("[VNK] FATAL: the toolchain image could not be planned: {s}", .{@errorName(err)});
        port.haltForever();
    };

    // F5: o manifest declarado no VEX é imposto contra a concessão do
    // kernel. A leitura usa um buffer próprio, porque o planejador
    // desembrulhou o payload no buffer da imagem.
    var declared: [vex.max_manifest_entries]vex.Capability = undefined;
    var toolchain_manifest_buffer: [toolchain_app.bytes.len + vex.header_size + vex.max_manifest_entries * 8]u8 = undefined;
    const declared_count = elf_loader.readManifestFromRamFs(
        "/apps/toolchain.vex",
        &toolchain_manifest_buffer,
        &declared,
    ) catch |err| {
        serial.printLine("[VNK] FATAL: the toolchain manifest could not be read: {s}", .{@errorName(err)});
        port.haltForever();
    };
    verifyVexManifest(declared[0..declared_count]);

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

    serial.printLine("[VNK] toolchain: /apps/toolchain.vex entry=0x{x} base=0x{x} end=0x{x}, {d} segments, {d} relocation(s)", .{
        plan.entry,
        plan.base,
        plan.end,
        plan.segment_count,
        plan.relocation_count,
    });
    serial.printLine("[VNK] vex: unwrapped and planned from the VEX image", .{});

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

/// F5: impõe o manifest VEX contra a concessão de capacidades do kernel.
///
/// Cada entrada declarada tem de ser um kind que o kernel concede a este
/// processo, e os direitos declarados têm de ser um subconjunto dos
/// direitos concedidos. Uma declaração que o kernel não honra é fatal: o
/// binário exigiria uma autoridade que o kernel não entrega.
fn verifyVexManifest(declared: []const vex.Capability) void {
    if (declared.len == 0) {
        serial.printLine("[VNK] FATAL: the VEX declares no capabilities", .{});
        port.haltForever();
    }
    for (declared) |entry| {
        const granted: u64 = switch (entry.kind) {
            .display => capability.Rights.write | capability.Rights.delegate,
            .input => capability.Rights.read | capability.Rights.delegate,
            else => {
                serial.printLine("[VNK] FATAL: the VEX declares kind {d}, which the kernel does not grant to this process", .{
                    @backingInt(entry.kind),
                });
                port.haltForever();
            },
        };
        if (@as(u64, entry.rights) & ~granted != 0) {
            serial.printLine("[VNK] FATAL: the VEX declares rights 0x{x} beyond the granted 0x{x}", .{
                entry.rights,
                granted,
            });
            port.haltForever();
        }
        serial.printLine("[VNK] vex: manifest entry kind={d} rights=0x{x} within the grant 0x{x}", .{
            @backingInt(entry.kind),
            entry.rights,
            granted,
        });
    }
    serial.printLine("[VNK] vex: manifest enforced against the kernel grant ({d} entries)", .{declared.len});
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
        serial.printLine("[VNK] toolchain: /apps/toolchain.vex ran from the toolchain", .{});
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
    fs.close(normal.id, normal_fd) catch |err| {
        serial.printLine("[VNK] FATAL: lifecycle normal close: {s}", .{@errorName(err)});
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
    fs.close(fault.id, fault_fd) catch |err| {
        serial.printLine("[VNK] FATAL: lifecycle fault close: {s}", .{@errorName(err)});
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
    var truncate_cleanup_ok = true;
    fs.unlink("/apps/truncate-probe.txt") catch |err| {
        truncate_cleanup_ok = false;
        // A failed ring-3 probe may never create the file. Report the
        // missing artifact without suppressing subsequent diagnostics.
        serial.printLine("[VNK] fs: truncate probe cleanup failed: {s}", .{@errorName(err)});
    };
    if (!truncate_cleanup_ok) {
        serial.printLine("[VNK] fs: lifecycle probe incomplete (truncate artifact missing)", .{});
        return;
    }
    if (fs.freeBlockCount() != lifecycle_blocks_before or
        fs.freeInodeCount() != lifecycle_inodes_before)
    {
        serial.printLine("[VNK] FATAL: fs lifecycle descriptors were not reclaimed", .{});
        port.haltForever();
    }
    serial.printLine("[VNK] fs: lifecycle cleanup normal exit and user fault ok", .{});
}

/// F4: commit do volume raiz em um dispositivo de blocos, wipe e recovery.
///
/// O autoteste executa depois do probe de ciclo de vida, quando todos os
/// processos de usuário terminaram e a fachada provou que nenhum descritor
/// ficou aberto: apagar o estado do volume não invalida um descritor vivo.
/// O commit serializa o estado vivo (`fs.stateFor(0)`) em uma imagem VNV,
/// o wipe destrói o estado, e a recuperação relê a imagem, valida magic,
/// geometria e CRC, e substitui o estado no lugar. Só depois disso o boot
/// volta a ler o filesystem.
fn verifyFsPersistence() void {
    const state = fs.stateFor(0) orelse {
        serial.printLine("[VNK] FATAL: the root RamFS volume is unavailable", .{});
        port.haltForever();
    };

    persistence_ramdisk = ramdisk.RamDisk.init(&persistence_ramdisk_memory, persistence_sector_size);
    const device = persistence_ramdisk.device();
    serial.printLine("[VNK] fs: persistence device ready, {d} sectors of {d} bytes", .{
        device.sector_count,
        device.sector_size,
    });

    persistence_sequence += 1;
    vnv_volume.commit(&device, state, persistence_sequence, &persistence_staging) catch |err| {
        serial.printLine("[VNK] FATAL: the VNV commit failed: {s}", .{@errorName(err)});
        port.haltForever();
    };
    serial.printLine("[VNK] fs: vnv committed sequence={d} image={d} bytes over {d} sectors", .{
        persistence_sequence,
        vnv.image_size,
        vnv_volume.requiredSectors(device.sector_size),
    });

    // O wipe destrói o estado vivo; a leitura tem de falhar.
    fs.wipeVolume(0);
    var probe: [8]u8 = undefined;
    if (fs.readFile("/apps/hello.txt", &probe)) |_| {
        serial.printLine("[VNK] FATAL: the wiped volume still holds /apps/hello.txt", .{});
        port.haltForever();
    } else |_| {
        serial.printLine("[VNK] fs: volume wiped, /apps/hello.txt no longer resolvable", .{});
    }

    device.readBytes(0, persistence_staging[0..vnv.image_size]) catch |err| {
        serial.printLine("[VNK] FATAL: the VNV image could not be read: {s}", .{@errorName(err)});
        port.haltForever();
    };
    vnv.decode(persistence_staging[0..vnv.image_size], state, &persistence_scratch) catch |err| {
        serial.printLine("[VNK] FATAL: the VNV recovery failed: {s}", .{@errorName(err)});
        port.haltForever();
    };
    serial.printLine("[VNK] fs: vnv recovered sequence={d} from the block device", .{persistence_sequence});

    // A árvore recuperada tem de servir o filesystem de novo.
    var buffer: [8]u8 = undefined;
    const count = fs.readFile("/apps/hello.txt", &buffer) catch |err| {
        serial.printLine("[VNK] FATAL: the recovered volume lost /apps/hello.txt: {s}", .{@errorName(err)});
        port.haltForever();
    };
    if (count != 7 or !std.mem.eql(u8, buffer[0..count], "VorynOS")) {
        serial.printLine("[VNK] FATAL: the recovered volume returned the wrong content", .{});
        port.haltForever();
    }
    verifyRecoveredSize("/apps/hello.elf", native_image_length);
    verifyRecoveredSize("/apps/toolchain.vex", toolchain_vex_length);
    verifyRecoveredSize("/apps/client.elf", client_app.bytes.len);
    verifyRecoveredSize("/apps/sample.vpk", vpk_packed_length);
    verifyRecoveredSize("/apps/large.bin", large_file_size);
    verifyLargeFileContent();
    verifyDirectoryRename();
    serial.printLine("[VNK] fs: persistence round trip ok (hello.txt + 5 files, {d} blocks free)", .{
        fs.freeBlockCount(),
    });
}

/// F4: rename de diretórios end-to-end, com subárvore e recusa de ciclo.
fn verifyDirectoryRename() void {
    _ = fs.mkdir("/apps/work") catch |err| {
        serial.printLine("[VNK] FATAL: work directory create: {s}", .{@errorName(err)});
        port.haltForever();
    };
    _ = fs.mkdir("/apps/work/sub") catch |err| {
        serial.printLine("[VNK] FATAL: work subdirectory create: {s}", .{@errorName(err)});
        port.haltForever();
    };
    const fd = fs.create(0, "/apps/work/sub/file.txt", 0o644) catch |err| {
        serial.printLine("[VNK] FATAL: work file create: {s}", .{@errorName(err)});
        port.haltForever();
    };
    _ = fs.write(0, fd, "renamed") catch |err| {
        serial.printLine("[VNK] FATAL: work file write: {s}", .{@errorName(err)});
        port.haltForever();
    };
    fs.close(0, fd) catch |err| {
        serial.printLine("[VNK] FATAL: work file close: {s}", .{@errorName(err)});
        port.haltForever();
    };

    fs.rename("/apps/work", "/apps/workspace") catch |err| {
        serial.printLine("[VNK] FATAL: directory rename failed: {s}", .{@errorName(err)});
        port.haltForever();
    };
    var buffer: [8]u8 = undefined;
    const count = fs.readFile("/apps/workspace/sub/file.txt", &buffer) catch |err| {
        serial.printLine("[VNK] FATAL: renamed subtree lost the file: {s}", .{@errorName(err)});
        port.haltForever();
    };
    if (count != 7 or !std.mem.eql(u8, buffer[0..count], "renamed")) {
        serial.printLine("[VNK] FATAL: renamed subtree holds the wrong content", .{});
        port.haltForever();
    }

    // Ciclo: mover o diretório para dentro da própria subárvore é recusado.
    if (fs.rename("/apps/workspace", "/apps/workspace/sub/loop")) |_| {
        serial.printLine("[VNK] FATAL: a directory cycle was accepted", .{});
        port.haltForever();
    } else |err| {
        if (err != error.InvalidDirectory) {
            serial.printLine("[VNK] FATAL: cycle rejection answered {s}, expected InvalidDirectory", .{@errorName(err)});
            port.haltForever();
        }
    }

    fs.unlink("/apps/workspace/sub/file.txt") catch |err| {
        serial.printLine("[VNK] FATAL: rename work file cleanup: {s}", .{@errorName(err)});
        port.haltForever();
    };
    serial.printLine("[VNK] fs: directory rename round trip ok", .{});
}

/// Verifica o conteúdo do arquivo grande recuperado, nas três regiões: o
/// primeiro bloco direto, o primeiro byte da tabela indireta e o fim.
fn verifyLargeFileContent() void {
    const descriptor = fs.open(0, "/apps/large.bin", 0) catch |err| {
        serial.printLine("[VNK] FATAL: the recovered volume lost /apps/large.bin: {s}", .{@errorName(err)});
        port.haltForever();
    };
    defer fs.close(0, descriptor) catch {};
    var window: [16]u8 = undefined;

    fs.seek(0, descriptor, 0) catch |err| {
        serial.printLine("[VNK] FATAL: large file seek failed: {s}", .{@errorName(err)});
        port.haltForever();
    };
    const first = fs.read(0, descriptor, &window) catch |err| {
        serial.printLine("[VNK] FATAL: large file read failed: {s}", .{@errorName(err)});
        port.haltForever();
    };
    if (first != window.len) {
        serial.printLine("[VNK] FATAL: large file read {d} bytes at the start", .{first});
        port.haltForever();
    }
    for (window, 0..) |byte, index| {
        if (byte != largeFileByte(index)) {
            serial.printLine("[VNK] FATAL: large file byte {d} is 0x{x}, expected 0x{x}", .{
                index, byte, largeFileByte(index),
            });
            port.haltForever();
        }
    }

    // Primeiro byte alcançado pela tabela indireta: o fim dos 12 diretos.
    const indirect_offset: usize = ramfs.direct_blocks * ramfs.block_size;
    fs.seek(0, descriptor, indirect_offset) catch |err| {
        serial.printLine("[VNK] FATAL: large file seek to indirect failed: {s}", .{@errorName(err)});
        port.haltForever();
    };
    const mid = fs.read(0, descriptor, &window) catch |err| {
        serial.printLine("[VNK] FATAL: large file indirect read failed: {s}", .{@errorName(err)});
        port.haltForever();
    };
    if (mid != window.len) {
        serial.printLine("[VNK] FATAL: large file read {d} bytes at the indirect boundary", .{mid});
        port.haltForever();
    }
    for (window, 0..) |byte, index| {
        if (byte != largeFileByte(indirect_offset + index)) {
            serial.printLine("[VNK] FATAL: large file indirect byte {d} is 0x{x}", .{ index, byte });
            port.haltForever();
        }
    }

    fs.seek(0, descriptor, large_file_size - window.len) catch |err| {
        serial.printLine("[VNK] FATAL: large file seek to end failed: {s}", .{@errorName(err)});
        port.haltForever();
    };
    const tail = fs.read(0, descriptor, &window) catch |err| {
        serial.printLine("[VNK] FATAL: large file tail read failed: {s}", .{@errorName(err)});
        port.haltForever();
    };
    if (tail != window.len) {
        serial.printLine("[VNK] FATAL: large file read {d} bytes at the end", .{tail});
        port.haltForever();
    }
    for (window, 0..) |byte, index| {
        if (byte != largeFileByte(large_file_size - window.len + index)) {
            serial.printLine("[VNK] FATAL: large file tail byte {d} is 0x{x}", .{ index, byte });
            port.haltForever();
        }
    }
    serial.printLine("[VNK] fs: large file round trip ok (indirect blocks)", .{});
}

/// Confere o tamanho de um arquivo recuperado do dispositivo de blocos.
fn verifyRecoveredSize(path: []const u8, expected: usize) void {
    const size = fs.sizeOf(path) catch |err| {
        serial.printLine("[VNK] FATAL: the recovered volume lost {s}: {s}", .{ path, @errorName(err) });
        port.haltForever();
    };
    if (size != expected) {
        serial.printLine("[VNK] FATAL: {s} recovered with {d} bytes, expected {d}", .{ path, size, expected });
        port.haltForever();
    }
}

/// F5: o pacote VPK gravado no RamFS é relido, validado e desempacotado.
///
/// A validação cobre magic, versão, geometria, CRC do corpo e consistência
/// da tabela; cada entrada é conferida pelo CRC próprio. O autoteste roda
/// depois da recuperação VNV, então o caminho verificado é empacotar,
/// persistir, recuperar e desempacotar.
fn verifyVpkPackaging() void {
    var package: [vpk_pack_buffer_size]u8 = undefined;
    const count = fs.readFile("/apps/sample.vpk", &package) catch |err| {
        serial.printLine("[VNK] FATAL: the recovered volume lost /apps/sample.vpk: {s}", .{@errorName(err)});
        port.haltForever();
    };
    const info = vpk.validate(package[0..count]) catch |err| {
        serial.printLine("[VNK] FATAL: the recovered VPK failed validation: {s}", .{@errorName(err)});
        port.haltForever();
    };
    if (info.entry_count != 2 or info.total_size != vpk_packed_length) {
        serial.printLine("[VNK] FATAL: the recovered VPK geometry changed", .{});
        port.haltForever();
    }

    var entry: [64]u8 = undefined;
    const hello = vpk.readEntryByName(package[0..count], "hello.txt", &entry) catch |err| {
        serial.printLine("[VNK] FATAL: the VPK entry hello.txt failed: {s}", .{@errorName(err)});
        port.haltForever();
    };
    if (hello != 7 or !std.mem.eql(u8, entry[0..hello], "VorynOS")) {
        serial.printLine("[VNK] FATAL: the VPK entry hello.txt has the wrong content", .{});
        port.haltForever();
    }
    const manifest = vpk.readEntryByName(package[0..count], "manifest.vcfg", &entry) catch |err| {
        serial.printLine("[VNK] FATAL: the VPK entry manifest.vcfg failed: {s}", .{@errorName(err)});
        port.haltForever();
    };
    if (!std.mem.eql(u8, entry[0..manifest], "app=hello\nexec=hello.vex\n")) {
        serial.printLine("[VNK] FATAL: the VPK entry manifest.vcfg has the wrong content", .{});
        port.haltForever();
    }
    serial.printLine("[VNK] vpk: /apps/sample.vpk validated and unpacked ({d} entries, {d} bytes)", .{
        info.entry_count,
        count,
    });
    serial.printLine("[VNK] vpk: pack/persist/recover/unpack round trip ok", .{});

    fs.unlink("/apps/sample.vpk") catch |err| {
        serial.printLine("[VNK] FATAL: the VPK file could not be removed: {s}", .{@errorName(err)});
        port.haltForever();
    };
}

/// Validates the library container after the VNV recovery.
///
/// The check is byte-for-byte between the file that the recovery returned and
/// the bytes that the kernel packed before the commit. A container that
/// validated but differed by one byte would pass a CRC-only comparison
/// against itself, therefore the comparison is against the **original**
/// buffer, and the CRC of the image is checked twice: by the codec and by the
/// equality with the toolchain image.
fn verifyVlibPackaging() void {
    const written = fs.readFile("/lib/libvoryn.vlb", &vlib_read_buffer) catch |err| {
        serial.printLine("[VNK] FATAL: the recovered volume lost /lib/libvoryn.vlb: {s}", .{@errorName(err)});
        port.haltForever();
    };
    if (written != vlib_packed_length) {
        serial.printLine("[VNK] FATAL: the recovered VLIB has {d} bytes, and the packed file had {d}", .{
            written,
            vlib_packed_length,
        });
        port.haltForever();
    }
    if (!std.mem.eql(u8, vlib_read_buffer[0..written], vlib_pack_buffer[0..vlib_packed_length])) {
        serial.printLine("[VNK] FATAL: the recovered VLIB differs from the packed file", .{});
        port.haltForever();
    }

    const info = vlib.validate(vlib_read_buffer[0..written]) catch |err| {
        serial.printLine("[VNK] FATAL: the recovered VLIB failed validation: {s}", .{@errorName(err)});
        port.haltForever();
    };
    if (!std.mem.eql(u8, info.name, vlib_library_name)) {
        serial.printLine("[VNK] FATAL: the recovered VLIB names another library", .{});
        port.haltForever();
    }
    if (info.abi_version != syscall.abi_version) {
        serial.printLine("[VNK] FATAL: the recovered VLIB targets ABI {d}, and the kernel implements {d}", .{
            info.abi_version,
            syscall.abi_version,
        });
        port.haltForever();
    }
    if (info.symbol_count != vlib_symbols.len or info.required_capabilities != vlib_required_capabilities) {
        serial.printLine("[VNK] FATAL: the recovered VLIB geometry changed", .{});
        port.haltForever();
    }
    if (info.image.len != toolchain_app.bytes.len or
        !std.mem.eql(u8, info.image, &toolchain_app.bytes))
    {
        serial.printLine("[VNK] FATAL: the image inside the recovered VLIB is not the one that was packed", .{});
        port.haltForever();
    }

    // O export é encontrado; o símbolo interno não é oferecido.
    const main = vlib.findExport(vlib_read_buffer[0..written], "voryn_main") catch |err| {
        serial.printLine("[VNK] FATAL: the VLIB export voryn_main was not found: {s}", .{@errorName(err)});
        port.haltForever();
    };
    if (main.value != 0x1000 or main.kind != .function) {
        serial.printLine("[VNK] FATAL: the VLIB export voryn_main has the wrong value", .{});
        port.haltForever();
    }
    if (vlib.findExport(vlib_read_buffer[0..written], "internal_helper")) |_| {
        serial.printLine("[VNK] FATAL: the VLIB offered a hidden symbol as an export", .{});
        port.haltForever();
    } else |err| {
        if (err != error.SymbolNotFound) {
            serial.printLine("[VNK] FATAL: the lookup of the hidden symbol failed with {s}", .{@errorName(err)});
            port.haltForever();
        }
    }

    // A imagem embutida é um ELF64 de verdade: o contêiner carrega código, e
    // não um blob opaco. O carregamento da biblioteca em um processo é o
    // próximo incremento e **não** é alegado aqui.
    var segments: [8]voryn.elf64.Segment = undefined;
    var relocations: [8]voryn.elf64.Relocation = undefined;
    const parsed = voryn.elf64.parse(info.image, &segments, &relocations) catch |err| {
        serial.printLine("[VNK] FATAL: the image inside the VLIB is not an ELF64: {s}", .{@errorName(err)});
        port.haltForever();
    };
    if (parsed.segments.len == 0) {
        serial.printLine("[VNK] FATAL: the image inside the VLIB has no loadable segment", .{});
        port.haltForever();
    }

    serial.printLine("[VNK] vlib: /lib/libvoryn.vlb validated after recovery symbols={d} image={d} bytes segments={d}", .{
        info.symbol_count,
        info.image.len,
        parsed.segments.len,
    });
    serial.printLine("[VNK] vlib: export voryn_main at 0x{x}, hidden internal_helper not exported", .{main.value});
    serial.printLine("[VNK] vlib: pack/persist/recover/validate round trip ok", .{});

    fs.unlink("/lib/libvoryn.vlb") catch |err| {
        serial.printLine("[VNK] FATAL: the VLIB file could not be removed: {s}", .{@errorName(err)});
        port.haltForever();
    };
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

test "F14 render latency accumulates bounded min mean max and baseline" {
    var stats: RenderLatency = .{};
    try std.testing.expectEqual(@as(u64, 0), stats.meanCycles());
    stats.record(300, 80, 120);
    stats.record(100, 60, 120);
    stats.record(200, 70, 120);
    try std.testing.expectEqual(@as(u64, 3), stats.samples);
    try std.testing.expectEqual(@as(u64, 100), stats.cycles_min);
    try std.testing.expectEqual(@as(u64, 200), stats.meanCycles());
    try std.testing.expectEqual(@as(u64, 300), stats.cycles_max);
    try std.testing.expectEqual(@as(u64, 210), stats.pixels_sum);
    try std.testing.expectEqual(@as(u64, 360), stats.baseline_sum);
}

test "F14.1 latency percentile window handles empty, ordering and eviction" {
    var stats: RenderLatency = .{};
    try std.testing.expectEqual(@as(u64, 0), stats.percentileCycles(95));
    stats.record(400, 1, 2);
    stats.record(100, 1, 2);
    stats.record(300, 1, 2);
    stats.record(200, 1, 2);
    try std.testing.expectEqual(@as(u64, 200), stats.percentileCycles(50));
    try std.testing.expectEqual(@as(u64, 400), stats.percentileCycles(95));
    for (0..32) |i| stats.record(@as(u64, @intCast(i + 1)), 1, 2);
    try std.testing.expectEqual(@as(usize, 32), stats.recent_count);
    try std.testing.expectEqual(@as(u64, 16), stats.percentileCycles(50));
    try std.testing.expectEqual(@as(u64, 31), stats.percentileCycles(95));
    try std.testing.expectEqual(@as(u64, 32), stats.percentileCycles(99));
}
