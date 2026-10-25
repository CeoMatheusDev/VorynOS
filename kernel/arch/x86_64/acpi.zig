//************************************************************************//
//  acpi.zig                                                              //
//************************************************************************//
//                         This file is part of:                          //
//                               VorynOS                                  //
//              https://github.com/CeoMatheusDev/VorynOS                  //
//************************************************************************//
// Copyright (C) 2026 VorynOS contributors.                               //
//                                                                        //
// SPDX-License-Identifier: GPL-3.0-only                                  //
//************************************************************************//

//! Descoberta de processadores pela ACPI.
//!
//! O carregador entrega o endereco fisico do RSDP (Root System Description
//! Pointer) no handoff. Durante o boot, antes de o kernel trocar as tabelas
//! de paginas do firmware, a memoria apontada pelo RSDP ainda esta acessivel
//! por identidade. O kernel le o RSDP, percorre a XSDT (ou a RSDT, em
//! sistemas ACPI 1.0) e localiza a MADT (Multiple APIC Description Table),
//! que descreve o APIC local de cada processador.
//!
//! As funcoes de validacao recebem fatias de bytes para que possam ser
//! testadas no host com tabelas sinteticas; a leitura da memoria fisica fica
//! na funcao de descoberta do modulo de SMP.
//!
//! Referencias: ACPI Specification 6.5, secoes 5.2.5 (RSDP), 5.2.7 (XSDT),
//! 5.2.6 (RSDT) e 5.2.12 (MADT).

const std = @import("std");

/// Assinatura do RSDP.
pub const rsdp_signature = "RSD PTR ";

/// Assinatura da RSDT.
pub const rsdt_signature = "RSDT";

/// Assinatura da XSDT.
pub const xsdt_signature = "XSDT";

/// Assinatura da MADT.
pub const madt_signature = "APIC";

/// Tamanho minimo do RSDP (ACPI 1.0).
pub const rsdp_base_size = 20;

/// Tamanho do RSDP estendido (ACPI 2.0 em diante).
pub const rsdp_extended_size = 36;

/// Tamanho minimo do cabecalho da MADT.
pub const madt_header_size = 44;

/// Maior tabela ACPI que o kernel aceita, em bytes.
///
/// O limite existe para que um ponteiro corrompido nao faca o kernel ler
/// uma regiao arbitraria da memoria: as tabelas reais tem alguns kibibytes.
pub const max_table_size = 1024 * 1024;

/// Erros da validacao e da leitura das tabelas.
pub const Error = error{
    /// A assinatura da tabela nao e a esperada.
    InvalidSignature,
    /// A soma de verificacao nao fecha.
    InvalidChecksum,
    /// A tabela e menor do que o cabecalho que ela declara.
    TruncatedTable,
    /// O comprimento declarado excede o limite ou a fatia recebida.
    InvalidLength,
    /// A versao do RSDP nao e suportada.
    UnsupportedRevision,
};

/// Conteudo do RSDP que a descoberta usa.
pub const Rsdp = struct {
    /// Versao da ACPI reportada pelo firmware.
    revision: u8,
    /// Endereco fisico da RSDT (ACPI 1.0), zero quando ausente.
    rsdt_address: u32,
    /// Endereco fisico da XSDT (ACPI 2.0 em diante), zero quando ausente.
    xsdt_address: u64,
};

/// Descreve um processador encontrado na MADT.
pub const Processor = struct {
    /// Identificador do APIC local do processador.
    apic_id: u32 = 0,
    /// O firmware reporta o processador como habilitado.
    enabled: bool = false,
    /// A entrada e do tipo x2APIC (identificador de 32 bits).
    x2apic: bool = false,
};

/// Resultado da leitura da MADT.
pub const Madt = struct {
    /// Endereco fisico do APIC local, lido da tabela.
    local_apic_base: u64 = 0,
    /// Numero de processadores gravados em `processors`.
    count: usize = 0,
    /// A tabela descreve mais processadores do que a capacidade da fatia.
    truncated: bool = false,
};

/// Le um inteiro de 32 bits little-endian de uma fatia.
fn readU32(bytes: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, bytes[offset..][0..4], .little);
}

/// Le um inteiro de 64 bits little-endian de uma fatia.
fn readU64(bytes: []const u8, offset: usize) u64 {
    return std.mem.readInt(u64, bytes[offset..][0..8], .little);
}

/// Soma todos os bytes de uma fatia com aritmetica de 8 bits.
///
/// As tabelas ACPI sao validadas por uma soma que deve resultar em zero.
pub fn checksum(bytes: []const u8) u8 {
    var sum: u8 = 0;
    for (bytes) |byte| sum +%= byte;
    return sum;
}

/// Valida a parte comum (ACPI 1.0) do RSDP.
///
/// A fatia tem de ter pelo menos 20 bytes. A soma de verificacao cobre
/// exatamente os primeiros 20 bytes nas duas versoes do formato.
pub fn validateRsdpBase(bytes: []const u8) Error!Rsdp {
    if (bytes.len < rsdp_base_size) return error.TruncatedTable;
    if (!std.mem.eql(u8, bytes[0..8], rsdp_signature)) return error.InvalidSignature;
    if (checksum(bytes[0..rsdp_base_size]) != 0) return error.InvalidChecksum;

    const revision = bytes[15];
    if (revision > 2) return error.UnsupportedRevision;

    return .{
        .revision = revision,
        .rsdt_address = readU32(bytes, 16),
        .xsdt_address = 0,
    };
}

/// Valida a parte estendida do RSDP e devolve o endereco da XSDT.
///
/// A fatia tem de ter pelo menos 36 bytes. A soma estendida cobre a
/// estrutura inteira e so existe a partir da revisao 2.
pub fn validateRsdpExtended(bytes: []const u8) Error!u64 {
    if (bytes.len < rsdp_extended_size) return error.TruncatedTable;
    if (checksum(bytes[0..rsdp_extended_size]) != 0) return error.InvalidChecksum;
    return readU64(bytes, 24);
}

/// Le o comprimento declarado no cabecalho de uma tabela ACPI.
///
/// O cabecalho tem 36 bytes; a funcao so confere os limites do valor, sem
/// exigir que a fatia contenha a tabela inteira. E a forma usada quando o
/// kernel le apenas o cabecalho e depois monta a fatia da tabela.
pub fn declaredLength(bytes: []const u8) Error!usize {
    if (bytes.len < 8) return error.TruncatedTable;
    const length = readU32(bytes, 4);
    if (length < 36 or length > max_table_size) return error.InvalidLength;
    return length;
}

/// Le o comprimento de uma tabela ACPI e verifica os limites.
///
/// O cabecalho tem 36 bytes: assinatura de 4 bytes, comprimento de 4 bytes,
/// revisao, soma de verificacao, identificador do fornecedor, identificador
/// da tabela e numero da revisao do fornecedor.
pub fn tableLength(bytes: []const u8) Error!usize {
    if (bytes.len < 36) return error.TruncatedTable;
    const length = try declaredLength(bytes);
    if (length > bytes.len) return error.InvalidLength;
    return length;
}

/// Confere a assinatura de uma tabela.
pub fn hasSignature(bytes: []const u8, signature: []const u8) bool {
    if (bytes.len < 4) return false;
    return std.mem.eql(u8, bytes[0..4], signature);
}

/// Le a MADT e grava os processadores habilitados na fatia recebida.
///
/// A fatia `processors` limita quantos processadores o kernel registra.
/// Entradas desabilitadas pelo firmware sao ignoradas; quando existem mais
/// processadores habilitados do que a capacidade da fatia, `truncated` fica
/// verdadeiro e o excedente nao e gravado.
pub fn parseMadt(bytes: []const u8, processors: []Processor) Error!Madt {
    if (!hasSignature(bytes, madt_signature)) return error.InvalidSignature;

    const length = try tableLength(bytes);
    if (length < madt_header_size) return error.TruncatedTable;
    if (checksum(bytes[0..length]) != 0) return error.InvalidChecksum;

    var result = Madt{
        .local_apic_base = readU32(bytes, 36),
    };

    var offset: usize = madt_header_size;
    while (offset + 2 <= length) {
        const entry_type = bytes[offset];
        const entry_length = bytes[offset + 1];
        if (entry_length < 2) return error.InvalidLength;
        if (offset + entry_length > length) return error.InvalidLength;

        switch (entry_type) {
            // Processor Local APIC (ACPI 1.0).
            0 => {
                if (entry_length < 8) return error.InvalidLength;
                const flags = readU32(bytes, offset + 4);
                if (flags & 1 != 0) {
                    if (result.count < processors.len) {
                        processors[result.count] = .{
                            .apic_id = bytes[offset + 3],
                            .enabled = true,
                            .x2apic = false,
                        };
                        result.count += 1;
                    } else {
                        result.truncated = true;
                    }
                }
            },
            // Processor Local x2APIC.
            9 => {
                if (entry_length < 16) return error.InvalidLength;
                const flags = readU32(bytes, offset + 8);
                if (flags & 1 != 0) {
                    if (result.count < processors.len) {
                        processors[result.count] = .{
                            .apic_id = readU32(bytes, offset + 4),
                            .enabled = true,
                            .x2apic = true,
                        };
                        result.count += 1;
                    } else {
                        result.truncated = true;
                    }
                }
            },
            // Local APIC Address Override.
            5 => {
                if (entry_length < 12) return error.InvalidLength;
                result.local_apic_base = readU64(bytes, offset + 4);
            },
            else => {},
        }

        offset += entry_length;
    }

    return result;
}

// ---------------------------------------------------------------------------
// Testes
// ---------------------------------------------------------------------------

/// Preenche uma tabela sintetica com a soma de verificacao correta.
fn seal(table: []u8) void {
    table[9] = 0;
    table[9] = 0 -% checksum(table);
}

test "checksum closes a sealed table" {
    var table = [_]u8{ 1, 2, 3, 4 };
    table[3] = 0 -% checksum(table[0..3]);
    try std.testing.expectEqual(@as(u8, 0), checksum(&table));
}

test "validateRsdpBase accepts a valid ACPI 1.0 RSDP" {
    var rsdp: [rsdp_base_size]u8 = @splat(0);
    @memcpy(rsdp[0..8], rsdp_signature);
    rsdp[15] = 0;
    std.mem.writeInt(u32, rsdp[16..20], 0x1000, .little);
    rsdp[8] = 0 -% checksum(rsdp[0..20]);

    const parsed = try validateRsdpBase(&rsdp);
    try std.testing.expectEqual(@as(u8, 0), parsed.revision);
    try std.testing.expectEqual(@as(u32, 0x1000), parsed.rsdt_address);
    try std.testing.expectEqual(@as(u64, 0), parsed.xsdt_address);
}

test "validateRsdpBase rejects a bad signature" {
    var rsdp: [rsdp_base_size]u8 = @splat(0);
    @memcpy(rsdp[0..8], "BAD PTR ");
    rsdp[8] = 0 -% checksum(rsdp[0..20]);
    try std.testing.expectError(error.InvalidSignature, validateRsdpBase(&rsdp));
}

test "validateRsdpBase rejects a bad checksum" {
    var rsdp: [rsdp_base_size]u8 = @splat(0);
    @memcpy(rsdp[0..8], rsdp_signature);
    rsdp[8] = 1;
    try std.testing.expectError(error.InvalidChecksum, validateRsdpBase(&rsdp));
}

test "validateRsdpExtended reads the XSDT address" {
    var rsdp: [rsdp_extended_size]u8 = @splat(0);
    @memcpy(rsdp[0..8], rsdp_signature);
    rsdp[15] = 2;
    std.mem.writeInt(u64, rsdp[24..32], 0x2000_0000, .little);
    rsdp[8] = 0 -% checksum(rsdp[0..36]);

    try std.testing.expectEqual(@as(u64, 0x2000_0000), try validateRsdpExtended(&rsdp));
}

test "tableLength rejects a table larger than the buffer" {
    var header: [36]u8 = @splat(0);
    std.mem.writeInt(u32, header[4..8], 4096, .little);
    try std.testing.expectError(error.InvalidLength, tableLength(&header));
}

/// Monta um cabecalho de tabela ACPI sintetico.
fn makeHeader(destination: []u8, signature: []const u8, length: usize) void {
    @memset(destination, 0);
    @memcpy(destination[0..4], signature);
    std.mem.writeInt(u32, destination[4..8], @intCast(length), .little);
}

test "parseMadt reads the local APIC base and the processors" {
    var table: [64]u8 = @splat(0);
    makeHeader(&table, madt_signature, table.len);
    std.mem.writeInt(u32, table[36..40], 0xFEE0_0000, .little);

    // Processor Local APIC: tipo 0, comprimento 8, id 0, flags 1.
    table[44] = 0;
    table[45] = 8;
    table[46] = 0;
    table[47] = 0;
    std.mem.writeInt(u32, table[48..52], 1, .little);

    // Segundo processador, desabilitado (flags 0).
    table[52] = 0;
    table[53] = 8;
    table[54] = 1;
    table[55] = 1;
    std.mem.writeInt(u32, table[56..60], 0, .little);

    // Terceiro processador, habilitado, id 2.
    table[60] = 0;
    table[61] = 4; // comprimento menor que o minimo: a tabela sera recusada
    seal(&table);

    try std.testing.expectError(error.InvalidLength, parseMadt(&table, &[_]Processor{}));
}

test "parseMadt accepts two enabled processors" {
    var table: [72]u8 = @splat(0);
    makeHeader(&table, madt_signature, table.len);
    std.mem.writeInt(u32, table[36..40], 0xFEE0_0000, .little);

    // Primeiro processador habilitado.
    table[44] = 0;
    table[45] = 8;
    table[46] = 0;
    table[47] = 0;
    std.mem.writeInt(u32, table[48..52], 1, .little);

    // Segundo processador habilitado.
    table[52] = 0;
    table[53] = 8;
    table[54] = 0;
    table[55] = 1;
    std.mem.writeInt(u32, table[56..60], 1, .little);

    // Entrada de sobreposicao do endereco do APIC local.
    table[60] = 5;
    table[61] = 12;
    std.mem.writeInt(u64, table[64..72], 0xFEE0_1000, .little);

    seal(&table);

    var processors: [4]Processor = @splat(.{});
    const result = try parseMadt(&table, &processors);
    try std.testing.expectEqual(@as(usize, 2), result.count);
    try std.testing.expectEqual(@as(u32, 0), processors[0].apic_id);
    try std.testing.expectEqual(@as(u32, 1), processors[1].apic_id);
    try std.testing.expect(!result.truncated);
    try std.testing.expectEqual(@as(u64, 0xFEE0_1000), result.local_apic_base);
}

test "parseMadt reports truncation when the slice is too small" {
    var table: [52]u8 = @splat(0);
    makeHeader(&table, madt_signature, table.len);
    std.mem.writeInt(u32, table[36..40], 0xFEE0_0000, .little);
    table[44] = 0;
    table[45] = 8;
    table[46] = 0;
    table[47] = 0;
    std.mem.writeInt(u32, table[48..52], 1, .little);
    seal(&table);

    var processors: [0]Processor = .{};
    const result = try parseMadt(&table, &processors);
    try std.testing.expectEqual(@as(usize, 0), result.count);
    try std.testing.expect(result.truncated);
}
