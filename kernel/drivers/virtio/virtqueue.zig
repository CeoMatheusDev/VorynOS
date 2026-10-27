//************************************************************************//
//  virtqueue.zig                                                         //
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

//! Virtqueue dividida (split virtqueue) do VirtIO 1.2, secoes 2.7.4 a 2.7.14.
//!
//! Uma fila dividida e um bloco de memoria que o driver compartilha com o
//! dispositivo. Ele tem tres areas, sempre nesta ordem:
//!
//! ```text
//!   +-------------------+  descritores, 16 bytes cada, alinhados a 16
//!   | descriptor table  |
//!   +-------------------+  `avail`: flags, idx, ring[size], used_event
//!   | available ring    |  alinhado a 2 (driver escreve, dispositivo le)
//!   +-------------------+  `used`: flags, idx, ring[size], avail_event
//!   | used ring         |  alinhado a 4 (dispositivo escreve, driver le)
//!   +-------------------+
//! ```
//!
//! Regras que o modulo aplica literalmente:
//!
//!   * o descritor tem 16 bytes e a tabela comeca alinhada a 16 (§2.7.4);
//!   * o anel `available` comeca alinhado a 2; o `used`, alinhado a 4
//!     (§2.7.6, §2.7.8). O alinhamento de 4096 pertence a interface legada e
//!     nao e exigido com `VIRTIO_F_VERSION_1`, que este driver so aceita;
//!   * `used_event` e `avail_event` fazem parte do layout mesmo sem
//!     `VIRTIO_F_EVENT_IDX`; apenas nao sao usados (§2.7.7, §2.7.9);
//!   * o indice do anel e um contador de 16 bits que avanca sem voltar
//!     (§2.7.7, §2.7.8), e por isso o tamanho da fila e uma potencia de dois:
//!     a posicao e calculada com mascara e o contador de 65536 continua
//!     alinhado ao inicio do anel.
//!
//! ## Propriedade dos descritores
//!
//! O driver e o dono da tabela de descritores; o dispositivo so a le. Ainda
//! assim, um descritor publicado fica reservado ate a conclusao, e liberar
//! cedo demais entrega ao dispositivo um descritor que o driver ja
//! reescreveu. O gerenciamento aqui recusa esse caminho em vez de confiar no
//! chamador:
//!
//!   * a **free list** é encadeada no proprio campo `next` dos descritores
//!     livres (`free_head` + `free_count`): alocar e liberar sao O(1) e nao
//!     custam memoria extra;
//!   * dois bitsets por descritor (`allocated`, `inflight`) distinguem livre,
//!     alocado e publicado. Publicar duas vezes, liberar um descritor em voo,
//!     liberar duas vezes ou consumir um `id` que o dispositivo nao devia sair
//!     viram erro nomeado (§2.7.13.2: o dispositivo MUST NOT devolver um `id`
//!     que nao foi publicado);
//!   * `validateChain` percorre a cadeia antes de publica-la, com limite de
//!     passos, para recusar ciclos e `next` fora da tabela.
//!
//! Os bitsets sao dimensionados pela capacidade do tipo (`Queue(256)` custa 64
//! bytes de estado), como `dma.Window(pages)` faz com a janela de DMA.
//!
//! ## Memoria e ordenacao
//!
//! O modulo nao aloca: ele recebe `Memory`, que e o endereco fisico
//! programado no dispositivo e a visao virtual da mesma faixa — no kernel, o
//! resultado do alocador DMA existente (`memory/dma.zig`) mapeado pela janela
//! virtual. O endereco fisico e o que o dispositivo usa; o virtual e o que o
//! driver escreve.
//!
//! A ordem das escritas importa: o dispositivo pode ler o anel a qualquer
//! momento depois do `idx`. Por isso a publicacao grava as entradas, depois o
//! `avail.idx` com `release`, e so entao uma barreira completa antes de quem
//! chamar tocar no registro de notificacao (§2.7.13.1, §2.7.3.2). O consumo
//! le `used.idx` com `acquire` antes de olhar as entradas (§2.7.13.2).
//!
//! Nada aqui le ou escreve setor: o que a fila transporta pertence ao driver
//! do tipo de dispositivo.

const std = @import("std");

/// Maior tamanho de fila definido pela especificacao (§2.7.5).
pub const max_queue_size: u16 = 32768;

/// Tamanho de um descritor, em bytes (§2.7.4).
pub const descriptor_size: u32 = 16;

/// Alinhamento exigido para a tabela de descritores.
pub const descriptor_alignment: u32 = 16;

/// Alinhamento exigido para o anel `available`.
pub const available_alignment: u32 = 2;

/// Alinhamento exigido para o anel `used`.
pub const used_alignment: u32 = 4;

/// Valor de `next` que nao aponta para descritor algum na free list.
pub const no_descriptor: u16 = 0xFFFF;

/// Bits de `virtq_desc.flags` (§2.7.4).
pub const descriptor_flags = struct {
    /// `next` e valido: o descritor continua a cadeia.
    pub const next: u16 = 1 << 0;
    /// O buffer e escrito pelo dispositivo.
    pub const write: u16 = 1 << 1;
    /// `next` aponta para uma tabela indireta; exige VIRTIO_F_INDIRECT_DESC.
    pub const indirect: u16 = 1 << 2;
};

/// Bits de `virtq_avail.flags` e de `virtq_used.flags` (§2.7.7, §2.7.8).
pub const ring_flags = struct {
    /// Em `avail.flags`: o dispositivo nao deve interromper por esta fila.
    pub const no_interrupt: u16 = 1 << 0;
    /// Em `used.flags`: o driver nao deve notificar o dispositivo.
    pub const no_notify: u16 = 1 << 0;
};

pub const Error = error{
    /// Tamanho zero, nao potencia de dois ou acima de `max_queue_size`.
    InvalidSize,
    /// O endereco fisico ou virtual nao respeita o alinhamento do layout.
    MisalignedMemory,
    /// A memoria entregue nao tem `total_size` bytes.
    MemoryTooSmall,
    /// A soma de um endereco com um comprimento nao cabe em 64 bits.
    Overflow,
    /// O indice nao pertence a tabela desta fila.
    InvalidDescriptor,
    /// O descritor nao esta alocado: a free list ja o entregou a outro.
    DescriptorNotAllocated,
    /// O descritor ja foi publicado e o dispositivo ainda o pode usar.
    DescriptorAlreadyPublished,
    /// O descritor esta publicado: libera-lo entregaria ao dispositivo um
    /// descritor que o driver ja reescreveu.
    DescriptorInFlight,
    /// Nao ha descritores livres suficientes.
    QueueFull,
    /// A cadeia nao caberia no numero de descritores pedido.
    ChainTooLong,
    /// A cadeia tem um ciclo ou um `next` fora da tabela.
    InvalidChain,
    /// Um buffer de comprimento zero nao descreve nada.
    EmptyBuffer,
    /// O dispositivo avancou `used.idx` mais do que o anel comporta.
    UsedIndexOutOfRange,
    /// O `id` devolvido pelo dispositivo nao e um descritor desta fila.
    UsedIdInvalid,
    /// O `id` devolvido nao estava em voo.
    UsedIdNotInflight,
};

/// Descritor da tabela (§2.7.4). O layout e o da especificacao, byte a byte.
pub const Descriptor = extern struct {
    /// Endereco fisico do buffer.
    address: u64,
    /// Comprimento do buffer em bytes.
    length: u32,
    /// `descriptor_flags`.
    flags: u16,
    /// Proximo descritor da cadeia, ou o elo da free list.
    next: u16,
};

comptime {
    // Um descritor com tamanho ou deslocamento diferente destes deslocaria
    // todos os outros: o dispositivo usa o layout da especificacao, e nao o
    // alinhamento que o compilador escolher.
    if (@sizeOf(Descriptor) != descriptor_size) {
        @compileError("virtq_desc must be 16 bytes");
    }
    if (@offsetOf(Descriptor, "address") != 0 or
        @offsetOf(Descriptor, "length") != 8 or
        @offsetOf(Descriptor, "flags") != 12 or
        @offsetOf(Descriptor, "next") != 14)
    {
        @compileError("virtq_desc field offsets must follow the specification");
    }
}

/// Enderecos das tres areas, como o transporte os programa no dispositivo.
pub const Addresses = struct {
    desc: u64,
    driver: u64,
    device: u64,
};

/// Offsets e tamanhos de uma fila contigua.
///
/// O calculo e feito uma vez (na inicializacao) e validado de novo pelo
/// construtor da fila: um layout com offset errado produz um dispositivo que
/// le descritores de outro lugar, e o erro nao aparece como falha de
/// compilacao.
pub const Layout = struct {
    size: u16,
    descriptor_offset: u32,
    available_offset: u32,
    used_offset: u32,
    descriptor_bytes: u32,
    available_bytes: u32,
    used_bytes: u32,
    total_size: u32,

    /// Calcula o layout de uma fila de `size` descritores.
    ///
    /// `size` precisa ser potencia de dois e no maximo 32768. A exigencia vem
    /// do proprio protocolo: o indice do anel e um contador de 16 bits, e a
    /// posicao e `indice & (size - 1)`.
    pub fn compute(size: u16) Error!Layout {
        if (size == 0 or size > max_queue_size) return error.InvalidSize;
        if (!std.math.isPowerOfTwo(size)) return error.InvalidSize;

        const count: u32 = size;
        const descriptor_bytes = std.math.mul(u32, count, descriptor_size) catch
            return error.Overflow;
        // `virtq_avail`: flags (2) + idx (2) + ring (2 * size) + used_event (2).
        const available_bytes = std.math.add(
            u32,
            std.math.mul(u32, count, 2) catch return error.Overflow,
            6,
        ) catch return error.Overflow;
        const used_unaligned = std.math.add(u32, descriptor_bytes, available_bytes) catch
            return error.Overflow;
        const used_offset = try alignForward(used_unaligned, used_alignment);
        // `virtq_used`: flags (2) + idx (2) + ring (8 * size) + avail_event (2).
        const used_bytes = std.math.add(
            u32,
            std.math.mul(u32, count, 8) catch return error.Overflow,
            6,
        ) catch return error.Overflow;
        const total_unaligned = std.math.add(u32, used_offset, used_bytes) catch
            return error.Overflow;
        const total_size = try alignForward(total_unaligned, descriptor_alignment);

        return .{
            .size = size,
            .descriptor_offset = 0,
            .available_offset = descriptor_bytes,
            .used_offset = used_offset,
            .descriptor_bytes = descriptor_bytes,
            .available_bytes = available_bytes,
            .used_bytes = used_bytes,
            .total_size = total_size,
        };
    }

    /// Tamanho da fila que cabe no dispositivo e no limite da especificacao.
    ///
    /// Devolve a maior potencia de dois menor ou igual a `max`. Um dispositivo
    /// que informe um maximo que nao e potencia de dois continua conduzivel:
    /// a fila usa o maior valor valido abaixo dele, e o driver escreve esse
    /// valor em `queue_size` (§2.7.5 permite ao driver escolher ate o maximo).
    pub fn negotiateSize(max: u16) Error!u16 {
        if (max == 0) return error.InvalidSize;
        const limited = @min(max, max_queue_size);
        var size: u16 = 1;
        while (size <= limited / 2) : (size *= 2) {}
        return size;
    }

    /// Enderecos fisicos das tres areas a partir da base da fila.
    ///
    /// A base zero e recusada: nao existe faixa de DMA ali, e programar o
    /// endereco nulo no dispositivo faria o driver apontar para a memoria do
    /// vetor de interrupcoes de outra maquina, ou para nada.
    pub fn addresses(self: Layout, base: u64) Error!Addresses {
        if (base == 0) return error.MisalignedMemory;
        if (base % descriptor_alignment != 0) return error.MisalignedMemory;
        return .{
            .desc = base + self.descriptor_offset,
            .driver = std.math.add(u64, base, self.available_offset) catch
                return error.Overflow,
            .device = std.math.add(u64, base, self.used_offset) catch
                return error.Overflow,
        };
    }
};

fn alignForward(value: u32, alignment: u32) Error!u32 {
    const mask = alignment - 1;
    const sum = std.math.add(u32, value, mask) catch return error.Overflow;
    return sum & ~mask;
}

/// Memoria da fila: o que o dispositivo alcanca e o que o driver escreve.
///
/// `physical` e o inicio da faixa que vai para `queue_desc`, `queue_driver` e
/// `queue_device`; `bytes` e a mesma faixa ja mapeada no espaco do kernel. O
/// modulo nao aloca essa memoria: o kernel a obtem do alocador DMA existente,
/// que garante paginas fisicas contiguas, e a mapeia na janela virtual.
pub const Memory = struct {
    physical: u64,
    bytes: []u8,
};

/// Conclusao consumida do anel `used`.
pub const Used = struct {
    /// Cabeca da cadeia publicada.
    head: u16,
    /// Bytes que o dispositivo escreveu nos buffers com `write`.
    length: u32,
};

/// Uma fila dividida com capacidade fixa de descritores.
///
/// `capacity` e o maior `queue_size` que a fila aceita, e define o tamanho do
/// estado auxiliar. O tamanho efetivo e escolhido a partir do que o
/// dispositivo informa (`Layout.negotiateSize`) e nunca passa da capacidade do
/// tipo.
pub fn Queue(comptime capacity: u16) type {
    if (capacity == 0 or capacity > max_queue_size) {
        @compileError("virtqueue capacity must be between 1 and 32768");
    }
    if (!std.math.isPowerOfTwo(capacity)) {
        @compileError("virtqueue capacity must be a power of two");
    }

    return struct {
        const Self = @This();

        /// Maior fila que este tipo aceita.
        pub const max_size = capacity;

        memory: Memory,
        layout: Layout,
        /// Quantidade efetiva de descritores: `layout.size`.
        size: u16,
        /// Cabeca da free list, ou `no_descriptor` quando nao ha descritor livre.
        free_head: u16 = no_descriptor,
        free_count: u16 = 0,
        /// Copia do `avail.idx` que o driver mantem em memoria.
        avail_index: u16 = 0,
        /// Ultimo `used.idx` consumido.
        last_used_index: u16 = 0,
        /// Cadeias publicadas e ainda nao consumidas.
        published: u16 = 0,
        /// True depois de um publish sem interrupcao (§2.7.7).
        no_interrupt: bool = false,
        /// Descritores entregues por `allocate` e ainda nao liberados.
        allocated: std.StaticBitSet(@as(usize, capacity)) = .empty,
        /// Descritores publicados e ainda nao consumidos do anel `used`.
        inflight: std.StaticBitSet(@as(usize, capacity)) = .empty,

        /// Prepara a fila sobre uma memoria ja mapeada.
        ///
        /// A funcao:
        ///
        ///   1. valida o tamanho e calcula o layout;
        ///   2. valida a memoria: endereco fisico alinhado a 16, sem
        ///      transbordo, e virtual com `total_size` bytes;
        ///   3. zera a faixa inteira, para que `avail.idx` e `used.idx`
        ///      comecem em zero no driver e no dispositivo. O reset da fila na
        ///      escrita de `queue_enable` nao garante que a memoria do driver
        ///      tenha sido zerada por outro caminho;
        ///   4. encadeia todos os descritores na free list.
        pub fn init(memory: Memory, size: u16) Error!Self {
            if (size > capacity) return error.InvalidSize;
            const layout = try Layout.compute(size);

            if (memory.physical == 0) return error.MisalignedMemory;
            if (memory.physical % descriptor_alignment != 0) return error.MisalignedMemory;
            _ = std.math.add(u64, memory.physical, layout.total_size) catch
                return error.Overflow;
            if (memory.bytes.len < layout.total_size) return error.MemoryTooSmall;
            if (@intFromPtr(memory.bytes.ptr) % descriptor_alignment != 0) {
                return error.MisalignedMemory;
            }

            var queue: Self = .{
                .memory = .{
                    .physical = memory.physical,
                    .bytes = memory.bytes[0..layout.total_size],
                },
                .layout = layout,
                .size = layout.size,
            };

            @memset(queue.memory.bytes, 0);
            queue.buildFreeList();
            return queue;
        }

        /// Encadeia todos os descritores livres e zera os contadores.
        fn buildFreeList(self: *Self) void {
            var index: u16 = 0;
            while (index < self.size) : (index += 1) {
                const last = index + 1 == self.size;
                self.descriptorAt(index).* = .{
                    .address = 0,
                    .length = 0,
                    .flags = 0,
                    .next = if (last) no_descriptor else index + 1,
                };
            }
            self.free_head = 0;
            self.free_count = self.size;
            self.avail_index = 0;
            self.last_used_index = 0;
            self.published = 0;
            self.no_interrupt = false;
            self.allocated = .empty;
            self.inflight = .empty;
        }

        /// Enderecos fisicos das tres areas.
        pub fn addresses(self: *const Self) Error!Addresses {
            return self.layout.addresses(self.memory.physical);
        }

        /// Descritores livres no momento.
        pub fn freeCount(self: *const Self) u16 {
            return self.free_count;
        }

        /// Cadeias publicadas e ainda sem conclusao.
        pub fn inFlightCount(self: *const Self) u16 {
            return self.published;
        }

        /// `avail.idx` do lado do driver.
        pub fn availableIndex(self: *const Self) u16 {
            return self.avail_index;
        }

        /// `used.idx` lido do anel, sem consumir nada.
        pub fn usedIndex(self: Self) u16 {
            return @atomicLoad(u16, self.usedIndexPtr(), .acquire);
        }

        /// Quantas conclusoes esperam consumo.
        pub fn pendingUsed(self: Self) u16 {
            return self.usedIndex() -% self.last_used_index;
        }

        // ------------------------------------------------------------------
        // Descritores.
        // ------------------------------------------------------------------

        /// Retira um descritor da free list. O(1).
        pub fn allocate(self: *Self) Error!u16 {
            const index = self.free_head;
            if (index == no_descriptor) return error.QueueFull;
            if (index >= self.size) return error.InvalidChain;

            const entry = self.descriptorAt(index);
            // Free list e estado auxiliar precisam concordar: um descritor na
            // lista nao pode estar marcado como alocado.
            if (self.allocated.isSet(index)) return error.InvalidChain;

            const next = entry.next;
            if (next != no_descriptor and next >= self.size) return error.InvalidChain;

            self.free_head = next;
            self.free_count -= 1;

            entry.* = .{ .address = 0, .length = 0, .flags = 0, .next = no_descriptor };
            self.allocated.set(index);
            return index;
        }

        /// Retira `count` descritores e os encadeia, devolvendo a cabeca.
        ///
        /// Em caso de falta de descritores, o que ja foi retirado volta para a
        /// free list: uma cadeia parcial nao fica alocada.
        pub fn allocateChain(self: *Self, count: u16) Error!u16 {
            if (count == 0) return error.InvalidSize;
            if (count > self.size) return error.QueueFull;

            const head = try self.allocate();
            errdefer self.freeChainUnchecked(head);

            var current = head;
            var remaining = count - 1;
            while (remaining > 0) : (remaining -= 1) {
                const next = try self.allocate();
                self.descriptorAt(current).next = next;
                self.descriptorAt(current).flags |= descriptor_flags.next;
                self.descriptorAt(current).flags &= ~descriptor_flags.indirect;
                current = next;
            }
            return head;
        }

        /// True quando o descritor esta alocado e ja pode receber um buffer.
        pub fn isAllocated(self: *const Self, index: u16) bool {
            if (index >= self.size) return false;
            return self.allocated.isSet(index);
        }

        /// True quando o descritor foi publicado e aguarda conclusao.
        pub fn isInFlight(self: *const Self, index: u16) bool {
            if (index >= self.size) return false;
            return self.inflight.isSet(index);
        }

        /// Le o descritor. A copia e feita campo a campo; o chamador nao
        /// recebe um ponteiro para memoria compartilhada com o dispositivo.
        pub fn descriptor(self: *const Self, index: u16) Error!Descriptor {
            if (index >= self.size) return error.InvalidDescriptor;
            const entry = self.descriptorAt(index);
            return .{
                .address = entry.address,
                .length = entry.length,
                .flags = entry.flags,
                .next = entry.next,
            };
        }

        /// Descreve o buffer de um descritor alocado.
        ///
        /// `address` e o endereco fisico: e ele que o dispositivo le. Um
        /// descritor em voo nao pode ser reescrito, porque o dispositivo pode
        /// estar lendo justamente aquele buffer.
        pub fn setBuffer(self: *Self, index: u16, address: u64, length: u32) Error!void {
            try self.requireWritable(index);
            if (length == 0) return error.EmptyBuffer;
            if (address == 0) return error.EmptyBuffer;
            _ = std.math.add(u64, address, length) catch return error.Overflow;

            const entry = self.descriptorAt(index);
            entry.address = address;
            entry.length = length;
        }

        /// Marca o buffer como escrito pelo dispositivo (flag `write`).
        pub fn setWritable(self: *Self, index: u16, writable: bool) Error!void {
            try self.requireWritable(index);
            const entry = self.descriptorAt(index);
            if (writable) {
                entry.flags |= descriptor_flags.write;
            } else {
                entry.flags &= ~descriptor_flags.write;
            }
        }

        /// Liga a flag `next` para uma tabela indireta.
        ///
        /// Recusado: `VIRTIO_F_INDIRECT_DESC` nao e negociado por este
        /// subsistema, e um descritor indireto sem a feature seria lido pelo
        /// dispositivo como um `next` comum.
        pub fn setIndirect(_: *Self, _: u16) Error!void {
            return error.InvalidDescriptor;
        }

        /// Devolve a cadeia a free list. O(1) por descritor.
        ///
        /// A liberacao nao depende de a cadeia estar intacta: a caminhada para
        /// quando encontra um elo nao alocado, um `next` fora da tabela ou o
        /// limite de passos. Assim uma cadeia corrompida nao duplica elos na
        /// free list — o descritor ja liberado deixa de estar alocado, e o
        /// percurso por um ciclo termina nele.
        pub fn release(self: *Self, head: u16) Error!void {
            if (head >= self.size) return error.InvalidDescriptor;
            if (!self.allocated.isSet(head)) return error.DescriptorNotAllocated;
            if (self.inflight.isSet(head)) return error.DescriptorInFlight;

            self.freeChainUnchecked(head);
        }

        /// Devolve a cadeia sem validar. So para caminhos internos, depois das
        /// verificacoes de `release` ou de uma alocacao que acabou de falhar.
        fn freeChainUnchecked(self: *Self, head: u16) void {
            var index = head;
            var guard: u16 = 0;
            while (guard < self.size) : (guard += 1) {
                const entry = self.descriptorAt(index);
                const flags = entry.flags;
                const next = entry.next;
                if (!self.allocated.isSet(index)) return;
                self.allocated.unset(index);
                self.free_count += 1;
                entry.* = .{
                    .address = 0,
                    .length = 0,
                    .flags = 0,
                    .next = self.free_head,
                };
                self.free_head = index;
                if (flags & descriptor_flags.next == 0) return;
                if (next >= self.size) return;
                index = next;
            }
        }

        fn requireWritable(self: *Self, index: u16) Error!void {
            if (index >= self.size) return error.InvalidDescriptor;
            if (!self.allocated.isSet(index)) return error.DescriptorNotAllocated;
            if (self.inflight.isSet(index)) return error.DescriptorAlreadyPublished;
        }

        /// Percorre a cadeia e recusa ciclo, `next` fora da tabela e
        /// descritor nao alocado. O limite de passos e o tamanho da fila.
        fn validateChain(self: *Self, head: u16) Error!void {
            var index = head;
            var steps: u16 = 0;
            while (steps < self.size) : (steps += 1) {
                if (index >= self.size) return error.InvalidChain;
                if (!self.allocated.isSet(index)) return error.InvalidChain;
                if (self.inflight.isSet(index)) return error.DescriptorInFlight;

                const entry = self.descriptorAt(index);
                if (entry.flags & descriptor_flags.indirect != 0) return error.InvalidChain;
                if (entry.flags & descriptor_flags.next == 0) return;
                index = entry.next;
            }
            return error.InvalidChain;
        }

        // ------------------------------------------------------------------
        // Anel `available`.
        // ------------------------------------------------------------------

        /// Publica uma cadeia no anel `available`.
        ///
        /// A ordem nao e um detalhe: as entradas do anel e o `used_event` sao
        /// gravados antes do `avail.idx`, e o indice sai com semantica de
        /// `release`. Uma barreira completa depois dele garante que o indice
        /// esteja visivel antes de o chamador escrever o registro de
        /// notificacao (§2.7.13.1, §2.7.3.2).
        pub fn publish(self: *Self, head: u16) Error!void {
            if (head >= self.size) return error.InvalidDescriptor;
            if (!self.allocated.isSet(head)) return error.DescriptorNotAllocated;
            if (self.inflight.isSet(head)) return error.DescriptorAlreadyPublished;
            try self.validateChain(head);
            if (self.published == self.size) return error.QueueFull;

            const index = self.avail_index;
            self.availableEntry(index & (self.size - 1)).* = head;
            @atomicStore(u16, self.availableIndexPtr(), index +% 1, .release);
            memoryBarrier();

            self.avail_index = index +% 1;
            self.inflight.set(head);
            self.published += 1;
        }

        /// Pede ao dispositivo que nao interrompa por esta fila (§2.7.7).
        pub fn setNoInterrupt(self: *Self, enabled: bool) void {
            const flags = self.availableFlags();
            if (enabled) {
                flags.* |= ring_flags.no_interrupt;
            } else {
                flags.* &= ~ring_flags.no_interrupt;
            }
            self.no_interrupt = enabled;
        }

        /// True quando o dispositivo pediu para nao ser notificado (§2.7.8).
        pub fn notificationsSuppressed(self: Self) bool {
            return self.usedFlags().* & ring_flags.no_notify != 0;
        }

        // ------------------------------------------------------------------
        // Anel `used`.
        // ------------------------------------------------------------------

        /// Consome uma conclusao do anel `used`, se houver.
        ///
        /// `used.idx` e lido com `acquire` antes das entradas. O `id` devolvido
        /// precisa ser um descritor publicado; um dispositivo que devolva
        /// outro valor viola §2.7.13.2, e a fila para em vez de liberar um
        /// descritor que nunca foi publicado.
        pub fn pollUsed(self: *Self) Error!?Used {
            const used_index = @atomicLoad(u16, self.usedIndexPtr(), .acquire);
            const pending = used_index -% self.last_used_index;
            if (pending == 0) return null;
            if (pending > self.size) return error.UsedIndexOutOfRange;

            const slot = self.last_used_index & (self.size - 1);
            const id = self.usedIdPtr(slot).*;
            const length = self.usedLengthPtr(slot).*;

            if (id >= self.size) return error.UsedIdInvalid;
            const head: u16 = @intCast(id);
            if (!self.inflight.isSet(head)) return error.UsedIdNotInflight;

            self.inflight.unset(head);
            self.published -= 1;
            self.last_used_index +%= 1;
            return .{ .head = head, .length = length };
        }

        // ------------------------------------------------------------------
        // Acesso as areas.
        // ------------------------------------------------------------------

        fn descriptorAt(self: *const Self, index: u16) *volatile Descriptor {
            const base: [*]u8 = self.memory.bytes.ptr + self.layout.descriptor_offset;
            const entry: [*]Descriptor = @ptrCast(@alignCast(base));
            return &entry[index];
        }

        fn availableFlags(self: *const Self) *volatile u16 {
            const at = self.memory.bytes.ptr + self.layout.available_offset;
            return @ptrCast(@alignCast(at));
        }

        fn availableIndexPtr(self: *const Self) *align(available_alignment) u16 {
            const at = self.memory.bytes.ptr + self.layout.available_offset + 2;
            return @ptrCast(@alignCast(at));
        }

        fn availableEntry(self: *const Self, slot: u16) *volatile u16 {
            const at = self.memory.bytes.ptr + self.layout.available_offset + 4 +
                @as(usize, slot) * 2;
            return @ptrCast(@alignCast(at));
        }

        fn usedFlags(self: *const Self) *volatile u16 {
            const at = self.memory.bytes.ptr + self.layout.used_offset;
            return @ptrCast(@alignCast(at));
        }

        fn usedIndexPtr(self: *const Self) *align(available_alignment) u16 {
            const at = self.memory.bytes.ptr + self.layout.used_offset + 2;
            return @ptrCast(@alignCast(at));
        }

        fn usedIdPtr(self: *const Self, slot: u16) *volatile u32 {
            const at = self.memory.bytes.ptr + self.layout.used_offset + 4 +
                @as(usize, slot) * 8;
            return @ptrCast(@alignCast(at));
        }

        fn usedLengthPtr(self: *const Self, slot: u16) *volatile u32 {
            const at = self.memory.bytes.ptr + self.layout.used_offset + 8 +
                @as(usize, slot) * 8;
            return @ptrCast(@alignCast(at));
        }
    };
}

/// Barreira completa de ordenacao.
///
/// `mfence` ordena *store* seguido de *load*, que e a sequencia do driver com
/// um dispositivo. O clobber `memory` impede o compilador de mover acessos
/// para o outro lado da barreira. A mesma instrucao e usada por `mmio.zig`;
/// aqui ela fecha a publicacao antes de quem chamar tocar no registro de
/// notificacao.
fn memoryBarrier() void {
    asm volatile ("mfence" ::: .{ .memory = true });
}

const testing = std.testing;

// ----------------------------------------------------------------------
// Apoio dos testes.
//
// A fila e exercitada sobre memoria comum alinhada, com um endereco fisico
// verossimil, e um "dispositivo" que so faz o que a especificacao permite:
// ler as entradas publicadas e escrever `used.idx` e as conclusoes.
// ----------------------------------------------------------------------

const TestQueue = Queue(64);

/// Memoria de apoio compartilhada pelos testes.
///
/// O buffer e maior do que a maior fila usada aqui, e a mesma faixa fisica e
/// reaproveitada: cada `init` zera a parte que lhe pertence, e os testes
/// rodam em sequencia no mesmo binario.
const test_backing_size: usize = 2048;
var test_backing: [test_backing_size]u8 align(4096) = @splat(0);
const test_physical: u64 = 0x2000_0000;

fn testMemory(size: u16) Memory {
    const layout = Layout.compute(size) catch unreachable;
    std.debug.assert(layout.total_size <= test_backing_size);
    return .{ .physical = test_physical, .bytes = test_backing[0..] };
}

/// Cabecalho do anel `used` de uma fila concreta.
fn usedHeader(comptime Q: type, queue: *const Q) usize {
    return queue.layout.used_offset;
}

/// Grava uma conclusao no anel `used`, como o dispositivo faria.
///
/// A funcao nao chama nenhuma rotina da fila: ela escreve os bytes crus da
/// especificacao e avanca `used.idx`, para que o lado do driver seja testado
/// contra memoria e nao contra a propria implementacao.
fn complete(comptime Q: type, queue: *Q, head: u16, length: u32) void {
    const used = usedHeader(Q, queue);
    const bytes = queue.memory.bytes;
    const index = std.mem.readInt(u16, bytes[used + 2 ..][0..2], .little);
    const slot = index & (queue.size - 1);

    std.mem.writeInt(u32, bytes[used + 4 + @as(usize, slot) * 8 ..][0..4], head, .little);
    std.mem.writeInt(u32, bytes[used + 8 + @as(usize, slot) * 8 ..][0..4], length, .little);
    std.mem.writeInt(u16, bytes[used + 2 ..][0..2], index +% 1, .little);
    memoryBarrier();
}

test "the split layout follows the specification offsets and alignment" {
    // Fila de 256 descritores: 4096 bytes de tabela, 518 de anel available e
    // 2054 de anel used. O used comeca no primeiro multiplo de 4 depois de
    // 4096 + 518 = 4614, ou seja, 4616.
    const layout = try Layout.compute(256);
    try testing.expectEqual(@as(u16, 256), layout.size);
    try testing.expectEqual(@as(u32, 0), layout.descriptor_offset);
    try testing.expectEqual(@as(u32, 4096), layout.descriptor_bytes);
    try testing.expectEqual(@as(u32, 4096), layout.available_offset);
    try testing.expectEqual(@as(u32, 518), layout.available_bytes);
    try testing.expectEqual(@as(u32, 4616), layout.used_offset);
    try testing.expectEqual(@as(u32, 2054), layout.used_bytes);
    // O total e arredondado para o alinhamento dos descritores, e nao para
    // 4096: quem arredonda para pagina e o alocador de DMA.
    try testing.expectEqual(@as(u32, 6672), layout.total_size);

    // As areas nao se sobrepoem e o inicio de cada uma respeita o alinhamento.
    try testing.expect(layout.available_offset >= layout.descriptor_bytes);
    try testing.expect(layout.used_offset >= layout.available_offset + layout.available_bytes);
    try testing.expect(layout.total_size >= layout.used_offset + layout.used_bytes);
    try testing.expect(layout.descriptor_offset % descriptor_alignment == 0);
    try testing.expect(layout.available_offset % available_alignment == 0);
    try testing.expect(layout.used_offset % used_alignment == 0);

    // Fila minima: um descritor, um lugar em cada anel. O anel used comeca em
    // 16 + 8 = 24, que ja e multiplo de 4.
    const smallest = try Layout.compute(1);
    try testing.expectEqual(@as(u32, 16), smallest.descriptor_bytes);
    try testing.expectEqual(@as(u32, 16), smallest.available_offset);
    try testing.expectEqual(@as(u32, 8), smallest.available_bytes);
    try testing.expectEqual(@as(u32, 24), smallest.used_offset);
    try testing.expectEqual(@as(u32, 14), smallest.used_bytes);
    try testing.expectEqual(@as(u32, 48), smallest.total_size);

    // A maior fila: 32768 descritores.
    const largest = try Layout.compute(max_queue_size);
    try testing.expectEqual(@as(u32, 32768 * 16), largest.descriptor_bytes);
    try testing.expectEqual(@as(u32, 32768 * 8 + 6), largest.used_bytes);

    // Todo tamanho valido produz um layout consistente.
    var size: u16 = 1;
    while (size != 0 and size <= max_queue_size) : (size *= 2) {
        const current = try Layout.compute(size);
        try testing.expectEqual(@as(u32, @as(u32, size) * 16), current.descriptor_bytes);
        try testing.expect(current.used_offset % used_alignment == 0);
        try testing.expect(current.total_size % descriptor_alignment == 0);
        try testing.expect(
            current.total_size >= current.used_offset + current.used_bytes,
        );
        if (size == max_queue_size) break;
    }
}

test "the split layout rejects sizes the protocol cannot carry" {
    try testing.expectError(error.InvalidSize, Layout.compute(0));
    // Nao potencia de dois: o indice de 16 bits deixaria de fechar no inicio
    // do anel quando voltasse a zero.
    try testing.expectError(error.InvalidSize, Layout.compute(3));
    try testing.expectError(error.InvalidSize, Layout.compute(100));
    try testing.expectError(error.InvalidSize, Layout.compute(max_queue_size + 1));
}

test "the queue size negotiated with the device is a power of two within limits" {
    try testing.expectError(error.InvalidSize, Layout.negotiateSize(0));
    try testing.expectEqual(@as(u16, 1), try Layout.negotiateSize(1));
    try testing.expectEqual(@as(u16, 2), try Layout.negotiateSize(2));
    try testing.expectEqual(@as(u16, 2), try Layout.negotiateSize(3));
    try testing.expectEqual(@as(u16, 128), try Layout.negotiateSize(255));
    try testing.expectEqual(@as(u16, 256), try Layout.negotiateSize(256));
    try testing.expectEqual(@as(u16, 32768), try Layout.negotiateSize(32768));
    try testing.expectEqual(@as(u16, 32768), try Layout.negotiateSize(65535));
}

test "the physical addresses of the three areas are the layout offsets" {
    // Fila de 8: 128 bytes de tabela, 22 de anel available, used em 152.
    const layout = try Layout.compute(8);
    try testing.expectEqual(@as(u32, 152), layout.used_offset);

    const addresses = try layout.addresses(0x4000_0000);
    try testing.expectEqual(@as(u64, 0x4000_0000), addresses.desc);
    try testing.expectEqual(@as(u64, 0x4000_0080), addresses.driver);
    try testing.expectEqual(@as(u64, 0x4000_0098), addresses.device);

    // Base desalinhada: a tabela de descritores precisa comecar em 16 bytes.
    try testing.expectError(error.MisalignedMemory, layout.addresses(0x4000_0008));
    try testing.expectError(error.MisalignedMemory, layout.addresses(0));
}

test "the queue initialises the free list and the rings in memory" {
    const layout = try Layout.compute(8);
    const memory = testMemory(8);
    @memset(memory.bytes, 0xAA);
    var queue = try TestQueue.init(memory, 8);

    try testing.expectEqual(@as(u16, 8), queue.size);
    try testing.expectEqual(@as(u16, 8), queue.freeCount());
    try testing.expectEqual(@as(u16, 0), queue.availableIndex());
    try testing.expectEqual(@as(u16, 0), queue.usedIndex());
    try testing.expectEqual(@as(u16, 0), queue.pendingUsed());
    try testing.expectEqual(@as(u16, 0), queue.inFlightCount());

    // Os dois aneis foram zerados: nenhum resto de uso anterior chega ao
    // dispositivo. A tabela de descritores nao fica zerada de proposito —
    // nela vive o encadeamento da free list, no campo `next`.
    for (queue.memory.bytes[layout.available_offset..]) |byte| {
        try testing.expectEqual(@as(u8, 0), byte);
    }

    // A free list esta encadeada na ordem dos indices.
    var index: u16 = 0;
    while (index < 8) : (index += 1) {
        const descriptor = try queue.descriptor(index);
        try testing.expect(!queue.isAllocated(index));
        try testing.expect(!queue.isInFlight(index));
        try testing.expectEqual(@as(u64, 0), descriptor.address);
        if (index + 1 < 8) {
            try testing.expectEqual(@as(u16, @as(u16, index) + 1), descriptor.next);
        }
    }
    try testing.expectEqual(no_descriptor, (try queue.descriptor(7)).next);

    try testing.expectEqual(layout.total_size, queue.memory.bytes.len);

    // Os enderecos programaveis saem da mesma base.
    const addresses = try queue.addresses();
    try testing.expectEqual(@as(u64, test_physical), addresses.desc);
    try testing.expectEqual(@as(u64, test_physical + 128), addresses.driver);
    try testing.expectEqual(@as(u64, test_physical + 152), addresses.device);
}

test "the queue refuses memory that cannot hold the layout" {
    // 223 bytes: um a menos que os 224 do layout de 8 descritores.
    var too_small: [223]u8 align(4096) = @splat(0);
    try testing.expectError(
        error.MemoryTooSmall,
        TestQueue.init(.{ .physical = test_physical, .bytes = too_small[0..] }, 8),
    );

    var aligned: [512]u8 align(4096) = @splat(0);
    // Endereco fisico desalinhado ou nulo.
    try testing.expectError(
        error.MisalignedMemory,
        TestQueue.init(.{ .physical = test_physical + 4, .bytes = aligned[0..] }, 8),
    );
    try testing.expectError(
        error.MisalignedMemory,
        TestQueue.init(.{ .physical = 0, .bytes = aligned[0..] }, 8),
    );
    // Memoria virtual desalinhada.
    try testing.expectError(
        error.MisalignedMemory,
        TestQueue.init(.{ .physical = test_physical, .bytes = aligned[8..] }, 8),
    );
    // Fila maior do que a capacidade do tipo.
    try testing.expectError(
        error.InvalidSize,
        TestQueue.init(.{ .physical = test_physical, .bytes = aligned[0..] }, 256),
    );
    // Tamanho que nao e potencia de dois.
    try testing.expectError(
        error.InvalidSize,
        TestQueue.init(.{ .physical = test_physical, .bytes = aligned[0..] }, 6),
    );
    // E a mesma memoria passa quando esta de acordo.
    var queue = try TestQueue.init(
        .{ .physical = test_physical, .bytes = aligned[0..] },
        8,
    );
    try testing.expectEqual(@as(u16, 8), queue.freeCount());
}

test "descriptor allocation is O(1) and releases in constant time" {
    var queue = try TestQueue.init(testMemory(4), 4);

    // A alocacao entrega a cabeca da free list e anda um passo.
    try testing.expectEqual(@as(u16, 0), try queue.allocate());
    try testing.expectEqual(@as(u16, 3), queue.freeCount());
    try testing.expect(queue.isAllocated(0));
    try testing.expectEqual(@as(u16, 1), try queue.allocate());
    try testing.expectEqual(@as(u16, 2), try queue.allocate());
    try testing.expectEqual(@as(u16, 3), try queue.allocate());
    try testing.expectEqual(@as(u16, 0), queue.freeCount());

    // Fila esgotada.
    try testing.expectError(error.QueueFull, queue.allocate());

    // A liberacao devolve o descritor para a cabeca: a proxima alocacao o
    // reusa sem varrer a tabela.
    try queue.release(2);
    try testing.expectEqual(@as(u16, 1), queue.freeCount());
    try testing.expect(!queue.isAllocated(2));
    try testing.expectEqual(@as(u16, 2), try queue.allocate());
    try testing.expect(queue.isAllocated(2));
    try testing.expectEqual(@as(u16, 0), queue.freeCount());

    var released: u16 = 0;
    while (released < 4) : (released += 1) try queue.release(released);
    try testing.expectEqual(@as(u16, 4), queue.freeCount());

    // Dois ciclos completos provam que a lista nao perde nem duplica elos.
    var round: usize = 0;
    while (round < 2) : (round += 1) {
        var indices: [4]u16 = undefined;
        for (&indices) |*slot| slot.* = try queue.allocate();
        try testing.expectError(error.QueueFull, queue.allocate());
        for (indices) |index| try queue.release(index);
        try testing.expectEqual(@as(u16, 4), queue.freeCount());
        var index: u16 = 0;
        while (index < 4) : (index += 1) try testing.expect(!queue.isAllocated(index));
    }
}

test "release refuses descriptors that are not allocated" {
    var queue = try TestQueue.init(testMemory(8), 8);
    try testing.expectError(error.InvalidDescriptor, queue.release(8));
    try testing.expectError(error.InvalidDescriptor, queue.release(0xFFFF));

    _ = try queue.allocate();
    // Liberar duas vezes devolveria o mesmo elo duas vezes a free list.
    try queue.release(0);
    try testing.expectError(error.DescriptorNotAllocated, queue.release(0));
    try testing.expectEqual(@as(u16, 8), queue.freeCount());
}

test "a chain links descriptors, is published once and is consumed once" {
    var queue = try TestQueue.init(testMemory(16), 16);

    const head = try queue.allocateChain(3);
    try testing.expectEqual(@as(u16, 0), head);
    try testing.expectEqual(@as(u16, 13), queue.freeCount());

    // A cadeia segue a ordem de alocacao, com NEXT nos elos intermediarios.
    const first = try queue.descriptor(head);
    try testing.expectEqual(descriptor_flags.next, first.flags);
    try testing.expectEqual(@as(u16, 1), first.next);
    const second = try queue.descriptor(first.next);
    try testing.expectEqual(descriptor_flags.next, second.flags);
    try testing.expectEqual(@as(u16, 2), second.next);
    const third = try queue.descriptor(second.next);
    try testing.expectEqual(@as(u16, 0), third.flags);
    try testing.expectEqual(no_descriptor, third.next);

    // Os buffers sao fisicos e checados.
    try queue.setBuffer(head, 0x3000_0000, 512);
    try queue.setBuffer(first.next, 0x3000_0200, 64);
    try queue.setBuffer(second.next, 0x3000_0240, 1);
    try queue.setWritable(second.next, true);
    try testing.expectEqual(@as(u64, 0x3000_0000), (try queue.descriptor(head)).address);
    try testing.expectEqual(@as(u32, 512), (try queue.descriptor(head)).length);
    try testing.expectEqual(
        descriptor_flags.write,
        (try queue.descriptor(second.next)).flags,
    );

    try queue.publish(head);
    try testing.expectEqual(@as(u16, 1), queue.availableIndex());
    try testing.expectEqual(@as(u16, 1), queue.inFlightCount());
    try testing.expect(queue.isInFlight(head));

    // Publicar de novo a mesma cadeia, ou mexer nela em voo, e recusado.
    try testing.expectError(error.DescriptorAlreadyPublished, queue.publish(head));
    try testing.expectError(
        error.DescriptorAlreadyPublished,
        queue.setBuffer(head, 0x3000_0000, 512),
    );
    try testing.expectError(error.DescriptorInFlight, queue.release(head));

    // Conclusao do dispositivo.
    complete(TestQueue, &queue, head, 512);
    const used = (try queue.pollUsed()).?;
    try testing.expectEqual(head, used.head);
    try testing.expectEqual(@as(u32, 512), used.length);
    try testing.expectEqual(@as(u16, 0), queue.pendingUsed());
    try testing.expectEqual(@as(u16, 0), queue.inFlightCount());
    try testing.expect((try queue.pollUsed()) == null);

    // Consumida a conclusao, a cadeia inteira volta para a free list.
    try queue.release(head);
    try testing.expectEqual(@as(u16, 16), queue.freeCount());
    var index: u16 = 0;
    while (index < 16) : (index += 1) {
        try testing.expect(!queue.isAllocated(index));
        try testing.expectEqual(@as(u64, 0), (try queue.descriptor(index)).address);
    }
}

test "publish writes the available ring before the index" {
    var queue = try TestQueue.init(testMemory(4), 4);
    const ring = queue.layout.available_offset + 4;

    const first = try queue.allocate();
    const second = try queue.allocate();
    try queue.setBuffer(first, 0x3000_0000, 16);
    try queue.setBuffer(second, 0x3000_0010, 32);

    try queue.publish(first);
    try queue.publish(second);

    // As entradas ficam nas posicoes 0 e 1 do anel, e o indice e 2.
    try testing.expectEqual(first, std.mem.readInt(u16, queue.memory.bytes[ring..][0..2], .little));
    try testing.expectEqual(
        second,
        std.mem.readInt(u16, queue.memory.bytes[ring + 2 ..][0..2], .little),
    );
    try testing.expectEqual(
        @as(u16, 2),
        std.mem.readInt(
            u16,
            queue.memory.bytes[queue.layout.available_offset + 2 ..][0..2],
            .little,
        ),
    );

    // A conclusao chega na ordem em que o dispositivo processou.
    complete(TestQueue, &queue, first, 16);
    complete(TestQueue, &queue, second, 32);

    const first_used = (try queue.pollUsed()).?;
    try testing.expectEqual(first, first_used.head);
    try testing.expectEqual(@as(u32, 16), first_used.length);

    const second_used = (try queue.pollUsed()).?;
    try testing.expectEqual(second, second_used.head);
    try testing.expectEqual(@as(u32, 32), second_used.length);

    try testing.expect((try queue.pollUsed()) == null);
}

test "the ring indices wrap at 16 bits while the slot wraps at the queue size" {
    // Fila de 2 descritores: cada publicacao reusa a mesma posicao do anel, e
    // o indice continua contando. Este e o caso em que uma copia do indice
    // com `+` estouraria em vez de voltar a zero.
    var queue = try TestQueue.init(testMemory(2), 2);
    const ring = queue.layout.available_offset + 4;

    var iteration: u32 = 0;
    while (iteration < 40) : (iteration += 1) {
        const head = try queue.allocate();
        try queue.setBuffer(head, 0x3000_0000, 8);
        try queue.publish(head);
        try testing.expectEqual(
            head,
            std.mem.readInt(u16, queue.memory.bytes[ring..][0..2], .little),
        );
        complete(TestQueue, &queue, head, 8);
        const used = (try queue.pollUsed()).?;
        try testing.expectEqual(head, used.head);
        try queue.release(head);
    }
    try testing.expectEqual(@as(u16, 40), queue.availableIndex());
    try testing.expectEqual(@as(u16, 40), queue.usedIndex());
    try testing.expectEqual(@as(u16, 2), queue.freeCount());
}

test "an unconsumed chain keeps the queue from publishing more than it holds" {
    var queue = try TestQueue.init(testMemory(2), 2);
    const first = try queue.allocate();
    const second = try queue.allocate();
    try testing.expectError(error.QueueFull, queue.allocate());
    try testing.expectError(error.QueueFull, queue.allocateChain(1));

    try queue.publish(first);
    try queue.publish(second);
    // Duas cadeias em voo: nao ha descritor para uma terceira.
    try testing.expectEqual(@as(u16, 2), queue.inFlightCount());
    try testing.expectEqual(@as(u16, 0), queue.freeCount());
    try testing.expectError(error.QueueFull, queue.allocate());

    // Interrupcoes suprimidas pela flag do anel available.
    queue.setNoInterrupt(true);
    try testing.expectEqual(
        ring_flags.no_interrupt,
        std.mem.readInt(u16, queue.memory.bytes[queue.layout.available_offset..][0..2], .little),
    );
    queue.setNoInterrupt(false);
    try testing.expectEqual(
        @as(u16, 0),
        std.mem.readInt(u16, queue.memory.bytes[queue.layout.available_offset..][0..2], .little),
    );
}

test "publish and release refuse descriptors that are not allocated" {
    var queue = try TestQueue.init(testMemory(8), 8);
    try testing.expectError(error.InvalidDescriptor, queue.publish(8));
    try testing.expectError(error.DescriptorNotAllocated, queue.publish(3));
    try testing.expectError(error.DescriptorNotAllocated, queue.release(3));
    try testing.expectError(
        error.DescriptorNotAllocated,
        queue.setBuffer(3, 0x1000, 64),
    );
    try testing.expectEqual(@as(u16, 0), queue.availableIndex());
}

test "buffer description rejects empty, overflowing and indirect entries" {
    var queue = try TestQueue.init(testMemory(8), 8);
    const head = try queue.allocate();

    try testing.expectError(error.EmptyBuffer, queue.setBuffer(head, 0x1000, 0));
    try testing.expectError(error.EmptyBuffer, queue.setBuffer(head, 0, 16));
    try testing.expectError(
        error.Overflow,
        queue.setBuffer(head, 0xFFFF_FFFF_FFFF_FFF0, 0x20),
    );
    // Um descritor indireto sem VIRTIO_F_INDIRECT_DESC seria lido como `next`.
    try testing.expectError(error.InvalidDescriptor, queue.setIndirect(head));

    // A cadeia com `next` fora da tabela e recusada antes da publicacao.
    try queue.setBuffer(head, 0x1000, 16);
    queue.descriptorAt(head).next = 0xFFFF;
    queue.descriptorAt(head).flags |= descriptor_flags.next;
    try testing.expectError(error.InvalidChain, queue.publish(head));
    try testing.expectEqual(@as(u16, 0), queue.availableIndex());

    // E a liberacao nao depende de a cadeia estar intacta: ela recupera o que
    // esta alocado e para no elo invalido.
    try queue.release(head);
    try testing.expectEqual(@as(u16, 8), queue.freeCount());
    try testing.expect(!queue.isAllocated(head));
}

test "a chain with a cycle is refused before publication and reclaimed" {
    var queue = try TestQueue.init(testMemory(4), 4);
    const head = try queue.allocateChain(2);
    const second = (try queue.descriptor(head)).next;
    // O ultimo elo aponta de volta para a cabeca.
    queue.descriptorAt(second).next = head;
    queue.descriptorAt(second).flags |= descriptor_flags.next;

    try testing.expectError(error.InvalidChain, queue.publish(head));
    try testing.expectEqual(@as(u16, 0), queue.availableIndex());

    // A caminhada da liberacao para no primeiro elo ja liberado, e nao
    // duplica descritores na free list: alocar os quatro devolve exatamente
    // um de cada indice.
    try queue.release(head);
    try testing.expectEqual(@as(u16, 4), queue.freeCount());

    var seen: [4]bool = @splat(false);
    var index: usize = 0;
    while (index < 4) : (index += 1) {
        const allocated = try queue.allocate();
        try testing.expect(allocated < 4);
        try testing.expect(!seen[allocated]);
        seen[allocated] = true;
    }
    try testing.expectEqual(@as(u16, 0), queue.freeCount());
    try testing.expectError(error.QueueFull, queue.allocate());
}

test "a failed chain allocation returns the part it took" {
    var queue = try TestQueue.init(testMemory(4), 4);
    _ = try queue.allocateChain(3);
    // Resta um descritor: uma cadeia de dois nao cabe.
    try testing.expectError(error.QueueFull, queue.allocateChain(2));
    try testing.expectEqual(@as(u16, 1), queue.freeCount());
    try testing.expect(queue.isAllocated(0));
    try testing.expect(queue.isAllocated(1));
    try testing.expect(queue.isAllocated(2));
    // E o unico descritor livre continua alocavel.
    const last = try queue.allocate();
    try testing.expectEqual(@as(u16, 3), last);
    try testing.expectEqual(@as(u16, 0), queue.freeCount());
}

test "the used ring refuses ids the driver never published" {
    var queue = try TestQueue.init(testMemory(8), 8);
    const used = usedHeader(TestQueue, &queue);

    // `used.idx` avanca sem nenhuma conclusao correspondente.
    std.mem.writeInt(u16, queue.memory.bytes[used + 2 ..][0..2], @as(u16, 1), .little);
    try testing.expectEqual(@as(u16, 1), queue.pendingUsed());
    try testing.expectError(error.UsedIdNotInflight, queue.pollUsed());

    // Uma fila nova para isolar o caso do `id` fora da tabela.
    var second = try TestQueue.init(testMemory(8), 8);
    const head = try second.allocate();
    try second.setBuffer(head, 0x3000_0000, 32);
    try second.publish(head);
    const second_used = usedHeader(TestQueue, &second);
    std.mem.writeInt(u32, second.memory.bytes[second_used + 4 ..][0..4], @as(u32, 8), .little);
    std.mem.writeInt(u32, second.memory.bytes[second_used + 8 ..][0..4], @as(u32, 32), .little);
    std.mem.writeInt(u16, second.memory.bytes[second_used + 2 ..][0..2], @as(u16, 1), .little);
    try testing.expectError(error.UsedIdInvalid, second.pollUsed());

    // O dispositivo nao pode avancar o indice mais do que o anel comporta.
    var third = try TestQueue.init(testMemory(2), 2);
    const third_used = usedHeader(TestQueue, &third);
    std.mem.writeInt(u16, third.memory.bytes[third_used + 2 ..][0..2], @as(u16, 3), .little);
    try testing.expectError(error.UsedIndexOutOfRange, third.pollUsed());
}

test "the device can suppress notifications through the used flags" {
    var queue = try TestQueue.init(testMemory(4), 4);
    try testing.expect(!queue.notificationsSuppressed());
    std.mem.writeInt(
        u16,
        queue.memory.bytes[queue.layout.used_offset..][0..2],
        ring_flags.no_notify,
        .little,
    );
    try testing.expect(queue.notificationsSuppressed());
}

test "the queue state is per instance and survives a second init" {
    var queue = try TestQueue.init(testMemory(8), 8);
    const head = try queue.allocateChain(2);
    try queue.setBuffer(head, 0x3000_0000, 16);
    try queue.publish(head);
    try testing.expectEqual(@as(u16, 1), queue.inFlightCount());

    // Um novo init sobre a mesma memoria zera os aneis e a free list: o estado
    // anterior nao vaza para o dispositivo seguinte.
    var fresh = try TestQueue.init(testMemory(8), 8);
    try testing.expectEqual(@as(u16, 8), fresh.freeCount());
    try testing.expectEqual(@as(u16, 0), fresh.availableIndex());
    try testing.expectEqual(@as(u16, 0), fresh.usedIndex());
    try testing.expectEqual(@as(u16, 0), fresh.inFlightCount());
    try testing.expect(!fresh.isAllocated(head));
}
