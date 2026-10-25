//************************************************************************//
//  smp.zig                                                               //
//************************************************************************//
//                         This file is part of:                          //
//                               VorynOS                                  //
//              https://github.com/CeoMatheusDev/VorynOS                  //
//************************************************************************//
// Copyright (C) 2026 VorynOS contributors.                               //
//                                                                        //
// SPDX-License-Identifier: GPL-3.0-only                                  //
//************************************************************************//

//! Suporte a multiprocessamento simetrico (SMP).
//!
//! O modulo descobre os processadores pela MADT da ACPI, mapeia o APIC
//! local, copia o trampoline para uma pagina abaixo de 1 MiB e inicializa
//! cada AP com a sequencia INIT-SIPI-SIPI.
//!
//! Cada CPU logica tem:
//!
//!   * um numero (0 para o BSP, 1..N para os APs);
//!   * o identificador do APIC local;
//!   * um estado (ausente, inicializando, online ou offline);
//!   * um ponteiro para a tarefa que esta executando.
//!
//! O escalonador ainda e monoprocessador: os APs entram em um laco de
//! espera com interrupcoes desligadas e nao executam tarefas. A fila por
//! CPU, as IPIs de reescalonamento e o EEVDF sao os proximos incrementos.
//!
//! O numero da CPU atual (`cpuId`) continua retornando zero: a leitura
//! correta exige uma area por CPU acessivel por GS, que sera instalada
//! junto com o escalonador multiprocessador.

const std = @import("std");
const voryn = @import("voryn_shared");

const acpi = @import("acpi.zig");
const apic = @import("apic.zig");
const paging = @import("paging.zig");
const spinlock = @import("spinlock.zig");
const timer = @import("timer.zig");
const serial = voryn.serial;
const x86_cpu = @import("cpu.zig");

/// Numero maximo de CPUs logicas suportadas.
pub const max_cpus: u8 = 8;

/// Menor pagina que o trampoline pode ocupar abaixo de 1 MiB.
///
/// A IVT e a BDA ocupam os primeiros 4 KiB; a EBDA e a area de video
/// comecam em 0xA0000. O trampoline nunca e colocado nessas regioes.
const low_memory_start: u64 = 0x1000;
const low_memory_end: u64 = 0xA0000;

/// Estado de uma CPU logica.
pub const CpuState = enum {
    /// A CPU nao foi detectada ou nao esta presente.
    absent,
    /// A CPU esta online e executando.
    online,
    /// A CPU esta sendo inicializada (AP em processo de boot).
    initializing,
    /// A CPU foi desligada.
    offline,
};

/// Dados privados de uma CPU logica.
pub const Cpu = struct {
    /// Numero da CPU (0 para o BSP, 1..N para os APs).
    id: u8 = 0,
    /// Identificador do APIC local da CPU.
    apic_id: u32 = 0,
    /// Estado atual da CPU.
    state: CpuState = .absent,
    /// Tarefa que esta executando nesta CPU (null se nenhuma).
    current_task: ?*anyopaque = null,
    /// Espinlock que protege os dados desta CPU.
    lock: spinlock.Spinlock = .{},
};

/// Tabela de CPUs: um slot por numero de CPU logica.
///
/// O BSP e a CPU zero e ja nasce online.
var cpus: [max_cpus]Cpu = blk: {
    var table: [max_cpus]Cpu = @splat(.{});
    table[0] = .{ .id = 0, .state = .online };
    break :blk table;
};

/// Numero de CPUs online atualmente.
var online_cpu_count: u8 = 1;

/// True depois que o BSP configurou o GS com a estrutura da CPU zero.
var gs_ready: bool = false;

/// Processadores habilitados que a MADT descreveu.
var madt_processors: [max_cpus]acpi.Processor = @splat(.{});

/// Numero de processadores gravados em `madt_processors`.
var madt_processor_count: usize = 0;

/// A MADT descreveu mais processadores do que a tabela comporta.
var madt_truncated: bool = false;

/// Endereco fisico do APIC local, lido da MADT.
var local_apic_base: u64 = apic.default_base;

/// O RSDP foi lido com sucesso.
var acpi_discovered: bool = false;

/// Identificador do APIC local do BSP.
var bsp_apic_id: u32 = 0;

/// Flags de disponibilidade dos APs: indice por numero logico da CPU.
///
/// O AP escreve 1 no proprio indice; o BSP observa o valor com semantica
/// de acquire/release. A tabela fica separada de `cpus` para que o AP nao
/// precise de nenhum lock para se anunciar.
var ap_online: [max_cpus]u8 = @splat(0);

/// Pilhas de kernel dos APs, uma por CPU logica (o BSP usa a pilha de
/// `kernel/main.zig`).
var ap_stacks: [max_cpus - 1][16 * 1024]u8 align(16) = undefined;

/// Retorna o numero da CPU atual.
///
/// Le o identificador no inicio da estrutura da CPU corrente, que fica
/// acessivel por GS. Antes de o BSP configurar o GS, retorna zero, de
/// modo que as chamadas do boot e os testes no host nao dependam do
/// registro.
pub fn cpuId() u8 {
    if (!gs_ready) return 0;
    var id: u8 = 0;
    asm volatile ("movb %%gs:0, %[out]"
        : [out] "=r" (id)
        :
        : .{ .memory = true });
    return id;
}

/// Configura o GS da CPU atual para apontar para a estrutura da CPU.
///
/// Apenas o BSP chama esta funcao durante o boot; cada AP configura o
/// proprio GS no ponto de entrada.
pub fn setGsBase(id: u8) void {
    if (id >= max_cpus) return;
    x86_cpu.writeMsr(x86_cpu.msr_gs_base, @intFromPtr(&cpus[id]));
    if (id == 0) gs_ready = true;
}

/// Retorna o ponteiro para a estrutura da CPU atual.
pub fn currentCpu() *Cpu {
    return &cpus[cpuId()];
}

/// Retorna o numero de CPUs online.
pub fn cpuCount() u8 {
    return online_cpu_count;
}

/// Retorna o estado de uma CPU logica.
pub fn stateOf(id: u8) CpuState {
    if (id >= max_cpus) return .absent;
    return cpus[id].state;
}

/// Retorna os dados de uma CPU logica.
pub fn cpuAt(id: u8) ?*Cpu {
    if (id >= max_cpus) return null;
    return &cpus[id];
}

/// Registra uma CPU e a marca online.
///
/// O BSP usa esta funcao para a CPU zero; os APs passam por `beginAp` e
/// `completeAp`, porque o anuncio deles e assincrono. A contagem so cresce
/// quando a CPU ainda nao estava online.
pub fn registerCpu(id: u8, apic_id: u32) ?*Cpu {
    if (id >= max_cpus) return null;
    const cpu = &cpus[id];
    const was_online = cpu.state == .online;
    cpu.* = .{
        .id = id,
        .apic_id = apic_id,
        .state = .online,
        .current_task = null,
    };
    if (!was_online and online_cpu_count < max_cpus) {
        online_cpu_count += 1;
    }
    return cpu;
}

/// Prepara um slot para um AP que ainda vai ser inicializado.
pub fn beginAp(id: u8, apic_id: u32) ?*Cpu {
    if (id == 0 or id >= max_cpus) return null;
    const cpu = &cpus[id];
    if (cpu.state == .online) return null;
    cpu.* = .{
        .id = id,
        .apic_id = apic_id,
        .state = .initializing,
        .current_task = null,
    };
    return cpu;
}

/// Marca como online uma CPU que o AP anunciou.
///
/// Chamado pelo BSP depois de observar a flag do AP; a contagem so cresce
/// uma vez.
pub fn completeAp(id: u8) void {
    if (id == 0 or id >= max_cpus) return;
    if (cpus[id].state == .online) return;
    cpus[id].state = .online;
    if (online_cpu_count < max_cpus) online_cpu_count += 1;
}

/// Marca uma CPU como offline.
pub fn offlineCpu(id: u8) void {
    if (id >= max_cpus) return;
    if (cpus[id].state != .online) return;
    cpus[id].state = .offline;
    if (online_cpu_count > 1) online_cpu_count -= 1;
}

// ---------------------------------------------------------------------------
// Descoberta da ACPI
// ---------------------------------------------------------------------------

/// Le bytes da memoria fisica enquanto o mapeamento de identidade do
/// firmware esta ativo.
fn readPhysical(address: u64, destination: []u8) bool {
    if (address == 0 or address < low_memory_start) return false;
    const end = std.math.add(u64, address, destination.len) catch return false;
    if (end < address) return false;
    if (end > voryn.handoff.identity_mapped_limit) return false;

    const source: [*]const u8 = @ptrFromInt(address);
    @memcpy(destination, source[0..destination.len]);
    return true;
}

/// Le um inteiro de 32 bits da memoria fisica.
fn readPhysicalU32(address: u64) ?u32 {
    var bytes: [4]u8 = undefined;
    if (!readPhysical(address, &bytes)) return null;
    return std.mem.readInt(u32, &bytes, .little);
}

/// Procura a MADT na XSDT ou na RSDT.
fn findMadt(table_address: u64, entries_are_64: bool) ?u64 {
    var header: [36]u8 = undefined;
    if (!readPhysical(table_address, &header)) return null;
    const expected: []const u8 = if (entries_are_64) acpi.xsdt_signature else acpi.rsdt_signature;
    if (!acpi.hasSignature(&header, expected)) return null;

    const length = acpi.declaredLength(&header) catch return null;
    const entries_offset: u64 = 36;
    const entry_size: u64 = if (entries_are_64) 8 else 4;
    if (length < entries_offset) return null;
    const count = (length - entries_offset) / entry_size;
    const address_length: usize = if (entries_are_64) 8 else 4;

    var index: u64 = 0;
    while (index < count) : (index += 1) {
        const entry_address = table_address + entries_offset + index * entry_size;
        if (entry_address + entry_size > voryn.handoff.identity_mapped_limit) return null;

        var entry_value: [8]u8 = @splat(0);
        if (!readPhysical(entry_address, entry_value[0..address_length])) return null;
        const table_addr = if (entries_are_64)
            std.mem.readInt(u64, entry_value[0..8], .little)
        else
            std.mem.readInt(u32, entry_value[0..4], .little);

        if (table_addr == 0 or table_addr + 4 > voryn.handoff.identity_mapped_limit) continue;

        var signature: [4]u8 = undefined;
        if (!readPhysical(table_addr, &signature)) continue;
        if (!std.mem.eql(u8, &signature, acpi.madt_signature)) continue;

        return table_addr;
    }

    return null;
}

/// Descobre o APIC local e os processadores pela ACPI.
///
/// Deve ser chamado antes de o kernel trocar as tabelas de paginas do
/// firmware: a leitura usa o mapeamento de identidade que o carregador
/// garante no handoff. Uma falha nao impede o boot: o kernel continua com
/// uma unica CPU.
pub fn discover(rsdp_address: u64) void {
    if (rsdp_address == 0) {
        reportAcpi("the firmware did not publish the RSDP");
        return;
    }

    var base_bytes: [acpi.rsdp_base_size]u8 = @splat(0);
    if (!readPhysical(rsdp_address, &base_bytes)) {
        reportAcpi("the RSDP is outside the identity mapping");
        return;
    }

    const rsdp = acpi.validateRsdpBase(&base_bytes) catch |err| {
        reportAcpiError("RSDP", err);
        return;
    };

    var table_address: u64 = rsdp.rsdt_address;
    var entries_are_64 = false;
    if (rsdp.revision >= 2) {
        var extended: [acpi.rsdp_extended_size]u8 = @splat(0);
        if (!readPhysical(rsdp_address, &extended)) {
            reportAcpi("the extended RSDP is outside the identity mapping");
            return;
        }
        const xsdt = acpi.validateRsdpExtended(&extended) catch |err| {
            reportAcpiError("extended RSDP", err);
            return;
        };
        if (xsdt != 0) {
            table_address = xsdt;
            entries_are_64 = true;
        }
    }

    if (table_address == 0) {
        reportAcpi("the RSDP has no table address");
        return;
    }

    const madt_address = findMadt(table_address, entries_are_64) orelse {
        reportAcpi("the MADT was not found");
        return;
    };

    var madt_header: [36]u8 = undefined;
    if (!readPhysical(madt_address, &madt_header)) {
        reportAcpi("the MADT is outside the identity mapping");
        return;
    }
    const madt_length = acpi.declaredLength(&madt_header) catch |err| {
        reportAcpiError("MADT header", err);
        return;
    };
    if (madt_address + madt_length > voryn.handoff.identity_mapped_limit) {
        reportAcpi("the MADT is outside the identity mapping");
        return;
    }

    const madt_bytes: [*]const u8 = @ptrFromInt(madt_address);
    const madt = acpi.parseMadt(madt_bytes[0..madt_length], &madt_processors) catch |err| {
        reportAcpiError("MADT", err);
        return;
    };

    if (madt.local_apic_base != 0) {
        local_apic_base = madt.local_apic_base;
    }
    madt_processor_count = madt.count;
    madt_truncated = madt.truncated;
    acpi_discovered = true;

    serial.printLine("[VNK] acpi: rsdp revision={d} madt=0x{x} processors={d} apic=0x{x}", .{
        rsdp.revision,
        madt_address,
        madt.count,
        local_apic_base,
    });
    if (madt.truncated) {
        serial.printLine("[VNK] acpi: more processors than the {d} slots of the kernel", .{max_cpus});
    }
}

/// Relata uma falha da descoberta sem interromper o boot.
fn reportAcpi(message: []const u8) void {
    serial.printLine("[VNK] acpi: {s}", .{message});
}

/// Relata um erro de validacao da ACPI.
fn reportAcpiError(table: []const u8, err: acpi.Error) void {
    serial.printLine("[VNK] acpi: {s}: {s}", .{ table, @errorName(err) });
}

// ---------------------------------------------------------------------------
// Inicializacao dos APs
// ---------------------------------------------------------------------------

/// Retorna o topo da pilha de kernel de um AP (indice = cpu_id - 1).
fn apStackTop(index: usize) u64 {
    const stack = &ap_stacks[index];
    return @intFromPtr(stack.ptr) + stack.len;
}

/// Escolhe uma pagina livre abaixo de 1 MiB para o trampoline.
///
/// A memoria abaixo de 1 MiB nao e gerenciada pelo alocador de paginas do
/// kernel. A varredura usa o mapa do firmware e aceita as regioes que ja
/// estavam livres depois de `ExitBootServices` (convencionais, de carga e
/// de servicos de boot), nunca a memoria de runtime, o framebuffer ou a
/// imagem do kernel.
fn findTrampolinePage(map: []const voryn.handoff.MemoryDescriptor) ?u64 {
    var best: ?u64 = null;

    for (map) |descriptor| {
        if (!acceptsLowMemory(descriptor.memory_type)) continue;
        const start = descriptor.physical_start;
        const size = descriptor.byteSize();
        if (size < voryn.handoff.page_size) continue;

        const end = std.math.add(u64, start, size) catch continue;
        if (start >= low_memory_end) continue;
        const limit = @min(end, low_memory_end);
        if (limit < low_memory_start + voryn.handoff.page_size) continue;

        const page = (limit - voryn.handoff.page_size) & ~(voryn.handoff.page_size - 1);
        if (page < start or page < low_memory_start) continue;
        if (best == null or page > best.?) best = page;
    }

    return best;
}

/// Tipos de memoria que podem receber o trampoline.
fn acceptsLowMemory(kind: voryn.handoff.MemoryType) bool {
    return switch (kind) {
        .conventional,
        .loader_code,
        .loader_data,
        .boot_services_code,
        .boot_services_data,
        => true,
        else => false,
    };
}

/// Escreve um inteiro de 32 bits na copia do trampoline.
fn patchU32(trampoline: [*]u8, offset: usize, value: u32) void {
    const field: *align(1) u32 = @ptrFromInt(@intFromPtr(trampoline) + offset);
    field.* = value;
}

/// Escreve um inteiro de 64 bits na copia do trampoline.
fn patchU64(trampoline: [*]u8, offset: usize, value: u64) void {
    const field: *align(1) u64 = @ptrFromInt(@intFromPtr(trampoline) + offset);
    field.* = value;
}

/// Escreve um inteiro de 16 bits na copia do trampoline.
fn patchU16(trampoline: [*]u8, offset: usize, value: u16) void {
    const field: *align(1) u16 = @ptrFromInt(@intFromPtr(trampoline) + offset);
    field.* = value;
}

/// Distancia de um simbolo do trampoline em relacao ao inicio do bloco.
fn offsetOf(symbol: *const anyopaque) usize {
    return @intFromPtr(symbol) - @intFromPtr(&voryn_ap_trampoline_start);
}

/// Espera um numero de ticks do timer; o limite de voltas evita um laco
/// infinito quando o timer nao esta ativo.
fn waitTicks(count: u64) void {
    if (count == 0) return;
    const start = timer.ticks();
    var spins: u64 = 0;
    while (timer.ticks() - start < count) : (spins += 1) {
        if (spins >= 100_000_000) return;
        x86_cpu.pause();
    }
}

/// Inicializa o SMP depois que as tabelas de paginas do kernel estao ativas
/// e o timer ja funciona.
pub fn install(map: []const voryn.handoff.MemoryDescriptor) void {
    if (!acpi_discovered or madt_processor_count == 0) {
        serial.printLine("[VNK] smp: no processor information; single CPU", .{});
        return;
    }

    // O APIC local e uma pagina de dispositivo: sem cache e sem execucao.
    paging.mapDevicePage(local_apic_base, local_apic_base) catch |err| {
        serial.printLine("[VNK] smp: the APIC page could not be mapped: {s}", .{@errorName(err)});
        return;
    };
    apic.map(local_apic_base);

    if (apic.isX2ApicEnabled()) {
        serial.printLine("[VNK] smp: x2APIC is active; the xAPIC path is unavailable", .{});
        return;
    }

    apic.enable();
    apic.configureLegacyPic();
    apic.setTpr(0);

    const version = apic.readVersion();
    bsp_apic_id = apic.readApicId();
    if (version == 0 or bsp_apic_id == 0xFF) {
        serial.printLine("[VNK] smp: no local APIC (version={d} id={d})", .{ version, bsp_apic_id });
        return;
    }

    serial.printLine("[VNK] smp: apic id={d} version={d} base=0x{x}", .{
        bsp_apic_id,
        version,
        local_apic_base,
    });

    // A CPU zero e o BSP, que ja esta executando este codigo.
    _ = registerCpu(0, bsp_apic_id);
    setGsBase(0);

    var logical: u8 = 1;
    var processor_index: usize = 0;
    var selected: usize = 0;

    while (processor_index < madt_processor_count and logical < max_cpus) : (processor_index += 1) {
        const processor = madt_processors[processor_index];
        if (!processor.enabled) continue;
        if (processor.apic_id == bsp_apic_id) continue;
        if (processor.apic_id > 0xFF) {
            serial.printLine("[VNK] smp: apic id {d} is outside the 8-bit xAPIC destination", .{processor.apic_id});
            continue;
        }
        _ = beginAp(logical, processor.apic_id);
        selected += 1;
        logical += 1;
    }

    if (selected == 0) {
        serial.printLine("[VNK] smp: single processor, no AP to start", .{});
        return;
    }

    const page = findTrampolinePage(map) orelse {
        serial.printLine("[VNK] smp: no free page below 1 MiB for the trampoline", .{});
        return;
    };

    paging.mapKernelPage(page, page) catch |err| {
        serial.printLine("[VNK] smp: the trampoline page could not be mapped: {s}", .{@errorName(err)});
        return;
    };

    const size = voryn_ap_trampoline_size;
    if (size == 0 or size > voryn.handoff.page_size) {
        serial.printLine("[VNK] smp: invalid trampoline size {d}", .{size});
        return;
    }

    const source: [*]const u8 = @ptrFromInt(@intFromPtr(&voryn_ap_trampoline_start));
    const trampoline: [*]u8 = @ptrFromInt(page);
    @memcpy(trampoline[0..size], source[0..size]);

    // Campos independentes do AP.
    patchU32(trampoline, offsetOf(&voryn_ap_trampoline_gdt_descriptor) + 2, @intCast(page + offsetOf(&voryn_ap_trampoline_gdt_table)));
    patchU32(trampoline, offsetOf(&voryn_ap_trampoline_far32), @intCast(page + offsetOf(&voryn_ap_trampoline_protected_mode)));
    patchU16(trampoline, offsetOf(&voryn_ap_trampoline_far32) + 4, 0x08);
    patchU32(trampoline, offsetOf(&voryn_ap_trampoline_cr3), @intCast(paging.rootAddress()));
    patchU64(trampoline, offsetOf(&voryn_ap_trampoline_entry), @intFromPtr(&voryn_ap_entry));

    const vector: u8 = @intCast(page / voryn.handoff.page_size);
    serial.printLine("[VNK] smp: trampoline page=0x{x} vector=0x{x}", .{ page, vector });

    var id: u8 = 1;
    while (id <= selected) : (id += 1) {
        const entry = &cpus[id];
        if (entry.state != .initializing) continue;

        // O AP ainda nao esta executando: a flag da geracao anterior e
        // limpa antes de a copia receber os valores deste processador.
        @atomicStore(u8, &ap_online[id], 0, .release);
        patchU32(trampoline, offsetOf(&voryn_ap_trampoline_cpu_id), id);
        patchU64(trampoline, offsetOf(&voryn_ap_trampoline_stack), apStackTop(id - 1));
        patchU16(trampoline, offsetOf(&voryn_ap_trampoline_ready), 1);

        _ = apic.takeError();
        apic.sendInit(entry.apic_id);
        waitTicks(2);
        apic.sendStartup(entry.apic_id, vector);

        var started = false;
        const deadline = timer.ticks() + 50;
        while (timer.ticks() < deadline) {
            if (@atomicLoad(u8, &ap_online[id], .acquire) != 0) {
                started = true;
                break;
            }
            x86_cpu.pause();
        }

        if (started) {
            completeAp(id);
            serial.printLine("[VNK] smp: cpu {d} online apic={d}", .{ id, entry.apic_id });
        } else {
            const apic_error = apic.takeError();
            serial.printLine("[VNK] smp: cpu {d} did not start apic={d} error=0x{x}", .{
                id,
                entry.apic_id,
                apic_error,
            });
        }
    }

    serial.printLine("[VNK] smp: {d} cpu(s) online", .{online_cpu_count});
}

/// Ponto de entrada de um AP, chamado pelo trampoline em modo longo.
///
/// A pilha ja foi carregada pelo trampoline e o numero logico da CPU vem
/// em RDI (primeiro argumento da ABI SysV). A funcao nao toca em nenhuma
/// estrutura compartilhada alem da propria flag: a tabela de CPUs e
/// atualizada pelo BSP quando ele observa a flag.
pub export fn voryn_ap_entry(cpu_id: u32) callconv(.c) noreturn {
    if (cpu_id < max_cpus) {
        const id: u8 = @intCast(cpu_id);
        x86_cpu.writeMsr(x86_cpu.msr_gs_base, @intFromPtr(&cpus[id]));
        @atomicStore(u8, &ap_online[id], 1, .release);
    }

    // Sem trabalho por enquanto: o escalonador multiprocessador ainda nao
    // distribui tarefas para os APs. As interrupcoes continuam desligadas
    // (a SIPI comeca com IF = 0 e o trampoline nao a liga).
    while (true) {
        x86_cpu.halt();
    }
}

// ---------------------------------------------------------------------------
// Simbolos do trampoline em Assembly
// ---------------------------------------------------------------------------

/// Inicio do bloco do trampoline.
pub extern const voryn_ap_trampoline_start: u8;
/// Tamanho do bloco do trampoline, em bytes (objeto com o valor).
pub extern const voryn_ap_trampoline_size: u64;
/// Pseudo-descritor da GDT (limite + base de 32 bits).
pub extern const voryn_ap_trampoline_gdt_descriptor: u8;
/// Tabela GDT do trampoline.
pub extern const voryn_ap_trampoline_gdt_table: u8;
/// Ponteiro do salto para o modo protegido (offset de 32 bits + seletor).
pub extern const voryn_ap_trampoline_far32: u8;
/// Inicio do codigo de 32 bits.
pub extern const voryn_ap_trampoline_protected_mode: u8;
/// CR3 (endereco fisico da PML4) que o AP carrega.
pub extern const voryn_ap_trampoline_cr3: u8;
/// Topo da pilha de kernel do AP.
pub extern const voryn_ap_trampoline_stack: u8;
/// Numero logico da CPU.
pub extern const voryn_ap_trampoline_cpu_id: u8;
/// Endereco do ponto de entrada do AP no kernel.
pub extern const voryn_ap_trampoline_entry: u8;
/// Palavra de sincronizacao preenchida por ultimo.
pub extern const voryn_ap_trampoline_ready: u8;

// ---------------------------------------------------------------------------
// Testes
// ---------------------------------------------------------------------------

test "cpuId returns zero in the single-CPU scheduler" {
    try std.testing.expectEqual(cpuId(), 0);
}

test "registerCpu adds a CPU to the table" {
    online_cpu_count = 1;
    cpus[2] = .{};
    const c = registerCpu(2, 7) orelse return;
    try std.testing.expectEqual(c.id, 2);
    try std.testing.expectEqual(c.apic_id, 7);
    try std.testing.expectEqual(c.state, .online);
    try std.testing.expectEqual(cpuCount(), 2);
}

test "registerCpu rejects IDs above max_cpus" {
    try std.testing.expectEqual(registerCpu(max_cpus, 0), null);
}

test "beginAp and completeAp count the AP once" {
    online_cpu_count = 1;
    cpus[3] = .{};
    _ = beginAp(3, 9) orelse return;
    try std.testing.expectEqual(stateOf(3), .initializing);
    try std.testing.expectEqual(cpuCount(), 1);
    completeAp(3);
    try std.testing.expectEqual(stateOf(3), .online);
    try std.testing.expectEqual(cpuCount(), 2);
    completeAp(3);
    try std.testing.expectEqual(cpuCount(), 2);
}

test "offlineCpu reduces the online count but keeps at least the BSP" {
    online_cpu_count = 4;
    cpus[3] = .{ .id = 3, .state = .online };
    cpus[2] = .{ .id = 2, .state = .online };
    cpus[1] = .{ .id = 1, .state = .online };
    offlineCpu(3);
    try std.testing.expectEqual(cpuCount(), 3);
    offlineCpu(2);
    offlineCpu(1);
    offlineCpu(0);
    try std.testing.expectEqual(cpuCount(), 1);
}

test "findTrampolinePage picks a page below 1 MiB" {
    const map = [_]voryn.handoff.MemoryDescriptor{
        .{
            .physical_start = 0,
            .virtual_start = 0,
            .page_count = 0x9F,
            .memory_type = .conventional,
        },
    };
    const page = findTrampolinePage(&map) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 0x9E000), page);
    try std.testing.expect(page < 0xA0000);
    try std.testing.expect(page >= 0x1000);
}

test "findTrampolinePage ignores runtime memory" {
    const map = [_]voryn.handoff.MemoryDescriptor{
        .{
            .physical_start = 0,
            .virtual_start = 0,
            .page_count = 0x9F,
            .memory_type = .runtime_services_data,
        },
    };
    try std.testing.expectEqual(@as(?u64, null), findTrampolinePage(&map));
}
