//************************************************************************//
//  native_image.zig                                                      //
//************************************************************************//
//                         This file is part of:                          //
//                               VorynOS                                  //
//              https://github.com/CeoMatheusDev/VorynOS                  //
//************************************************************************//
// Copyright (C) 2026 VorynOS contributors.                               //
//                                                                        //
// SPDX-License-Identifier: GPL-3.0-only                                  //
//************************************************************************//

//! Imagem ELF64 nativa de demonstração.
//!
//! O incremento F5.2 prova o caminho completo do carregador: um arquivo
//! ELF64 real é gravado no RamFS, lido de volta, validado pelo planejador,
//! materializado em páginas físicas com permissões W^X e executado em modo
//! usuário.
//!
//! A imagem é montada em memória porque o SDK de aplicações nativas ainda
//! não existe. Ela não é um esboço: o cabeçalho, a tabela de programas e os
//! dois segmentos `PT_LOAD` são ELF64 válidos, e o código é x86-64 real. O
//! próximo incremento substitui o construtor pelo compilador de aplicações
//! sem mudar o carregador.
//!
//! Layout da imagem:
//!
//!   * segmento de código: `vaddr = 0x0000`, arquivo em `0x1000`, R+X,
//!     memória de uma página;
//!   * segmento de dados: `vaddr = 0x1000`, arquivo em `0x2000`, R+W,
//!     memória de uma página;
//!   * entrada em `0x0000`, deslocada pelo viés de carga da janela.
//!
//! O código usa endereçamento relativo ao `RIP`, portanto não precisa de
//! realocações: o mesmo arquivo roda em qualquer janela alinhada a página.
//! Ele escreve `native ELF\n` no console pela chamada 2, grava o marcador
//! `0x464c456e79726f56` no deslocamento 16 da página de dados e termina com
//! a chamada 4.

const std = @import("std");
const voryn = @import("voryn_shared");
const elf64 = voryn.elf64;

/// Tamanho máximo da imagem, incluindo os espaços entre as seções.
pub const max_image_size: usize = 0x3000;

/// Deslocamento do primeiro byte do segmento de código no arquivo.
pub const code_file_offset: u64 = 0x1000;

/// Deslocamento do primeiro byte do segmento de dados no arquivo.
pub const data_file_offset: u64 = 0x2000;

/// Endereço virtual do segmento de código, relativo ao viés de carga.
pub const code_virtual_address: u64 = 0x0000;

/// Endereço virtual do segmento de dados, relativo ao viés de carga.
pub const data_virtual_address: u64 = 0x1000;

/// Tamanho do segmento de código em memória, incluindo o BSS.
pub const code_memory_size: u64 = 0x1000;

/// Tamanho do segmento de dados em memória, incluindo o BSS.
pub const data_memory_size: u64 = 0x1000;

/// Deslocamento do marcador dentro do segmento de dados.
pub const data_marker_offset: u64 = 16;

/// Deslocamento da tabela de realocações dentro do segmento de dados.
pub const relocation_table_offset: u64 = 24;

/// Deslocamento do alvo da realocação dentro do segmento de dados.
pub const relocation_target_offset: u64 = 48;

/// Deslocamento da seção dinâmica dentro do arquivo.
pub const dynamic_file_offset: u64 = 0x2040;

/// Tamanho da seção dinâmica: `DT_RELA`, `DT_RELASIZE` e `DT_NONE`.
const dynamic_size: usize = 3 * @sizeOf(elf64.Dyn);

/// Valor que o programa grava no marcador.
///
/// Os oito bytes, em ordem little-endian, formam o texto `VorynELF`.
pub const marker: u64 = 0x464C_456E_7972_6F56;

/// Comprimento do texto que o programa escreve no console.
pub const message_length: u64 = 11;

/// Código de máquina do programa nativo.
///
/// A listagem que produziu os bytes está abaixo. Cada instrução foi montada
/// para o endereço virtual zero, e o deslocamento relativo ao `RIP` aponta
/// para a página de dados em `0x1000`.
///
/// ```asm
/// _start:
///     mov $2, %rax                 ; write
///     lea message(%rip), %rdi      ; "native ELF\n"
///     mov $11, %rsi
///     mov $1, %rdx                 ; console
///     syscall
///     movabs $0x464C456E79726F56, %rax
///     lea marker(%rip), %rdi       ; página de dados + 16
///     mov %rax, (%rdi)
///     mov $4, %rax                 ; exit
///     xor %rdi, %rdi
///     syscall
/// 1:  jmp 1b
/// ```
const code = [_]u8{
    0x48, 0xC7, 0xC0, 0x02, 0x00, 0x00, 0x00, // mov rax, 2
    0x48, 0x8D, 0x3D, 0xF2, 0x0F, 0x00, 0x00, // lea rdi, [rip + 0xff2]
    0x48, 0xC7, 0xC6, 0x0B, 0x00, 0x00, 0x00, // mov rsi, 11
    0x48, 0xC7, 0xC2, 0x01, 0x00, 0x00, 0x00, // mov rdx, 1
    0x0F, 0x05, // syscall
    0x48, 0xB8, 0x56, 0x6F, 0x72, 0x79, 0x6E, 0x45, 0x4C, 0x46, // movabs rax, marker
    0x48, 0x8D, 0x3D, 0xE1, 0x0F, 0x00, 0x00, // lea rdi, [rip + 0xfe1]
    0x48, 0x89, 0x07, // mov [rdi], rax
    0x48, 0xC7, 0xC0, 0x04, 0x00, 0x00, 0x00, // mov rax, 4
    0x48, 0x31, 0xFF, // xor rdi, rdi
    0x0F, 0x05, // syscall
    0xEB, 0xFE, // jmp $
};

/// Texto que o programa escreve no console.
const message = "native ELF\n";

/// Conteúdo do segmento de dados que vem do arquivo.
///
/// O marcador fica no deslocamento 16 e começa zerado; o próprio programa o
/// preenche antes de terminar, e o kernel lê o valor para provar que o
/// processo executou. A tabela de realocações fica em 24, o alvo relativo
/// fica em 48 e a seção dinâmica aponta para os dois. O alvo é preenchido
/// pelo materializador com o viés de carga, e o kernel confere o valor.
const data_size: usize = 56;

/// Tamanho total do arquivo ELF.
const image_size: usize = @as(usize, @intCast(dynamic_file_offset)) + dynamic_size;

comptime {
    if (code.len > code_memory_size) {
        @compileError("o segmento de código não cabe em uma página");
    }
    if (data_size > data_memory_size) {
        @compileError("o segmento de dados não cabe em uma página");
    }
    if (message.len != message_length) {
        @compileError("o comprimento da mensagem não corresponde ao argumento da chamada");
    }
}

/// Erros da montagem da imagem.
pub const Error = error{
    /// O buffer do chamador não comporta a imagem inteira.
    BufferTooSmall,
};

/// Monta a imagem ELF64 em `buffer` e devolve a fatia ocupada.
///
/// O buffer tem de ter ao menos `max_image_size` bytes, mas o contrato é
/// verificado: um buffer menor recebe o erro em vez de uma imagem truncada.
pub fn build(buffer: []u8) Error![]const u8 {
    if (buffer.len < image_size) return error.BufferTooSmall;

    // Os espaços entre o cabeçalho, a tabela e os segmentos não pertencem a
    // nenhum deles, mas um arquivo determinístico tem de ser igual em toda
    // execução: o buffer inteiro começa zerado.
    @memset(buffer[0..image_size], 0);

    const header: elf64.Ehdr = .{
        .ident = .{
            0x7F,           'E',            'L',                   'F',
            elf64.class_64, elf64.data_lsb, elf64.version_current, 0,
            0,              0,              0,                     0,
            0,              0,              0,                     0,
        },
        .type = elf64.type_dyn,
        .machine = elf64.machine_x86_64,
        .version = 1,
        .entry = code_virtual_address,
        .program_header_offset = @sizeOf(elf64.Ehdr),
        .section_header_offset = 0,
        .flags = 0,
        .header_size = @sizeOf(elf64.Ehdr),
        .program_header_entry_size = @sizeOf(elf64.Phdr),
        .program_header_count = 3,
        .section_header_entry_size = 0,
        .section_header_count = 0,
        .section_name_index = 0,
    };
    @memcpy(buffer[0..@sizeOf(elf64.Ehdr)], std.mem.asBytes(&header));

    const code_header: elf64.Phdr = .{
        .type = elf64.pt_load,
        .flags = elf64.pf_r | elf64.pf_x,
        .offset = code_file_offset,
        .virtual_address = code_virtual_address,
        .physical_address = code_virtual_address,
        .file_size = code.len,
        .memory_size = code_memory_size,
        .alignment = 0x1000,
    };
    const data_header: elf64.Phdr = .{
        .type = elf64.pt_load,
        .flags = elf64.pf_r | elf64.pf_w,
        .offset = data_file_offset,
        .virtual_address = data_virtual_address,
        .physical_address = data_virtual_address,
        .file_size = data_size,
        .memory_size = data_memory_size,
        .alignment = 0x1000,
    };
    const dynamic_header: elf64.Phdr = .{
        .type = elf64.pt_dynamic,
        .flags = elf64.pf_r,
        .offset = dynamic_file_offset,
        .virtual_address = 0,
        .physical_address = 0,
        .file_size = dynamic_size,
        .memory_size = dynamic_size,
        .alignment = 8,
    };

    const table = @sizeOf(elf64.Ehdr);
    const entry_size = @sizeOf(elf64.Phdr);
    @memcpy(buffer[table..][0..entry_size], std.mem.asBytes(&code_header));
    @memcpy(buffer[table + entry_size ..][0..entry_size], std.mem.asBytes(&data_header));
    @memcpy(buffer[table + 2 * entry_size ..][0..entry_size], std.mem.asBytes(&dynamic_header));

    const code_offset: usize = @intCast(code_file_offset);
    const data_offset: usize = @intCast(data_file_offset);
    @memcpy(buffer[code_offset..][0..code.len], &code);
    @memcpy(buffer[data_offset..][0..message.len], message);

    // A realocação relativa. O alvo começa zerado no arquivo; o
    // materializador escreve `load_bias + addend`, e o kernel confere o
    // valor na página do processo.
    const relocation = elf64.Rela{
        .offset = data_virtual_address + relocation_target_offset,
        .info = elf64.r_x86_64_relative,
        .addend = 0,
    };
    const relocation_offset = data_offset + @as(usize, @intCast(relocation_table_offset));
    @memcpy(
        buffer[relocation_offset..][0..@sizeOf(elf64.Rela)],
        std.mem.asBytes(&relocation),
    );

    // A seção dinâmica aponta para a tabela de realocações dentro do
    // segmento de dados. O tamanho é o de uma entrada `Rela`.
    const dynamic_entries = [_]elf64.Dyn{
        .{
            .tag = elf64.DynamicTag.rela,
            .value = data_virtual_address + relocation_table_offset,
        },
        .{
            .tag = elf64.DynamicTag.rela_size,
            .value = @sizeOf(elf64.Rela),
        },
        .{ .tag = elf64.DynamicTag.none, .value = 0 },
    };
    @memcpy(buffer[@intCast(dynamic_file_offset)..][0..dynamic_size], std.mem.asBytes(&dynamic_entries));

    return buffer[0..image_size];
}

const testing = std.testing;

test "a imagem tem cabeçalho, dois segmentos e uma realocação" {
    var buffer: [max_image_size]u8 = undefined;
    const bytes = try build(&buffer);

    try testing.expectEqual(@as(usize, image_size), bytes.len);

    var segments: [8]elf64.Segment = undefined;
    var relocations: [8]elf64.Relocation = undefined;
    const image = try elf64.parse(bytes, &segments, &relocations);

    try testing.expect(image.relocatable);
    try testing.expectEqual(@as(u64, code_virtual_address), image.entry);
    try testing.expectEqual(@as(u64, code_virtual_address), image.base);
    try testing.expectEqual(@as(u64, 0x2000), image.end);
    try testing.expectEqual(@as(usize, 2), image.segments.len);
    try testing.expectEqual(@as(usize, 1), image.relocations.len);
    try testing.expectEqual(
        @as(u64, data_virtual_address + relocation_target_offset),
        image.relocations[0].offset,
    );
    try testing.expectEqual(@as(i64, 0), image.relocations[0].addend);

    try testing.expect(image.segments[0].isReadable());
    try testing.expect(image.segments[0].isExecutable());
    try testing.expect(!image.segments[0].isWritable());
    try testing.expect(image.segments[1].isReadable());
    try testing.expect(image.segments[1].isWritable());
    try testing.expect(!image.segments[1].isExecutable());

    // O marcador e o alvo da realocação começam zerados no arquivo: quem
    // escreve o primeiro é o programa, e o segundo é o materializador.
    const data_offset: usize = @intCast(data_file_offset);
    const marker_offset = data_offset + @as(usize, @intCast(data_marker_offset));
    const target_offset = data_offset + @as(usize, @intCast(relocation_target_offset));
    try testing.expectEqual(
        @as(u64, 0),
        std.mem.readInt(u64, bytes[marker_offset..][0..8], .little),
    );
    try testing.expectEqual(
        @as(u64, 0),
        std.mem.readInt(u64, bytes[target_offset..][0..8], .little),
    );
}

test "um buffer menor recusa a imagem em vez de truncá-la" {
    var buffer: [image_size - 1]u8 = undefined;
    try testing.expectError(error.BufferTooSmall, build(&buffer));
}
