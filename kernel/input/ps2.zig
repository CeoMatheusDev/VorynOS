//************************************************************************//
//  ps2.zig                                                               //
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

//! F6.7: IRQ1 PS/2 keyboard (legacy 8042). Acesso ao buffer em contexto
//! normal exige interrupções locais desabilitadas; IRQ1 é o único produtor.
//!
//! F6.27: cada evento decodificado entra em duas filas. A fila `queue`
//! pertence ao diagnóstico do kernel, e a fila `user_queue` pertence ao
//! serviço gráfico de usuário. A separação impede que o consumidor de
//! usuário roube a tecla que seleciona o modo interativo do kernel.

const voryn = @import("voryn_shared");
const keyboard = @import("voryn_keyboard");
const mouse = @import("mouse.zig");
/// O tipo do pacote de movimento, para quem consome a fila do mouse.
pub const Mouse = mouse;
const cpu = @import("../arch/x86_64/cpu.zig");

const status_port: u16 = 0x64;
const data_port: u16 = 0x60;
const output_full: u8 = 1;
const input_full: u8 = 2;
const auxiliary_data: u8 = 0x20;

/// Comandos do controlador 8042 (porta 0x64).
const command_read_config: u8 = 0x20;
const command_write_config: u8 = 0x60;
const command_enable_auxiliary: u8 = 0xA8;
const command_next_auxiliary: u8 = 0xD4;

/// Comandos do mouse (porta 0x60, precedidos de `command_next_auxiliary`).
const mouse_defaults: u8 = 0xF6;
const mouse_enable_reporting: u8 = 0xF4;

/// Resposta de reconhecimento de um comando do dispositivo.
const acknowledge_byte: u8 = 0xFA;

/// Bit 1 da configuração do 8042: interrupção do dispositivo auxiliar.
const config_aux_irq: u8 = 0x02;
/// Bit 5 da configuração do 8042: relógio do dispositivo auxiliar desligado.
const config_aux_clock_disabled: u8 = 0x20;

/// Limite de giros em cada espera do handshake.
///
/// Não existe tempo garantido no protocolo, e um laço aberto em um
/// controlador ausente ou defeituoso prenderia o boot para sempre. Cada
/// espera desiste e devolve `false`; `initAuxiliary` traduz isso em um motivo.
const handshake_attempts: usize = 100_000;

var decoder: keyboard.Set1Decoder = .{};
var queue: keyboard.EventQueue = .{};
var user_queue: keyboard.EventQueue = .{};
const available: bool = true;
var received: usize = 0;

/// F6.32: decodificador e fila do mouse. A fila é separada da fila do
/// teclado porque os dois têm consumidores diferentes e o consumo de um não
/// deve descartar o outro.
var mouse_decoder: mouse.Decoder = .{};
var mouse_queue: mouse.Queue = .{};
var mouse_bytes: usize = 0;
var mouse_present: bool = false;

/// Accumulated cost of the IRQ1 handler since the previous take.
pub const IrqStats = struct {
    interrupts: usize = 0,
    bytes: usize = 0,
    cycles: u64 = 0,
};

var irq_stats: IrqStats = .{};
/// Custo acumulado do IRQ12 desde a última retirada.
var mouse_irq_stats: IrqStats = .{};

/// Esvazia o buffer de saída do 8042, encaminhando cada byte ao dono.
///
/// Os dois IRQs (1 e 12) chamam esta função. Um byte do dispositivo
/// auxiliar que chegue enquanto o IRQ1 está sendo tratado precisa ir para o
/// mouse, e não ser descartado: perder um byte do meio de um pacote de três
/// desalinha todos os pacotes seguintes até o próximo sincronismo.
fn drainOutputBuffer() void {
    // Limite de trabalho por IRQ: evita prender o processador em hardware
    // defeituoso ou em uma fila de saída que nunca esvazia.
    for (0..16) |_| {
        const status = voryn.port.inb(status_port);
        if (status & output_full == 0) break;
        const byte = voryn.port.inb(data_port);
        if (status & auxiliary_data != 0) {
            mouse_bytes +|= 1;
            if (mouse_decoder.feed(byte)) |packet| _ = mouse_queue.push(packet);
            continue;
        }
        received +|= 1;
        irq_stats.bytes +|= 1;
        if (decoder.feed(byte)) |event| {
            _ = queue.push(event);
            _ = user_queue.push(event);
        }
    }
}

/// IRQ1: teclado PS/2 (e qualquer byte do auxiliar que esteja pendente).
/// O EOI é responsabilidade do despachante de interrupções.
pub fn onInterrupt() void {
    const start = cpu.readTimestamp();
    drainOutputBuffer();
    irq_stats.interrupts +|= 1;
    irq_stats.cycles +|= cpu.readTimestamp() - start;
}

/// IRQ12: mouse PS/2.
///
/// O handler tem o mesmo trabalho do IRQ1 — os bytes são distinguidos pelo
/// bit do dispositivo auxiliar no registrador de estado —, mas conta as
/// interrupções em separado, para que o diagnóstico distinga um mouse mudo
/// de um teclado mudo.
pub fn onMouseInterrupt() void {
    const start = cpu.readTimestamp();
    drainOutputBuffer();
    mouse_irq_stats.interrupts +|= 1;
    mouse_irq_stats.cycles +|= cpu.readTimestamp() - start;
}

/// Returns the cost accumulated since the previous call and resets it.
/// The counters are updated by IRQ1, therefore the caller must disable the
/// local interrupts while taking and resetting them.
pub fn takeIrqStatsIrqsDisabled() IrqStats {
    const stats = irq_stats;
    irq_stats = .{};
    return stats;
}

/// Resultado do handshake com o dispositivo auxiliar.
///
/// O kernel registra isto no console: um mouse que não responde precisa ser
/// distinguível de um mouse que responde e não se move.
pub const AuxiliaryStatus = struct {
    /// O dispositivo respondeu a todos os comandos que exigem ACK.
    present: bool = false,
    /// Byte de configuração do 8042 antes e depois do ajuste.
    config_before: u8 = 0,
    config_after: u8 = 0,
    /// Quantos comandos do mouse foram reconhecidos.
    acks: u8 = 0,
    /// Motivo da recusa, quando `present` é falso.
    reason: []const u8 = "",

    const ok_reason = "";
};

/// Espera o buffer de entrada do 8042 esvaziar.
fn waitInputClear() bool {
    for (0..handshake_attempts) |_| {
        if (voryn.port.inb(status_port) & input_full == 0) return true;
    }
    return false;
}

/// Espera um byte do controlador e o devolve.
fn readControllerByte() ?u8 {
    for (0..handshake_attempts) |_| {
        if (voryn.port.inb(status_port) & output_full != 0) return voryn.port.inb(data_port);
    }
    return null;
}

/// Escreve um comando na porta de comando.
fn writeControllerCommand(command: u8) bool {
    if (!waitInputClear()) return false;
    voryn.port.outb(status_port, command);
    return true;
}

/// Escreve um byte de dados (destinado ao controlador ou ao dispositivo).
fn writeControllerData(value: u8) bool {
    if (!waitInputClear()) return false;
    voryn.port.outb(data_port, value);
    return true;
}

/// Envia um comando ao dispositivo auxiliar e espera o ACK.
///
/// O ACK pode vir acompanhado de bytes de um pacote em trânsito; os bytes do
/// dispositivo auxiliar que não são ACK vão para o decodificador, porque
/// descartá-los desalinharia o fluxo do mouse.
fn writeAuxiliaryCommand(command: u8) bool {
    if (!writeControllerCommand(command_next_auxiliary)) return false;
    if (!writeControllerData(command)) return false;
    for (0..handshake_attempts) |_| {
        const status = voryn.port.inb(status_port);
        if (status & output_full == 0) continue;
        const byte = voryn.port.inb(data_port);
        if (status & auxiliary_data == 0) continue;
        if (byte == acknowledge_byte) return true;
        mouse_bytes +|= 1;
        if (mouse_decoder.feed(byte)) |packet| _ = mouse_queue.push(packet);
    }
    return false;
}

/// Habilita o dispositivo auxiliar (mouse) e a linha IRQ12.
///
/// Chamar com as interrupções locais desabilitadas, antes de o despachante
/// começar a aceitar o IRQ12: um pacote recebido no meio do handshake seria
/// interpretado como resposta de comando.
pub fn initAuxiliaryIrqsDisabled() AuxiliaryStatus {
    var status: AuxiliaryStatus = .{};

    // habilita o dispositivo auxiliar no controlador
    if (!writeControllerCommand(command_enable_auxiliary)) {
        status.reason = "the controller did not accept the auxiliary enable";
        return status;
    }

    // lê a configuração, liga a interrupção do auxiliar e o relógio dele
    if (!writeControllerCommand(command_read_config)) {
        status.reason = "the controller did not report its configuration";
        return status;
    }
    const configuration = readControllerByte() orelse {
        status.reason = "the configuration byte did not arrive";
        return status;
    };
    status.config_before = configuration;
    const wanted = (configuration | config_aux_irq) & ~config_aux_clock_disabled;
    if (!writeControllerCommand(command_write_config)) {
        status.reason = "the controller did not accept the configuration write";
        return status;
    }
    if (!writeControllerData(wanted)) {
        status.reason = "the configuration byte was not written";
        return status;
    }
    status.config_after = wanted;

    // O mouse volta aos padrões (taxa, resolução, escala 1:1) e passa a
    // reportar. Os dois comandos exigem ACK: sem ele o dispositivo pode
    // estar presente mas não estar enviando nada.
    if (!writeAuxiliaryCommand(mouse_defaults)) {
        status.reason = "the mouse did not acknowledge the defaults";
        return status;
    }
    status.acks +|= 1;
    if (!writeAuxiliaryCommand(mouse_enable_reporting)) {
        status.reason = "the mouse did not acknowledge the reporting enable";
        return status;
    }
    status.acks +|= 1;

    status.present = true;
    status.reason = AuxiliaryStatus.ok_reason;
    mouse_present = true;
    return status;
}

/// True quando o handshake do dispositivo auxiliar terminou com ACK.
pub fn mouseReady() bool {
    return mouse_present;
}

/// Um pacote de movimento, com as interrupções locais desabilitadas.
pub fn popMouseIrqsDisabled() ?mouse.Packet {
    return mouse_queue.pop();
}

/// Pacotes perdidos porque a fila estava cheia.
pub fn mouseDroppedIrqsDisabled() usize {
    return mouse_queue.dropped;
}

/// Bytes recebidos do dispositivo auxiliar.
pub fn mouseBytesIrqsDisabled() usize {
    return mouse_bytes;
}

/// Contadores do decodificador (pacotes, ressincronizações e saturações).
pub fn mouseDecoderStatsIrqsDisabled() struct { packets: usize, resyncs: usize, overflows: usize } {
    return .{
        .packets = mouse_decoder.packets,
        .resyncs = mouse_decoder.resyncs,
        .overflows = mouse_decoder.overflows,
    };
}

/// Custo acumulado do IRQ12 desde a última retirada.
pub fn takeMouseIrqStatsIrqsDisabled() IrqStats {
    const stats = mouse_irq_stats;
    mouse_irq_stats = .{};
    return stats;
}

/// Somente com IRQs locais desabilitadas (por exemplo, CLI/STI no consumidor).
pub fn popIrqsDisabled() ?keyboard.KeyEvent {
    return queue.pop();
}

/// Only with the local interrupts disabled; the queue of the graphics
/// service, separate from the diagnostic queue of the kernel.
pub fn popUserIrqsDisabled() ?keyboard.KeyEvent {
    return user_queue.pop();
}

/// True when the kernel has an input queue for the user mode.
pub fn userQueueReady() bool {
    return available;
}

/// Only with the local interrupts disabled.
pub fn userDroppedIrqsDisabled() usize {
    return user_queue.dropped;
}

/// Somente com IRQs locais desabilitadas.
pub fn receivedIrqsDisabled() usize {
    return received;
}

/// Somente com IRQs locais desabilitadas.
pub fn droppedIrqsDisabled() usize {
    return queue.dropped;
}
