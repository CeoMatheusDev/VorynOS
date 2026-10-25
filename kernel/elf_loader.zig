//************************************************************************//
//  elf_loader.zig                                                        //
//************************************************************************//
//                         This file is part of:                          //
//                               VorynOS                                  //
//              https://github.com/CeoMatheusDev/VorynOS                  //
//************************************************************************//
// Copyright (C) 2026 VorynOS contributors.                               //
//                                                                        //
// SPDX-License-Identifier: GPL-3.0-only                                  //
//************************************************************************//

//! Planejamento de carga de programas ELF64.
//!
//! O carregador é dividido em duas camadas:
//!
//!   1. o **plano de carga**, implementado aqui, que valida a imagem e
//!      calcula quais páginas cada segmento ocupa, com que permissões e em
//!      que endereço a entrada do programa fica;
//!   2. a **materialização**, que aloca páginas físicas, mapeia o espaço
//!      do processo, copia o conteúdo e cria a tarefa.
//!
//! A primeira camada é pura: ela não toca em hardware, não aloca memória
//! dinâmica e pode ser exercitada no host com imagens arbitrárias. A
//! segunda camada pertence ao incremento seguinte, e depende do paginador
//! e do escalonador.
//!
//! Regras validadas pelo plano:
//!
//!   * a imagem tem de conter ao menos um segmento carregável;
//!   * todo segmento tem de cair inteiro dentro da janela pedida;
//!   * a congruência `p_vaddr ≡ p_offset (mod p_align)` tem de valer;
//!   * dois segmentos não podem compartilhar uma página;
//!   * um segmento não pode ser gravável e executável ao mesmo tempo
//!     (W^X);
//!   * a entrada tem de cair dentro de um segmento executável;
//!   * uma imagem `ET_EXEC` não aceita deslocamento de carga; uma `ET_DYN`
//!     aceita;
//!   * cada realocação relativa tem de apontar para um segmento gravável.

const std = @import("std");
const voryn = @import("voryn_shared");
const elf64 = voryn.elf64;
const fs = @import("fs/fs.zig");
const vex = @import("voryn_vex");

/// Tamanho de uma página, em bytes.
pub const page_size: u64 = 4096;

/// Número máximo de segmentos carregáveis em um plano.
pub const max_segments: usize = 16;

/// Número máximo de realocações relativas em um plano.
pub const max_relocations: usize = 64;

/// Erros próprios do carregador.
pub const LoadError = error{
    /// A imagem não tem conteúdo ou não tem segmento carregável útil.
    EmptyImage,
    /// `window_base + window_size` não cabe em 64 bits.
    WindowOverflow,
    /// O deslocamento de carga ou a janela não está alinhado a página.
    SegmentNotAligned,
    /// Um segmento cai fora da janela de endereços pedida.
    SegmentOutsideWindow,
    /// Dois segmentos ocupam a mesma página.
    SegmentOverlaps,
    /// Um segmento pede escrita e execução ao mesmo tempo.
    WritableExecutableSegment,
    /// A imagem não tem segmento executável.
    NoExecutableSegment,
    /// A entrada do programa não está em um segmento executável.
    EntryOutsideExecutableSegment,
    /// Uma realocação aponta para fora de um segmento gravável.
    RelocationOutsideWritableSegment,
    /// A imagem tem mais segmentos do que o plano suporta.
    TooManySegments,
    /// A imagem tem mais realocações do que o plano suporta.
    TooManyRelocations,
    /// Uma imagem `ET_EXEC` recebeu deslocamento de carga.
    BiasNotAllowed,
    /// O buffer não comporta o arquivo inteiro.
    BufferTooSmall,
};

/// Erro do planejamento puro.
pub const PlanError = elf64.ParseError || LoadError;

/// Erro do planejamento a partir do RamFS.
pub const Error = fs.Error || PlanError || vex.Error;

/// Segmento já posicionado no espaço de endereços virtual.
pub const PlannedSegment = struct {
    /// Endereço virtual do primeiro byte do segmento, já com o deslocamento.
    virtual_address: u64,
    /// Deslocamento do conteúdo dentro do arquivo.
    file_offset: u64,
    /// Número de bytes presentes no arquivo.
    file_size: u64,
    /// Número de bytes ocupados em memória (inclui o BSS).
    memory_size: u64,
    /// Flags do segmento, ver `elf64.pf_*`.
    flags: u32,
    /// Primeira página tocada, alinhada para baixo.
    page_start: u64,
    /// Primeira página depois do segmento, alinhada para cima.
    page_end: u64,

    /// Verdadeiro quando o segmento é executável.
    pub fn isExecutable(self: PlannedSegment) bool {
        return self.flags & elf64.pf_x != 0;
    }

    /// Verdadeiro quando o segmento é gravável.
    pub fn isWritable(self: PlannedSegment) bool {
        return self.flags & elf64.pf_w != 0;
    }

    /// Verdadeiro quando o segmento é legível.
    pub fn isReadable(self: PlannedSegment) bool {
        return self.flags & elf64.pf_r != 0;
    }

    /// Número de páginas que o segmento ocupa.
    pub fn pageCount(self: PlannedSegment) u64 {
        return (self.page_end - self.page_start) / page_size;
    }
};

/// Plano de carga completo, em armazenamento fixo.
pub const LoadPlan = struct {
    /// Endereço virtual da entrada do programa.
    entry: u64 = 0,
    /// Deslocamento somado aos endereços da imagem.
    load_bias: u64 = 0,
    /// Primeira página ocupada pela imagem.
    base: u64 = 0,
    /// Primeira página depois da imagem.
    end: u64 = 0,
    /// Verdadeiro quando a imagem pode ser carregada em qualquer endereço.
    relocatable: bool = false,

    /// Armazenamento dos segmentos.
    segments: [max_segments]PlannedSegment = undefined,
    /// Número de segmentos válidos em `segments`.
    segment_count: usize = 0,

    /// Armazenamento das realocações.
    relocations: [max_relocations]elf64.Relocation = undefined,
    /// Número de realocações válidas.
    relocation_count: usize = 0,

    /// Segmentos válidos do plano.
    pub fn segmentList(self: *const LoadPlan) []const PlannedSegment {
        return self.segments[0..self.segment_count];
    }

    /// Realocações válidas do plano.
    pub fn relocationList(self: *const LoadPlan) []const elf64.Relocation {
        return self.relocations[0..self.relocation_count];
    }

    /// Tamanho da imagem em bytes, de `base` a `end`.
    pub fn size(self: *const LoadPlan) u64 {
        return self.end - self.base;
    }
};

/// Alinha um endereço para baixo, no tamanho de página.
fn alignDown(address: u64) u64 {
    return address & ~(page_size - 1);
}

/// Alinha um endereço para cima, no tamanho de página.
fn alignUp(address: u64) PlanError!u64 {
    const padded = std.math.add(u64, address, page_size - 1) catch return error.WindowOverflow;
    return padded & ~(page_size - 1);
}

/// Valida uma imagem ELF64 e calcula o plano de carga.
///
/// `load_bias` é somado a todos os endereços da imagem. A janela
/// `[window_base, window_base + window_size)` é o espaço virtual que o
/// processo tem para receber a imagem; a janela e o deslocamento têm de
/// estar alinhados a página.
pub fn plan(
    bytes: []const u8,
    load_bias: u64,
    window_base: u64,
    window_size: u64,
) PlanError!LoadPlan {
    if (bytes.len == 0) return error.EmptyImage;
    if (window_size == 0) return error.SegmentOutsideWindow;
    if (window_base % page_size != 0 or load_bias % page_size != 0) {
        return error.SegmentNotAligned;
    }

    const window_end = std.math.add(u64, window_base, window_size) catch
        return error.WindowOverflow;

    var raw_segments: [max_segments]elf64.Segment = undefined;
    var raw_relocations: [max_relocations]elf64.Relocation = undefined;
    const image = try elf64.parse(bytes, &raw_segments, &raw_relocations);

    if (!image.relocatable and load_bias != 0) return error.BiasNotAllowed;

    var result: LoadPlan = .{
        .load_bias = load_bias,
        .base = std.math.maxInt(u64),
        .relocatable = image.relocatable,
    };

    for (image.segments) |segment| {
        // Um segmento vazio não ocupa página e não entra no plano.
        if (segment.memory_size == 0) continue;

        const virtual_address = std.math.add(u64, segment.virtual_address, load_bias) catch
            return error.WindowOverflow;
        const memory_end = std.math.add(u64, virtual_address, segment.memory_size) catch
            return error.WindowOverflow;

        // A regra do ELF: o endereço e o deslocamento têm de ser
        // congruentes módulo o alinhamento pedido pelo segmento.
        if (segment.alignment > 1) {
            if (!std.math.isPowerOfTwo(segment.alignment)) return error.SegmentNotAligned;
            if (virtual_address % segment.alignment != segment.file_offset % segment.alignment) {
                return error.SegmentNotAligned;
            }
        }

        if ((segment.flags & (elf64.pf_w | elf64.pf_x)) == (elf64.pf_w | elf64.pf_x)) {
            return error.WritableExecutableSegment;
        }

        const page_start = alignDown(virtual_address);
        const page_end = try alignUp(memory_end);
        if (page_start < window_base or page_end > window_end) {
            return error.SegmentOutsideWindow;
        }

        if (result.segment_count >= max_segments) return error.TooManySegments;
        result.segments[result.segment_count] = .{
            .virtual_address = virtual_address,
            .file_offset = segment.file_offset,
            .file_size = segment.file_size,
            .memory_size = segment.memory_size,
            .flags = segment.flags,
            .page_start = page_start,
            .page_end = page_end,
        };
        result.segment_count += 1;

        if (page_start < result.base) result.base = page_start;
        if (page_end > result.end) result.end = page_end;
    }

    if (result.segment_count == 0) return error.EmptyImage;

    // Dois segmentos não podem compartilhar uma página: o mapeamento tem
    // permissões por página, e duas permissões diferentes na mesma página
    // seriam resolvidas por um dos segmentos, em silêncio.
    for (result.segments[0..result.segment_count], 0..) |first, index| {
        for (result.segments[index + 1 .. result.segment_count]) |second| {
            if (first.page_start < second.page_end and second.page_start < first.page_end) {
                return error.SegmentOverlaps;
            }
        }
    }

    const entry = std.math.add(u64, image.entry, load_bias) catch
        return error.WindowOverflow;
    if (entry < window_base or entry >= window_end) {
        return error.EntryOutsideExecutableSegment;
    }

    var entry_is_executable = false;
    var has_executable_segment = false;
    for (result.segments[0..result.segment_count]) |segment| {
        if (!segment.isExecutable()) continue;
        has_executable_segment = true;

        // A entrada tem de estar no conteúdo vindo do arquivo: uma entrada
        // no BSS seria código que o arquivo não fornece.
        const executable_end = segment.virtual_address + segment.file_size;
        if (entry >= segment.virtual_address and entry < executable_end) {
            entry_is_executable = true;
        }
    }

    if (!has_executable_segment) return error.NoExecutableSegment;
    if (!entry_is_executable) return error.EntryOutsideExecutableSegment;
    result.entry = entry;

    for (image.relocations) |relocation| {
        if (result.relocation_count >= max_relocations) return error.TooManyRelocations;

        const target = std.math.add(u64, relocation.offset, load_bias) catch
            return error.WindowOverflow;
        const target_end = std.math.add(u64, target, @sizeOf(u64)) catch
            return error.WindowOverflow;

        var target_is_writable = false;
        for (result.segments[0..result.segment_count]) |segment| {
            if (!segment.isWritable()) continue;
            const segment_end = segment.virtual_address + segment.memory_size;
            if (target >= segment.virtual_address and target_end <= segment_end) {
                target_is_writable = true;
                break;
            }
        }

        if (!target_is_writable) return error.RelocationOutsideWritableSegment;

        result.relocations[result.relocation_count] = relocation;
        result.relocation_count += 1;
    }

    return result;
}

/// Lê um programa do RamFS e calcula o plano de carga.
///
/// O buffer tem de comportar o arquivo inteiro, porque o tamanho é
/// consultado antes da leitura: um buffer menor recusa o plano em vez de
/// analisar uma imagem truncada.
///
/// O arquivo pode ser um ELF64 puro ou um container VEX (`formats/vex.zig`):
/// o magic decide. Para um VEX, o cabeçalho e o manifest são validados, o
/// CRC do payload é conferido e a imagem ELF é deslocada para o início do
/// buffer, para que o materializador leia os bytes a partir do offset
/// zero. O manifest declarado é metadado validado; a concessão das
/// capacidades continua sendo decisão do kernel.
pub fn planFromRamFs(
    path: []const u8,
    buffer: []u8,
    load_bias: u64,
    window_base: u64,
    window_size: u64,
) Error!LoadPlan {
    const file_size = try fs.sizeOf(path);
    if (file_size > @as(u64, buffer.len)) return error.BufferTooSmall;

    const count = try fs.readFile(path, buffer);
    if (@as(u64, count) != file_size) return error.BufferTooSmall;

    const image = vex.unwrap(buffer[0..count]) catch |err| {
        if (err == error.NotVex) return plan(buffer[0..count], load_bias, window_base, window_size);
        return err;
    };
    // Container VEX: move o payload para o início do buffer.
    if (image.len != count) {
        std.mem.copyForwards(u8, buffer[0..image.len], image);
    }
    return plan(buffer[0..image.len], load_bias, window_base, window_size);
}

// ---------------------------------------------------------------------------
// Testes
// ---------------------------------------------------------------------------

const testing = std.testing;

/// Descrição de um segmento usada para montar imagens de teste.
const TestSegment = struct {
    flags: u32,
    virtual_address: u64,
    file_offset: u64,
    file_size: u64,
    memory_size: u64,
    alignment: u64,
};

/// Monta uma imagem ELF64 `ET_EXEC` válida com os segmentos pedidos.
fn buildTestImage(buffer: []u8, entry: u64, segments: []const TestSegment) ![]const u8 {
    const header_size = @sizeOf(elf64.Ehdr);
    const phdr_size = @sizeOf(elf64.Phdr);
    const table_end = header_size + segments.len * phdr_size;
    if (buffer.len < table_end) return error.BufferTooSmall;

    @memset(buffer[0..], 0);

    const header: elf64.Ehdr = .{
        .ident = .{
            0x7f,
            'E',
            'L',
            'F',
            elf64.class_64,
            elf64.data_lsb,
            elf64.version_current,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
        },
        .type = elf64.type_exec,
        .machine = elf64.machine_x86_64,
        .version = 1,
        .entry = entry,
        .program_header_offset = header_size,
        .header_size = header_size,
        .program_header_entry_size = phdr_size,
        .program_header_count = @intCast(segments.len),
    };
    @memcpy(buffer[0..header_size], std.mem.asBytes(&header));

    var image_end = table_end;
    for (segments, 0..) |segment, index| {
        const file_end = std.math.add(u64, segment.file_offset, segment.file_size) catch
            return error.BufferTooSmall;
        if (file_end > buffer.len) return error.BufferTooSmall;

        const phdr: elf64.Phdr = .{
            .type = elf64.pt_load,
            .flags = segment.flags,
            .offset = segment.file_offset,
            .virtual_address = segment.virtual_address,
            .physical_address = segment.virtual_address,
            .file_size = segment.file_size,
            .memory_size = segment.memory_size,
            .alignment = segment.alignment,
        };
        const target = header_size + index * phdr_size;
        @memcpy(buffer[target..][0..phdr_size], std.mem.asBytes(&phdr));

        const start: usize = @intCast(segment.file_offset);
        const length: usize = @intCast(segment.file_size);
        @memset(buffer[start..][0..length], 0x90);

        if (file_end > image_end) image_end = file_end;
    }

    return buffer[0..@intCast(image_end)];
}

const rx_segment = TestSegment{
    .flags = elf64.pf_r | elf64.pf_x,
    .virtual_address = 0x400000,
    .file_offset = 0x1000,
    .file_size = 0x100,
    .memory_size = 0x1000,
    .alignment = 0x1000,
};

const rw_segment = TestSegment{
    .flags = elf64.pf_r | elf64.pf_w,
    .virtual_address = 0x401000,
    .file_offset = 0x2000,
    .file_size = 0x100,
    .memory_size = 0x1000,
    .alignment = 0x1000,
};

test "plan accepts a two segment image and computes the page range" {
    var buffer: [0x3000]u8 = undefined;
    const segments = [_]TestSegment{ rx_segment, rw_segment };
    const bytes = try buildTestImage(&buffer, 0x400080, &segments);

    const load_plan = try plan(bytes, 0, 0x400000, 0x2000);
    try testing.expectEqual(@as(u64, 0x400080), load_plan.entry);
    try testing.expectEqual(@as(u64, 0), load_plan.load_bias);
    try testing.expectEqual(@as(u64, 0x400000), load_plan.base);
    try testing.expectEqual(@as(u64, 0x402000), load_plan.end);
    try testing.expectEqual(@as(usize, 2), load_plan.segment_count);
    try testing.expect(!load_plan.relocatable);

    const list = load_plan.segmentList();
    try testing.expect(list[0].isExecutable());
    try testing.expect(list[1].isWritable());
    try testing.expectEqual(@as(u64, 1), list[0].pageCount());
    try testing.expectEqual(@as(u64, 1), list[1].pageCount());
}

test "plan refuses a writable and executable segment" {
    var buffer: [0x3000]u8 = undefined;
    var code = rx_segment;
    code.flags = elf64.pf_r | elf64.pf_w | elf64.pf_x;
    const segments = [_]TestSegment{ code, rw_segment };
    const bytes = try buildTestImage(&buffer, 0x400080, &segments);

    try testing.expectError(
        error.WritableExecutableSegment,
        plan(bytes, 0, 0x400000, 0x2000),
    );
}

test "plan refuses overlapping pages and segments outside the window" {
    var buffer: [0x3000]u8 = undefined;

    var overlapping = rw_segment;
    overlapping.virtual_address = 0x400000;
    overlapping.file_offset = 0x2000;
    const overlap_segments = [_]TestSegment{ rx_segment, overlapping };
    const overlap_bytes = try buildTestImage(&buffer, 0x400080, &overlap_segments);
    try testing.expectError(
        error.SegmentOverlaps,
        plan(overlap_bytes, 0, 0x400000, 0x2000),
    );

    var outside = rw_segment;
    outside.virtual_address = 0x500000;
    const outside_segments = [_]TestSegment{ rx_segment, outside };
    const outside_bytes = try buildTestImage(&buffer, 0x400080, &outside_segments);
    try testing.expectError(
        error.SegmentOutsideWindow,
        plan(outside_bytes, 0, 0x400000, 0x2000),
    );
}

test "plan enforces the alignment of the segment" {
    var buffer: [0x3000]u8 = undefined;
    var misaligned = rx_segment;
    misaligned.virtual_address = 0x400100;
    const segments = [_]TestSegment{misaligned};
    const bytes = try buildTestImage(&buffer, 0x400180, &segments);

    try testing.expectError(
        error.SegmentNotAligned,
        plan(bytes, 0, 0x400000, 0x2000),
    );
}

test "plan requires the entry point to be executable" {
    var buffer: [0x3000]u8 = undefined;
    const segments = [_]TestSegment{ rx_segment, rw_segment };

    const in_data = try buildTestImage(&buffer, 0x401080, &segments);
    try testing.expectError(
        error.EntryOutsideExecutableSegment,
        plan(in_data, 0, 0x400000, 0x2000),
    );

    const outside = try buildTestImage(&buffer, 0x900000, &segments);
    try testing.expectError(
        error.EntryOutsideSegments,
        plan(outside, 0, 0x400000, 0x2000),
    );
}

test "a fixed image does not accept a load bias" {
    var buffer: [0x3000]u8 = undefined;
    const segments = [_]TestSegment{ rx_segment, rw_segment };
    const bytes = try buildTestImage(&buffer, 0x400080, &segments);

    try testing.expectError(
        error.BiasNotAllowed,
        plan(bytes, 0x1000, 0x400000, 0x2000),
    );
}

test "a position independent image accepts a load bias" {
    var buffer: [0x3000]u8 = undefined;
    const segment = TestSegment{
        .flags = elf64.pf_r | elf64.pf_x,
        .virtual_address = 0,
        .file_offset = 0x1000,
        .file_size = 0x100,
        .memory_size = 0x1000,
        .alignment = 0x1000,
    };
    const segments = [_]TestSegment{segment};
    const bytes = try buildTestImage(&buffer, 0x80, &segments);

    // O tipo `ET_DYN` é escrito no cabeçalho, no campo `e_type` (offset 16).
    std.mem.writeInt(u16, buffer[16..18], elf64.type_dyn, .little);

    const load_plan = try plan(bytes, 0x700000, 0x700000, 0x2000);
    try testing.expect(load_plan.relocatable);
    try testing.expectEqual(@as(u64, 0x700000), load_plan.load_bias);
    try testing.expectEqual(@as(u64, 0x700080), load_plan.entry);
    try testing.expectEqual(@as(u64, 0x700000), load_plan.base);
    try testing.expectEqual(@as(u64, 0x701000), load_plan.end);
}

test "planFromRamFs reads the image and refuses a small buffer" {
    fs.init();

    var image_buffer: [0x3000]u8 = undefined;
    const segments = [_]TestSegment{ rx_segment, rw_segment };
    const bytes = try buildTestImage(&image_buffer, 0x400080, &segments);

    const fd = try fs.create(0, "/app.elf", 0o755);
    _ = try fs.write(0, fd, bytes);
    try fs.close(0, fd);

    var scratch: [0x3000]u8 = undefined;
    const load_plan = try planFromRamFs("/app.elf", &scratch, 0, 0x400000, 0x2000);
    try testing.expectEqual(@as(u64, 0x400080), load_plan.entry);

    var small: [16]u8 = undefined;
    try testing.expectError(
        error.BufferTooSmall,
        planFromRamFs("/app.elf", &small, 0, 0x400000, 0x2000),
    );

    try testing.expectError(
        error.EntryNotFound,
        planFromRamFs("/missing.elf", &scratch, 0, 0x400000, 0x2000),
    );
}

test "planFromRamFs unwraps a VEX container and plans the inner ELF" {
    fs.init();

    var image_buffer: [0x3000]u8 = undefined;
    const segments = [_]TestSegment{ rx_segment, rw_segment };
    const bytes = try buildTestImage(&image_buffer, 0x400080, &segments);

    // Empacota o ELF em um VEX com manifest de capacidades.
    var vex_buffer: [0x3000 + vex.header_size]u8 = undefined;
    const manifest = [_]vex.Capability{
        .{ .kind = .display, .rights = 8 },
        .{ .kind = .input, .rights = 16 },
    };
    const wrapped = try vex.wrap(bytes, &manifest, &vex_buffer);

    const fd = try fs.create(0, "/app.vex", 0o755);
    _ = try fs.write(0, fd, vex_buffer[0..wrapped]);
    try fs.close(0, fd);

    var scratch: [0x3000 + vex.header_size]u8 = undefined;
    const load_plan = try planFromRamFs("/app.vex", &scratch, 0, 0x400000, 0x2000);
    try testing.expectEqual(@as(u64, 0x400080), load_plan.entry);
    try testing.expectEqual(@as(usize, 2), load_plan.segment_count);

    // Um VEX com payload corrompido é recusado antes do planejamento.
    var corrupted: [0x3000 + vex.header_size]u8 = undefined;
    @memcpy(corrupted[0..wrapped], vex_buffer[0..wrapped]);
    corrupted[vex.header_size + 4] ^= 0xFF;
    const bad_fd = try fs.create(0, "/bad.vex", 0o755);
    _ = try fs.write(0, bad_fd, corrupted[0..wrapped]);
    try fs.close(0, bad_fd);
    try testing.expectError(
        error.ChecksumMismatch,
        planFromRamFs("/bad.vex", &scratch, 0, 0x400000, 0x2000),
    );
}
