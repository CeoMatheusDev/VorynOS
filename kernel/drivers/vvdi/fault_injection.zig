//************************************************************************//
//  fault_injection.zig                                                   //
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

//! Simulador de dispositivo VirtIO Block para injecao de falhas.
//!
//! Este arquivo responde a pergunta que os testes de unidade dos modulos nao
//! respondem: o que acontece com a memoria de DMA e com os descritores quando
//! o dispositivo real — atras do transporte PCI — falha no meio de um pedido?
//!
//! O simulador nao reimplementa o driver. Ele reusa a cadeia de producao
//! inteira e troca **apenas** o outro lado do barramento:
//!
//! ```text
//!   bytes de configuracao  -> caps.parse          (producao)
//!   capabilities validadas -> Transport.attach    (producao)
//!   registradores          -> transport.Device    (producao)
//!   fila 0 programada      -> pci_transport       (producao)
//!   DMA + virtqueue        -> virtqueue.Queue     (producao)
//!   pedidos e conclusoes   -> block.Driver        (producao)
//!                                |
//!                                +-- MMIO e DMA descritos por este arquivo
//! ```
//!
//! O que este arquivo descreve e o **dispositivo**: os registradores da
//! configuracao comum (especificacao 4.1.4.3), a configuracao do tipo bloco
//! (§5.2.4), o anel `available` que ele le e o anel `used` que ele escreve.
//! Nada aqui chama `Queue.publish`, `Queue.pollUsed`, `Queue.descriptor` ou
//! qualquer rotina do driver: o dispositivo conversa com a fila por bytes,
//! como o hardware faz. Uma fila que o driver programe errado nao pode ser
//! "corrigida" pelo simulador.
//!
//! O simulador tambem nao decide o que e falha. Ele obedece a um `Mode`:
//! completar, nunca completar, completar com `id` errado, com comprimento
//! errado, com status fora da especificacao ou com erro de dispositivo. A
//! conclusao e sempre escrita nos bytes da especificacao, e o que o driver faz
//! com ela e o que os testes medem.
//!
//! ## Por que ele e test-only
//!
//! O arquivo so entra na compilacao quando os testes sao construidos: a raiz
//! do modulo (`root.zig`) o importa dentro do bloco `test`. O kernel nao o
//! referencia, e `FakeBar` de `pci_transport.zig` continua privado — criar um
//! segundo dispositivo, em vez de exportar aquele, preserva o encapsulamento
//! do teste existente e mantem cada arquivo com o simulador de que precisa.
//!
//! ## Limite honesto
//!
//! Isto e host-side. Nao ha barramento PCI, nao ha OVMF e nao ha dispositivo
//! fisico: o MMIO e um vetor de bytes e o DMA e memoria comum. O que se prova
//! aqui e o comportamento do driver contra um dispositivo que se comporta como
//! a especificacao permite (e, nos testes de falha, como ela proibe). Nenhuma
//! conclusao sobre hardware real sai deste arquivo.

const std = @import("std");

const block_api = @import("voryn_block");
const block = @import("block.zig");
const caps = @import("caps.zig");
const containment = @import("containment.zig");
const features = @import("features.zig");
const mmio = @import("mmio.zig");
const pci_transport = @import("pci_transport.zig");
const transport = @import("transport.zig");
const types = @import("types.zig");
const virtqueue = @import("virtqueue.zig");

const testing = std.testing;

// ----------------------------------------------------------------------
// Geometria do BAR e da memoria de DMA.
//
// O BAR e um vetor de bytes enderecado pela "janela virtual" que o kernel
// mapearia. As quatro regioes ficam em faixas disjuntas, para que uma
// notificacao nunca caia sobre a configuracao do dispositivo.
// ----------------------------------------------------------------------

const bar_size: usize = 0x4000;
const bar_virtual: u64 = 0x4400_0000;
const bar_physical: u64 = 0xFE00_0000;
const bar_index: u8 = 4;

const common_offset: u32 = 0x0000;
const common_length: u32 = 0x1000;
const notify_offset: u32 = 0x1000;
const notify_length: u32 = 0x1000;
const device_offset: u32 = 0x2000;
const device_length: u32 = 0x40;
const isr_offset: u32 = 0x3000;
const isr_length: u32 = 1;

/// Multiplicador da capability de notificacao: potencia de dois e par (§4.1.4.4).
const notify_off_multiplier: u32 = 4;

/// Memoria de DMA da fila: o mesmo bloco contiguo que o kernel obtem do
/// alocador. `BufferLayout.required` cabe folgado em uma pagina de 4 KiB.
const dma_size: usize = 4096;
const dma_physical: u64 = 0x3000_0000;

/// Setores do meio simulado.
const medium_sectors: usize = 64;
const sector_size: usize = block.sector_size;

// ----------------------------------------------------------------------
// Modo de resposta do dispositivo.
// ----------------------------------------------------------------------

const Mode = enum {
    /// Completa todo pedido notificado, como um dispositivo saudavel.
    complete,
    /// Le o pedido e nao escreve conclusao alguma. A conclusao pode chegar
    /// depois, por `Device.deliverPending` — e o caso do *timeout* seguido de
    /// conclusao tardia.
    deferred,
    /// Devolve no anel `used` o `id` de um elo do meio da cadeia, e nao o da
    /// cabeca (§2.7.13.2 proibe: o dispositivo so devolve o `id` publicado).
    wrong_id,
    /// Devolve comprimento de 1 byte, como se o dispositivo tivesse escrito
    /// apenas o status e ignorado os 512 bytes do buffer `write`.
    short_length,
    /// Escreve no status um valor que a especificacao nao define (0xFF).
    corrupt_status,
    /// Completa com `VIRTIO_BLK_S_IOERR`.
    device_error,
    /// Completa com `VIRTIO_BLK_S_UNSUPP`.
    unsupported,
};

// ----------------------------------------------------------------------
// Dispositivo simulado.
//
// Todo o estado e estatico porque a contencao guarda ponteiros para ele e
// porque o transporte e o driver sobrevivem ao corpo do teste. Cada teste
// chama `reset`, que devolve o dispositivo ao estado pos-reset.
// ----------------------------------------------------------------------

const Device = struct {
    /// Bytes do BAR: configuracao comum (0x0000), notificacao (0x1000),
    /// configuracao do tipo (0x2000) e ISR (0x3000).
    var bar: [bar_size]u8 align(4096) = @splat(0);

    /// Memoria de DMA da fila, do jeito que o dispositivo a alcanca.
    var dma: [dma_size]u8 align(4096) = @splat(0);

    /// Meio de armazenamento. Persiste ao longo de um reset, como um disco.
    var medium: [medium_sectors * sector_size]u8 = @splat(0);

    // --- registradores do dispositivo --------------------------------

    /// Palavras de `device_feature` (§4.1.4.3): a primeira traz as features de
    /// bloco, a segunda traz VIRTIO_F_VERSION_1 no bit 0.
    var device_words: [2]u32 = @splat(0);
    /// Palavras de `driver_feature`, o que o driver publicou.
    var driver_words: [2]u32 = @splat(0);
    var num_queues: u16 = 1;
    var queue_max_size: u16 = 8;
    var queue_notify_off: u16 = 0;
    /// Capacidade anunciada em `virtio_blk_config.capacity`, em setores.
    var capacity_sectors: u64 = medium_sectors;
    /// O dispositivo oferece VIRTIO_BLK_F_FLUSH na primeira palavra.
    var offer_flush: bool = true;

    // --- injecao de falhas -------------------------------------------

    var mode: Mode = .complete;
    /// False quando o dispositivo ignora a escrita de 0 em `device_status`:
    /// o reset nao se confirma na leitura de volta.
    var confirm_reset: bool = true;
    /// Quando verdadeiro, `config_generation` alterna a cada leitura: a
    /// capacidade nao pode ser lida de forma consistente (§2.7.4.3).
    var unstable_generation: bool = false;

    // --- observacao --------------------------------------------------

    var notify_count: u32 = 0;
    var completion_count: u32 = 0;
    var reset_writes: u32 = 0;
    /// Ultimo `VIRTIO_BLK_T_*` que o dispositivo leu do cabecalho.
    var last_request_type: u32 = 0;
    /// Ultimo `sector` que o dispositivo leu do cabecalho.
    var last_sector: u64 = 0;
    /// Indice do anel `available` ja processado.
    var processed_available: u16 = 0;
    /// Pedido lido no modo `deferred` e ainda sem conclusao.
    var pending: ?Pending = null;

    var generation: u1 = 0;

    /// Pedido aceito e nao respondido, guardado para a conclusao tardia.
    const Pending = struct {
        head: u16,
        length: u32,
        status: u8,
        status_address: u64,
    };

    /// Descritor lido da tabela, com os campos da especificacao.
    const Buffer = struct {
        address: u64,
        length: u32,
        flags: u16,
        next: u16,
    };

    fn reset() void {
        bar = @splat(0);
        dma = @splat(0);
        for (&medium, 0..) |*byte, index| byte.* = @truncate(index *% 31 +% 7);

        // Um disco de bloco moderno: features de bloco na primeira palavra
        // (FLUSH, bit 9) e VERSION_1 na segunda (bit 32).
        device_words = .{
            if (offer_flush) @truncate(@as(u64, block.flush_feature)) else 0,
            @truncate(features.version_1 >> 32),
        };
        driver_words = @splat(0);
        num_queues = 1;
        queue_max_size = 8;
        queue_notify_off = 0;
        capacity_sectors = medium_sectors;

        mode = .complete;
        confirm_reset = true;
        unstable_generation = false;

        notify_count = 0;
        completion_count = 0;
        reset_writes = 0;
        last_request_type = 0;
        last_sector = 0;
        processed_available = 0;
        pending = null;
        generation = 0;

        writeLe16(@intCast(pci_transport.offset.num_queues), num_queues);
        writeLe16(@intCast(pci_transport.offset.queue_size), queue_max_size);
        writeLe16(@intCast(pci_transport.offset.queue_notify_off), queue_notify_off);
        writeLe16(@intCast(pci_transport.offset.queue_enable), 0);
        writeLe64(device_offset, capacity_sectors);
    }

    // --- acesso a bytes little-endian --------------------------------

    fn readLe16(at: usize) u16 {
        return std.mem.readInt(u16, bar[at..][0..2], .little);
    }

    fn readLe64(at: usize) u64 {
        return std.mem.readInt(u64, bar[at..][0..8], .little);
    }

    fn writeLe16(at: usize, value: u16) void {
        std.mem.writeInt(u16, bar[at..][0..2], value, .little);
    }

    fn writeLe64(at: usize, value: u64) void {
        std.mem.writeInt(u64, bar[at..][0..8], value, .little);
    }

    /// True quando o driver escreveu 1 em `queue_enable` para a fila 0.
    fn queueEnabled() bool {
        return readLe16(@intCast(pci_transport.offset.queue_enable)) == 1;
    }

    /// Tamanho que o driver programou em `queue_size`.
    fn programmedQueueSize() u16 {
        return readLe16(@intCast(pci_transport.offset.queue_size));
    }

    fn queueDescAddress() u64 {
        return readLe64(@intCast(pci_transport.offset.queue_desc));
    }

    fn queueDriverAddress() u64 {
        return readLe64(@intCast(pci_transport.offset.queue_driver));
    }

    fn queueDeviceAddress() u64 {
        return readLe64(@intCast(pci_transport.offset.queue_device));
    }

    /// Capacidade escrita na configuracao do tipo bloco.
    fn setCapacity(sectors: u64) void {
        capacity_sectors = sectors;
        writeLe64(device_offset, sectors);
    }

    // --- traducao do endereco fisico para a memoria do teste ---------

    fn dmaAt(physical: u64, length: usize) ?[]u8 {
        if (physical < dma_physical) return null;
        const offset = physical - dma_physical;
        if (offset > dma.len) return null;
        const start: usize = @intCast(offset);
        if (length > dma.len - start) return null;
        return dma[start .. start + length];
    }

    // --- aneis, do lado do dispositivo -------------------------------

    /// Area do driver: `avail.flags`, `avail.idx`, `avail.ring[]`,
    /// `avail.used_event` (§2.7.7).
    fn availableArea() []u8 {
        return dmaAt(queueDriverAddress(), @as(usize, programmedQueueSize()) * 2 + 6) orelse
            @panic("available ring outside the DMA region");
    }

    /// Area do dispositivo: `used.flags`, `used.idx`, `used.ring[]`,
    /// `used.avail_event` (§2.7.8).
    fn usedArea() []u8 {
        return dmaAt(queueDeviceAddress(), @as(usize, programmedQueueSize()) * 8 + 6) orelse
            @panic("used ring outside the DMA region");
    }

    /// Le o descritor `index` da tabela, como o dispositivo a le.
    fn descriptor(index: u16) Buffer {
        const table = dmaAt(
            queueDescAddress(),
            @as(usize, programmedQueueSize()) * virtqueue.descriptor_size,
        ) orelse @panic("descriptor table outside the DMA region");
        const base = @as(usize, index) * virtqueue.descriptor_size;
        return .{
            .address = std.mem.readInt(u64, table[base..][0..8], .little),
            .length = std.mem.readInt(u32, table[base + 8 ..][0..4], .little),
            .flags = std.mem.readInt(u16, table[base + 12 ..][0..2], .little),
            .next = std.mem.readInt(u16, table[base + 14 ..][0..2], .little),
        };
    }

    // --- servico da fila ---------------------------------------------

    /// Processa as cadeias que o driver publicou desde a ultima vez.
    ///
    /// Chamada quando o driver escreve no registro de notificacao. O
    /// dispositivo nao chama nenhuma rotina da fila: ele le `avail.idx`, as
    /// entradas, a tabela de descritores e os buffers pelo endereco fisico,
    /// exatamente como o hardware faria.
    fn serviceQueue() void {
        if (!queueEnabled()) return;
        const size = programmedQueueSize();
        if (size == 0) return;

        const available = availableArea();
        const available_index = std.mem.readInt(u16, available[2..][0..2], .little);

        while (processed_available != available_index) {
            const slot = processed_available & (size - 1);
            const head = std.mem.readInt(u16, available[4 + @as(usize, slot) * 2 ..][0..2], .little);
            processed_available +%= 1;

            const request = readRequest(head) orelse
                @panic("the driver published a chain outside the specification");

            switch (mode) {
                .complete => complete(request),
                .deferred => pending = .{
                    .head = request.head,
                    .length = request.used_length,
                    .status = request.status,
                    .status_address = request.status_address,
                },
                .wrong_id => complete(request.withHead(request.middle)),
                // Um byte so: o comprimento que o dispositivo escreveria se
                // tivesse parado no status e ignorado o buffer `write`.
                .short_length => complete(request.withLength(1)),
                .corrupt_status => complete(request.withStatus(0xFF)),
                // Com erro o dispositivo nao escreve dados: o comprimento
                // usado volta a ser o do status (§2.7.13.2, §5.2.6).
                .device_error => complete(request.withStatusAndLength(block.status_io_error, 1)),
                .unsupported => complete(request.withStatusAndLength(block.status_unsupported, 1)),
            }
        }
    }

    const Request = struct {
        head: u16,
        /// Elo do meio da cadeia: o `next` da cabeca, que tambem esta em voo.
        middle: u16,
        used_length: u32,
        status: u8,
        status_address: u64,
        type: u32,
        sector: u64,

        fn withHead(self: Request, head: u16) Request {
            var copy = self;
            copy.head = head;
            return copy;
        }

        fn withLength(self: Request, length: u32) Request {
            var copy = self;
            copy.used_length = length;
            return copy;
        }

        fn withStatus(self: Request, status: u8) Request {
            var copy = self;
            copy.status = status;
            return copy;
        }

        fn withStatusAndLength(self: Request, status: u8, length: u32) Request {
            return self.withStatus(status).withLength(length);
        }
    };

    /// Le a cadeia publicada e aplica o efeito no meio simulado.
    fn readRequest(head: u16) ?Request {
        const header = descriptor(head);
        if (header.flags & virtqueue.descriptor_flags.write != 0) return null;
        const header_bytes = dmaAt(header.address, @sizeOf(block.RequestHeader)) orelse return null;
        const request_type = std.mem.readInt(u32, header_bytes[0..][0..4], .little);
        const sector = std.mem.readInt(u64, header_bytes[8..][0..8], .little);

        last_request_type = request_type;
        last_sector = sector;

        if (request_type == block.request_flush) {
            const status = descriptor(header.next);
            if (status.flags & virtqueue.descriptor_flags.write == 0) return null;
            return .{
                .head = head,
                .middle = header.next,
                .used_length = 1,
                .status = block.status_ok,
                .status_address = status.address,
                .type = request_type,
                .sector = sector,
            };
        }

        if (request_type != block.request_in and request_type != block.request_out) return null;

        const data = descriptor(header.next);
        const status = descriptor(data.next);
        if (status.flags & virtqueue.descriptor_flags.write == 0) return null;

        const writes_data = data.flags & virtqueue.descriptor_flags.write != 0;
        if (request_type == block.request_in and !writes_data) return null;
        if (request_type == block.request_out and writes_data) return null;

        const data_bytes = dmaAt(data.address, data.length) orelse return null;

        // O efeito no meio: leitura copia do meio para o buffer, escrita copia
        // do buffer para o meio. Setor fora da capacidade responde erro.
        var status_value: u8 = block.status_ok;
        if (sector >= capacity_sectors or sector >= medium_sectors) {
            status_value = block.status_io_error;
        } else {
            const start: usize = @intCast(sector * sector_size);
            if (request_type == block.request_in) {
                @memcpy(data_bytes[0..sector_size], medium[start .. start + sector_size]);
            } else {
                @memcpy(medium[start .. start + sector_size], data_bytes[0..sector_size]);
            }
        }

        return .{
            .head = head,
            .middle = header.next,
            .used_length = if (writes_data and status_value == block.status_ok)
                @as(u32, block.sector_size) + 1
            else
                1,
            .status = status_value,
            .status_address = status.address,
            .type = request_type,
            .sector = sector,
        };
    }

    /// Escreve o status e publica a conclusao no anel `used`.
    fn complete(request: Request) void {
        writeStatus(request.status_address, request.status);
        publishUsed(request.head, request.used_length);
    }

    fn writeStatus(address: u64, value: u8) void {
        const bytes = dmaAt(address, 1) orelse @panic("status byte outside the DMA region");
        bytes[0] = value;
    }

    /// Conclusao no anel `used` (§2.7.8): `id`, `len`, e depois `used.idx`.
    fn publishUsed(id: u16, length: u32) void {
        const used = usedArea();
        const size = programmedQueueSize();
        const index = std.mem.readInt(u16, used[2..][0..2], .little);
        const slot = index & (size - 1);

        std.mem.writeInt(u32, used[4 + @as(usize, slot) * 8 ..][0..4], id, .little);
        std.mem.writeInt(u32, used[8 + @as(usize, slot) * 8 ..][0..4], length, .little);
        std.mem.writeInt(u16, used[2..][0..2], index +% 1, .little);
        completion_count += 1;
    }

    /// Entrega a conclusao do pedido que o dispositivo aceitou e nao
    /// respondeu. E a conclusao tardia, que chega depois de o driver desistir.
    fn deliverPending() ?Pending {
        const request = pending orelse return null;
        writeStatus(request.status_address, request.status);
        publishUsed(request.head, request.length);
        pending = null;
        return request;
    }

    // --- barramento MMIO ---------------------------------------------

    /// Leitura de registrador. A janela de selecao de features e o unico
    /// lugar em que o valor nao esta nos bytes: `device_feature` e
    /// `driver_feature` mostram a palavra escolhida por `*_select`.
    fn read(_: ?*const anyopaque, address: u64, width: mmio.Width) u64 {
        const start: usize = @intCast(address - bar_virtual);

        if (width == .dword and start == pci_transport.offset.device_feature) {
            const selected = bar[@intCast(pci_transport.offset.device_feature_select)] & 1;
            return device_words[selected];
        }
        if (width == .dword and start == pci_transport.offset.driver_feature) {
            const selected = bar[@intCast(pci_transport.offset.driver_feature_select)] & 1;
            return driver_words[selected];
        }
        if (width == .byte and start == pci_transport.offset.config_generation) {
            if (!unstable_generation) return 0;
            generation +%= 1;
            return generation;
        }

        var value: u64 = 0;
        var index: usize = 0;
        while (index < width.size()) : (index += 1) {
            value |= @as(u64, bar[start + index]) << @intCast(index * 8);
        }
        return value;
    }

    fn write(_: ?*const anyopaque, address: u64, width: mmio.Width, value: u64) void {
        const start: usize = @intCast(address - bar_virtual);

        // Notificacao: o dispositivo olha a fila. O valor escrito e o indice
        // da fila (§4.1.4.4).
        if (start >= notify_offset and start < notify_offset + notify_length) {
            notify_count += 1;
            serviceQueue();
            return;
        }

        if (width == .dword and start == pci_transport.offset.driver_feature) {
            const selected = bar[@intCast(pci_transport.offset.driver_feature_select)] & 1;
            driver_words[selected] = @truncate(value);
            return;
        }

        if (width == .byte and start == pci_transport.offset.device_status) {
            if (value == 0) {
                reset_writes += 1;
                if (confirm_reset) applyReset();
                return;
            }
            bar[start] = @truncate(value);
            return;
        }

        var index: usize = 0;
        while (index < width.size()) : (index += 1) {
            bar[start + index] = @truncate(value >> @intCast(index * 8));
        }
    }

    /// Reset (§2.4.2): `device_status` volta a zero e o dispositivo esquece a
    /// programacao das filas e as features publicadas pelo driver. O meio
    /// simulado nao e apagado.
    fn applyReset() void {
        @memset(bar[0..common_length], 0);
        writeLe16(@intCast(pci_transport.offset.num_queues), num_queues);
        writeLe16(@intCast(pci_transport.offset.queue_size), queue_max_size);
        writeLe16(@intCast(pci_transport.offset.queue_notify_off), queue_notify_off);
        driver_words = @splat(0);
        processed_available = 0;
        pending = null;
    }

    fn bus() mmio.Bus {
        return .{ .ctx = null, .read_fn = read, .write_fn = write };
    }

    /// O BAR inteiro, como a `Window.mapRange` o entregaria.
    fn region() mmio.Region {
        return .{
            .bus = bus(),
            .virtual = bar_virtual,
            .physical = bar_physical,
            .length = bar_size,
            .permissions = mmio.Permissions.read_write,
            .mapped = true,
        };
    }

    /// Escreve `ring_flags.no_notify` na area do dispositivo, como o
    /// dispositivo faria antes de o driver publicar.
    fn suppressNotifications(queue: anytype) void {
        std.mem.writeInt(
            u16,
            queue.memory.bytes[queue.layout.used_offset..][0..2],
            virtqueue.ring_flags.no_notify,
            .little,
        );
    }
};

// ----------------------------------------------------------------------
// Funcao PCI simulada: o alvo da revogacao de *bus master*.
//
// `Containment.BusMaster` recebe uma funcao de revogacao que devolve true
// **somente** com leitura de volta confirmando o bit desligado. A funcao aqui
// implementa esse contrato sobre um registrador `Command` em memoria: escreve,
// le de volta e compara, do mesmo modo que `pci.setBusMaster` faz sobre o
// espaco de configuracao real — caminho coberto por `arch-tests`, porque
// `pci.zig` pertence a outro modulo e nao e importado pela VVDI (ADR-0021).
// ----------------------------------------------------------------------

const PciFunction = struct {
    /// `Command` depois do firmware: `Memory Space` (bit 1) e
    /// `Bus Master` (bit 2) ligados.
    var command: u16 = command_initial;
    /// Escritas no registrador `Command`, para provar idempotencia.
    var writes: u32 = 0;
    /// Quando verdadeiro, o dispositivo descarta a limpeza do bit 2: a
    /// revogacao nao se confirma na leitura de volta.
    var ignore_bus_master_write: bool = false;

    const command_initial: u16 = 0x0006;
    const memory_space: u16 = 0x0002;
    const bus_master: u16 = 0x0004;

    fn reset() void {
        command = command_initial;
        writes = 0;
        ignore_bus_master_write = false;
    }

    /// Escreve o bit 2 e devolve se a leitura de volta confirmou o pedido.
    fn setBusMaster(enabled: bool) bool {
        writes += 1;
        if (!ignore_bus_master_write) {
            if (enabled) {
                command |= bus_master;
            } else {
                command &= ~bus_master;
            }
        }
        const current = command;
        return (current & bus_master != 0) == enabled;
    }

    /// O `Containment` nao escolhe o alvo: o alvo e o estado deste arquivo,
    /// que sobrevive ao teste porque e estatico.
    fn revoke(_: *anyopaque) bool {
        return setBusMaster(false);
    }

    fn busMasterRevoked() bool {
        return command & bus_master == 0;
    }

    fn memorySpacePreserved() bool {
        return command & memory_space != 0;
    }

    fn handle(self: *PciFunction) containment.BusMaster {
        return .{ .ctx = @ptrCast(self), .revoke = revoke };
    }
};

/// O alvo da revogacao precisa sobreviver ao teste: a contencao guarda um
/// ponteiro para ele e pode ser consultada depois do retorno da funcao.
var pci_function: PciFunction = .{};

// ----------------------------------------------------------------------
// Bancada: transporte, fila, driver e posse da memoria.
//
// A ordem de `bringUpToDriverOk` e a de `kernel/main.zig` (`programVirtqueue`):
// capabilities -> transporte -> tamanho -> layout -> DMA -> fila -> posse ->
// `configureQueue` -> `enableQueue` -> `markQueueReady` -> `DRIVER_OK`.
// Mantida nessa ordem, o que os testes exercitam e o contrato do boot, e nao
// uma sequencia inventada para o teste passar.
// ----------------------------------------------------------------------

const BlockQueue = virtqueue.Queue(block.queue_capacity);

const Harness = struct {
    device_transport: pci_transport.Transport = undefined,
    protocol: transport.Device = undefined,
    queue: BlockQueue = undefined,
    ownership: transport.QueueMemory = .{},
    state: containment.Containment = .{},
    driver: block.Driver = undefined,

    fn device(self: *Harness) block_api.Device {
        return self.driver.device();
    }

    /// Instantaneo do que os testes usam para provar retencao.
    const Snapshot = struct {
        free: u16,
        available: u16,
        dma: [dma_size]u8,
    };

    fn snapshot(self: *Harness) Snapshot {
        return .{
            .free = self.queue.freeCount(),
            .available = self.queue.availableIndex(),
            .dma = Device.dma,
        };
    }

    /// A memoria da fila nao voltou ao alocador: nenhum descritor foi
    /// liberado e nada novo foi publicado.
    fn expectQueueMemoryRetained(self: *Harness, before: Snapshot) !void {
        try testing.expectEqual(before.free, self.queue.freeCount());
        try testing.expectEqual(before.available, self.queue.availableIndex());
    }

    /// Nada escreveu na memoria de DMA depois da falha: o driver em quarentena
    /// nao toca no buffer compartilhado nem no anel que o dispositivo le.
    fn expectDmaUntouched(before: Snapshot) !void {
        try testing.expectEqualSlices(u8, &before.dma, &Device.dma);
    }

    /// As duas provas que `virtqueueMemoryMayBeReturned` (main.zig) combina
    /// com `and` antes de devolver a memoria: o transporte afirma que a fila
    /// deixou de pertencer ao dispositivo, e a contencao autoriza a liberacao.
    /// Cada uma e verificada separadamente, porque a funcao do boot nao e
    /// host-testavel e porque a combinacao esconderia uma delas quando a outra
    /// ja recusasse.
    fn memoryMayReturnToAllocator(self: *Harness) bool {
        return self.ownership.canReturnToAllocator() and self.state.permitsMemoryRelease();
    }
};

/// Le as capabilities do espaco de configuracao do dispositivo simulado.
///
/// Os bytes sao codificados na ordem de `struct virtio_pci_cap` e passam pelo
/// mesmo `caps.parse` + `caps.build` que o boot usa, com um validador de BAR
/// que responde o que `pci.barSupportsRegion` responderia para este BAR.
fn deviceCapabilities() !caps.Collection {
    const definitions = [_]caps.Capability{
        .{ .cfg_type = caps.cfg_type.common, .bar = bar_index, .id = 0, .offset = common_offset, .length = common_length },
        .{ .cfg_type = caps.cfg_type.notify, .bar = bar_index, .id = 0, .offset = notify_offset, .length = notify_length, .notify_off_multiplier = notify_off_multiplier },
        .{ .cfg_type = caps.cfg_type.isr, .bar = bar_index, .id = 0, .offset = isr_offset, .length = isr_length },
        .{ .cfg_type = caps.cfg_type.device, .bar = bar_index, .id = 0, .offset = device_offset, .length = device_length },
    };

    var storage: [definitions.len * caps.notify_structure_size]u8 = undefined;
    var parsed: [definitions.len]caps.Capability = undefined;
    for (definitions, 0..) |definition, index| {
        const start = index * caps.notify_structure_size;
        const bytes = encodeCapability(storage[start..][0..caps.notify_structure_size], definition);
        parsed[index] = try caps.parse(bytes);
    }
    return caps.build(&parsed, barSupportsRegion);
}

fn encodeCapability(buffer: *[caps.notify_structure_size]u8, capability: caps.Capability) []const u8 {
    const length: usize = if (capability.isNotify()) caps.notify_structure_size else caps.structure_size;
    @memset(buffer, 0);
    buffer[0] = caps.capability_id;
    buffer[2] = @intCast(length);
    buffer[3] = capability.cfg_type;
    buffer[4] = capability.bar;
    buffer[5] = capability.id;
    std.mem.writeInt(u32, buffer[8..12], capability.offset, .little);
    std.mem.writeInt(u32, buffer[12..16], capability.length, .little);
    std.mem.writeInt(u32, buffer[16..20], capability.notify_off_multiplier, .little);
    return buffer[0..length];
}

/// O que `pci.zig` responderia para uma regiao dentro do BAR medido.
fn barSupportsRegion(bar: u8, offset: u32, length: u32) bool {
    if (bar != bar_index) return false;
    const end = std.math.add(u64, offset, length) catch return false;
    return end <= bar_size;
}

/// Opcoes que precisam valer **antes** da negociacao de features.
///
/// Elas sao passadas a cada bring-up em vez de ficarem em variaveis do
/// dispositivo: um teste que desliga FLUSH nao pode mudar o que o seguinte
/// negocia.
const Options = struct {
    /// O dispositivo oferece VIRTIO_BLK_F_FLUSH na primeira palavra.
    offer_flush: bool = true,
};

/// Executa a sequencia de boot ate `DRIVER_OK`, e para ai.
fn bringUpToDriverOk(harness: *Harness, options: Options) !void {
    Device.offer_flush = options.offer_flush;
    Device.reset();
    PciFunction.reset();

    const identification = try types.identify(types.vendor_id, 0x1042);
    try testing.expectEqual(types.DeviceType.block, identification.device_type);
    try testing.expect(identification.modern_id);

    harness.* = .{};
    harness.device_transport = try pci_transport.Transport.attach(
        identification,
        try deviceCapabilities(),
        Device.region(),
    );
    harness.protocol = .{ .registers = harness.device_transport.registers() };

    const outcome = harness.protocol.initializeOptional(features.supported, block.flush_feature);
    try testing.expect(outcome.isInitialized());
    try testing.expectEqual(features.version_1, harness.protocol.accepted & features.version_1);
    try testing.expect(harness.protocol.isAwaitingQueues());

    const max_size = try harness.protocol.queueMaxSize(0);
    const size = try virtqueue.Layout.negotiateSize(max_size);
    const layout = try virtqueue.Layout.compute(size);
    const buffers = block.BufferLayout.compute(layout.total_size).?;
    try testing.expect(buffers.required <= dma_size);

    harness.queue = try BlockQueue.init(.{
        .physical = dma_physical,
        .bytes = Device.dma[0..],
    }, size);
    // O driver de bloco faz polling sincrono: a fila nao pede interrupcao.
    harness.queue.setNoInterrupt(true);
    try testing.expectEqual(size, harness.queue.freeCount());
    try testing.expectEqual(@as(u16, 0), harness.queue.inFlightCount());

    const addresses = try harness.queue.addresses();

    // A posse da memoria comeca antes da primeira escrita que aponta o
    // dispositivo para ela, e a contencao e armada no mesmo ponto: uma falha
    // no meio da programacao nao prova que o dispositivo ficou sem acesso.
    harness.ownership.handOver();
    harness.state = .{};
    harness.state.arm(pci_function.handle());

    try harness.device_transport.configureQueue(0, size, .{
        .desc = addresses.desc,
        .driver = addresses.driver,
        .device = addresses.device,
    });
    try harness.device_transport.enableQueue(0);
    try testing.expect(try harness.device_transport.queueEnabled(0));
    try harness.protocol.markQueueReady(0);

    const finished = harness.protocol.finish();
    try testing.expect(finished.isInitialized());
    // ACKNOWLEDGE | DRIVER | FEATURES_OK | DRIVER_OK.
    try testing.expectEqual(@as(u8, 0x0F), harness.protocol.status);
}

/// Sequencia completa, incluindo o driver de bloco.
fn bringUp(harness: *Harness) !void {
    try bringUpToDriverOk(harness, .{});
    try harness.driver.init(
        &harness.device_transport,
        &harness.queue,
        dma_physical,
        Device.dma[0..],
        harness.queue.layout,
        harness.protocol.accepted,
        &harness.state,
    );
}

/// Executa pedidos com o driver em quarentena e prova que a tentativa nao
/// alterou nenhum byte da memoria compartilhada.
fn expectPoisonedWithoutTouchingDma(harness: *Harness) !void {
    const before = harness.snapshot();
    var buffer: [sector_size]u8 = @splat(0);
    try testing.expectError(error.DeviceFailure, harness.device().readBytes(0, &buffer));
    try testing.expectError(error.DeviceFailure, harness.device().writeBytes(0, &buffer));
    try testing.expectError(error.DeviceFailure, harness.device().flushWrites());
    // A recusa acontece antes de qualquer escrita: a fifa de descritores, o
    // cabecalho e o status continuam exatamente como o dispositivo os deixou.
    try Harness.expectDmaUntouched(before);
    try harness.expectQueueMemoryRetained(before);
}

// ----------------------------------------------------------------------
// 1. Fluxo real do driver: leitura, escrita e FLUSH pelo transporte PCI.
// ----------------------------------------------------------------------

test "a real virtio block read crosses the PCI transport and the virtqueue" {
    var harness: Harness = undefined;
    try bringUp(&harness);

    // O dispositivo se apresenta em DRIVER_OK, com a fila 0 habilitada.
    try testing.expect(Device.queueEnabled());
    try testing.expectEqual(@as(u16, 8), Device.programmedQueueSize());
    try testing.expectEqual(@as(u64, medium_sectors), harness.driver.sectors);
    try testing.expect(harness.driver.flush_supported);
    try testing.expectEqual(containment.State.armed, harness.state.state);
    try testing.expectEqual(@as(u32, 0), PciFunction.writes);

    const expected = Device.medium[0..sector_size];
    var buffer: [sector_size]u8 = @splat(0);
    var device = harness.device();
    try device.readBytes(0, &buffer);

    // O que o dispositivo entregou e o setor do meio, byte a byte.
    try testing.expectEqualSlices(u8, expected, &buffer);
    // O pedido chegou pelo registro de notificacao e a cadeia foi consumida.
    try testing.expectEqual(@as(u32, 1), Device.notify_count);
    try testing.expectEqual(@as(u32, 1), Device.completion_count);
    try testing.expectEqual(block.request_in, Device.last_request_type);
    try testing.expectEqual(@as(u64, 0), Device.last_sector);
    // A conclusao foi validada e a cadeia voltou inteira para a free list.
    try testing.expectEqual(@as(u16, 8), harness.queue.freeCount());
    try testing.expectEqual(@as(u16, 0), harness.queue.inFlightCount());
    try testing.expectEqual(@as(u16, 1), harness.queue.availableIndex());
    try testing.expectEqual(@as(u16, 1), harness.queue.usedIndex());
    // Nenhuma falha: o dispositivo nao foi contido e o driver nao envenenou.
    try testing.expect(!harness.state.isQuarantined());
    try testing.expect(harness.state.reason == null);
    try testing.expect(!harness.driver.poisoned);

    // Dois pedidos seguidos reutilizam a fila sem deixar descritor preso.
    const second_expected = Device.medium[sector_size .. 2 * sector_size];
    var second: [sector_size]u8 = @splat(0);
    try device.readBytes(sector_size, &second);
    try testing.expectEqualSlices(u8, second_expected, &second);
    try testing.expectEqual(@as(u16, 8), harness.queue.freeCount());
    try testing.expectEqual(@as(u32, 2), Device.notify_count);
}

test "a full sector write and a partial one reach the medium through the device" {
    var harness: Harness = undefined;
    try bringUp(&harness);
    var device = harness.device();

    // Escrita de um setor inteiro: um unico VIRTIO_BLK_T_OUT, sem leitura
    // previa, porque nada do setor precisa ser preservado.
    var sector: [sector_size]u8 = undefined;
    for (&sector, 0..) |*byte, index| byte.* = @truncate(index *% 3 +% 1);
    try device.writeBytes(sector_size, &sector);
    try testing.expectEqualSlices(u8, &sector, Device.medium[sector_size .. 2 * sector_size]);
    try testing.expectEqual(@as(u32, 1), Device.notify_count);
    try testing.expectEqual(block.request_out, Device.last_request_type);
    try testing.expectEqual(@as(u16, 8), harness.queue.freeCount());

    // Lido de volta pelo mesmo driver: o meio e a fonte dos 512 bytes.
    var read_back: [sector_size]u8 = @splat(0);
    try device.readBytes(sector_size, &read_back);
    try testing.expectEqualSlices(u8, &sector, &read_back);

    // Escrita parcial: o driver precisa preservar o resto do setor, e para
    // isso faz read-modify-write — IN e depois OUT, duas publicacoes.
    const original = Device.medium[2 * sector_size .. 3 * sector_size].*;
    const before = Device.notify_count;
    const partial = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF };
    try device.writeBytes(2 * sector_size + 100, &partial);

    const written = Device.medium[2 * sector_size .. 3 * sector_size];
    try testing.expectEqualSlices(u8, &partial, written[100..104]);
    // Todo o resto do setor foi preservado: a leitura previa fez o trabalho.
    try testing.expectEqualSlices(u8, original[0..100], written[0..100]);
    try testing.expectEqualSlices(u8, original[104..], written[104..]);
    // Duas notificacoes: o IN do setor e o OUT com o byte alterado.
    try testing.expectEqual(before + 2, Device.notify_count);
    try testing.expectEqual(block.request_out, Device.last_request_type);
    try testing.expectEqual(@as(u64, 2), Device.last_sector);
    try testing.expectEqual(@as(u16, 8), harness.queue.freeCount());
    try testing.expectEqual(@as(u16, 0), harness.queue.inFlightCount());
}

test "FLUSH is only published when the device offered the feature" {
    var harness: Harness = undefined;
    try bringUp(&harness);
    try testing.expect(harness.driver.flush_supported);

    try harness.driver.flush();
    try testing.expectEqual(block.request_flush, Device.last_request_type);
    // FLUSH usa a cadeia de dois descritores: cabecalho e status.
    try testing.expectEqual(@as(u16, 8), harness.queue.freeCount());
    try testing.expectEqual(@as(u32, 1), Device.notify_count);

    // Sem a feature negociada o driver recusa antes de publicar qualquer
    // coisa: nenhum descritor sai da free list e nada e notificado.
    var without_flush: Harness = undefined;
    try bringUpToDriverOk(&without_flush, .{ .offer_flush = false });
    try without_flush.driver.init(
        &without_flush.device_transport,
        &without_flush.queue,
        dma_physical,
        Device.dma[0..],
        without_flush.queue.layout,
        without_flush.protocol.accepted,
        &without_flush.state,
    );
    try testing.expect(!without_flush.driver.flush_supported);
    var device = without_flush.device();
    try testing.expectError(error.NotImplemented, device.flushWrites());
    try testing.expectEqual(@as(u32, 0), Device.notify_count);
    try testing.expectEqual(@as(u16, 8), without_flush.queue.freeCount());
    try testing.expectEqual(@as(u16, 0), without_flush.queue.availableIndex());
    // E a leitura continua funcionando: a ausencia de FLUSH nao e falha.
    var buffer: [sector_size]u8 = @splat(0);
    try device.readBytes(0, &buffer);
    try testing.expectEqualSlices(u8, Device.medium[0..sector_size], &buffer);
}

// ----------------------------------------------------------------------
// 2. Timeout, conclusao tardia e quarentena.
// ----------------------------------------------------------------------

test "a device that never completes quarantines the driver and retains the descriptors" {
    var harness: Harness = undefined;
    try bringUp(&harness);
    Device.mode = .deferred;

    const before = harness.snapshot();
    var buffer: [sector_size]u8 = @splat(0);
    try testing.expectError(error.IoTimeout, harness.device().readBytes(0, &buffer));

    // O dispositivo recebeu o pedido (a notificacao chegou) e nao respondeu.
    try testing.expectEqual(@as(u32, 1), Device.notify_count);
    try testing.expectEqual(@as(u32, 0), Device.completion_count);
    try testing.expect(Device.pending != null);

    // A cadeia ficou com o dispositivo: um pedido publicado, nenhum descritor
    // liberado e o pedido ainda em voo.
    try testing.expectEqual(before.available + 1, harness.queue.availableIndex());
    try testing.expectEqual(before.free - 3, harness.queue.freeCount());
    try testing.expectEqual(@as(u16, 1), harness.queue.inFlightCount());
    try testing.expectEqual(@as(u16, 0), harness.queue.pendingUsed());

    // O driver se fechou e a falha escalou para o dispositivo.
    try testing.expect(harness.driver.poisoned);
    try testing.expect(harness.state.isQuarantined());
    try testing.expectEqual(containment.State.contained, harness.state.state);
    try testing.expectEqual(containment.Reason.timeout, harness.state.reason.?);
    try testing.expectEqual(containment.Revocation.revoked, harness.state.revocation.?);
    try testing.expectEqual(@as(u32, 1), PciFunction.writes);
    try testing.expect(PciFunction.busMasterRevoked());
    try testing.expect(PciFunction.memorySpacePreserved());

    // Revogar nao e quiescencia: a memoria continua retida.
    try testing.expect(!harness.ownership.canReturnToAllocator());
    try testing.expect(!harness.state.permitsMemoryRelease());
    try testing.expect(!harness.memoryMayReturnToAllocator());

    // Nenhum pedido novo alcanca a fila nem a memoria compartilhada.
    try expectPoisonedWithoutTouchingDma(&harness);
    try testing.expectEqual(@as(u32, 1), Device.notify_count);
}

test "a completion that arrives after the timeout changes no invariant" {
    var harness: Harness = undefined;
    try bringUp(&harness);
    Device.mode = .deferred;

    var buffer: [sector_size]u8 = @splat(0);
    try testing.expectError(error.IoTimeout, harness.device().readBytes(0, &buffer));

    const pending = Device.pending.?;
    try testing.expectEqual(@as(u16, 0), pending.head);

    // A conclusao tardia chega ao anel `used` depois de o driver desistir. Ela
    // e uma escrita do dispositivo: `id` e comprimento sao os de um pedido
    // valido, e o status e o que o dispositivo teria escrito.
    const delivered = Device.deliverPending().?;
    try testing.expectEqual(pending.head, delivered.head);
    try testing.expectEqual(@as(u16, 1), harness.queue.usedIndex());

    // Nada foi consumido: o driver esta em quarentena e nao volta a olhar o
    // anel. A cadeia continua alocada e “em voo” do ponto de vista do driver.
    try testing.expectEqual(@as(u16, 1), harness.queue.inFlightCount());
    try testing.expectEqual(@as(u16, 1), harness.queue.pendingUsed());
    try testing.expectEqual(@as(u16, 5), harness.queue.freeCount());

    // A quarentena e irreversivel: um segundo evento nao reabre nada, nao
    // repete a revogacao e nao troca o motivo.
    const outcome = harness.state.contain(.invalid_completion);
    try testing.expectEqual(containment.Revocation.revoked, outcome);
    try testing.expectEqual(@as(u32, 1), PciFunction.writes);
    try testing.expectEqual(containment.Reason.timeout, harness.state.reason.?);
    try testing.expectEqual(containment.State.contained, harness.state.state);
    try testing.expectEqual(@as(u32, 2), harness.state.contain_calls);

    // E o driver continua fechado para pedidos novos, sem tocar em nada.
    try expectPoisonedWithoutTouchingDma(&harness);
}

test "a refused notification quarantines and keeps the published chain" {
    var harness: Harness = undefined;
    try bringUp(&harness);
    // O dispositivo reporta `queue_notify_off` fora da regiao de notificacao:
    // a escrita no registro falha depois de a cadeia ja ter sido publicada.
    Device.writeLe16(@intCast(pci_transport.offset.queue_notify_off), 0x800);

    const before = harness.snapshot();
    var buffer: [sector_size]u8 = @splat(0);
    try testing.expectError(error.IoFailure, harness.device().readBytes(0, &buffer));

    // O dispositivo nunca soube do pedido, e o driver nao o publicou de novo.
    try testing.expectEqual(@as(u32, 0), Device.notify_count);
    try testing.expectEqual(before.available + 1, harness.queue.availableIndex());
    try testing.expectEqual(before.free - 3, harness.queue.freeCount());
    try testing.expectEqual(@as(u16, 1), harness.queue.inFlightCount());
    try testing.expectEqual(containment.Reason.notify_failure, harness.state.reason.?);
    try testing.expect(harness.state.isQuarantined());
    try testing.expect(!harness.memoryMayReturnToAllocator());
}

test "invalid completions quarantine without returning a descriptor" {
    const faults = [_]struct { mode: Mode, reason: containment.Reason }{
        .{ .mode = .wrong_id, .reason = .invalid_completion },
        .{ .mode = .short_length, .reason = .invalid_completion },
        .{ .mode = .corrupt_status, .reason = .invalid_completion },
    };

    for (faults) |fault| {
        var harness: Harness = undefined;
        try bringUp(&harness);
        Device.mode = fault.mode;

        const before = harness.snapshot();
        var buffer: [sector_size]u8 = @splat(0);
        try testing.expectError(error.DeviceFailure, harness.device().readBytes(0, &buffer));

        // A conclusao chegou, mas nao descreve o pedido: o driver recusa em
        // vez de acreditar no dispositivo.
        try testing.expectEqual(@as(u32, 1), Device.completion_count);
        try testing.expect(harness.driver.poisoned);
        try testing.expectEqual(fault.reason, harness.state.reason.?);
        try testing.expect(harness.state.isQuarantined());
        // Um pedido publicado e nenhum descritor devolvido a free list: e a
        // regra de vida util dos descritores.
        try testing.expectEqual(before.available + 1, harness.queue.availableIndex());
        try testing.expectEqual(before.free - 3, harness.queue.freeCount());
        try testing.expect(!harness.memoryMayReturnToAllocator());
        try expectPoisonedWithoutTouchingDma(&harness);
    }
}

test "a device reported I/O error fails the request without containment" {
    var harness: Harness = undefined;
    try bringUp(&harness);
    Device.mode = .device_error;

    var buffer: [sector_size]u8 = @splat(0);
    try testing.expectError(error.IoFailure, harness.device().readBytes(0, &buffer));

    // O dispositivo respondeu: a conclusao prova que a DMA daquele pedido
    // terminou, e por isso a cadeia volta para a free list.
    try testing.expectEqual(@as(u32, 1), Device.completion_count);
    try testing.expectEqual(@as(u16, 8), harness.queue.freeCount());
    try testing.expectEqual(@as(u16, 0), harness.queue.inFlightCount());
    // Um erro de dispositivo e uma resposta, e nao uma falha inexplicavel:
    // o driver continua utilizavel e o dispositivo nao e contido.
    try testing.expect(!harness.driver.poisoned);
    try testing.expectEqual(containment.State.armed, harness.state.state);
    try testing.expect(harness.state.reason == null);
    try testing.expectEqual(@as(u32, 0), PciFunction.writes);

    // E o proximo pedido funciona.
    Device.mode = .complete;
    var recovered: [sector_size]u8 = @splat(0);
    try harness.device().readBytes(0, &recovered);
    try testing.expectEqualSlices(u8, Device.medium[0..sector_size], &recovered);
    try testing.expectEqual(@as(u16, 8), harness.queue.freeCount());
}

test "an unimplemented request status is reported as NotImplemented" {
    var harness: Harness = undefined;
    try bringUp(&harness);
    Device.mode = .unsupported;

    var buffer: [sector_size]u8 = @splat(0);
    try testing.expectError(error.NotImplemented, harness.device().readBytes(0, &buffer));
    try testing.expectEqual(@as(u16, 8), harness.queue.freeCount());
    try testing.expect(!harness.state.isQuarantined());
    try testing.expect(!harness.driver.poisoned);
}

test "an exhausted queue fails the request locally without containment" {
    var harness: Harness = undefined;
    try bringUp(&harness);

    // Oito descritores ocupados por cadeias que ninguem publica: o pedido
    // seguinte nao cabe na fila.
    const first = try harness.queue.allocateChain(3);
    const second = try harness.queue.allocateChain(3);
    _ = try harness.queue.allocateChain(2);
    try testing.expectEqual(@as(u16, 0), harness.queue.freeCount());

    var buffer: [sector_size]u8 = @splat(0);
    try testing.expectError(error.IoFailure, harness.device().readBytes(0, &buffer));
    // Nada foi publicado nem notificado, e o driver continua saudavel: o
    // pedido nunca chegou ao dispositivo, entao nao ha DMA a conter.
    try testing.expectEqual(@as(u16, 0), harness.queue.availableIndex());
    try testing.expectEqual(@as(u32, 0), Device.notify_count);
    try testing.expect(!harness.driver.poisoned);
    try testing.expect(!harness.state.isQuarantined());
    // A alocacao que falhou devolveu o que ja havia retirado.
    try testing.expectEqual(@as(u16, 0), harness.queue.freeCount());

    try harness.queue.release(first);
    try harness.queue.release(second);
    try testing.expectEqual(@as(u16, 6), harness.queue.freeCount());
    try harness.device().readBytes(0, &buffer);
    try testing.expectEqual(@as(u16, 6), harness.queue.freeCount());
    try testing.expectEqual(@as(u32, 1), Device.notify_count);
}

// ----------------------------------------------------------------------
// 3. Reset: confirmado e nao confirmado.
// ----------------------------------------------------------------------

test "an unconfirmed reset keeps the DMA memory retained" {
    var harness: Harness = undefined;
    try bringUp(&harness);

    // O cenario de `abandonVirtqueue`: o dispositivo recebe o reset e nao
    // confirma, porque ignora a escrita de zero em `device_status`.
    Device.confirm_reset = false;
    try testing.expectError(error.DeviceDidNotReset, harness.protocol.resetDevice());
    harness.state.noteReset(false);
    try testing.expect(harness.state.reset_attempted);
    try testing.expect(!harness.state.reset_confirmed);

    const outcome = harness.state.contain(.reset_unconfirmed);
    try testing.expectEqual(containment.Revocation.revoked, outcome);
    try testing.expectEqual(containment.Reason.reset_unconfirmed, harness.state.reason.?);
    try testing.expect(harness.state.isQuarantined());
    // A revogacao funcionou **e** o reset falhou, ao mesmo tempo. Sem a
    // confirmacao, nada volta ao alocador.
    try testing.expect(harness.state.revocationConfirmed());
    try testing.expect(!harness.ownership.canReturnToAllocator());
    try testing.expect(!harness.state.permitsMemoryRelease());
    try testing.expect(!harness.memoryMayReturnToAllocator());
    // O dispositivo continua com a fila habilitada e apontando para a memoria
    // que o kernel nao pode devolver.
    try testing.expect(Device.queueEnabled());
    try testing.expect(Device.queueDescAddress() != 0);
}

test "a confirmed reset releases the memory but never rearms the device" {
    var harness: Harness = undefined;
    try bringUp(&harness);
    Device.mode = .deferred;

    var buffer: [sector_size]u8 = @splat(0);
    try testing.expectError(error.IoTimeout, harness.device().readBytes(0, &buffer));
    try testing.expect(harness.state.isQuarantined());

    // Sem reset, a memoria esta retida.
    try testing.expect(!harness.memoryMayReturnToAllocator());

    // O dispositivo aceita o reset e a leitura de volta devolve zero.
    try harness.protocol.resetDevice();
    harness.ownership.deviceReleased();
    harness.state.noteReset(true);
    try testing.expect(harness.state.reset_confirmed);
    // Agora sim as duas condicoes do boot valem, e a liberacao passaria.
    try testing.expect(harness.ownership.canReturnToAllocator());
    try testing.expect(harness.state.permitsMemoryRelease());
    try testing.expect(harness.memoryMayReturnToAllocator());
    // O reset limpou o `queue_enable` do dispositivo (§2.4.2).
    try testing.expect(!Device.queueEnabled());

    // Mas o reset nao rearma: armar de novo nao devolve o dispositivo ao
    // estado operacional, e um novo ciclo de vida e recusado.
    harness.state.arm(pci_function.handle());
    try testing.expectEqual(containment.State.contained, harness.state.state);
    try testing.expect(harness.state.isQuarantined());
    try testing.expectError(error.DeviceQuarantined, harness.state.beginNewLifecycle(.{
        .queue_returned = true,
        .memory_released = true,
        .driver_detached = true,
    }));
    // O reset nao reabriu o driver.
    try testing.expect(harness.driver.poisoned);
    try testing.expectError(error.DeviceFailure, harness.device().readBytes(0, &buffer));
}

// ----------------------------------------------------------------------
// 4. Falhas depois de `DRIVER_OK`.
//
// O dispositivo respondeu `DRIVER_OK` e continua com a fila 0 habilitada: a
// partir daqui nenhuma falha de configuracao pode devolver a memoria nem
// desmapear o BAR. E o caminho que `bringUpVirtioFunction` trata como
// `configuration_failure`.
// ----------------------------------------------------------------------

test "a block configuration failure after DRIVER_OK contains the device" {
    const Fault = struct {
        name: []const u8,
        expected: block.Error,
        unstable_generation: bool = false,
        capacity: ?u64 = null,
        wrong_dma: bool = false,
    };

    const faults = [_]Fault{
        .{ .name = "unstable config generation", .expected = error.CapacityUnavailable, .unstable_generation = true },
        .{ .name = "empty capacity", .expected = error.CapacityUnavailable, .capacity = 0 },
        .{ .name = "queue memory not the one programmed", .expected = error.InvalidMemory, .wrong_dma = true },
    };

    for (faults) |fault| {
        var harness: Harness = undefined;
        try bringUpToDriverOk(&harness, .{});
        try testing.expectEqual(@as(u8, 0x0F), harness.protocol.status);

        if (fault.unstable_generation) Device.unstable_generation = true;
        if (fault.capacity) |capacity| Device.setCapacity(capacity);

        const dma_base = if (fault.wrong_dma) dma_physical + 0x1000 else dma_physical;
        const result = harness.driver.init(
            &harness.device_transport,
            &harness.queue,
            dma_base,
            Device.dma[0..],
            harness.queue.layout,
            harness.protocol.accepted,
            &harness.state,
        );
        if (result) |_| {
            std.debug.print("fault '{s}' was not refused\n", .{fault.name});
            return error.TestUnexpectedResult;
        } else |err| {
            try testing.expectEqual(fault.expected, err);
        }

        // O driver nao contem o dispositivo por conta propria: quem decide
        // isso e a orquestracao do boot, e o teste faz o mesmo.
        try testing.expect(!harness.state.isQuarantined());
        const outcome = harness.state.contain(.configuration_failure);
        try testing.expectEqual(containment.Revocation.revoked, outcome);
        try testing.expectEqual(containment.Reason.configuration_failure, harness.state.reason.?);
        try testing.expectEqual(containment.State.contained, harness.state.state);

        // A falha aconteceu depois de o dispositivo poder emitir DMA: a
        // memoria fica retida e o BAR continua necessario para o reset.
        try testing.expect(!harness.ownership.canReturnToAllocator());
        try testing.expect(!harness.state.permitsMemoryRelease());
        try testing.expect(!harness.memoryMayReturnToAllocator());
        try testing.expect(Device.queueEnabled());
    }
}

// ----------------------------------------------------------------------
// 5. Composicao PCI -> contencao -> retencao de DMA.
//
// O caminho completo, com os passos nomeados na ordem do boot. E a prova de
// que a revogacao do *bus master* nao autoriza, sozinha, devolver a memoria.
// ----------------------------------------------------------------------

test "the PCI, the containment and the DMA retention compose in that order" {
    var harness: Harness = undefined;
    try bringUp(&harness);

    // 1. PCI: as capabilities vieram dos bytes de configuracao, o BAR foi
    //    validado e cada regiao aponta para a faixa fisica correspondente.
    try testing.expectEqual(bar_index, harness.device_transport.bar);
    try testing.expectEqual(bar_physical + common_offset, harness.device_transport.regions.common.physical);
    try testing.expectEqual(bar_physical + notify_offset, harness.device_transport.regions.notify.physical);
    try testing.expectEqual(bar_physical + device_offset, harness.device_transport.regions.device.?.physical);
    // 2. Contencao: armada no ponto em que a memoria passa a ser do
    //    dispositivo, com o alvo da revogacao ja registrado.
    try testing.expectEqual(containment.State.armed, harness.state.state);
    try testing.expect(harness.state.bus_master != null);
    // 3. DMA: a posse foi transferida, e nenhuma das duas condicoes autoriza
    //    a liberacao.
    try testing.expect(!harness.ownership.canReturnToAllocator());
    try testing.expect(!harness.state.permitsMemoryRelease());
    try testing.expect(!harness.memoryMayReturnToAllocator());

    // Uma falha real do dispositivo, no meio de um pedido.
    Device.mode = .deferred;
    var buffer: [sector_size]u8 = @splat(0);
    try testing.expectError(error.IoTimeout, harness.device().readBytes(0, &buffer));

    // A revogacao foi confirmada pela leitura de volta do `Command`.
    try testing.expect(harness.state.revocationConfirmed());
    try testing.expectEqual(containment.State.contained, harness.state.state);
    try testing.expect(PciFunction.busMasterRevoked());
    // `Memory Space` sobrevive: o MMIO continua utilizavel para o reset.
    try testing.expect(PciFunction.memorySpacePreserved());
    // E mesmo assim a memoria nao volta: revogar nao e quiescencia. As duas
    // condicoes sao verificadas separadamente, porque a combinacao com `and`
    // esconderia uma delas se a outra ja recusasse a liberacao.
    try testing.expect(!harness.state.permitsMemoryRelease());
    try testing.expect(!harness.memoryMayReturnToAllocator());

    // O unico caminho de devolucao continua sendo o reset confirmado, e ele
    // tambem nao rearma o dispositivo.
    try harness.protocol.resetDevice();
    harness.ownership.deviceReleased();
    harness.state.noteReset(true);
    try testing.expect(harness.memoryMayReturnToAllocator());
    try testing.expect(harness.state.isQuarantined());
    try testing.expectError(error.DeviceQuarantined, harness.state.beginNewLifecycle(.{
        .queue_returned = true,
        .memory_released = true,
        .driver_detached = true,
    }));
}

test "an unconfirmed revocation still contains and still retains the memory" {
    var harness: Harness = undefined;
    try bringUp(&harness);
    // A funcao PCI descarta a limpeza do bit 2: a leitura de volta continua
    // com o *bus master* ligado.
    PciFunction.ignore_bus_master_write = true;

    Device.mode = .deferred;
    var buffer: [sector_size]u8 = @splat(0);
    try testing.expectError(error.IoTimeout, harness.device().readBytes(0, &buffer));

    // A falha de revogacao nao e mascarada e nao reabre o driver.
    try testing.expectEqual(containment.State.contained_unrevoked, harness.state.state);
    try testing.expectEqual(containment.Revocation.failed, harness.state.revocation.?);
    try testing.expect(!harness.state.revocationConfirmed());
    try testing.expect(harness.state.isQuarantined());
    try testing.expect(harness.driver.poisoned);
    try testing.expect(!harness.memoryMayReturnToAllocator());
    // O *bus master* continua ligado: o teste nao finge que a revogacao
    // aconteceu.
    try testing.expect(!PciFunction.busMasterRevoked());
    // E a revogacao nao e repetida por uma segunda chamada.
    _ = harness.state.contain(.timeout);
    try testing.expectEqual(@as(u32, 1), PciFunction.writes);
}

// ----------------------------------------------------------------------
// 6. Invariantes de vida util: o que nenhuma falha pode fazer.
// ----------------------------------------------------------------------

test "no injected failure returns queue memory to the allocator" {
    const Failure = enum { timeout, wrong_id, short_length, corrupt_status, notify_failure, device_error };
    const cases = [_]Failure{
        .timeout,
        .wrong_id,
        .short_length,
        .corrupt_status,
        .notify_failure,
        .device_error,
    };

    for (cases) |case| {
        var harness: Harness = undefined;
        try bringUp(&harness);

        const before = harness.snapshot();
        switch (case) {
            .timeout => Device.mode = .deferred,
            .wrong_id => Device.mode = .wrong_id,
            .short_length => Device.mode = .short_length,
            .corrupt_status => Device.mode = .corrupt_status,
            .notify_failure => Device.writeLe16(@intCast(pci_transport.offset.queue_notify_off), 0x800),
            .device_error => Device.mode = .device_error,
        }

        var buffer: [sector_size]u8 = @splat(0);
        harness.device().readBytes(0, &buffer) catch {};

        // Um pedido foi publicado e nada mais: nenhuma falha publica um
        // segundo pedido, e nenhuma devolve descritor a free list antes de o
        // dispositivo provar que parou de usar a cadeia.
        try testing.expectEqual(before.available + 1, harness.queue.availableIndex());
        try testing.expect(harness.queue.freeCount() <= before.free);

        if (case == .device_error) {
            // Uma conclusao valida com erro devolve a cadeia ao driver.
            try testing.expectEqual(before.free, harness.queue.freeCount());
            try testing.expectEqual(@as(u16, 0), harness.queue.inFlightCount());
            try testing.expect(!harness.state.isQuarantined());
        } else {
            // Toda falha inexplicavel contem o dispositivo e retem a memoria.
            try testing.expect(harness.state.isQuarantined());
            try testing.expect(!harness.memoryMayReturnToAllocator());
            try testing.expectEqual(before.free - 3, harness.queue.freeCount());
            // `inFlightCount` conta cadeias publicadas e nao consumidas:
            //   * sem conclusao (`timeout`, `notify_failure`), a cadeia
            //     continua publicada;
            //   * com o `id` de um elo do meio (`wrong_id`), ou com o `id` da
            //     cabeca e conteudo invalido (`short_length`, `corrupt_status`),
            //     o driver consumiu uma conclusao, mas nao liberou nada.
            const expected_chains: u16 = switch (case) {
                .timeout, .notify_failure => 1,
                .wrong_id, .short_length, .corrupt_status => 0,
                .device_error => unreachable,
            };
            try testing.expectEqual(expected_chains, harness.queue.inFlightCount());
            // No `wrong_id`, a cabeca continua marcada como posse do
            // dispositivo: a cadeia nao pode ser liberada, nem por engano.
            if (case == .wrong_id) {
                try testing.expect(harness.queue.isInFlight(0));
                try testing.expectError(error.DescriptorInFlight, harness.queue.release(0));
            }
        }
    }
}

test "a device that suppresses notifications is not notified and retains the chain" {
    var harness: Harness = undefined;
    try bringUp(&harness);
    // O dispositivo publica `no_notify` em `used.flags` (§2.7.8): o driver
    // deve confiar nele e nao escrever no registro de notificacao.
    Device.suppressNotifications(&harness.queue);
    try testing.expect(harness.queue.notificationsSuppressed());

    const before = harness.snapshot();
    var buffer: [sector_size]u8 = @splat(0);
    try testing.expectError(error.IoTimeout, harness.device().readBytes(0, &buffer));

    // Nenhuma notificacao foi escrita: o driver respeitou a flag.
    try testing.expectEqual(@as(u32, 0), Device.notify_count);
    // E o pedido ficou publicado, sem descritor devolvido.
    try testing.expectEqual(before.available + 1, harness.queue.availableIndex());
    try testing.expectEqual(before.free - 3, harness.queue.freeCount());
    try testing.expectEqual(@as(u16, 1), harness.queue.inFlightCount());
    try testing.expectEqual(containment.Reason.timeout, harness.state.reason.?);
    try testing.expect(!harness.memoryMayReturnToAllocator());
}
