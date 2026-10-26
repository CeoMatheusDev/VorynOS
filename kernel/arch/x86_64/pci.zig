//************************************************************************//
//  pci.zig                                                               //
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

//! Leitura do espaco de configuracao PCI legado em x86-64.
//!
//! O mecanismo usa as portas CONFIG_ADDRESS (0xCF8) e CONFIG_DATA (0xCFC).
//! As portas sao acessadas pelas instrucoes x86 de port I/O, nunca como
//! enderecos de memoria. O par de portas e serializado por um IrqSpinlock:
//! sem isso, duas CPUs poderiam intercalar o endereco de uma com os dados
//! da outra.

const voryn = @import("voryn_shared");
const port = voryn.port;
const spinlock = @import("spinlock.zig");
const std = @import("std");

/// Serializa o par CONFIG_ADDRESS/CONFIG_DATA.
///
/// O mecanismo legado tem um unico par de portas para toda a maquina. Se
/// duas CPUs escreverem o endereco e lerem os dados sem exclusao mutua, uma
/// leitura pode acabar no dispositivo que a outra CPU selecionou. O lock e
/// irq-safe porque um handler de interrupcao pode, no futuro, consultar o
/// espaco de configuracao enquanto uma thread ja o estiver usando.
var config_lock: spinlock.IrqSpinlock = .{};

/// Endereco da porta de configuracao PCI (CONFIG_ADDRESS).
pub const PCI_CONFIG_ADDRESS: u16 = 0xCF8;
/// Endereco da porta de dados PCI (CONFIG_DATA).
pub const PCI_CONFIG_DATA: u16 = 0xCFC;

/// Retorna true quando um offset pode iniciar uma leitura DWORD PCI.
pub fn isValidDwordOffset(offset: u8) bool {
    return offset <= 0xFC;
}

/// Retorna true quando um offset pode iniciar uma leitura de palavra PCI.
///
/// O mecanismo legado sempre entrega um DWORD alinhado. Uma palavra em
/// offset impar ocuparia bytes de dois DWORDs diferentes e nao pode ser
/// extraida de uma unica leitura; por isso offsets impares sao rejeitados.
/// O offset 0xFE e valido porque seus dois bytes estao no DWORD 0xFC.
pub fn isValidWordOffset(offset: u8) bool {
    return offset <= 0xFE and (offset & 1) == 0;
}

/// Extrai um byte de um DWORD de configuracao usando a ordem little-endian.
pub fn extractByte(dword: u32, offset: u8) u8 {
    const shift: u5 = @intCast((offset & 3) * 8);
    return @truncate(dword >> shift);
}

/// Extrai uma palavra little-endian de um DWORD de configuracao.
///
/// Retorna null para offset impar ou acima de 0xFE, casos em que a palavra
/// nao pode ser representada por um unico DWORD alinhado.
pub fn extractWord(dword: u32, offset: u8) ?u16 {
    if (!isValidWordOffset(offset)) return null;
    const shift: u5 = @intCast((offset & 2) * 8);
    return @truncate(dword >> shift);
}

/// Compila um endereco PCI de configuracao no formato definido pela PCI.
///
/// O bit 31 habilita a transacao; bus ocupa 23:16, device 15:11, function
/// 10:8 e o registrador DWORD alinhado ocupa 7:2.
pub fn configAddress(bus: u8, device: u8, function: u8, offset: u8) u32 {
    return (1 << 31) |
        (@as(u32, bus) << 16) |
        ((@as(u32, device) & 0x1F) << 11) |
        ((@as(u32, function) & 0x07) << 8) |
        (@as(u32, offset) & 0xFC);
}

pub const Bar = struct {
    address: u64,
    is_io: bool,
    is_64bit: bool,
    prefetchable: bool,
};

/// Decodifica um BAR PCI sem acessar hardware.
/// `high` e usado somente para BAR de memoria 64-bit.
pub fn decodeBar(low: u32, high: u32) ?Bar {
    if (low == 0 or low == 0xFFFF_FFFF) return null;
    if ((low & 1) != 0) return .{
        .address = low & 0xFFFF_FFFC,
        .is_io = true,
        .is_64bit = false,
        .prefetchable = false,
    };
    const memory_type = (low >> 1) & 0x3;
    if (memory_type == 0x3) return null;
    const is_64bit = memory_type == 0x2;
    const address = if (is_64bit)
        (@as(u64, high) << 32) | (low & 0xFFFF_FFF0)
    else
        low & 0xFFFF_FFF0;
    return .{
        .address = address,
        .is_io = false,
        .is_64bit = is_64bit,
        .prefetchable = (low & 0x8) != 0,
    };
}

/// Le um DWORD do espaco de configuracao PCI.
///
/// O offset e alinhado para o inicio do DWORD conforme a especificacao. Um
/// offset acima de 0xFC nao descreve um DWORD dentro do espaco legado e
/// retorna zero, sem tocar nas portas.
pub fn readConfigDword(bus: u8, device: u8, function: u8, offset: u8) u32 {
    if (!isValidDwordOffset(offset)) return 0;

    // The address and the data ports form one transaction. The lock covers
    // both accesses, so another CPU cannot replace CONFIG_ADDRESS between
    // the write and the read. The saved flags preserve the caller's
    // interrupt state, including the case where interrupts were already
    // disabled before the call.
    const flags = config_lock.lockIrqSave();
    defer config_lock.unlockIrqRestore(flags);

    port.outl(PCI_CONFIG_ADDRESS, configAddress(bus, device, function, offset));
    return port.inl(PCI_CONFIG_DATA);
}

// ----------------------------------------------------------------------
// Acesso generico ao espaco de configuracao.
//
// O percurso da lista de capabilities e as validacoes de BAR sao puros: eles
// recebem um `Reader` e nao sabem se os bytes vieram das portas 0xCF8/0xCFC,
// de uma imagem simulada ou de um teste. Assim a mesma logica que roda no
// kernel e exercitada no host, sem port I/O e sem hardware.
// ----------------------------------------------------------------------

/// Tamanho do espaco de configuracao do mecanismo legado.
pub const config_space_size: usize = 256;

/// Offset do registrador de status do cabecalho PCI.
pub const status_offset: u8 = 0x06;

/// Offset do ponteiro para o inicio da lista de capabilities.
pub const capability_pointer_offset: u8 = 0x34;

/// Offset do primeiro BAR.
pub const bar_register_base: u8 = 0x10;

/// Quantidade de BARs de uma funcao PCI type 0.
pub const bar_count: usize = 6;

/// Bit 4 do status: a funcao possui uma lista de capabilities.
pub const status_capabilities: u16 = 0x0010;

/// Primeiro offset possivel de uma capability. O cabecalho PCI (identificacao,
/// BARs, ponteiro para a lista) ocupa os offsets 0x00 a 0x3F.
pub const first_capability_offset: u8 = 0x40;

/// Identificador de capability vendor-specific, usado pelo VirtIO moderno.
pub const capability_vendor_specific: u8 = 0x09;

/// Bytes minimos de uma capability: identificador e ponteiro para a proxima.
pub const capability_header_size: u8 = 2;

/// Leitor de bytes de um espaco de configuracao PCI.
///
/// O campo `ctx` pertence ao chamador e precisa continuar vivo enquanto o
/// leitor for usado. `read_byte` nunca pode falhar: o projeto da interface
/// assume que o espaco de configuracao esta sempre acessivel, como no
/// mecanismo legado, onde uma leitura de porta nao devolve erro.
pub const Reader = struct {
    ctx: *const anyopaque,
    read_byte: *const fn (ctx: *const anyopaque, offset: u8) u8,

    /// Le um byte do espaco de configuracao.
    pub fn readByte(self: Reader, offset: u8) u8 {
        return self.read_byte(self.ctx, offset);
    }

    /// Le uma palavra little-endian, ou null para um offset que atravessa
    /// dois DWORDs e nao pode ser montado byte a byte com garantia.
    pub fn readWord(self: Reader, offset: u8) ?u16 {
        if (!isValidWordOffset(offset)) return null;
        const low = self.readByte(offset);
        const high = self.readByte(offset + 1);
        return (@as(u16, high) << 8) | low;
    }

    /// Le um DWORD little-endian, ou null para um offset acima de 0xFC.
    pub fn readDword(self: Reader, offset: u8) ?u32 {
        if (!isValidDwordOffset(offset)) return null;
        const base = offset & 0xFC;
        const b0: u32 = self.readByte(base);
        const b1: u32 = self.readByte(base + 1);
        const b2: u32 = self.readByte(base + 2);
        const b3: u32 = self.readByte(base + 3);
        return (b3 << 24) | (b2 << 16) | (b1 << 8) | b0;
    }
};

/// Localizacao de uma funcao PCI no mecanismo legado.
pub const Function = struct {
    bus: u8,
    device: u8,
    function: u8,
};

fn readPortByte(ctx: *const anyopaque, offset: u8) u8 {
    const location: *const Function = @ptrCast(@alignCast(ctx));
    return readConfigByte(location.bus, location.device, location.function, offset);
}

/// Leitor ligado as portas 0xCF8/0xCFC de uma funcao PCI.
///
/// `location` precisa continuar vivo enquanto o leitor for usado.
pub fn functionReader(location: *const Function) Reader {
    return .{ .ctx = location, .read_byte = readPortByte };
}

/// Espaco de configuracao simulado de 256 bytes.
///
/// A imagem existe para que o percurso e as validacoes sejam testados com
/// uma configuracao PCI montada byte a byte, sem portas de I/O.
pub const ConfigImage = struct {
    bytes: [config_space_size]u8,

    /// Imagem com todos os bytes em zero.
    pub fn zeroed() ConfigImage {
        return .{ .bytes = @splat(0) };
    }

    pub fn writeByte(self: *ConfigImage, offset: u8, value: u8) void {
        self.bytes[offset] = value;
    }

    pub fn writeWord(self: *ConfigImage, offset: u8, value: u16) void {
        if (@as(usize, offset) + 2 > config_space_size) return;
        self.bytes[offset] = @truncate(value);
        self.bytes[offset + 1] = @truncate(value >> 8);
    }

    pub fn writeDword(self: *ConfigImage, offset: u8, value: u32) void {
        if (@as(usize, offset) + 4 > config_space_size) return;
        self.bytes[offset] = @truncate(value);
        self.bytes[offset + 1] = @truncate(value >> 8);
        self.bytes[offset + 2] = @truncate(value >> 16);
        self.bytes[offset + 3] = @truncate(value >> 24);
    }

    fn readImageByte(ctx: *const anyopaque, offset: u8) u8 {
        const self: *const ConfigImage = @ptrCast(@alignCast(ctx));
        return self.bytes[offset];
    }

    pub fn reader(self: *const ConfigImage) Reader {
        return .{ .ctx = self, .read_byte = readImageByte };
    }
};

/// Uma entrada da lista de capabilities do espaco de configuracao.
pub const Capability = struct {
    /// Identificador da capability (`PCI_CAP_ID_*`).
    id: u8,
    /// Offset no espaco de configuracao onde a capability comeca.
    offset: u8,
    /// Tamanho declarado pelo campo `cap_len` da capability.
    length: u8,
};

pub const CapabilityError = error{
    /// O status nao anuncia lista de capabilities.
    CapabilitiesUnsupported,
    /// O ponteiro esta fora da regiao de capabilities ou fora do espaco.
    InvalidCapabilityPointer,
    /// O ponteiro nao esta alinhado em DWORD.
    UnalignedCapabilityPointer,
    /// Identificador 0x00 ou 0xFF, reservados pela especificacao PCI.
    InvalidCapabilityId,
    /// O tamanho declarado nao cabe no espaco de configuracao.
    TruncatedCapability,
    /// A lista volta a um offset ja visitado.
    CycleInCapabilityList,
};

/// Valida um ponteiro da lista de capabilities.
///
/// Um ponteiro valido comeca na regiao de capabilities (0x40), deixa espaco
/// para o cabecalho de dois bytes e esta alinhado em DWORD, como a
/// especificacao PCI exige; os dois bits baixos do ponteiro sao reservados.
fn validateCapabilityPointer(pointer: u8) CapabilityError!void {
    if (@as(usize, pointer) < first_capability_offset) return error.InvalidCapabilityPointer;
    if (@as(usize, pointer) + capability_header_size > config_space_size) {
        return error.InvalidCapabilityPointer;
    }
    if (pointer % 4 != 0) return error.UnalignedCapabilityPointer;
}

/// Percurso seguro da lista de capabilities.
///
/// Cada passo valida o ponteiro, o identificador e o tamanho declarado, e
/// recusa um offset ja visitado. A deteccao de ciclo usa um mapa de bits dos
/// 256 offsets, e nao uma comparacao com o passo anterior: uma lista que
/// salta A -> B -> C -> A tambem e recusada.
///
/// O numero de iteracoes e limitado pela propria geometria: um ponteiro
/// valido e um dos 48 offsets alinhados de 0x40 a 0xFC, e o mapa de bits
/// permite no maximo uma visita por offset. Nao existe caminho de lista
/// aberta, e por isso o percurso termina em no maximo 48 passos.
pub const CapabilityIterator = struct {
    reader: Reader,
    next_offset: u8,
    visited: [config_space_size / 8]u8 = @splat(0),

    /// Prepara o percurso a partir do ponteiro do cabecalho PCI.
    ///
    /// Uma lista vazia e valida: um ponteiro nulo devolve um iterador que
    /// termina imediatamente. Sem o bit 4 do status nao existe lista, e o
    /// erro e explicito em vez de um resultado vazio.
    pub fn init(reader: Reader) CapabilityError!CapabilityIterator {
        const status = reader.readWord(status_offset) orelse return error.CapabilitiesUnsupported;
        if (status & status_capabilities == 0) return error.CapabilitiesUnsupported;

        const pointer = reader.readByte(capability_pointer_offset);
        var iterator: CapabilityIterator = .{ .reader = reader, .next_offset = 0 };
        if (pointer == 0) return iterator;
        try validateCapabilityPointer(pointer);
        iterator.next_offset = pointer;
        return iterator;
    }

    /// Devolve a proxima capability ou null no fim da lista.
    ///
    /// O ponteiro para a capability seguinte e validado antes de a entrada
    /// atual ser devolvida: uma lista com um elo corrompido falha mesmo que o
    /// chamador pare de percorrer logo depois daquela entrada.
    pub fn next(self: *CapabilityIterator) CapabilityError!?Capability {
        const offset = self.next_offset;
        if (offset == 0) return null;

        const mask: u8 = @as(u8, 1) << @intCast(offset % 8);
        const index = offset / 8;
        if (self.visited[index] & mask != 0) return error.CycleInCapabilityList;
        self.visited[index] |= mask;

        // `offset` foi validado no passo anterior: ele e no maximo 0xFC, e os
        // tres bytes do cabecalho da capability estao dentro do espaco.
        const id = self.reader.readByte(offset);
        const next_pointer = self.reader.readByte(offset + 1);
        const length = self.reader.readByte(offset + 2);

        if (id == 0x00 or id == 0xFF) return error.InvalidCapabilityId;
        if (length < capability_header_size) return error.TruncatedCapability;
        if (@as(usize, offset) + @as(usize, length) > config_space_size) {
            return error.TruncatedCapability;
        }
        if (next_pointer != 0) try validateCapabilityPointer(next_pointer);

        self.next_offset = next_pointer;
        return .{ .id = id, .offset = offset, .length = length };
    }
};

/// Procura a primeira capability com o identificador dado.
pub fn findCapability(reader: Reader, id: u8) CapabilityError!?Capability {
    var iterator = try CapabilityIterator.init(reader);
    while (try iterator.next()) |capability| {
        if (capability.id == id) return capability;
    }
    return null;
}

/// Interpretacao dos bits de tipo de um BAR.
pub const BarKind = enum {
    /// BAR de espaco de I/O.
    io,
    /// BAR de memoria de 32 bits. O tipo 0b01 ("abaixo de 1 MiB") e tratado
    /// como 32 bits, do mesmo modo que `decodeBar`.
    memory32,
    /// Metade baixa de um BAR de memoria de 64 bits.
    memory64,
    /// Tipo reservado pela especificacao PCI; o BAR nao pode ser usado.
    reserved,
};

/// Classifica um BAR a partir da metade baixa lida do espaco de configuracao.
pub fn barKind(low: u32) BarKind {
    if (low & 1 != 0) return .io;
    return switch ((low >> 1) & 0x3) {
        0b00, 0b01 => .memory32,
        0b10 => .memory64,
        else => .reserved,
    };
}

fn memoryBarSizeFromMask(mask: u64, width: u64) ?u64 {
    if (mask == 0) return null;
    // Um BAR de 32 bits so endereca 32 bits: os bits altos da mascara nao
    // existem e precisam ser ignorados antes de inverter.
    const size = ((~mask) & width) + 1;
    if (size < 16 or !std.math.isPowerOfTwo(size)) return null;
    return size;
}

/// Calcula o tamanho de um BAR a partir das mascaras lidas depois de o driver
/// escrever todos os bits em 1 no BAR e ler o valor de volta.
///
/// `high` e usado somente pela metade alta de um BAR de memoria de 64 bits e
/// e ignorado nos demais tipos. A funcao e pura: a escrita e a leitura que
/// produzem as mascaras pertencem ao chamador, porque dependem do hardware.
///
/// Um BAR nao implementado (0x0000_0000 ou 0xFFFF_FFFF), um tipo reservado ou
/// uma mascara que nao descreve um tamanho potencia de dois devolvem null.
pub fn barSize(low: u32, high: u32) ?u64 {
    if (low == 0 or low == 0xFFFF_FFFF) return null;
    return switch (barKind(low)) {
        .reserved => null,
        .io => blk: {
            // Em um BAR de I/O os bits 31:2 enderecam e os bits 1:0 sao
            // fixos; o tamanho minimo e de 4 bytes.
            const mask: u64 = low & 0xFFFF_FFFC;
            if (mask == 0) break :blk null;
            const size = (~mask & 0xFFFF_FFFF) + 1;
            if (size < 4 or !std.math.isPowerOfTwo(size)) break :blk null;
            break :blk size;
        },
        .memory32 => memoryBarSizeFromMask(low & 0xFFFF_FFF0, 0xFFFF_FFFF),
        .memory64 => memoryBarSizeFromMask(
            (@as(u64, high) << 32) | (low & 0xFFFF_FFF0),
            std.math.maxInt(u64),
        ),
    };
}

/// Os seis BARs de uma funcao, ja decodificados.
///
/// A metade alta de um BAR de 64 bits nao ocupa uma entrada propria: ela e
/// consumida pela entrada do BAR, que continua ocupando o indice original.
pub const BarTable = struct {
    bars: [bar_count]?Bar,

    /// Decodifica os seis DWORDs lidos em 0x10..0x24.
    ///
    /// Um BAR nao implementado (0x0000_0000 ou 0xFFFF_FFFF) fica nulo. Um BAR
    /// de 64 bits no ultimo indice, ou um tipo reservado, invalida a tabela:
    /// nesse caso a funcao devolve null em vez de inventar um endereco.
    pub fn decode(low: [bar_count]u32) ?BarTable {
        var table: BarTable = .{ .bars = @splat(null) };
        var index: usize = 0;
        while (index < bar_count) : (index += 1) {
            const value = low[index];
            if (value == 0 or value == 0xFFFF_FFFF) continue;
            switch (barKind(value)) {
                .reserved => return null,
                .io, .memory32 => {
                    table.bars[index] = decodeBar(value, 0) orelse return null;
                },
                .memory64 => {
                    // A metade alta precisa existir dentro dos seis BARs.
                    if (index + 1 >= bar_count) return null;
                    table.bars[index] = decodeBar(value, low[index + 1]) orelse return null;
                    index += 1;
                },
            }
        }
        return table;
    }
};

/// Le e decodifica os seis BARs de uma funcao.
pub fn readBarTable(reader: Reader) ?BarTable {
    var low: [bar_count]u32 = undefined;
    for (&low, 0..) |*entry, index| {
        const offset: u8 = bar_register_base + @as(u8, @intCast(index)) * 4;
        entry.* = reader.readDword(offset) orelse return null;
    }
    return BarTable.decode(low);
}

/// Verifica se uma regiao [offset, offset + length) cabe em um BAR.
///
/// `size` e o tamanho obtido por `barSize`. O BAR precisa estar alinhado ao
/// proprio tamanho, o tamanho precisa ser potencia de dois e a regiao nao
/// pode passar do fim do BAR nem transbordar a aritmetica de 64 bits. Um BAR
/// de 64 bits no ultimo indice nao pode existir, porque a metade alta
/// ocuparia um registrador inexistente.
pub fn barSupportsRegion(bar: Bar, index: usize, size: u64, offset: u32, length: u32) bool {
    if (index >= bar_count) return false;
    if (length == 0) return false;
    if (bar.is_io) {
        if (size < 4) return false;
    } else {
        if (bar.is_64bit and index + 1 >= bar_count) return false;
        if (size < 16) return false;
    }
    if (!std.math.isPowerOfTwo(size)) return false;
    if (bar.address % size != 0) return false;
    const end = @as(u64, offset) + @as(u64, length);
    return end <= size;
}

/// Le um byte do espaco de configuracao PCI.
///
/// O byte e extraido do DWORD alinhado que o contem. Isso vale inclusive
/// para 0xFD, 0xFE e 0xFF, cujos bytes pertencem ao DWORD iniciado em 0xFC.
pub fn readConfigByte(bus: u8, device: u8, function: u8, offset: u8) u8 {
    const data = readConfigDword(bus, device, function, offset & 0xFC);
    return extractByte(data, offset);
}

/// Le uma palavra little-endian do espaco de configuracao PCI.
///
/// A palavra em 0xFE pertence ao DWORD 0xFC e e extraida com shift 16.
/// Offsets impares sao rejeitados, porque atravessam dois DWORDs.
pub fn readConfigWord(bus: u8, device: u8, function: u8, offset: u8) u16 {
    if (!isValidWordOffset(offset)) return 0;
    const data = readConfigDword(bus, device, function, offset & 0xFC);
    return extractWord(data, offset) orelse 0;
}

test "pci bar decoder handles io and memory bars" {
    const io = decodeBar(0x0000_C001, 0);
    try std.testing.expect(io != null);
    try std.testing.expect(io.?.is_io);
    try std.testing.expectEqual(@as(u64, 0xC000), io.?.address);

    const memory = decodeBar(0x8000_0008, 0);
    try std.testing.expect(memory != null);
    try std.testing.expect(!memory.?.is_io);
    try std.testing.expect(memory.?.prefetchable);
    try std.testing.expectEqual(@as(u64, 0x8000_0000), memory.?.address);

    const wide = decodeBar(0x0000_0004, 0x0000_0001);
    try std.testing.expect(wide != null);
    try std.testing.expect(wide.?.is_64bit);
    try std.testing.expectEqual(@as(u64, 0x0000_0001_0000_0000), wide.?.address);
    try std.testing.expect(decodeBar(0x0000_0006, 0) == null);
}

test "pci config address sets enable and encodes fields" {
    try std.testing.expectEqual(
        @as(u32, 0x8000_0000),
        configAddress(0, 0, 0, 0),
    );
    try std.testing.expectEqual(
        @as(u32, 0x8001_177C),
        configAddress(1, 2, 7, 0x7F),
    );

    // O registrador PCI e sempre alinhado em DWORD.
    try std.testing.expectEqual(
        configAddress(1, 2, 7, 0x7C),
        configAddress(1, 2, 7, 0x7F),
    );
}

test "pci register offset validation" {
    try std.testing.expect(isValidDwordOffset(0x00));
    try std.testing.expect(isValidDwordOffset(0xFC));
    try std.testing.expect(!isValidDwordOffset(0xFD));
    try std.testing.expect(!isValidDwordOffset(0xFF));

    try std.testing.expect(isValidWordOffset(0x00));
    try std.testing.expect(isValidWordOffset(0x02));
    try std.testing.expect(isValidWordOffset(0xFC));
    try std.testing.expect(isValidWordOffset(0xFE));
    try std.testing.expect(!isValidWordOffset(0x01));
    try std.testing.expect(!isValidWordOffset(0x03));
    try std.testing.expect(!isValidWordOffset(0xFD));
    try std.testing.expect(!isValidWordOffset(0xFF));
}

test "pci byte extraction covers the last configuration dword" {
    const sample: u32 = 0x1234_5678;

    try std.testing.expectEqual(@as(u8, 0x78), extractByte(sample, 0xFC));
    try std.testing.expectEqual(@as(u8, 0x56), extractByte(sample, 0xFD));
    try std.testing.expectEqual(@as(u8, 0x34), extractByte(sample, 0xFE));
    try std.testing.expectEqual(@as(u8, 0x12), extractByte(sample, 0xFF));
}

test "pci word extraction handles 0xFE and rejects odd offsets" {
    const sample: u32 = 0x1234_5678;

    try std.testing.expectEqual(@as(u16, 0x5678), extractWord(sample, 0xFC).?);
    try std.testing.expectEqual(@as(u16, 0x1234), extractWord(sample, 0xFE).?);
    try std.testing.expect(extractWord(sample, 0x01) == null);
    try std.testing.expect(extractWord(sample, 0xFD) == null);
    try std.testing.expect(extractWord(sample, 0xFF) == null);
}

test "pci little endian extraction from a configuration dword" {
    const sample: u32 = 0x1234_5678;

    try std.testing.expectEqual(@as(u8, 0x78), @as(u8, @truncate(sample)));
    try std.testing.expectEqual(@as(u8, 0x56), @as(u8, @truncate(sample >> 8)));
    try std.testing.expectEqual(@as(u8, 0x34), @as(u8, @truncate(sample >> 16)));
    try std.testing.expectEqual(@as(u8, 0x12), @as(u8, @truncate(sample >> 24)));

    try std.testing.expectEqual(@as(u16, 0x5678), @as(u16, @truncate(sample)));
    try std.testing.expectEqual(@as(u16, 0x1234), @as(u16, @truncate(sample >> 16)));
}

test "pci vendor and device fields use little endian layout" {
    const vendor_device: u32 = (@as(u32, 0x1001) << 16) | 0x1AF4;
    try std.testing.expectEqual(@as(u16, 0x1AF4), @as(u16, @truncate(vendor_device)));
    try std.testing.expectEqual(@as(u16, 0x1001), @as(u16, @truncate(vendor_device >> 16)));
}

test "pci invalid reads return zero without port access" {
    try std.testing.expectEqual(@as(u32, 0), readConfigDword(0, 0, 0, 0xFD));
    try std.testing.expectEqual(@as(u16, 0), readConfigWord(0, 0, 0, 0xFF));
}

// ----------------------------------------------------------------------
// Testes da lista de capabilities e dos BARs.
//
// Todos os casos usam uma imagem de configuracao simulada: nenhuma porta de
// I/O e aberta e nenhum dispositivo real e necessario.
// ----------------------------------------------------------------------

/// Imagem com a lista minima de duas capabilities: uma vendor-specific de 16
/// bytes em 0x40 e uma de gerenciamento de energia de 2 bytes em 0x50.
fn twoCapabilityImage() ConfigImage {
    var image = ConfigImage.zeroed();
    image.writeWord(status_offset, status_capabilities);
    image.writeByte(capability_pointer_offset, 0x40);

    image.writeByte(0x40, capability_vendor_specific);
    image.writeByte(0x41, 0x50);
    image.writeByte(0x42, 16);

    image.writeByte(0x50, 0x01);
    image.writeByte(0x51, 0x00);
    image.writeByte(0x52, 0x02);
    return image;
}

test "pci capability list walk reads every entry in order" {
    const image = twoCapabilityImage();
    var iterator = try CapabilityIterator.init(image.reader());

    const first = (try iterator.next()).?;
    try std.testing.expectEqual(capability_vendor_specific, first.id);
    try std.testing.expectEqual(@as(u8, 0x40), first.offset);
    try std.testing.expectEqual(@as(u8, 16), first.length);

    const second = (try iterator.next()).?;
    try std.testing.expectEqual(@as(u8, 0x01), second.id);
    try std.testing.expectEqual(@as(u8, 0x50), second.offset);
    try std.testing.expectEqual(@as(u8, 2), second.length);

    try std.testing.expect(try iterator.next() == null);
    try std.testing.expect(try iterator.next() == null);

    const found = (try findCapability(image.reader(), 0x01)).?;
    try std.testing.expectEqual(@as(u8, 0x50), found.offset);
    try std.testing.expect(try findCapability(image.reader(), 0x05) == null);
}

test "pci capability list accepts an empty list and rejects a missing one" {
    var image = ConfigImage.zeroed();
    image.writeWord(status_offset, status_capabilities);
    image.writeByte(capability_pointer_offset, 0);

    var iterator = try CapabilityIterator.init(image.reader());
    try std.testing.expect(try iterator.next() == null);
    try std.testing.expect(try findCapability(image.reader(), 0x09) == null);

    // Sem o bit 4 do status o dispositivo nao declara lista alguma. O erro e
    // explicito: uma lista inexistente nao pode ser confundida com uma lista
    // vazia, porque o chamador precisa saber que a capacidade esta ausente.
    var without_status = ConfigImage.zeroed();
    without_status.writeByte(capability_pointer_offset, 0x40);
    try std.testing.expectError(
        error.CapabilitiesUnsupported,
        CapabilityIterator.init(without_status.reader()),
    );
}

test "pci capability list rejects invalid and unaligned pointers" {
    var image = ConfigImage.zeroed();
    image.writeWord(status_offset, status_capabilities);

    // Dentro do cabecalho PCI.
    image.writeByte(capability_pointer_offset, 0x20);
    try std.testing.expectError(
        error.InvalidCapabilityPointer,
        CapabilityIterator.init(image.reader()),
    );

    image.writeByte(capability_pointer_offset, 0x3F);
    try std.testing.expectError(
        error.InvalidCapabilityPointer,
        CapabilityIterator.init(image.reader()),
    );

    // A especificacao PCI exige alinhamento em DWORD.
    image.writeByte(capability_pointer_offset, 0x42);
    try std.testing.expectError(
        error.UnalignedCapabilityPointer,
        CapabilityIterator.init(image.reader()),
    );

    image.writeByte(capability_pointer_offset, 0x43);
    try std.testing.expectError(
        error.UnalignedCapabilityPointer,
        CapabilityIterator.init(image.reader()),
    );

    // 0xFC e o ultimo offset alinhado possivel; os dois bytes do cabecalho
    // ainda cabem no espaco, e o identificador zero e recusado.
    image.writeByte(capability_pointer_offset, 0xFC);
    var iterator = try CapabilityIterator.init(image.reader());
    try std.testing.expectError(error.InvalidCapabilityId, iterator.next());

    // O ponteiro seguinte tambem e validado, e nao apenas o primeiro. O elo
    // e verificado antes de a entrada atual ser devolvida, para que uma lista
    // corrompida falhe mesmo que o chamador pare de percorrer naquela entrada.
    var chained = ConfigImage.zeroed();
    chained.writeWord(status_offset, status_capabilities);
    chained.writeByte(capability_pointer_offset, 0x40);
    chained.writeByte(0x40, capability_vendor_specific);
    chained.writeByte(0x41, 0x42);
    chained.writeByte(0x42, 0x04);
    var chained_iterator = try CapabilityIterator.init(chained.reader());
    try std.testing.expectError(
        error.UnalignedCapabilityPointer,
        chained_iterator.next(),
    );

    // Um elo que aponta para dentro do cabecalho PCI, e nao para a regiao de
    // capabilities.
    chained.writeByte(0x41, 0x20);
    var short_iterator = try CapabilityIterator.init(chained.reader());
    try std.testing.expectError(
        error.InvalidCapabilityPointer,
        short_iterator.next(),
    );
}

test "pci capability list detects cycles that skip a step" {
    var image = ConfigImage.zeroed();
    image.writeWord(status_offset, status_capabilities);
    image.writeByte(capability_pointer_offset, 0x40);

    // 0x40 -> 0x50 -> 0x60 -> 0x40: o ciclo nao repete o passo anterior.
    image.writeByte(0x40, capability_vendor_specific);
    image.writeByte(0x41, 0x50);
    image.writeByte(0x42, 0x04);
    image.writeByte(0x50, capability_vendor_specific);
    image.writeByte(0x51, 0x60);
    image.writeByte(0x52, 0x04);
    image.writeByte(0x60, capability_vendor_specific);
    image.writeByte(0x61, 0x40);
    image.writeByte(0x62, 0x04);

    var iterator = try CapabilityIterator.init(image.reader());
    try std.testing.expect(try iterator.next() != null);
    try std.testing.expect(try iterator.next() != null);
    try std.testing.expect(try iterator.next() != null);
    try std.testing.expectError(error.CycleInCapabilityList, iterator.next());

    // Uma capability que aponta para si mesma tambem e um ciclo.
    var self_loop = ConfigImage.zeroed();
    self_loop.writeWord(status_offset, status_capabilities);
    self_loop.writeByte(capability_pointer_offset, 0x40);
    self_loop.writeByte(0x40, capability_vendor_specific);
    self_loop.writeByte(0x41, 0x40);
    self_loop.writeByte(0x42, 0x04);
    var loop_iterator = try CapabilityIterator.init(self_loop.reader());
    _ = (try loop_iterator.next()).?;
    try std.testing.expectError(error.CycleInCapabilityList, loop_iterator.next());
}

test "pci capability list rejects truncated and malformed entries" {
    var image = ConfigImage.zeroed();
    image.writeWord(status_offset, status_capabilities);
    image.writeByte(capability_pointer_offset, 0x40);
    image.writeByte(0x40, capability_vendor_specific);
    image.writeByte(0x41, 0x00);

    // Tamanho menor que o cabecalho de dois bytes.
    image.writeByte(0x42, 0x00);
    var zero = try CapabilityIterator.init(image.reader());
    try std.testing.expectError(error.TruncatedCapability, zero.next());

    image.writeByte(0x42, 0x01);
    var one = try CapabilityIterator.init(image.reader());
    try std.testing.expectError(error.TruncatedCapability, one.next());

    // Tamanho declarado que passa do fim do espaco de configuracao.
    image.writeByte(0x42, 0xC1);
    var beyond = try CapabilityIterator.init(image.reader());
    try std.testing.expectError(error.TruncatedCapability, beyond.next());

    // Identificadores reservados pela especificacao PCI.
    image.writeByte(0x42, 0x04);
    image.writeByte(0x40, 0x00);
    var zero_id = try CapabilityIterator.init(image.reader());
    try std.testing.expectError(error.InvalidCapabilityId, zero_id.next());

    image.writeByte(0x40, 0xFF);
    var ff_id = try CapabilityIterator.init(image.reader());
    try std.testing.expectError(error.InvalidCapabilityId, ff_id.next());
}

test "pci capability walk is bounded by the alignment grid" {
    // O maior caminho possivel: os 48 offsets alinhados de 0x40 a 0xFC, sem
    // ciclo. O percurso precisa terminar e visitar cada offset uma unica vez.
    var image = ConfigImage.zeroed();
    image.writeWord(status_offset, status_capabilities);
    image.writeByte(capability_pointer_offset, 0x40);

    var offset: u8 = 0x40;
    while (true) {
        const following: u8 = if (offset == 0xFC) 0 else offset + 4;
        image.writeByte(offset, capability_vendor_specific);
        image.writeByte(offset + 1, following);
        image.writeByte(offset + 2, 0x04);
        if (following == 0) break;
        offset = following;
    }

    var iterator = try CapabilityIterator.init(image.reader());
    var count: usize = 0;
    while (try iterator.next()) |capability| {
        try std.testing.expectEqual(@as(u8, 0x40) + @as(u8, @intCast(count)) * 4, capability.offset);
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 48), count);
}

test "pci bar size is derived from the all ones mask" {
    // memoria de 32 bits
    try std.testing.expectEqual(@as(u64, 0x1000), barSize(0xFFFF_F000, 0).?);
    try std.testing.expectEqual(@as(u64, 0x1_0000), barSize(0xFFFF_0000, 0).?);
    // I/O: os bits 1:0 sao fixos e o endereco usa 31:2.
    try std.testing.expectEqual(@as(u64, 0x100), barSize(0xFFFF_FF01, 0).?);
    // memoria de 64 bits: a metade alta entra na mascara.
    try std.testing.expectEqual(
        @as(u64, 0x1000),
        barSize(0xFFFF_F004, 0xFFFF_FFFF).?,
    );

    // BAR nao implementado, tipo reservado e mascara sem tamanho potencia de
    // dois nao produzem tamanho.
    try std.testing.expect(barSize(0, 0) == null);
    try std.testing.expect(barSize(0xFFFF_FFFF, 0) == null);
    try std.testing.expect(barSize(0x0000_0006, 0) == null);
    try std.testing.expect(barSize(0xFFFF_F7F0, 0) == null);
    try std.testing.expect(barSize(0x0000_0004, 0) == null);
    try std.testing.expect(barSize(0x0000_FF01, 0) == null);
}

test "pci bar table decodes sixty four bit pairs and rejects malformed tables" {
    var low: [bar_count]u32 = @splat(0);
    low[0] = 0x0000_C001; // BAR 0: I/O em 0xC000
    low[2] = 0x0000_0004; // BAR 2: memoria 64 bits, metade baixa
    low[3] = 0x0000_0001; // metade alta do BAR 2
    low[4] = 0x8000_0008; // BAR 4: memoria 32 bits prefetchable
    const table = BarTable.decode(low).?;

    try std.testing.expect(table.bars[0].?.is_io);
    try std.testing.expectEqual(@as(u64, 0xC000), table.bars[0].?.address);
    try std.testing.expectEqual(@as(u64, 0x1_0000_0000), table.bars[2].?.address);
    try std.testing.expect(table.bars[2].?.is_64bit);
    // A metade alta nao ocupa um BAR proprio.
    try std.testing.expect(table.bars[3] == null);
    try std.testing.expect(table.bars[5] == null);
    try std.testing.expect(table.bars[1] == null);

    // Um BAR de 64 bits no ultimo indice precisaria de um setimo registrador.
    var last: [bar_count]u32 = @splat(0);
    last[5] = 0x0000_0004;
    try std.testing.expect(BarTable.decode(last) == null);

    // Tipo reservado.
    var reserved: [bar_count]u32 = @splat(0);
    reserved[1] = 0x0000_0006;
    try std.testing.expect(BarTable.decode(reserved) == null);
}

test "pci bar table is read from the configuration image" {
    var image = ConfigImage.zeroed();
    image.writeDword(bar_register_base, 0x0000_C001);
    image.writeDword(bar_register_base + 4, 0x0000_0004);
    image.writeDword(bar_register_base + 8, 0x0000_0001);

    const table = readBarTable(image.reader()).?;
    try std.testing.expect(table.bars[0].?.is_io);
    try std.testing.expect(table.bars[1].?.is_64bit);
    try std.testing.expectEqual(@as(u64, 0x1_0000_0000), table.bars[1].?.address);
    try std.testing.expect(table.bars[2] == null);
}

test "pci bar region validation rejects overflow and unaligned bars" {
    const bar: Bar = .{
        .address = 0xFE00_0000,
        .is_io = false,
        .is_64bit = false,
        .prefetchable = false,
    };
    try std.testing.expect(barSupportsRegion(bar, 0, 0x1000, 0x0000, 0x1000));
    try std.testing.expect(barSupportsRegion(bar, 0, 0x1000, 0x0F00, 0x100));
    try std.testing.expect(!barSupportsRegion(bar, 0, 0x1000, 0x0F00, 0x101));
    try std.testing.expect(!barSupportsRegion(bar, 0, 0x1000, 0, 0));
    try std.testing.expect(!barSupportsRegion(bar, bar_count, 0x1000, 0, 4));
    try std.testing.expect(!barSupportsRegion(bar, 0, 0x1000, 0xFFFF_FFFF, 0x10));
    try std.testing.expect(!barSupportsRegion(bar, 0, 0x0C00, 0, 4));
    try std.testing.expect(!barSupportsRegion(bar, 0, 0x8, 0, 4));

    // O endereco do BAR precisa estar alinhado ao proprio tamanho.
    const unaligned: Bar = .{
        .address = 0xFE00_0800,
        .is_io = false,
        .is_64bit = false,
        .prefetchable = false,
    };
    try std.testing.expect(!barSupportsRegion(unaligned, 0, 0x1000, 0, 4));

    // Um BAR de 64 bits nao cabe no ultimo indice.
    const wide: Bar = .{
        .address = 0x1_0000_0000,
        .is_io = false,
        .is_64bit = true,
        .prefetchable = false,
    };
    try std.testing.expect(barSupportsRegion(wide, 4, 0x1000, 0, 4));
    try std.testing.expect(!barSupportsRegion(wide, 5, 0x1000, 0, 4));

    // BAR de I/O cujo tamanho minimo e de 4 bytes.
    const io: Bar = .{ .address = 0xC000, .is_io = true, .is_64bit = false, .prefetchable = false };
    try std.testing.expect(barSupportsRegion(io, 0, 4, 0, 4));
    try std.testing.expect(!barSupportsRegion(io, 0, 4, 0, 5));
}

test "pci simulated configuration reader extracts little endian fields" {
    var image = ConfigImage.zeroed();
    image.writeDword(0x10, 0x1234_5678);
    const reader = image.reader();

    try std.testing.expectEqual(@as(u32, 0x1234_5678), reader.readDword(0x10).?);
    try std.testing.expectEqual(@as(u16, 0x5678), reader.readWord(0x10).?);
    try std.testing.expectEqual(@as(u16, 0x1234), reader.readWord(0x12).?);
    try std.testing.expectEqual(@as(u8, 0x34), reader.readByte(0x12));
    try std.testing.expect(reader.readDword(0xFD) == null);
    try std.testing.expect(reader.readWord(0xFF) == null);
    try std.testing.expect(reader.readWord(0x11) == null);

    // O leitor de hardware nao e chamado neste teste: ele abriria as portas.
    const location: Function = .{ .bus = 0, .device = 3, .function = 0 };
    try std.testing.expectEqual(
        @intFromPtr(&location),
        @intFromPtr(functionReader(&location).ctx),
    );
}

// O acesso real as portas nao e executado nos testes host: inl/outl sao
// instrucoes privilegiadas e exigem um kernel x86-64 em execucao.
comptime {
    if (@sizeOf(u32) != 4) @compileError("PCI DWORD must be four bytes");
}

// std e mantido importado explicitamente para os testes deste modulo.
comptime {
    _ = std.testing;
}
