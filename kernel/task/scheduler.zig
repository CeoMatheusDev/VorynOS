// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 VorynOS contributors

//! The task fabric: tasks and the scheduler.
//!
//! A task is a context of execution: the registers that the architecture
//! does not save between calls and a stack. The scheduler is preemptive, the
//! timer of the kernel decides when a task leaves the processor.
//!
//! The policy is deliberately the simplest one that can be verified: the
//! tasks are visited in the order of their creation. Every design decision
//! that needs measurements, like the latency sensitive scheduling for
//! interactive applications, belongs to a later increment and has to be
//! justified with data.

const std = @import("std");
const voryn = @import("voryn_shared");

const context = @import("context.zig");
const segment = @import("../arch/x86_64/segment.zig");

/// The context of a task.
pub const Context = context.Context;

/// The selector of the code segment of the kernel.
const kernel_code_selector: u64 = segment.selectors.kernel_code;

/// The selector of the data segment of the kernel.
const kernel_data_selector: u64 = segment.selectors.kernel_data;

/// The selector of the code segment of the user mode.
const user_code_selector: u64 = segment.selectors.user_code;

/// The selector of the data segment of the user mode.
const user_data_selector: u64 = segment.selectors.user_data;

/// The state of a task.
pub const State = enum {
    /// The task can be scheduled.
    ready,
    /// The task is running.
    running,
    /// The task is waiting for an event.
    blocked,
    /// The task finished.
    terminated,
};

/// A task of the kernel.
pub const Task = struct {
    /// The identifier of the task, in the order of creation.
    id: u32 = 0,
    /// The saved context of the task.
    context: Context = .{},
    /// The stack of the task.
    stack: []u8 = &.{},
    /// The stack of the kernel of the task, where the handlers run.
    ///
    /// A task that runs in the user mode has two stacks: the one of the
    /// user, which is the one the task uses, and the one of the kernel,
    /// which receives the frames of the interrupts and of the calls.
    kernel_rsp: u64 = 0,
    /// The state of the task.
    state: State = .ready,
    /// The code with which the task ended.
    exit_code: u64 = 0,
    /// The number of times the task was scheduled.
    schedules: u64 = 0,
};

/// Maximum number of tasks that the kernel supports.
pub const max_tasks = 32;

/// Summary of the state of the scheduler.
pub const Statistics = struct {
    /// Number of tasks that exist.
    tasks: u32 = 0,
    /// Number of tasks that are ready.
    ready: u32 = 0,
    /// Number of ticks of the timer.
    ticks: u64 = 0,
    /// Number of switches between tasks.
    switches: u64 = 0,
    /// Total cost of the switches, in cycles.
    switch_cycles: u64 = 0,
    /// Cost of the last switch, in cycles.
    last_switch_cycles: u64 = 0,
    /// Smallest cost of a switch, in cycles.
    minimum_switch_cycles: u64 = 0,
};

/// The scheduler of the kernel.
pub const Scheduler = struct {
    /// The storage of the tasks. The address of a task has to be stable,
    /// because the context of a task is referred to by pointer.
    storage: [max_tasks]Task = @splat(.{}),
    /// The tasks of the kernel, in the order of their creation.
    tasks: [max_tasks]?*Task = @splat(null),
    /// The number of tasks that exist.
    count: u32 = 0,
    /// The task that is running.
    current: ?*Task = null,
    /// The identifier of the next task that is created.
    next_id: u32 = 0,
    /// The state of the scheduler.
    statistics: Statistics = .{},

    /// Prepares the scheduler and captures the context of the task that is
    /// running, which becomes the first task.
    ///
    /// `kernel_stack_top` is the top of the stack that the boot left. The
    /// handlers of the calls and of the interrupts of the first task run on
    /// it, and the segment of task state points at it.
    pub fn init(self: *Scheduler, kernel_stack_top: u64) void {
        self.tasks = @splat(null);
        self.count = 0;
        self.current = null;
        self.next_id = 0;
        self.statistics = .{};

        // The smallest switch is measured, the first one is the reference.
        voryn_switch_minimum = std.math.maxInt(u64);

        const task = self.allocate() orelse return;
        voryn_capture_context(&task.context);
        // The first task runs on the stack of the kernel that the boot left,
        // and the handlers of the calls run on the same stack.
        task.kernel_rsp = kernel_stack_top;
        task.state = .running;
        self.current = task;
        segment.tss.rsp0 = task.kernel_rsp;
        voryn_kernel_stack_pointer = task.kernel_rsp;
    }

    /// Creates a task that starts at `entry` with the given stack.
    ///
    /// The stack has to be aligned to sixteen bytes and to be large enough
    /// for the frame of the entry function.
    pub fn spawn(self: *Scheduler, entry: *const fn () void, stack: []u8) ?*Task {
        if (stack.len < 256) return null;

        const task = self.allocate() orelse return null;

        // The task starts with the stack that the kernel gave it, and it
        // continues at the function that was chosen for it.
        const top = @intFromPtr(stack.ptr) + stack.len;
        const aligned = top & ~@as(usize, 0xF);

        task.context = .{
            .rsp = aligned,
            // The interrupt flag and the reserved bit of the flags.
            .rflags = 0x202,
            .rip = @intFromPtr(entry),
            .cs = kernel_code_selector,
            .ss = kernel_data_selector,
        };
        task.stack = stack;
        task.kernel_rsp = aligned;
        task.state = .ready;

        return task;
    }

    /// Creates a task that runs in the third level of privilege.
    ///
    /// The task starts at `entry` with the stack of the user mode. The stack
    /// is described by its virtual address, because the task only knows the
    /// virtual address space.
    pub fn spawnUser(
        self: *Scheduler,
        entry: u64,
        user_stack_address: u64,
        user_stack_length: u64,
        kernel_stack: []u8,
    ) ?*Task {
        if (user_stack_length < 1024) return null;

        const task = self.allocate() orelse return null;

        const user_top = (user_stack_address + user_stack_length) & ~@as(u64, 0xF);

        task.context = .{
            .rsp = user_top,
            .rflags = 0x202,
            .rip = entry,
            .cs = user_code_selector,
            .ss = user_data_selector,
        };
        task.stack = @as([*]u8, @ptrFromInt(user_stack_address))[0..@intCast(user_stack_length)];
        // The handlers of the task run on the stack of the kernel that the
        // kernel gave it, and not on the stack of the user.
        const kernel_top = (@intFromPtr(kernel_stack.ptr) + kernel_stack.len) & ~@as(u64, 0xF);
        task.kernel_rsp = kernel_top;
        task.state = .ready;

        return task;
    }

    /// Decides whether the processor has to run another task.
    ///
    /// The function is called by the handler of the timer. When it returns
    /// true, the entry point of the interrupt switches to the next task.
    pub fn tick(self: *Scheduler) bool {
        self.statistics.ticks += 1;

        const current = self.current orelse return false;

        const next = self.findNextReady(current) orelse return false;

        current.state = .ready;
        next.state = .running;
        self.current = next;
        next.schedules += 1;

        // The processor loads the stack pointer of the task state segment
        // whenever the privilege level changes, in both directions. The
        // stack of the task that is going to run is therefore the one that
        // the segment of task state points at, which is the stack of the
        // kernel of the task, and not the stack of the user.
        segment.tss.rsp0 = next.kernel_rsp;
        voryn_kernel_stack_pointer = next.kernel_rsp;

        voryn_current_context = &current.context;
        voryn_next_context = &next.context;

        return true;
    }

    /// Ends the task that is running.
    ///
    /// The task is marked as terminated, and the scheduler does not choose
    /// it again. The processor keeps running the task until the next
    /// interruption, and the task does not have to know that it ended.
    pub fn terminateCurrent(self: *Scheduler, code: u64) void {
        const current = self.current orelse return;
        current.state = .terminated;
        current.exit_code = code;
    }

    /// The state of the scheduler, with the measurements of the switches.
    pub fn statisticsOf(self: *const Scheduler) Statistics {
        var statistics = self.statistics;
        statistics.switches = voryn_switch_count;
        statistics.switch_cycles = voryn_switch_total;
        statistics.last_switch_cycles = voryn_switch_cycles;
        statistics.minimum_switch_cycles = voryn_switch_minimum;
        statistics.tasks = self.count;

        var ready: u32 = 0;
        for (self.tasks) |task| {
            const value = task orelse continue;
            if (value.state == .ready) ready += 1;
        }
        statistics.ready = ready;

        return statistics;
    }

    /// Finds the next task that is ready.
    ///
    /// The search continues after the current task, so that every task
    /// reaches the processor. A policy that always returned the first task
    /// of the list would starve the others.
    fn findNextReady(self: *const Scheduler, current: *Task) ?*Task {
        const start = self.indexOf(current) + 1;

        var offset: usize = 0;
        while (offset < self.tasks.len) : (offset += 1) {
            const index = (start + offset) % self.tasks.len;
            const task = self.tasks[index] orelse continue;
            if (task == current) continue;
            if (task.state != .ready) continue;
            return task;
        }
        return null;
    }

    /// The position of a task in the list of the scheduler.
    fn indexOf(self: *const Scheduler, task: *Task) usize {
        for (self.tasks, 0..) |entry, index| {
            const value = entry orelse continue;
            if (value == task) return index;
        }
        return 0;
    }

    /// Reserves a task of the storage of the scheduler.
    fn allocate(self: *Scheduler) ?*Task {
        if (self.count >= max_tasks) return null;

        const index = self.count;
        self.count += 1;

        const task = &self.storage[index];
        task.* = .{ .id = self.next_id, .state = .ready };
        self.next_id += 1;
        self.tasks[index] = task;

        return task;
    }
};

/// The scheduler of the kernel.
pub var scheduler: Scheduler = .{};

/// The context of the task that is leaving, used by the switch.
pub extern var voryn_current_context: *Context;

/// The context of the task that is entering, used by the switch.
pub extern var voryn_next_context: *Context;

/// The number of switches between tasks.
pub extern var voryn_switch_count: u64;

/// The total cost of the switches, in cycles.
pub extern var voryn_switch_total: u64;

/// The cost of the last switch, in cycles.
pub extern var voryn_switch_cycles: u64;

/// The smallest cost of a switch, in cycles.
pub extern var voryn_switch_minimum: u64;

/// The stack of the kernel of the task that is running.
pub extern var voryn_kernel_stack_pointer: u64;

/// Captures the context of the task that is running.
extern fn voryn_capture_context(task_context: *Context) callconv(.c) void;
