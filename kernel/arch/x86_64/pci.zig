//************************************************************************//
//  pci.zig — Config space PCI básico (F7)                                 //
//************************************************************************//
// SPDX-License-Identifier: GPL-3.0-only                                   //
//************************************************************************//

//! Leitura do espaco de configuracao PCI (porta 0xCF8 / 0xCFC) sem alocacao
//! dinamica. Usado pelo `virtio.zig` para detectar dispositivos VirtIO.

const std = @import("std");

/// Endereco base do registrador de configuracao PCI (CONFIG_ADDRESS).
pub const PCI_CONFIG_ADDRESS: u32 = 0xCF8;
/// Endereco base do registrador de dados PCI (CONFIG_DATA).
pub const PCI_CONFIG_DATA: u32 = 0xCFC;

/// Compila um endereco de dispositivo PCI no formato 0xCF8 (bus | dev | func | reg).
fn configAddress(bus: u8, device: u8, function: u8, offset: u8) u32 {
    return (@as(u32, bus) << 16) |
           (@as(u32, device) << 11) |
           (@as(u32, function) << 8) |
           (@as(u32, offset) & 0xFC);
}

/// Le um byte do espaco de configuracao PCI.
/// Escreve o endereco em 0xCF8, retorna o byte de 0xCFC.
pub fn readConfigByte(bus: u8, device: u8, function: u8, offset: u8) u8 {
    const addr: u32 = configAddress(bus, device, function, offset);
    const ptr: *volatile u32 = @ptrFromInt(PCI_CONFIG_ADDRESS);
    ptr.* = addr;
    const data_ptr: *volatile u32 = @ptrFromInt(PCI_CONFIG_DATA);
    const data: u32 = data_ptr.*;
    return @as(u8, @truncate(data >> (@as(u5, @intCast((offset & 3) * 8)))));
}

/// Le uma palavra (16 bits) do espaco de configuracao PCI.
pub fn readConfigWord(bus: u8, device: u8, function: u8, offset: u8) u16 {
    const low: u8 = readConfigByte(bus, device, function, @as(u8, @truncate(@as(u32, offset) + 1)));
    const high: u8 = readConfigByte(bus, device, function, @truncate(@as(u32, offset)));
    return (@as(u16, @as(u16, high)) << 8) | @as(u16, low);
}

test "pciReadConfigByteAndWord" {
    // Teste compilavel: nao executa acesso PCI real em ambiente freestanding,
    // mas valida a compilacao e a aritmetica do endereco.
    const addr = configAddress(0, 0, 0, 0);
    try std.testing.expectEqual(@as(u32, 0x80000000), addr);
    const word_offset = configAddress(0, 1, 0, 0);
    try std.testing.expect(word_offset > 0);
}
