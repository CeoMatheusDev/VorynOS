//************************************************************************//
//  pci.zig — Config space PCI básico (F7)                                 //
//************************************************************************//
// SPDX-License-Identifier: GPL-3.0-only                                   //
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

// O acesso real as portas nao e executado nos testes host: inl/outl sao
// instrucoes privilegiadas e exigem um kernel x86-64 em execucao.
comptime {
    if (@sizeOf(u32) != 4) @compileError("PCI DWORD must be four bytes");
}

// std e mantido importado explicitamente para os testes deste modulo.
comptime {
    _ = std.testing;
}
