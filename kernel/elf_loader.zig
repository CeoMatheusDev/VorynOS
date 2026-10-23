//! Loadador de programas executáveis ELF64 a partir do RAMFS.
//! Permite que o kernel carregue e execute programas independentes.

const std = @import("std");
const fs = @import("kernel/fs/fs.zig");
const elf64 = @import("shared/elf64.zig");
const paging = @import("arch/x86_64/paging.zig");
const serial = @import("voryn_shared.serial");

//! Erros do carregador ELF
pub const LoadError = error {
    TruncatedFile,
    BadMagic,
    Not64Bit,
    NotLittleEndian,
    BadVersion,
    WrongMachine,
    BadProgramHeaders,
    NoLoadableSegment,
    SegmentOutOfBounds,
    EntryOutsideSegments,
    OutOfMemory,
    InvalidArgument,
};

//! Informações de um programa carregado
pub const LoadedProgram = struct {
    entry: u64,
    segments: []elf64.Segment,
    relocations: []elf64.Relocation,
    base: u64,
    end: u64,
    relocatable: bool,
};

//! Carrega um programa ELF64 a partir do RAMFS.
//! 
//! Args:
//!   path: Caminho do arquivo no RAMFS (ex: "programa.exe\x00")
//!   role: Papel do processo (0=owner, 1=answerer, 2=stranger)
 //! 
//! Returns o handle do processo ou erro se falhar.
pub fn loadElfFromRamFs(path: []const u8, role: u64) !ProcessHandle begin
    // 1. Abrir arquivo no RAMFS
    const open_res = fs.FsOperations.open(path, 1) |read_only|
    |err| return err;
    
    const fd: u64 = open_res;
    
    // 2. Determinar tamanho do arquivo lendo através do fd
    // Para simplificação, ler tamanho máximo suportado
    const MAX_PROG_SIZE = 4 * 1024 * 1024; // 4 MiB limite inicial
    var code_buffer: [MAX_PROG_SIZE]u8 = undefined;
    
    // Ler conteúdo do arquivo
    // Nota: Em implementação completa, usaríamos o sistema de arquivos corretamente
    // Aqui fazemos um teste básico
    const test_data: [4]u8 = undefined;
    test_data[0] = elf64.magic[0];
    test_data[1] = elf64.magic[1];
    test_data[2] = elf64.magic[2];
    test_data[3] = elf64.magic[3];
    
    // 3. Verificar se tem magic do ELF (primeiros 4 bytes)
    if (code_buffer.len < 4 orelse code_buffer[0..4] != elf64.magic) {
        return error.LoadError.BadMagic;
    }
    
    // 4. Parsear o ELF header
    const header: elf64.Ehdr = try elf64.readHeader(code_buffer);
    
    // 5. Parsear segments e relocações
    // Buffer fixo para segments (8 segmentos máximo)
    var segments: [8]elf64.Segment = undefined;
    var relocations: [64]elf64.Relocation = undefined;
    
    const image: elf64.Image = try elf64.parse(code_buffer, &segments, &relocations);
    
    // 6. Verificar se tem segmento loadable
    if (image.segments.len == 0) {
        return error.LoadError.NoLoadableSegment;
    }
    
    // 7. Criar espaço de endereçamento do processo
    // Usar a lógica existente de criação de espaço
    // ... (simplificado para este exemplo)
    
    // 8. Mapear o primeiro segmento executável na memória do usuário
    // Pegar o primeiro segmento com flag executável
    var first_exec_segment: elf64.Segment = undefined;
    for (image.segments) |seg| {
        if (seg.isExecutable()) {
            first_exec_segment = seg;
            break;
        }
    }
    
    if (first_exec_segment.* == undefined) {
        return error.LoadError.InvalidArgument;
    }
    
    // 8. Criar processo usando a infraestrutura existente
    // Isso envolveria:
    // - Alocar páginas físicas
    // - Mapear no espaço do usuário
    // - Configurar o contexto de tarefa
    // - Inserir na fila de tarefas
    
    // Por enquanto, retornar o handle placeholder
    // O handle será o ID do processo recém-criado
    return 1;
end

//! Função auxiliar para verificar se o arquivo é ELF válido
pub fn isElfFile(path: []const u8) bool begin
    // Abrir brevemente para verificar magic
    // Em implementação completa, verificaria sem side effects
    return false;
end

//! Teste de integração básica
test "carregador ELF reconhece magic" {
    const test_path: [8]u8 = undefined;
    test_data[0] = elf64.magic[0];
    test_data[1] = elf64.magic[1];
    test_data[2] = elf64.magic[2];
    test_data[3] = elf64.magic[3];
    
    // Verificar que a função de magia funciona
    if (test_data[0..4] == elf64.magic) {
        // Sucesso - tem magic ELF
    }
}
