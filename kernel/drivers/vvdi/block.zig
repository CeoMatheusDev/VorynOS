//************************************************************************//
//  block.zig                                                             //
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

//! Driver de bloco VirtIO 1.2 sobre o transporte PCI da VVDI.
//!
//! O driver recebe um transporte e uma split virtqueue já inicializados; a
//! descoberta PCI, a propriedade das páginas DMA e a ativação DRIVER_OK são
//! responsabilidades do chamador. A memória da fila fornecida precisa conter
//! espaço, após o layout da fila, para um cabeçalho de 16 bytes, um setor de
//! dados de 512 bytes e um byte de status. Ela permanece emprestada ao driver
//! durante toda a vida da fila.
//!
//! Cada operação síncrona publica exatamente uma cadeia e só retorna sucesso
//! após validar o ID, o comprimento usado e o status escritos pelo dispositivo.
//! Timeouts e conclusões inválidas envenenam a instância: a fila e o buffer
//! compartilhado não são reutilizados nem liberados, pois o dispositivo pode
//! ainda possuir referências a eles.
//!
//! Envenenar a instância é uma decisão local; ela não impede o dispositivo de
//! continuar emitindo DMA. Quando um `Containment` é fornecido em `init`, cada
//! envenenamento escala para o dispositivo: o *bus master* PCI é revogado e o
//! estado de contenção fica registrado com o motivo. Sem a estrutura, o driver
//! preserva exatamente o comportamento anterior.

const std = @import("std");
const block_api = @import("voryn_block");
const containment = @import("containment.zig");
const pci_transport = @import("pci_transport.zig");
const virtqueue = @import("virtqueue.zig");

pub const sector_size: u32 = 512;
pub const request_in: u32 = 0;
pub const request_out: u32 = 1;
pub const request_flush: u32 = 4;
pub const flush_feature: u64 = 1 << 9;
pub const status_ok: u8 = 0;
pub const status_io_error: u8 = 1;
pub const status_unsupported: u8 = 2;
pub const timeout_polls: u32 = 10_000_000;
pub const queue_capacity: u16 = 256;

const Queue = virtqueue.Queue(queue_capacity);

pub const Error = error{
    InvalidDevice,
    InvalidMemory,
    CapacityUnavailable,
    OutOfRange,
    InvalidRequest,
    QueueFailure,
    NotifyFailure,
    Timeout,
    InvalidCompletion,
    DeviceIo,
    Unsupported,
    DevicePoisoned,
};

/// VIRTIO_BLK_REQ header (§5.2.6), little-endian on the x86_64 target.
pub const RequestHeader = extern struct {
    request_type: u32,
    reserved: u32 = 0,
    sector: u64,
};

comptime {
    if (@sizeOf(RequestHeader) != 16) @compileError("virtio-blk header must be 16 bytes");
}

/// Buffer positions within the contiguous DMA allocation.
pub const BufferLayout = struct {
    header: usize,
    data: usize,
    status: usize,
    required: usize,

    pub fn compute(queue_bytes: usize) ?BufferLayout {
        const header = alignForward(queue_bytes, 16) orelse return null;
        const data = std.math.add(usize, header, @sizeOf(RequestHeader)) catch return null;
        const status = std.math.add(usize, data, sector_size) catch return null;
        const required = std.math.add(usize, status, 1) catch return null;
        return .{ .header = header, .data = data, .status = status, .required = required };
    }
};

/// Driver ativo sobre uma fila VirtIO previamente configurada.
pub const Driver = struct {
    transport: *pci_transport.Transport,
    queue: *Queue,
    dma_physical: u64,
    dma_virtual: []u8,
    layout: virtqueue.Layout,
    buffers: BufferLayout,
    sectors: u64,
    flush_supported: bool,
    /// Estado do dispositivo, quando o chamador fornece um. O ponteiro é
    /// emprestado e precisa sobreviver a esta instância, porque a contenção é
    /// consultada depois que o pedido que falhou já retornou. `null` mantém o
    /// comportamento anterior: a falha envenena só o driver.
    containment: ?*containment.Containment = null,
    poisoned: bool = false,
    lock: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),

    /// Lê a capacidade de 64 bits com a proteção de generation da configuração.
    /// Rejeita uma configuração instável ou uma capacidade vazia.
    pub fn init(
        self: *Driver,
        device_transport: *pci_transport.Transport,
        device_queue: *Queue,
        dma_physical: u64,
        dma_virtual: []u8,
        queue_layout: virtqueue.Layout,
        negotiated_features: u64,
        device_containment: ?*containment.Containment,
    ) Error!void {
        const buffers = BufferLayout.compute(queue_layout.total_size) orelse return error.InvalidMemory;
        if (dma_physical == 0 or dma_physical % virtqueue.descriptor_alignment != 0) return error.InvalidMemory;
        if (@intFromPtr(dma_virtual.ptr) % virtqueue.descriptor_alignment != 0) return error.InvalidMemory;
        if (dma_virtual.len < buffers.required or dma_virtual.len < queue_layout.total_size) return error.InvalidMemory;
        if (@intFromPtr(device_queue.memory.bytes.ptr) != @intFromPtr(dma_virtual.ptr) or
            device_queue.memory.bytes.len < queue_layout.total_size or
            device_queue.layout.total_size != queue_layout.total_size or
            device_queue.layout.size != queue_layout.size)
            return error.InvalidMemory;
        const dma_end = std.math.add(u64, dma_physical, buffers.required) catch return error.InvalidMemory;
        if (dma_end > 0x1_0000_0000) return error.InvalidMemory;
        if (device_transport.identification.device_type != .block or !device_transport.identification.modern_id)
            return error.InvalidDevice;
        if (device_queue.size != queue_layout.size or device_queue.memory.physical != dma_physical)
            return error.InvalidMemory;

        var sectors: ?u64 = null;
        var attempt: u8 = 0;
        while (attempt < 8) : (attempt += 1) {
            const before = device_transport.regions.common.read8(pci_transport.offset.config_generation) catch
                return error.CapacityUnavailable;
            var capacity_bytes: [8]u8 = undefined;
            device_transport.readDeviceConfig(0, &capacity_bytes) catch return error.CapacityUnavailable;
            const after = device_transport.regions.common.read8(pci_transport.offset.config_generation) catch
                return error.CapacityUnavailable;
            if (before == after) {
                var value: u64 = 0;
                for (capacity_bytes, 0..) |byte, index| value |= @as(u64, byte) << @intCast(index * 8);
                sectors = value;
                break;
            }
        }
        const capacity = sectors orelse return error.CapacityUnavailable;
        if (capacity == 0 or capacity > std.math.maxInt(u64) / @as(u64, sector_size))
            return error.CapacityUnavailable;

        self.* = .{
            .transport = device_transport,
            .queue = device_queue,
            .dma_physical = dma_physical,
            .dma_virtual = dma_virtual,
            .layout = queue_layout,
            .buffers = buffers,
            .sectors = capacity,
            .flush_supported = negotiated_features & flush_feature != 0,
            .containment = device_containment,
        };
    }

    pub fn device(self: *Driver) block_api.Device {
        return .{
            .ctx = self,
            .read = readCallback,
            .write = writeCallback,
            .sector_size = sector_size,
            .sector_count = self.sectors,
            .flush = if (self.flush_supported) flushCallback else null,
        };
    }

    /// Envia VIRTIO_BLK_T_FLUSH e aguarda a confirmação real do dispositivo.
    pub fn flush(self: *Driver) Error!void {
        self.lockQueue();
        defer self.unlockQueue();
        try self.requireHealthy();
        if (!self.flush_supported) return error.Unsupported;
        try self.submit(request_flush, 0, false, false);
    }

    fn readCallback(ctx: *anyopaque, lba: u64, count: usize, inside: usize, out: []u8) block_api.Error!void {
        const self: *Driver = @ptrCast(@alignCast(ctx));
        self.transfer(lba, count, inside, out, null) catch |err| return mapBlockError(err);
    }

    fn writeCallback(ctx: *anyopaque, lba: u64, count: usize, inside: usize, in: []const u8) block_api.Error!void {
        const self: *Driver = @ptrCast(@alignCast(ctx));
        self.transfer(lba, count, inside, null, in) catch |err| return mapBlockError(err);
    }

    fn flushCallback(ctx: *anyopaque) block_api.Error!void {
        const self: *Driver = @ptrCast(@alignCast(ctx));
        self.flush() catch |err| return mapBlockError(err);
    }

    fn transfer(
        self: *Driver,
        lba: u64,
        count: usize,
        inside: usize,
        out: ?[]u8,
        input: ?[]const u8,
    ) Error!void {
        if (count != 1 or (out == null) == (input == null)) return error.InvalidRequest;
        const length = if (out) |slice| slice.len else input.?.len;
        if (length == 0 or inside >= sector_size or length > sector_size - inside) return error.InvalidRequest;
        if (lba >= self.sectors) return error.OutOfRange;

        self.lockQueue();
        defer self.unlockQueue();
        try self.requireHealthy();

        const sector_buffer = self.dma_virtual[self.buffers.data .. self.buffers.data + sector_size];
        if (input) |bytes| {
            // Partial-sector writes preserve the unmodified bytes by reading
            // the real sector first; a complete sector needs no read.
            if (inside != 0 or bytes.len != sector_size) {
                try self.submit(request_in, lba, true, true);
            }
            @memcpy(sector_buffer[inside .. inside + bytes.len], bytes);
            try self.submit(request_out, lba, false, true);
        } else {
            try self.submit(request_in, lba, true, true);
            @memcpy(out.?[0..], sector_buffer[inside .. inside + length]);
        }
    }

    /// Submit one request and wait for a validated used-ring completion.
    /// `keep_data` is false only for the header/status-only flush request.
    fn submit(self: *Driver, kind: u32, lba: u64, device_writes_data: bool, keep_data: bool) Error!void {
        try self.requireHealthy();
        if (lba >= self.sectors and kind != request_flush) return error.OutOfRange;

        const head = self.queue.allocateChain(if (keep_data) 3 else 2) catch return error.QueueFailure;
        const header_index = head;
        const data_index = self.queue.descriptor(header_index) catch {
            self.queue.release(head) catch {};
            return error.QueueFailure;
        };
        const data_id = data_index.next;
        const status_id = if (keep_data)
            (self.queue.descriptor(data_id) catch {
                self.queue.release(head) catch {};
                return error.QueueFailure;
            }).next
        else
            data_id;

        const header = RequestHeader{ .request_type = kind, .reserved = 0, .sector = lba };
        const header_ptr: *RequestHeader = @ptrCast(@alignCast(self.dma_virtual.ptr + self.buffers.header));
        header_ptr.* = header;
        const status_ptr: *volatile u8 = @ptrCast(self.dma_virtual.ptr + self.buffers.status);
        status_ptr.* = 0xFF;

        const header_phys = std.math.add(u64, self.dma_physical, self.buffers.header) catch {
            self.queue.release(head) catch {};
            return error.InvalidMemory;
        };
        const status_phys = std.math.add(u64, self.dma_physical, self.buffers.status) catch {
            self.queue.release(head) catch {};
            return error.InvalidMemory;
        };
        self.queue.setBuffer(header_index, header_phys, @sizeOf(RequestHeader)) catch {
            self.queue.release(head) catch {};
            return error.QueueFailure;
        };
        self.queue.setBuffer(status_id, status_phys, 1) catch {
            self.queue.release(head) catch {};
            return error.QueueFailure;
        };
        self.queue.setWritable(status_id, true) catch {
            self.queue.release(head) catch {};
            return error.QueueFailure;
        };

        if (keep_data) {
            const data_phys = std.math.add(u64, self.dma_physical, self.buffers.data) catch {
                self.queue.release(head) catch {};
                return error.InvalidMemory;
            };
            self.queue.setBuffer(data_id, data_phys, sector_size) catch {
                self.queue.release(head) catch {};
                return error.QueueFailure;
            };
            self.queue.setWritable(data_id, device_writes_data) catch {
                self.queue.release(head) catch {};
                return error.QueueFailure;
            };
        }

        self.queue.publish(head) catch {
            self.queue.release(head) catch {};
            return error.QueueFailure;
        };

        // Respect the device's no-notify flag from the used ring. Otherwise
        // notifyQueue validates the selected queue and MMIO range.
        if (!self.queue.notificationsSuppressed()) {
            self.transport.notifyQueue(0) catch {
                self.quarantine(.notify_failure);
                return error.NotifyFailure;
            };
        }

        var remaining = timeout_polls;
        var completion: ?virtqueue.Used = null;
        while (remaining > 0) : (remaining -= 1) {
            const used = self.queue.pollUsed() catch {
                self.quarantine(.invalid_completion);
                return error.InvalidCompletion;
            };
            if (used) |entry| {
                completion = entry;
                break;
            }
            std.atomic.spinLoopHint();
        }
        const used = completion orelse {
            // Do not release descriptors or reuse the DMA scratch area: the
            // device may still own every address in this request chain.
            self.quarantine(.timeout);
            return error.Timeout;
        };
        const device_status = status_ptr.*;
        if (!validCompletion(head, used, device_status, keep_data, device_writes_data)) {
            self.quarantine(.invalid_completion);
            return error.InvalidCompletion;
        }

        if (device_status == status_ok) {
            self.queue.release(head) catch {
                self.quarantine(.invalid_completion);
                return error.InvalidCompletion;
            };
            return;
        }

        // The used entry proves DMA has stopped for this request. Retiring the
        // descriptors is safe, but a device error still fails the operation.
        self.queue.release(head) catch {
            self.quarantine(.invalid_completion);
            return error.InvalidCompletion;
        };
        return switch (device_status) {
            status_io_error => error.DeviceIo,
            status_unsupported => error.Unsupported,
            else => blk: {
                self.quarantine(.invalid_completion);
                break :blk error.InvalidCompletion;
            },
        };
    }

    /// Envenena a instância e escala a falha para o dispositivo.
    ///
    /// A ordem importa: o driver se fecha primeiro, e só depois a contenção é
    /// aplicada. Uma falha dentro da revogação não pode deixar o driver
    /// aceitando pedidos novos, e `contain` é idempotente e não espera, então
    /// o caminho de erro continua limitado.
    fn quarantine(self: *Driver, why: containment.Reason) void {
        self.poisoned = true;
        if (self.containment) |state| _ = state.contain(why);
    }

    fn requireHealthy(self: *const Driver) Error!void {
        if (self.poisoned) return error.DevicePoisoned;
    }

    fn lockQueue(self: *Driver) void {
        while (self.lock.swap(1, .acquire) != 0) {
            while (self.lock.load(.monotonic) != 0) std.atomic.spinLoopHint();
        }
    }

    fn unlockQueue(self: *Driver) void {
        self.lock.store(0, .release);
    }
};

fn mapBlockError(err: anyerror) block_api.Error {
    return switch (err) {
        error.OutOfRange => error.OutOfRange,
        error.InvalidRequest => error.InvalidRequest,
        error.Unsupported => error.NotImplemented,
        error.Timeout => error.IoTimeout,
        error.DevicePoisoned, error.InvalidCompletion => error.DeviceFailure,
        else => error.IoFailure,
    };
}

fn alignForward(value: usize, alignment: usize) ?usize {
    const mask = alignment - 1;
    const sum = std.math.add(usize, value, mask) catch return null;
    return sum & ~mask;
}

const testing = std.testing;

test "VirtIO Block request header layout and operation identifiers follow the spec" {
    try testing.expectEqual(@as(usize, 16), @sizeOf(RequestHeader));
    try testing.expectEqual(@as(u32, 0), request_in);
    try testing.expectEqual(@as(u32, 1), request_out);
    try testing.expectEqual(@as(u32, 4), request_flush);
    try testing.expectEqual(@as(u64, 1 << 9), flush_feature);
}

test "request DMA scratch layout is aligned and overflow-safe" {
    const buffers = BufferLayout.compute(0x2031).?;
    try testing.expectEqual(@as(usize, 0x2040), buffers.header);
    try testing.expectEqual(@as(usize, 0x2050), buffers.data);
    try testing.expectEqual(@as(usize, 0x2250), buffers.status);
    try testing.expectEqual(@as(usize, 0x2251), buffers.required);
    try testing.expect(BufferLayout.compute(std.math.maxInt(usize)) == null);
}

const TestQueue = Queue;
var test_queue_memory: [8192]u8 align(4096) = @splat(0);

test "VirtIO block requests use a three-descriptor header-data-status chain" {
    const queue_size: u16 = 8;
    var queue = try TestQueue.init(.{
        .physical = 0x3000_0000,
        .bytes = test_queue_memory[0..],
    }, queue_size);
    const head = try queue.allocateChain(3);
    const first = try queue.descriptor(head);
    const second = try queue.descriptor(first.next);
    const third = try queue.descriptor(second.next);
    try testing.expectEqual(@as(u16, virtqueue.descriptor_flags.next), first.flags);
    try testing.expectEqual(@as(u16, virtqueue.descriptor_flags.next), second.flags);
    try testing.expectEqual(@as(u16, 0), third.flags);
    try testing.expectEqual(virtqueue.no_descriptor, third.next);
    try queue.setBuffer(head, 0x3100_0000, @sizeOf(RequestHeader));
    try queue.setBuffer(first.next, 0x3100_0010, sector_size);
    try queue.setWritable(first.next, true);
    try queue.setBuffer(second.next, 0x3100_0210, 1);
    try queue.setWritable(second.next, true);
    try testing.expectEqual(@as(u64, 0x3100_0000), (try queue.descriptor(head)).address);
    try testing.expectEqual(@as(u64, 0x3100_0010), (try queue.descriptor(first.next)).address);
    try testing.expectEqual(@as(u64, 0x3100_0210), (try queue.descriptor(second.next)).address);
}

test "descriptors are not recycled before a valid used-ring completion" {
    var queue = try TestQueue.init(.{
        .physical = 0x3000_0000,
        .bytes = test_queue_memory[0..],
    }, 8);
    const head = try queue.allocateChain(3);
    try queue.setBuffer(head, 0x3100_0000, @sizeOf(RequestHeader));
    const data_id = (try queue.descriptor(head)).next;
    try queue.setBuffer(data_id, 0x3100_0010, sector_size);
    try queue.setWritable(data_id, true);
    const status_id = (try queue.descriptor(data_id)).next;
    try queue.setBuffer(status_id, 0x3100_0210, 1);
    try queue.setWritable(status_id, true);
    try queue.publish(head);
    try testing.expectError(error.DescriptorInFlight, queue.release(head));

    const used = queue.layout.used_offset;
    std.mem.writeInt(u32, queue.memory.bytes[used + 4 ..][0..4], head, .little);
    std.mem.writeInt(u32, queue.memory.bytes[used + 8 ..][0..4], sector_size + 1, .little);
    std.mem.writeInt(u16, queue.memory.bytes[used + 2 ..][0..2], 1, .little);
    const completed = (try queue.pollUsed()).?;
    try testing.expectEqual(head, completed.head);
    try queue.release(head);
    try testing.expectEqual(@as(u16, 8), queue.freeCount());
    _ = try queue.allocateChain(3);
}

test "descriptor DMA permissions distinguish IN, OUT, and status" {
    try testing.expect(descriptorWritable(request_in, true, false));
    try testing.expect(!descriptorWritable(request_out, true, false));
    try testing.expect(descriptorWritable(request_out, false, true));
    try testing.expect(!descriptorWritable(request_in, false, false));
}

fn descriptorWritable(kind: u32, data_descriptor: bool, status_descriptor: bool) bool {
    if (status_descriptor) return true;
    if (!data_descriptor) return false;
    return kind == request_in;
}

test "sector limits reject overflow without wrapping" {
    try testing.expect(validateSectorRange(10, 9, 1));
    try testing.expect(!validateSectorRange(10, 9, 0));
    try testing.expect(!validateSectorRange(10, 10, 1));
    try testing.expect(!validateSectorRange(10, std.math.maxInt(u64), 2));
}

fn validateSectorRange(capacity: u64, lba: u64, count: u64) bool {
    return count != 0 and lba < capacity and count <= capacity - lba;
}

test "VirtIO block status values map only documented success and failures" {
    try testing.expectEqual(@as(?Error, null), statusError(status_ok));
    try testing.expectEqual(@as(?Error, error.DeviceIo), statusError(status_io_error));
    try testing.expectEqual(@as(?Error, error.Unsupported), statusError(status_unsupported));
    try testing.expectEqual(@as(?Error, error.InvalidCompletion), statusError(0xFF));
}

fn statusError(value: u8) ?Error {
    return switch (value) {
        status_ok => null,
        status_io_error => error.DeviceIo,
        status_unsupported => error.Unsupported,
        else => error.InvalidCompletion,
    };
}

fn validCompletion(
    head: u16,
    used: virtqueue.Used,
    device_status: u8,
    has_data: bool,
    device_writes_data: bool,
) bool {
    if (used.head != head or
        (device_status != status_ok and device_status != status_io_error and device_status != status_unsupported)) return false;
    const expected: u32 = if (device_status == status_ok and has_data and device_writes_data)
        sector_size + 1
    else
        1;
    return used.length == expected;
}

test "used completions validate request identity, byte count and status" {
    const read_success = virtqueue.Used{ .head = 3, .length = sector_size + 1 };
    try testing.expect(validCompletion(3, read_success, status_ok, true, true));

    // Identidade: o `id` devolvido precisa ser a cabeca publicada.
    try testing.expect(!validCompletion(4, read_success, status_ok, true, true));

    // Comprimento sozinho, com status valido dos dois lados: 512 bytes para
    // uma leitura de 512 + 1 nao serve, e 1 serve para um erro do dispositivo.
    try testing.expect(!validCompletion(3, .{ .head = 3, .length = 512 }, status_ok, true, true));
    try testing.expect(validCompletion(3, .{ .head = 3, .length = 1 }, status_io_error, true, true));

    // Status sozinho: para um status fora da lista documentada, a regra de
    // comprimento ja espera `1`. Com esse comprimento, a unica razao para
    // recusar e a lista de status — se ela sair, este caso passa a ser aceito.
    // E o par que a falha `corrupt_status` do dispositivo simulado reproduz.
    try testing.expect(!validCompletion(3, .{ .head = 3, .length = 1 }, 0xFF, true, true));

    // O mesmo status com o comprimento de uma leitura bem-sucedida e recusado
    // pela regra de comprimento, nao pela lista: este par nao isola a
    // validacao de status e nao deve ser usado como prova dela.
    try testing.expect(!validCompletion(3, .{ .head = 3, .length = sector_size + 1 }, 0xFF, true, true));
}

// Cobre apenas `Driver.quarantine` e `Driver.requireHealthy`: nao ha `init`,
// transporte nem fila aqui. O nome diz o que o teste faz; os caminhos com
// dispositivo de verdade estao em `fault_injection.zig`.
test "quarantine closes the gate without a transport or a queue" {
    var driver: Driver = undefined;
    driver.poisoned = false;
    driver.containment = null;

    driver.quarantine(.timeout);
    try testing.expect(driver.poisoned);
    // The same gate is checked by read/write and FLUSH before a later request
    // can touch the queue or DMA scratch memory.
    try testing.expectError(error.DevicePoisoned, driver.requireHealthy());

    // Irreversivel: um segundo motivo nao reabre o portao.
    driver.quarantine(.invalid_completion);
    try testing.expectError(error.DevicePoisoned, driver.requireHealthy());
}

/// Alvo de revogação observável, sem portas de I/O.
const FakeRevoker = struct {
    confirm: bool = true,
    attempts: u32 = 0,

    fn revoke(ctx: *anyopaque) bool {
        const self: *FakeRevoker = @ptrCast(@alignCast(ctx));
        self.attempts += 1;
        return self.confirm;
    }

    fn handle(self: *FakeRevoker) containment.BusMaster {
        return .{ .ctx = @ptrCast(self), .revoke = revoke };
    }
};

test "a driver failure escalates to the device containment with its reason" {
    var revoker: FakeRevoker = .{ .confirm = true };
    var state: containment.Containment = .{};
    state.arm(revoker.handle());

    var driver: Driver = undefined;
    driver.poisoned = false;
    driver.containment = &state;

    driver.quarantine(.timeout);

    // O driver se fecha e o dispositivo é contido: as duas coisas acontecem.
    try testing.expectError(error.DevicePoisoned, driver.requireHealthy());
    try testing.expect(state.isQuarantined());
    try testing.expectEqual(containment.Reason.timeout, state.reason.?);
    try testing.expectEqual(@as(u32, 1), revoker.attempts);
    // Revogar não libera a memória que o dispositivo já recebeu.
    try testing.expect(!state.permitsMemoryRelease());
}

test "a failed revocation still leaves the driver poisoned" {
    var revoker: FakeRevoker = .{ .confirm = false };
    var state: containment.Containment = .{};
    state.arm(revoker.handle());

    var driver: Driver = undefined;
    driver.poisoned = false;
    driver.containment = &state;

    driver.quarantine(.invalid_completion);

    // A falha de revogação não pode reabrir o caminho de pedidos.
    try testing.expectError(error.DevicePoisoned, driver.requireHealthy());
    try testing.expectEqual(containment.State.contained_unrevoked, state.state);
    try testing.expect(!state.revocationConfirmed());
    try testing.expect(!state.permitsMemoryRelease());
}

test "repeated failures keep the first containment reason" {
    var revoker: FakeRevoker = .{ .confirm = true };
    var state: containment.Containment = .{};
    state.arm(revoker.handle());

    var driver: Driver = undefined;
    driver.poisoned = false;
    driver.containment = &state;

    driver.quarantine(.notify_failure);
    driver.quarantine(.timeout);
    driver.quarantine(.invalid_completion);

    try testing.expectEqual(containment.Reason.notify_failure, state.reason.?);
    try testing.expectEqual(@as(u32, 1), revoker.attempts);
}

test "a driver without containment keeps the previous behaviour" {
    var driver: Driver = undefined;
    driver.poisoned = false;
    driver.containment = null;
    driver.quarantine(.timeout);
    try testing.expectError(error.DevicePoisoned, driver.requireHealthy());
    try testing.expect(driver.poisoned);
}
