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

/// Escreve um DWORD no espaco de configuracao PCI.
///
/// Duas operacoes escrevem neste espaco: a sondagem de tamanho de BAR, que
/// altera o registrador de BAR de um dispositivo que o kernel ainda nao
/// conduz, e a revogacao de *bus master* (`setBusMaster`), que altera o
/// registrador `Command` de um dispositivo em contencao. O par de portas e
/// serializado pelo mesmo lock da leitura.
pub fn writeConfigDword(bus: u8, device: u8, function: u8, offset: u8, value: u32) void {
    if (!isValidDwordOffset(offset)) return;

    const flags = config_lock.lockIrqSave();
    defer config_lock.unlockIrqRestore(flags);

    port.outl(PCI_CONFIG_ADDRESS, configAddress(bus, device, function, offset));
    port.outl(PCI_CONFIG_DATA, value);
}

fn readConfigDwordLocked(bus: u8, device: u8, function: u8, offset: u8) u32 {
    port.outl(PCI_CONFIG_ADDRESS, configAddress(bus, device, function, offset));
    return port.inl(PCI_CONFIG_DATA);
}

fn writeConfigDwordLocked(bus: u8, device: u8, function: u8, offset: u8, value: u32) void {
    port.outl(PCI_CONFIG_ADDRESS, configAddress(bus, device, function, offset));
    port.outl(PCI_CONFIG_DATA, value);
}

/// Acesso de leitura e escrita a um espaco de configuracao.
///
/// A sonda de tamanho de BAR e escrita uma unica vez e roda em dois contextos:
/// nas portas `0xCF8`/`0xCFC` do kernel e numa imagem em memoria, no host. A
/// interface e o que permite testar a logica — mascara, BAR de 64 bits e
/// restauracao — sem tocar em hardware.
pub const ConfigAccess = struct {
    ctx: *anyopaque,
    read_fn: *const fn (ctx: *anyopaque, offset: u8) u32,
    write_fn: *const fn (ctx: *anyopaque, offset: u8, value: u32) void,

    fn read(self: ConfigAccess, offset: u8) u32 {
        return self.read_fn(self.ctx, offset);
    }

    fn write(self: ConfigAccess, offset: u8, value: u32) void {
        self.write_fn(self.ctx, offset, value);
    }
};

/// Alvo da sonda quando o acesso sao as portas do kernel.
///
/// O lock de configuracao e tomado antes da escrita, e o valor so existe
/// enquanto ele esta tomado: duas sondagens nunca se intercalam.
var probe_target: [3]u8 = .{ 0, 0, 0 };

fn probeRead(_: *anyopaque, offset: u8) u32 {
    return readConfigDwordLocked(probe_target[0], probe_target[1], probe_target[2], offset);
}

fn probeWrite(_: *anyopaque, offset: u8, value: u32) void {
    writeConfigDwordLocked(probe_target[0], probe_target[1], probe_target[2], offset, value);
}

/// Sondagem dos tamanhos dos BARs de uma funcao.
///
/// O tamanho de um BAR nao esta escrito em lugar nenhum do espaco de
/// configuracao: ele e descoberto escrevendo todos os bits de endereco em 1 e
/// lendo a mascara que o dispositivo devolve. A sequencia inteira acontece sob
/// o lock, porque duas sondagens intercaladas em CPUs diferentes deixariam o
/// BAR com a mascara de uma e a leitura da outra.
///
/// A metade alta de um BAR de 64 bits e sondada e restaurada junto com a
/// baixa, e o par consome dois indices. Um BAR ausente (todos os bits em zero)
/// nao tem tamanho e fica nulo.
pub fn probeBarSizes(bus: u8, device: u8, function: u8) BarSizes {
    const flags = config_lock.lockIrqSave();
    defer config_lock.unlockIrqRestore(flags);

    probe_target = .{ bus, device, function };
    return probeBarSizesWith(.{
        .ctx = @ptrCast(&probe_target),
        .read_fn = probeRead,
        .write_fn = probeWrite,
    });
}

/// Corpo da sondagem, independente de onde o espaco de configuracao mora.
///
/// Nao toma o lock: quem chama garante a exclusao. E essa separacao que deixa o
/// teste usar uma imagem em memoria com a mesma logica que roda no kernel.
pub fn probeBarSizesWith(access: ConfigAccess) BarSizes {
    var sizes: BarSizes = @splat(null);

    var index: usize = 0;
    while (index < bar_count) : (index += 1) {
        const offset: u8 = bar_register_base + @as(u8, @intCast(index)) * 4;
        const low = access.read(offset);
        if (low == 0 or low == 0xFFFF_FFFF) continue;

        const wide = barKind(low) == .memory64;
        var high: u32 = 0;
        if (wide) {
            if (index + 1 >= bar_count) continue;
            high = access.read(offset + 4);
        }

        access.write(offset, 0xFFFF_FFFF);
        if (wide) access.write(offset + 4, 0xFFFF_FFFF);

        const mask_low = access.read(offset);
        const mask_high = if (wide) access.read(offset + 4) else 0;

        access.write(offset, low);
        if (wide) access.write(offset + 4, high);

        sizes[index] = barSize(mask_low, mask_high);
        if (wide) index += 1;
    }
    return sizes;
}

/// Tamanho de cada um dos seis BARs, ou nulo quando o BAR nao existe ou a
/// mascara nao descreve um tamanho potencia de dois.
pub const BarSizes = [bar_count]?u64;

// ----------------------------------------------------------------------
// Bus master (registrador `Command`, bit 2).
//
// O kernel nao configura o bit *bus master* em lugar algum: o estado que ele
// encontra ao receber o controle e o que o firmware deixou. No caminho UEFI,
// o `PciBus` do OVMF habilita `Memory Space` e `Bus Master` da funcao antes de
// `ExitBootServices`, e o VorynOS herda esse estado — o MMIO do BAR funciona
// sem que nenhuma escrita no `Command` tenha acontecido.
//
// A consequencia pratica e dupla:
//
//   * revogar o bit nao quebra o MMIO, porque quem autoriza a decodificacao de
//     memoria e o bit 1, nao o bit 2; por isso a revogacao preserva todos os
//     outros bits, inclusive `Memory Space`, e o kernel mantem o caminho para
//     tentar um reset;
//   * revogar o bit nao prova que o dispositivo parou de acessar a memoria.
//     Nao existe, no PCI, operacao que confirme a drenagem de transacoes ja
//     emitidas. A revogacao impede que *novas* transacoes sejam iniciadas; o
//     que ja foi despachado pode continuar chegando.
// ----------------------------------------------------------------------

/// Resultado de uma escrita no bit *bus master*.
///
/// O tipo e explicito para que um chamador nao trate "escrevi" como "revoguei":
/// a leitura de volta e o unico dado que existe, e ela pode divergir.
pub const BusMasterChange = union(enum) {
    /// O valor foi relido e o bit esta no estado pedido; os bits alheios
    /// continuam iguais aos que a funcao apresentava.
    confirmed: struct { before: u16, after: u16 },
    /// A funcao respondeu, mas nao devolveu o valor escrito: o pedido nao
    /// pode ser considerado aplicado.
    unconfirmed: struct { before: u16, after: u16 },
    /// O espaco de configuracao devolveu todos os bits em um: nao ha funcao
    /// naquele endereco, e nao existe valor a interpretar.
    absent,

    /// True somente quando a leitura de volta confirmou o pedido.
    pub fn isConfirmed(self: BusMasterChange) bool {
        return switch (self) {
            .confirmed => true,
            .unconfirmed, .absent => false,
        };
    }
};

/// Valor do `Command` com o bit *bus master* ligado ou desligado.
///
/// Nenhum outro bit muda: `Memory Space`, `I/O Space`, paridade, `SERR` e
/// `INTx Disable` sao preservados exatamente como foram lidos.
pub fn commandWithBusMaster(current: u16, enabled: bool) u16 {
    return if (enabled)
        current | command_bus_master
    else
        current & ~command_bus_master;
}

/// Liga ou desliga o bit *bus master* e verifica o resultado pela leitura.
///
/// A escrita grava apenas os 16 bits baixos do DWORD de 0x04; a metade alta
/// (`Status`) sai zerada de proposito, porque seus bits sao
/// *read/write-1-to-clear* e um 1 acidental apagaria um erro registrado.
///
/// A operacao e idempotente: pedir o estado que a funcao ja apresenta nao
/// escreve nada e devolve `confirmed` com `before == after`.
///
/// Uma funcao ausente (`0xFFFF_FFFF`) devolve `absent`. Nao ha tentativa de
/// escrever nela, e o chamador obtem uma resposta que nao se confunde com
/// "revogado".
///
/// Nao toma o lock: quem chama garante a exclusao, como em
/// `probeBarSizesWith`. O par de portas `CONFIG_ADDRESS`/`CONFIG_DATA` e unico
/// para a maquina, e duas operacoes intercaladas escreveriam o `Command` de um
/// dispositivo e leriam o de outro. No kernel a entrada serializada e
/// `setBusMaster`; o teste de host usa esta forma direta sobre uma imagem.
pub fn setBusMasterWith(access: ConfigAccess, enabled: bool) BusMasterChange {
    const before_dword = access.read(command_offset);
    if (before_dword == 0xFFFF_FFFF) return .absent;

    const before: u16 = @truncate(before_dword);
    const desired = commandWithBusMaster(before, enabled);
    if (desired == before) {
        const unchanged: BusMasterChange = .{ .confirmed = .{ .before = before, .after = before } };
        return unchanged;
    }

    access.write(command_offset, @as(u32, desired));

    const after_dword = access.read(command_offset);
    if (after_dword == 0xFFFF_FFFF) return .absent;

    const after: u16 = @truncate(after_dword);
    const bus_master_ok = (after & command_bus_master) == (desired & command_bus_master);
    // O bit de decodificacao de memoria nao e alvo desta operacao. Se ele
    // tivesse mudado, o MMIO do dispositivo deixaria de responder, e o kernel
    // perderia o caminho para tentar um reset: o pedido nao pode ser dado
    // como aplicado.
    const memory_space_ok = (after & command_memory_space) == (before & command_memory_space);
    if (!bus_master_ok or !memory_space_ok) {
        const rejected: BusMasterChange = .{ .unconfirmed = .{ .before = before, .after = after } };
        return rejected;
    }

    const applied: BusMasterChange = .{ .confirmed = .{ .before = before, .after = after } };
    return applied;
}

/// Revoga (ou restaura) o *bus master* da funcao, sob o lock de configuracao.
///
/// O alvo fica em `probe_target` porque `ConfigAccess` nao carrega contexto
/// proprio; o lock e o mesmo de `probeBarSizes`, entao as duas operacoes nunca
/// se intercalam sobre o par `CONFIG_ADDRESS`/`CONFIG_DATA`.
pub fn setBusMaster(bus: u8, device: u8, function: u8, enabled: bool) BusMasterChange {
    const flags = config_lock.lockIrqSave();
    defer config_lock.unlockIrqRestore(flags);

    probe_target = .{ bus, device, function };
    return setBusMasterWith(.{
        .ctx = @ptrCast(&probe_target),
        .read_fn = probeRead,
        .write_fn = probeWrite,
    }, enabled);
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

/// Offset do registrador `Command` do cabecalho PCI (16 bits).
///
/// O DWORD em 0x04 carrega dois registradores: `Command` nos 16 bits baixos e
/// `Status` nos altos. Eles nao podem ser escritos como se fossem um valor
/// unico: os bits de `Status` sao *read/write-1-to-clear*, e devolver 1 a eles
/// apagaria um erro registrado pelo dispositivo (paridade, *target abort*) que
/// o kernel nunca chegou a ler.
pub const command_offset: u8 = 0x04;

/// Bit 2 do `Command`: a funcao pode iniciar transacoes como *bus master*.
///
/// E o bit que autoriza o dispositivo a emitir DMA. Apenas desliga-lo nao
/// devolve ao driver prova alguma sobre transacoes ja emitidas: a especificacao
/// PCI nao define drenagem, e o *bus master* habilitado durante uma falha
/// permite que o dispositivo continue escrevendo na memoria do kernel.
pub const command_bus_master: u16 = 0x0004;

/// Bit 1 do `Command`: a funcao decodifica acessos de memoria.
///
/// E o que mantem o MMIO do BAR do dispositivo alcancavel. Revogar o *bus
/// master* nao pode desligar este bit, ou o kernel perderia o unico caminho
/// para tentar um reset.
pub const command_memory_space: u16 = 0x0002;

/// Bit 4 do status: a funcao possui uma lista de capabilities.
pub const status_capabilities: u16 = 0x0010;

/// Primeiro offset possivel de uma capability. O cabecalho PCI (identificacao,
/// BARs, ponteiro para a lista) ocupa os offsets 0x00 a 0x3F.
pub const first_capability_offset: u8 = 0x40;

/// Identificador de capability vendor-specific, usado pelo VirtIO moderno.
pub const capability_vendor_specific: u8 = 0x09;

/// True quando o byte 2 da capability e o tamanho declarado (`cap_len`).
///
/// O cabecalho comum de uma capability tem dois bytes: o identificador e o
/// ponteiro para a proxima. O byte de tamanho so existe nos formatos que o
/// definem; nos outros, o offset 2 pertence a um registrador da propria
/// capability:
///
///   * 0x10 (PCI Express): inicio do PCI Express Capabilities Register. Um
///     endpoint declara 0x00 ali;
///   * 0x11 (MSI-X) e 0x05 (MSI): o Message Control, com o numero de vetores.
///
/// Ler o tamanho nesses offsets produz um valor sem significado, e foi assim
/// que o disco do QEMU (virtio-blk transicional no q35) foi recusado como
/// truncado antes desta correcao: a capability PCI Express declara 0x00 no
/// offset 2.
///
/// A resposta e afirmativa apenas para o identificador cujo formato este
/// modulo interpreta, a capability vendor-specific (0x09), que e a que o
/// VirtIO moderno usa. Um identificador desconhecido e percorrido sem
/// validacao de tamanho: validar um byte que pode ser um registrador
/// recusaria dispositivos corretos, e o percurso continua limitado pela
/// validacao de ponteiro, pelo mapa de offsets visitados e pelo fim do espaco
/// de configuracao.
pub fn declaresLength(id: u8) bool {
    return id == capability_vendor_specific;
}

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
    /// Tamanho declarado pelo campo `cap_len`, ou null quando o formato da
    /// capability nao tem esse campo (`declaresLength`).
    length: ?u8,
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
/// Cada passo valida o ponteiro, o identificador e, quando o formato da
/// capability declara um tamanho, o `cap_len`; um offset ja visitado e
/// recusado. A deteccao de ciclo usa um mapa de bits dos
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

        if (id == 0x00 or id == 0xFF) return error.InvalidCapabilityId;

        // O offset 2 so e o tamanho declarado nas capabilities que tem esse
        // campo; nos outros ele e o primeiro byte de um registrador e nao
        // pode ser validado como tamanho.
        var length: ?u8 = null;
        if (declaresLength(id)) {
            const declared = self.reader.readByte(offset + 2);
            if (declared < capability_header_size) return error.TruncatedCapability;
            if (@as(usize, offset) + @as(usize, declared) > config_space_size) {
                return error.TruncatedCapability;
            }
            length = declared;
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
    try std.testing.expectEqual(@as(u8, 16), first.length.?);

    const second = (try iterator.next()).?;
    try std.testing.expectEqual(@as(u8, 0x01), second.id);
    try std.testing.expectEqual(@as(u8, 0x50), second.offset);
    // A capability de gerenciamento de energia nao declara tamanho: o byte 2
    // dela e o inicio do PMCSR.
    try std.testing.expect(second.length == null);

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

test "pci capabilities that have no length field are not validated as truncated" {
    // Layout real do disco do QEMU (virtio-blk transicional no q35): a
    // capability PCI Express declara 0x00 no offset 2, porque ali comeca o PCI
    // Express Capabilities Register, e a capability MSI-X declara o numero de
    // vetores. Nenhuma das duas tem `cap_len`.
    var image = ConfigImage.zeroed();
    image.writeWord(status_offset, status_capabilities);
    image.writeByte(capability_pointer_offset, 0x40);

    // 0x40 -> 0x80 (PCI Express) -> 0xC0 (MSI-X) -> fim.
    image.writeByte(0x40, 0x10);
    image.writeByte(0x41, 0x80);
    image.writeByte(0x42, 0x00);
    image.writeByte(0x80, 0x11);
    image.writeByte(0x81, 0xC0);
    image.writeByte(0x82, 0x03);
    image.writeByte(0xC0, 0x09);
    image.writeByte(0xC1, 0x00);
    image.writeByte(0xC2, 0x14);

    var iterator = try CapabilityIterator.init(image.reader());

    const express = (try iterator.next()).?;
    try std.testing.expectEqual(@as(u8, 0x10), express.id);
    try std.testing.expect(express.length == null);
    try std.testing.expect(!declaresLength(express.id));

    const msix = (try iterator.next()).?;
    try std.testing.expectEqual(@as(u8, 0x11), msix.id);
    try std.testing.expect(msix.length == null);

    const vendor = (try iterator.next()).?;
    try std.testing.expectEqual(capability_vendor_specific, vendor.id);
    try std.testing.expectEqual(@as(u8, 0x14), vendor.length.?);

    try std.testing.expect(try iterator.next() == null);
}

test "pci vendor specific capabilities still reject a truncated length" {
    // A capability que declara tamanho continua validada: a mesma lista que
    // aceita PCI Express e MSI-X recusa uma vendor-specific menor que o
    // cabecalho de dois bytes.
    var image = ConfigImage.zeroed();
    image.writeWord(status_offset, status_capabilities);
    image.writeByte(capability_pointer_offset, 0x40);
    image.writeByte(0x40, capability_vendor_specific);
    image.writeByte(0x41, 0x00);
    image.writeByte(0x42, 0x01);

    var iterator = try CapabilityIterator.init(image.reader());
    try std.testing.expectError(error.TruncatedCapability, iterator.next());
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

test "pci bar size probe masks, measures and restores every bar" {
    // Imagem de configuracao que se comporta como um dispositivo: um BAR
    // mascarado devolve a mascara de tamanho quando recebe todos os bits de
    // endereco em 1, e guarda qualquer outro valor.
    const Image = struct {
        var words: [config_space_size / 4]u32 = @splat(0);
        var masks: [config_space_size / 4]u32 = @splat(0);
        var writes: usize = 0;

        fn reset() void {
            words = @splat(0);
            masks = @splat(0);
            writes = 0;
        }

        fn read(_: *anyopaque, offset: u8) u32 {
            return words[offset / 4];
        }

        fn write(_: *anyopaque, offset: u8, value: u32) void {
            const at: usize = offset / 4;
            writes += 1;
            if (value == 0xFFFF_FFFF) {
                words[at] = masks[at];
            } else {
                words[at] = value;
            }
        }

        fn access() ConfigAccess {
            return .{ .ctx = @ptrCast(&words), .read_fn = read, .write_fn = write };
        }
    };

    Image.reset();

    // BAR 0: memoria de 32 bits em 0xFE00_0000, 64 KiB.
    Image.words[bar_register_base / 4] = 0xFE00_0000;
    Image.masks[bar_register_base / 4] = 0xFFFF_0000;

    // BAR 2: memoria de 64 bits. A metade alta tem mascara propria e nao e
    // sondada como um BAR independente.
    Image.words[bar_register_base / 4 + 2] = 0xFE10_0004;
    Image.words[bar_register_base / 4 + 3] = 0x0000_0001;
    Image.masks[bar_register_base / 4 + 2] = 0xFFFF_0004;
    Image.masks[bar_register_base / 4 + 3] = 0xFFFF_FFFF;

    const sizes = probeBarSizesWith(Image.access());
    try std.testing.expectEqual(@as(?u64, 0x1_0000), sizes[0]);
    try std.testing.expectEqual(@as(?u64, 0x1_0000), sizes[2]);

    // BAR ausente, metade alta do par e os BARs nao implementados nao tem
    // tamanho.
    try std.testing.expect(sizes[1] == null);
    try std.testing.expect(sizes[3] == null);
    try std.testing.expect(sizes[4] == null);
    try std.testing.expect(sizes[5] == null);

    // A sonda restaura o valor de cada BAR que ela mascarou.
    try std.testing.expectEqual(@as(u32, 0xFE00_0000), Image.words[bar_register_base / 4]);
    try std.testing.expectEqual(@as(u32, 0xFE10_0004), Image.words[bar_register_base / 4 + 2]);
    try std.testing.expectEqual(@as(u32, 0x0000_0001), Image.words[bar_register_base / 4 + 3]);

    // Dois BARs sondados: duas escritas de mascara e duas restauracoes para o
    // BAR de 32 bits, o dobro para o par de 64 bits. Nenhum registrador alheio
    // e tocado.
    try std.testing.expectEqual(@as(usize, 6), Image.writes);
    try std.testing.expectEqual(@as(u32, 0), Image.words[bar_register_base / 4 + 1]);
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

// ----------------------------------------------------------------------
// Bus master: logica pura e acesso simulado.
//
// Estes testes rodam no host. Nenhum deles abre `0xCF8`/`0xCFC`: o espaco de
// configuracao e uma imagem em memoria, e o que se verifica e a regra — quais
// bits mudam, qual e o valor relido e o que acontece quando a funcao nao
// devolve o que foi escrito.
// ----------------------------------------------------------------------

/// Espaco de configuracao em memoria com falhas injetaveis.
///
/// Cada modo de falha corresponde a um comportamento real: uma funcao que
/// ignora escritas de `Command`, uma funcao que nao existe (o barramento
/// devolve tudo em um) e uma funcao que responde mas apaga `Memory Space` ao
/// receber a escrita.
const SimulatedConfig = struct {
    bytes: [config_space_size]u8 = @splat(0),
    writes: u32 = 0,
    mode: Mode = .normal,

    const Mode = enum {
        /// A escrita e aplicada.
        normal,
        /// A escrita e descartada: o dispositivo nao aceita o `Command`.
        ignore_writes,
        /// Todos os bits voltam em um, como numa funcao ausente.
        absent,
        /// A escrita e aceita, mas `Memory Space` sai desligado.
        drops_memory_space,
    };

    fn read(ctx: *anyopaque, offset: u8) u32 {
        const self: *SimulatedConfig = @ptrCast(@alignCast(ctx));
        if (self.mode == .absent) return 0xFFFF_FFFF;
        const at: usize = offset;
        if (at + 4 > config_space_size) return 0xFFFF_FFFF;
        return @as(u32, self.bytes[at]) |
            (@as(u32, self.bytes[at + 1]) << 8) |
            (@as(u32, self.bytes[at + 2]) << 16) |
            (@as(u32, self.bytes[at + 3]) << 24);
    }

    fn write(ctx: *anyopaque, offset: u8, value: u32) void {
        const self: *SimulatedConfig = @ptrCast(@alignCast(ctx));
        self.writes += 1;
        if (self.mode == .ignore_writes or self.mode == .absent) return;
        const at: usize = offset;
        if (at + 4 > config_space_size) return;

        // O DWORD de 0x04 carrega `Command` e `Status`. Um modelo que apenas
        // guarda os bytes mentiria sobre `Status`: os bits dele sao
        // *read/write-1-to-clear*, entao escrever 0 preserva o que estiver
        // ligado, e so um 1 apaga. E essa a semantica que o driver depende e
        // que este simulador reproduz — inclusive para que o teste abaixo
        // possa provar que a revogacao nao apaga um erro registrado.
        if (offset == command_offset) {
            var decoded: u16 = @truncate(value);
            if (self.mode == .drops_memory_space) decoded &= ~command_memory_space;
            self.setCommand(decoded);
            const writable: u16 = @truncate(value >> 16);
            self.setStatus(self.status() & ~writable);
            return;
        }

        self.bytes[at] = @truncate(value);
        self.bytes[at + 1] = @truncate(value >> 8);
        self.bytes[at + 2] = @truncate(value >> 16);
        self.bytes[at + 3] = @truncate(value >> 24);
    }

    fn access(self: *SimulatedConfig) ConfigAccess {
        return .{
            .ctx = @ptrCast(self),
            .read_fn = read,
            .write_fn = write,
        };
    }

    fn command(self: *const SimulatedConfig) u16 {
        return @as(u16, self.bytes[command_offset]) |
            (@as(u16, self.bytes[command_offset + 1]) << 8);
    }

    fn status(self: *const SimulatedConfig) u16 {
        return @as(u16, self.bytes[command_offset + 2]) |
            (@as(u16, self.bytes[command_offset + 3]) << 8);
    }

    fn setCommand(self: *SimulatedConfig, value: u16) void {
        self.bytes[command_offset] = @truncate(value);
        self.bytes[command_offset + 1] = @truncate(value >> 8);
    }

    fn setStatus(self: *SimulatedConfig, value: u16) void {
        self.bytes[command_offset + 2] = @truncate(value);
        self.bytes[command_offset + 3] = @truncate(value >> 8);
    }
};

test "bus master bit is the only command bit the helper changes" {
    // Estado tipico herdado do firmware: I/O Space, Memory Space, Bus Master,
    // SERR e INTx habilitados.
    const firmware_state: u16 = 0x0007;
    try std.testing.expectEqual(
        @as(u16, 0x0003),
        commandWithBusMaster(firmware_state, false),
    );
    try std.testing.expectEqual(
        @as(u16, 0x0007),
        commandWithBusMaster(firmware_state, true),
    );

    // Bit ja desligado: desligar de novo nao liga nada.
    try std.testing.expectEqual(@as(u16, 0x0003), commandWithBusMaster(0x0003, false));
    // Bit ja ligado: ligar de novo nao desliga nada.
    try std.testing.expectEqual(@as(u16, 0x0007), commandWithBusMaster(0x0007, true));

    // Todos os bits altos do Command sobrevivem, um por um.
    for (0..16) |index| {
        const mask = @as(u16, 1) << @intCast(index);
        if (mask == command_bus_master) continue;
        try std.testing.expectEqual(mask, commandWithBusMaster(mask, false) & mask);
        try std.testing.expectEqual(mask, commandWithBusMaster(mask, true) & mask);
    }

    // E o bit 2 e o unico que a funcao liga ou desliga.
    try std.testing.expectEqual(
        @as(u16, 0xFFFF & ~command_bus_master),
        commandWithBusMaster(0xFFFF, false),
    );
    // Partindo de zero, ligar o bit 2 liga *so* o bit 2.
    try std.testing.expectEqual(command_bus_master, commandWithBusMaster(0, true));
}

test "revoking bus master preserves memory space and the status register" {
    var device: SimulatedConfig = .{};
    device.setCommand(0x0007); // I/O Space | Memory Space | Bus Master
    device.setStatus(0xF900); // bits RW1C ligados: nao podem ser apagados

    const change = setBusMasterWith(device.access(), false);
    try std.testing.expect(change.isConfirmed());
    try std.testing.expectEqual(@as(u16, 0x0007), change.confirmed.before);
    try std.testing.expectEqual(@as(u16, 0x0003), change.confirmed.after);

    // O dispositivo ficou com Memory Space ligado: o MMIO continua valido.
    try std.testing.expectEqual(@as(u16, 0x0003), device.command());
    try std.testing.expectEqual(command_memory_space, device.command() & command_memory_space);
    try std.testing.expectEqual(@as(u16, 0), device.command() & command_bus_master);

    // O DWORD inteiro foi escrito, e o Status nao foi zerado: o driver
    // gravou 0 na metade alta, que e o valor que nao limpa bit nenhum.
    try std.testing.expectEqual(@as(u16, 0xF900), device.status());
}

test "the status half of the command dword is never written as one" {
    // Um erro registrado antes da revogacao continua registrado depois dela.
    var device: SimulatedConfig = .{};
    device.setCommand(0x0006);
    device.setStatus(0x2300); // Signaled Target Abort | Master Data Parity Error
    _ = setBusMasterWith(device.access(), false);
    try std.testing.expectEqual(@as(u16, 0x2300), device.status());

    // E restaurar o bit tambem nao mexe no Status.
    _ = setBusMasterWith(device.access(), true);
    try std.testing.expectEqual(@as(u16, 0x2300), device.status());
    try std.testing.expectEqual(@as(u16, 0x0006), device.command());
}

test "revocation is idempotent and writes nothing when already revoked" {
    var device: SimulatedConfig = .{};
    device.setCommand(0x0007);

    const first = setBusMasterWith(device.access(), false);
    try std.testing.expect(first.isConfirmed());
    const writes_after_first = device.writes;

    const second = setBusMasterWith(device.access(), false);
    try std.testing.expect(second.isConfirmed());
    try std.testing.expectEqual(@as(u16, 0x0003), second.confirmed.before);
    try std.testing.expectEqual(@as(u16, 0x0003), second.confirmed.after);
    // O estado pedido ja estava no dispositivo: nenhuma escrita nova.
    try std.testing.expectEqual(writes_after_first, device.writes);
}

test "a device that ignores the write is reported unconfirmed, not revoked" {
    var device: SimulatedConfig = .{ .mode = .ignore_writes };
    device.setCommand(0x0007);

    const change = setBusMasterWith(device.access(), false);
    try std.testing.expect(!change.isConfirmed());
    try std.testing.expectEqual(@as(u16, 0x0007), change.unconfirmed.after);
    // O dispositivo continua como bus master: o chamador precisa saber disso.
    try std.testing.expectEqual(@as(u16, 0x0007), device.command());
}

test "an absent function is distinguished from an unconfirmed revocation" {
    var device: SimulatedConfig = .{ .mode = .absent };
    const change = setBusMasterWith(device.access(), false);
    try std.testing.expect(!change.isConfirmed());
    try std.testing.expectEqual(BusMasterChange.absent, change);
    // Nao se escreve numa funcao que nao responde.
    try std.testing.expectEqual(@as(u32, 0), device.writes);
}

test "a device that drops memory space fails the revocation instead of hiding it" {
    var device: SimulatedConfig = .{ .mode = .drops_memory_space };
    device.setCommand(0x0007);

    const change = setBusMasterWith(device.access(), false);
    // O bit 2 ficou como pedido, mas `Memory Space` sumiu: o MMIO do
    // dispositivo acabou de deixar de responder e o driver nao pode
    // apresentar a operacao como aplicada.
    try std.testing.expect(!change.isConfirmed());
    try std.testing.expectEqual(@as(u16, 0x0007), change.unconfirmed.before);
    try std.testing.expectEqual(@as(u16, 0x0001), change.unconfirmed.after);
    try std.testing.expectEqual(@as(u16, 0), device.command() & command_memory_space);
}

test "enabling bus master again is confirmed only by the read-back" {
    var device: SimulatedConfig = .{};
    device.setCommand(0x0003);
    const change = setBusMasterWith(device.access(), true);
    try std.testing.expect(change.isConfirmed());
    try std.testing.expectEqual(@as(u16, 0x0003), change.confirmed.before);
    try std.testing.expectEqual(@as(u16, 0x0007), change.confirmed.after);
    try std.testing.expectEqual(command_bus_master, device.command() & command_bus_master);
}

// std e mantido importado explicitamente para os testes deste modulo.
comptime {
    _ = std.testing;
}
