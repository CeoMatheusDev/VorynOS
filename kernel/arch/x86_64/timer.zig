// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 VorynOS contributors

//! The timer of the kernel and the interrupt controllers.
//!
//! The kernel uses the programmable interval timer of the PC, the 8254, in
//! its most simple mode: channel zero generates a periodic interrupt at a
//! fixed frequency. The interrupt is delivered by the first of the two
//! interrupt controllers, the 8259, which the kernel reprograms so that the
//! hardware interrupts occupy the vectors that follow the exceptions of the
//! processor.

const std = @import("std");
const voryn = @import("voryn_shared");

const cpu = @import("cpu.zig");

/// The frequency of the timer of the PC.
pub const pit_frequency: u32 = 1_193_182;

/// Ports of the programmable interval timer.
const pit = struct {
    const channel0 = 0x40;
    const command = 0x43;
};

/// Ports of the interrupt controllers.
const pic = struct {
    const master_command = 0x20;
    const master_data = 0x21;
    const slave_command = 0xA0;
    const slave_data = 0xA1;
};

/// The vector of the first hardware interrupt.
pub const first_hardware_vector: u8 = 32;

/// The number of hardware interrupts.
pub const hardware_interrupt_count: u8 = 16;

/// Number of ticks since the timer was started.
var tick_count: u64 = 0;

/// The frequency of the timer in interrupts per second.
var frequency: u32 = 100;

/// Prepares the interrupt controllers and the timer.
///
/// The controllers are reprogrammed so that the hardware interrupts use the
/// vectors that follow the exceptions of the processor, and the timer is
/// started at the given frequency.
pub fn init(ticks_per_second: u32) void {
    frequency = ticks_per_second;
    tick_count = 0;

    // Remap the interrupt controllers.
    //
    // The first controller receives the vectors 32 to 39 and the second one
    // the vectors 40 to 47. The second controller is connected to the
    // interrupt request line 2 of the first one.
    writePort(pic.master_command, 0x11); // initialisation, expects the fourth word
    writePort(pic.master_data, first_hardware_vector);
    writePort(pic.master_data, 0x04); // the second controller is on line 2
    writePort(pic.master_data, 0x01); // 8086 mode

    writePort(pic.slave_command, 0x11);
    writePort(pic.slave_data, first_hardware_vector + 8);
    writePort(pic.slave_data, 0x02); // the cascade identity
    writePort(pic.slave_data, 0x01);

    // Only the timer of the first controller is enabled.
    writePort(pic.master_data, 0xFE);
    writePort(pic.slave_data, 0xFF);

    // Program the timer: channel zero, low and high byte of the divisor,
    // square wave mode.
    const divisor = pit_frequency / ticks_per_second;
    writePort(pit.command, 0x34);
    writePort(pit.channel0, @truncate(divisor & 0xFF));
    writePort(pit.channel0, @truncate((divisor >> 8) & 0xFF));
}

/// Counts one tick of the timer.
pub fn onTick() void {
    tick_count += 1;
}

/// The number of ticks since the timer was started.
pub fn ticks() u64 {
    return tick_count;
}

/// The frequency of the timer in interrupts per second.
pub fn ticksPerSecond() u32 {
    return frequency;
}

/// Acknowledges the interrupt to the controllers.
///
/// The first controller is acknowledged when the interrupt comes from the
/// second one, because the second controller is connected to it.
pub fn acknowledge(vector: u8) void {
    if (vector >= first_hardware_vector + 8) {
        writePort(pic.slave_command, 0x20);
    }
    writePort(pic.master_command, 0x20);
}

/// Enables the interrupts of the processor.
pub fn enableInterrupts() void {
    cpu.enableInterrupts();
}

/// Writes a byte to a port.
fn writePort(port: u16, value: u8) void {
    voryn.port.outb(port, value);
}
