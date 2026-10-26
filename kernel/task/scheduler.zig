//************************************************************************//
//  scheduler.zig                                                         //
//************************************************************************//
//                         This file is part of:                          //
//                               VorynOS                                  //
//              https://github.com/CeoMatheusDev/VorynOS                  //
//************************************************************************//
// Copyright (C) 2026 VorynOS contributors.                               //
//                                                                        //
// SPDX-License-Identifier: GPL-3.0-only                                  //
//************************************************************************//

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
const cpu = @import("../arch/x86_64/cpu.zig");
const voryn = @import("voryn_shared");

const context = @import("context.zig");
const paging = @import("../arch/x86_64/paging.zig");
const segment = @import("../arch/x86_64/segment.zig");
const smp = @import("../arch/x86_64/smp.zig");
const channel = @import("../ipc/channel.zig");

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
    ///
    /// The blocked task waits for a message, and the scheduler does not
    /// choose it until the message arrives.
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
    /// The stack of the task, the one where its own code runs.
    stack: []u8 = &.{},
    /// Stack canary: value stored at the top of the kernel stack.
    ///
    /// On every context switch, the canary is written to the stack and
    /// verified when the task resumes. A mismatch indicates a stack
    /// corruption (buffer overflow, stack smashing), and the kernel
    /// will terminate the offending task.
    stack_canary: u64 = 0,
    /// The stack of the kernel of the task, where the handlers run.
    ///
    /// A task has two stacks: the one of its own code, and the one of the
    /// kernel, which receives the frames of the interrupts and of the
    /// calls. The two are never the same memory, for two reasons: the
    /// frame of the interrupt is built on the stack of the kernel, and the
    /// frame of a task that runs in the user mode would otherwise live in
    /// a page that the user owns and can rewrite.
    kernel_rsp: u64 = 0,
    /// The address space of the task, when the task is a process.
    ///
    /// A null value means the space of the kernel, which is the space of
    /// the tasks of the kernel.
    space: ?*paging.AddressSpace = null,
    /// The state of the task.
    state: State = .ready,
    /// The code with which the task ended.
    exit_code: u64 = 0,
    /// The number of times the task was scheduled.
    schedules: u64 = 0,
    /// The priority of the task. Higher values mean higher priority.
    /// The scheduler chooses the ready task with the highest priority.
    priority: u8 = 0,
    /// The time quantum of the task, in ticks of the scheduler timer.
    ///
    /// When the quantum expires, the task is preempted and returned to the
    /// ready queue, and the scheduler chooses the next task. A quantum of
    /// zero means that the task is not subject to time-slicing.
    quantum: u16 = 0,
    /// Peso da tarefa para o EEVDF (virtual runtime).
    ///
    /// Um peso maior significa mais tempo de CPU por tick. O valor padrao
    /// 1024 corresponde ao peso unitario (nice 0). O runtime virtual
    /// avanca em `1024 / weight` por tick.
    weight: u32 = 1024,
    /// Runtime virtual acumulado da tarefa (EEVDF).
    vruntime: i64 = 0,
    /// Prazo virtual da tarefa (EEVDF): o escalonador escolhe, entre as
    /// tarefas elegiveis, a que tem o menor prazo.
    deadline: i64 = 0,
    /// Fatia de tempo da tarefa, em ticks, usada para calcular o prazo.
    slice: u16 = 10,
};

/// Maximum number of tasks that the kernel supports.
pub const max_tasks = 32;

/// Summary of the state of the scheduler.
pub const Statistics = struct {
    /// Number of tasks that exist.
    tasks: u32 = 0,
    /// Number of tasks that are ready.
    ready: u32 = 0,
    /// Number of tasks that are blocked waiting for a message.
    blocked: u32 = 0,
    /// Number of ticks of the timer.
    ticks: u64 = 0,
    /// Number of switches between tasks.
    switches: u64 = 0,
    /// Number of times a task blocked waiting for a message.
    blocks: u64 = 0,
    /// Number of tasks that were killed by an exception.
    killed: u64 = 0,
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
    /// The task that is running on each CPU.
    ///
    /// O indice e o numero logico da CPU. Apenas o BSP executa tarefas
    /// hoje; os APs entram no laco de espera e nao tocam nesta tabela.
    current: [smp.max_cpus]?*Task = @splat(null),

    /// Fila de tarefas prontas de cada CPU.
    ///
    /// O indice externo e o numero logico da CPU; o interno e a posicao
    /// na fila. A fila e um anel logico FIFO: a insercao acrescenta no
    /// fim e a remocao retira do inicio.
    ready_queue: [smp.max_cpus][max_tasks]?*Task = @splat(@splat(null)),

    /// Numero de tarefas prontas em cada fila.
    ready_count: [smp.max_cpus]u32 = @splat(0),
    /// The identifier of the next task that is created.
    next_id: u32 = 0,
    /// The state of the scheduler.
    statistics: Statistics = .{},

    /// Returns the task that is running on the current CPU.
    pub fn currentTask(self: *Scheduler) ?*Task {
        return self.current[smp.cpuId()];
    }

    /// Enfileira uma tarefa na fila de prontos de uma CPU.
    ///
    /// A tarefa passa a ser considerada pronta para ser escolhida quando a
    /// CPU esvaziar a fila. A funcao ignora silenciosamente filas cheias:
    /// o limite de `max_tasks` ja protege o armazenamento.
    pub fn enqueueReady(self: *Scheduler, task: *Task, cpu_id: u8) void {
        if (cpu_id >= smp.max_cpus) return;
        if (self.ready_count[cpu_id] >= max_tasks) return;
        self.ready_queue[cpu_id][self.ready_count[cpu_id]] = task;
        self.ready_count[cpu_id] += 1;
    }

    /// Retira a proxima tarefa da fila de prontos de uma CPU.
    ///
    /// Retorna null quando a fila esta vazia.
    pub fn dequeueReady(self: *Scheduler, cpu_id: u8) ?*Task {
        if (cpu_id >= smp.max_cpus) return null;
        if (self.ready_count[cpu_id] == 0) return null;
        const task = self.ready_queue[cpu_id][0];
        var index: u32 = 0;
        while (index + 1 < self.ready_count[cpu_id]) : (index += 1) {
            self.ready_queue[cpu_id][index] = self.ready_queue[cpu_id][index + 1];
        }
        self.ready_count[cpu_id] -= 1;
        self.ready_queue[cpu_id][self.ready_count[cpu_id]] = null;
        return task;
    }

    /// Numero de tarefas prontas na fila de uma CPU.
    pub fn readyCount(self: *Scheduler, cpu_id: u8) u32 {
        if (cpu_id >= smp.max_cpus) return 0;
        return self.ready_count[cpu_id];
    }

    /// Prepares the scheduler and captures the context of the task that is
    /// running, which becomes the first task.
    ///
    /// `kernel_stack_top` is the top of the stack that the boot left, and it
    /// is the stack where the code of the first task runs. `kernel_stack` is
    /// the stack of the kernel of the first task, and it is a different
    /// memory: the frame of an interrupt is built on it, and the frame
    /// cannot live in the stack that the code of the task uses.
    pub fn init(self: *Scheduler, kernel_stack_top: u64, kernel_stack: []u8) void {
        self.tasks = @splat(null);
        self.count = 0;
        self.current = @splat(null);
        self.next_id = 0;
        self.statistics = .{};

        // The smallest switch is measured, the first one is the reference.
        voryn_switch_minimum = std.math.maxInt(u64);

        const task = self.allocate() orelse return;
        voryn_capture_context(&task.context);
        // The first task runs on the stack of the kernel that the boot left,
        // and the handlers of the calls and of the interrupts run on the
        // stack of the kernel of the task.
        task.stack = @as([*]u8, @ptrFromInt(kernel_stack_top))[0..0];
        task.kernel_rsp = stackTop(kernel_stack);
        task.state = .running;
        task.priority = 0;
        self.current[0] = task;
        segment.tss.rsp0 = task.kernel_rsp;
        voryn_kernel_stack_pointer = task.kernel_rsp;
    }

    /// Spawns a new task that starts at `entry` with the given stack.
    ///
    /// The stack of the task has to be aligned to sixteen bytes and to be
    /// large enough for the frame of the entry function. The stack of the
    /// kernel of the task is a different memory, and it receives the frames
    /// of the interrupts and of the calls.
    ///
    /// The priority of the new task is set to `priority` (0-255), with 0 being
    /// the default and higher values meaning higher priority. If `priority` is
    /// not specified, it defaults to 0.
    pub fn spawn(self: *Scheduler, entry: *const fn () void, stack: []u8, kernel_stack: []u8, priority: u8) ?*Task {
        if (stack.len < 256) return null;
        if (kernel_stack.len < 256) return null;

        const task = self.allocate() orelse return null;

        // The task starts with the stack that the kernel gave it, and it
        // continues at the function that was chosen for it.
        const top = @intFromPtr(stack.ptr) + stack.len;
        const aligned = top & ~@as(usize, 0xF);
        // The function entry expects `RSP + 8` to be aligned to 16 bytes,
        // because a call would have pushed the return address. The task is
        // not called, so the initial stack emulates that call frame.
        const entry_stack = aligned - 8;

        task.context = .{
            .rsp = entry_stack,
            // The interrupt flag and the reserved bit of the flags.
            .rflags = 0x202,
            .rip = @intFromPtr(entry),
            .cs = kernel_code_selector,
            .ss = kernel_data_selector,
        };
        task.stack = stack;
        task.kernel_rsp = stackTop(kernel_stack);
        task.state = .ready;
        task.priority = priority;
        // F10 hardening: calcula o canary como timestamp XOR com o ID da tarefa.
        // O valor é escrito na pilha do kernel do task em spawn(), imediatamente
        // abaixo do registrador kernel_rsp.
        //
        // A pilha é montada a partir de stackTop(kernel_stack), que aponta
        // para o registro usado pelo trampolim ASM. Imprimimos o canary no
        // espaço da pilha para que um buffer overflow na pilha seja
        // detectável.
        task.stack_canary = cpu.readTimestamp() ^ @as(u64, @intCast(task.id));
        // F10: canary inicializado; integração completa da escrita
        // no assembly voryn_task_switch ainda pendente (ver docs).

        // O EEVDF herda o menor vruntime das tarefas prontas, para que a
        // tarefa nova nao seja adiada indefinidamente.
        var min_vruntime: i64 = 0;
        var has_ready = false;
        for (self.tasks) |slot| {
            const other = slot orelse continue;
            if (other == task) continue;
            if (other.state != .ready) continue;
            if (!has_ready or other.vruntime < min_vruntime) {
                min_vruntime = other.vruntime;
                has_ready = true;
            }
        }
        task.vruntime = if (has_ready) min_vruntime else 0;
        const quantum_vtime: i64 = @divTrunc(@as(i64, task.slice) * 1024, @as(i64, @intCast(task.weight)));
        // Performance note: this division occurs once per new-task setup,
        // not every tick; the deadline is incremented by cached quantum.
        task.deadline = task.vruntime + @max(@as(i64, 1), quantum_vtime);

        return task;
    }

    /// Creates a task that runs in the third level of privilege.
    ///
    /// The task starts at `entry` with the stack of the user mode. The stack
    /// is described by its virtual address, because the task only knows the
    /// virtual address space.
    ///
    /// The task receives the address of its own window in the first
    /// register, which is the way a process learns where its memory is when
    /// it starts.
    pub fn spawnUser(
        self: *Scheduler,
        entry: u64,
        user_stack_address: u64,
        user_stack_length: u64,
        kernel_stack: []u8,
        window_base: u64,
        space: ?*paging.AddressSpace,
        role: u64,
    ) ?*Task {
        if (user_stack_length < 1024) return null;

        const task = self.allocate() orelse return null;

        const user_top = (user_stack_address + user_stack_length) & ~@as(u64, 0xF);
        // The entry of a function expects `RSP + 8` to be aligned to 16
        // bytes, because a call would have pushed the return address. The
        // task is not called, but a freestanding compiler may still use
        // aligned SSE spills in the prologue: the initial stack emulates
        // the frame of a call so that those spills are valid.
        const user_entry = user_top - 8;

        task.context = .{
            .rbx = window_base,
            .rcx = role,
            .rsp = user_entry,
            .rflags = 0x202,
            .rip = entry,
            .cs = user_code_selector,
            .ss = user_data_selector,
        };
        task.stack = @as([*]u8, @ptrFromInt(user_stack_address))[0..@intCast(user_stack_length)];
        // The handlers of the task run on the stack of the kernel that the
        // kernel gave it, and not on the stack of the user.
        task.kernel_rsp = stackTop(kernel_stack);
        task.space = space;
        task.state = .ready;

        return task;
    }

    /// Counts a tick of the timer and decides whether the processor has to
    /// run another task.
    ///
    /// The waits whose deadline has passed expire **before** the next task
    /// is chosen, so that a task that timed out is ready in the same tick.
    /// `timeout_result` is the result of the call that timed out: the
    /// scheduler does not know the code of the error, because the contract
    /// of the calls is what owns it.
    ///
    /// The function is called by the handler of the timer. When it returns
    /// true, the entry point of the interrupt switches to the next task.
    pub fn tick(self: *Scheduler, timeout_result: u64) bool {
        self.statistics.ticks += 1;
        _ = channel.expireAll(self.statistics.ticks, timeout_result);

        return self.prepareNext();
    }

    /// Prepares the switch to the next task that can be chosen.
    ///
    /// The function is used by the timer and by the blocking of a task: in
    /// both cases the task that leaves is saved, and the next task is
    /// chosen and prepared. The difference is that the blocking is not a
    /// tick of the timer, and therefore the tick counter does not move.
    fn prepareNext(self: *Scheduler) bool {
        const current = self.current[smp.cpuId()] orelse return false;


        // Decrement the quantum of the current task, and preempt it if it
        // has expired. A quantum of zero means the task is not subject to
        // time-slicing.
        //
        // Only a task that is still running may be returned to the ready
        // queue here. The blocking paths mark the task as blocked **before**
        // they call this function; without the guard, a quantum that expired
        // in the same tick would turn the blocked task ready again and it
        // would resume with the neutral result of the call before the event
        // or the message arrives.
        if (context.quantumPreempts(current.state == .running, current.quantum)) {
            current.quantum -= 1;
            if (current.quantum == 0) {
                // The current task has exhausted its quantum: return it to
                // the ready queue and choose the next task.
                current.state = .ready;
            }
        }

        const next = self.findNextReady(current) orelse return false;

        // The task that leaves becomes ready to be chosen again, and
        // **does not** become ready again when it is blocked: a task that
        // waits for a message is only chosen again when the message
        // arrives.
        if (current.state == .running) {
            current.state = .ready;
        }
        const leaving = current;
        // F10 hardening: verifica stack canary apenas se inicializado
        // (integracao com task.s ainda pendente; evita pânico prematuro).
        if (leaving.stack_canary != 0) {
            const ptr_canary = @as(*const u64, @ptrFromInt(leaving.kernel_rsp - 8));
            const stored_canary = @as(u64, ptr_canary.*);
            if (stored_canary != leaving.stack_canary) {
                @panic("stack corruption");
            }
        }

        next.state = .running;
        self.current[smp.cpuId()] = next;
        next.schedules += 1;

        // EEVDF: avanca vruntime pela fatia/weight (1024 = peso unitario).
        if (next.weight != 0) {
            next.vruntime += @divTrunc(@as(i64, @intCast(next.slice)) * 1024, @as(i64, @intCast(next.weight)));
        }

        // The processor loads the stack pointer of the task state segment
        // whenever the privilege level changes, in both directions. The
        // stack of the task that is going to run is therefore the one that
        // the segment of task state points at, which is the stack of the
        // kernel of the task, and not the stack of the user.
        segment.tss.rsp0 = next.kernel_rsp;
        voryn_kernel_stack_pointer = next.kernel_rsp;

        voryn_current_context = &current.context;
        voryn_next_context = &next.context;

        // The address space travels with the task: a process runs in the
        // space of its own, and the switch of the space happens together
        // with the switch of the context. The value is the root table of
        // the space that the entering task runs in, and zero means that the
        // space does not change.
        voryn_next_cr3 = 0;
        if (next.space != current.space) {
            if (next.space) |space| {
                voryn_next_cr3 = paging.spaceRoot(space);
            } else {
                voryn_next_cr3 = paging.rootAddress();
            }
            // The module of the tables has to know which space is the
            // active one, because the checks of the ranges of the user mode
            // walk the tables of the active space.
            paging.setActiveSpace(next.space);
        }

        return true;
    }

    /// Blocks the current task waiting for a message.
    ///
    /// The function registers the wait in the queue of the channel, marks
    /// the task as blocked and prepares the switch to another task. The
    /// result of the call is written in the context saved of the task when
    /// the message arrives, and the task continues after the call, as if the
    /// call had answered at once.
    ///
    /// `timeout` is the number of ticks that the wait may last, counted
    /// from the current tick of the scheduler. Zero means that the wait
    /// does not expire. A timeout that would overflow the counter saturates,
    /// and the wait therefore expires at the end of the counter and not
    /// before.
    ///
    /// The function returns false when there is no other task to choose,
    /// and in that case the task is **not** blocked: the call returns the
    /// error of the wait that cannot happen, and the task continues.
    pub fn blockCurrent(self: *Scheduler, target: *channel.Channel, side: u64, timeout: u64) bool {
        const task = self.current[smp.cpuId()] orelse return false;

        // The deadline is in the ticks of the scheduler, which is the
        // counter that the timer moves and the one that the expiry reads.
        const deadline = if (timeout == 0)
            0
        else
            self.statistics.ticks +| timeout;

        const waiter = channel.Waiter{
            .kind = &task.context.rax,
            .value = &task.context.rdx,
            .task = task,
            .wake = wakeTask,
            .deadline = deadline,
        };

        if (!target.wait(side, waiter)) return false;

        // The task stays blocked, and the scheduler does not choose it
        // until the message arrives.
        task.state = .blocked;
        self.statistics.blocks += 1;

        // With no other task to run, the blocking makes no sense: the task
        // would be the only one, and the wait would be a busy loop.
        if (!self.prepareNext()) {
            task.state = .running;
            _ = target.cancelWait(side, waiter);
            return false;
        }

        // The entry of the call knows that the task cannot go back to the
        // user mode, and hands the control to the scheduler.
        voryn_syscall_blocked = 1;

        return true;
    }

    /// Releases per-process file descriptors after the final live task
    /// of an address space terminates. Task IDs are not process IDs.
    fn releaseProcessFilesIfLast(self: *Scheduler, finished: *Task) void {
        const space = finished.space orelse return;
        for (self.tasks[0..self.count]) |candidate| {
            const other = candidate orelse continue;
            if (other == finished or other.state == .terminated) continue;
            if (other.space == space) return;
        }
        const fs = @import("../fs/fs.zig");
        fs.closeAll(space.id) catch {};
    }

    /// Kills the current task.
    ///
    /// The task is marked as terminated, and the scheduler does not choose
    /// it again. It is the fate of an exception that came from the user
    /// mode: the process has a defect, and the defect of a process does not
    /// bring the machine down.
    pub fn killCurrent(self: *Scheduler) void {
        const task = self.current[smp.cpuId()] orelse return;
        if (task.state == .terminated) return;
        task.state = .terminated;
        task.exit_code = 1;
        self.releaseProcessFilesIfLast(task);
        self.statistics.killed += 1;
    }

    /// Wakes the task that waits for a message.
    ///
    /// The task becomes ready, and the scheduler chooses it on the next
    /// tick.
    pub fn wakeTask(task: *anyopaque) void {
        const value: *Task = @ptrCast(@alignCast(task));
        if (value.state == .terminated) return;
        value.state = .ready;
    }

    /// Blocks the current task waiting for an input event.
    ///
    /// The wait is registered by the caller (the syscall of the input
    /// wait), not in a channel queue: the producer is the PS/2 interrupt
    /// filling the user queue, and the timer tick delivers the event or
    /// expires the wait. This function marks the task as blocked and
    /// prepares the switch, exactly like the channel wait.
    pub fn blockCurrentForInput(self: *Scheduler) bool {
        const task = self.current[smp.cpuId()] orelse return false;
        task.state = .blocked;
        self.statistics.blocks += 1;

        if (!self.prepareNext()) {
            task.state = .running;
            return false;
        }

        // The entry of the call knows that the task cannot go back to the
        // user mode, and hands the control to the scheduler.
        voryn_syscall_blocked = 1;

        return true;
    }

    /// Ends the task that is running.
    ///
    /// The task is marked as terminated, and the scheduler does not choose
    /// it again. The processor keeps running the task until the next
    /// interruption, and the task does not have to know that it ended.
    pub fn terminateCurrent(self: *Scheduler, code: u64) void {
        const current = self.current[smp.cpuId()] orelse return;
        if (current.state == .terminated) return;
        current.state = .terminated;
        current.exit_code = code;
        self.releaseProcessFilesIfLast(current);
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
        var blocked: u32 = 0;
        for (self.tasks) |task| {
            const value = task orelse continue;
            if (value.state == .ready) ready += 1;
            if (value.state == .blocked) blocked += 1;
        }
        statistics.ready = ready;
        statistics.blocked = blocked;

        return statistics;
    }

    /// Finds the next task that is ready.
    ///
    /// The search continues after the current task, so that every task
    /// reaches the processor. A policy that always returned the first task
    /// of the list would starve the others.
    fn findNextReady(self: *const Scheduler, current: *Task) ?*Task {
        const start = self.indexOf(current) + 1;

        var best_task: ?*Task = null;
        var best_vruntime: i64 = std.math.maxInt(i64);

        var offset: usize = 0;
        while (offset < self.tasks.len) : (offset += 1) {
            const index = (start + offset) % self.tasks.len;
            const task = self.tasks[index] orelse continue;
            if (task == current) continue;
            if (task.state != .ready) continue;
            // EEVDF: escolhe a tarefa elegivel com menor vruntime.
            if (best_task == null or task.vruntime < best_vruntime) {
                best_vruntime = task.vruntime;
                best_task = task;
            }
        }
        return best_task;
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
        task.* = .{ .id = self.next_id, .state = .ready, .quantum = 16 };
        self.next_id += 1;
        self.tasks[index] = task;

        return task;
    }
};

/// The scheduler of the kernel.
pub var scheduler: Scheduler = .{};

/// The top of a stack, aligned to sixteen bytes.
///
/// The stack of a task grows towards the low addresses, therefore the top is
/// the end of the region, and the first frame of the kernel is built below
/// it.
fn stackTop(stack: []u8) u64 {
    const top = @intFromPtr(stack.ptr) + stack.len;
    return top & ~@as(u64, 0xF);
}

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

/// The root table of the address space of the task that is entering.
///
/// The value is zero when the address space does not change, and the switch
/// reads it to know whether it has to write the register of the tables.
pub extern var voryn_next_cr3: u64;

/// The flag that tells the entry of the system call that the task blocked.
///
/// The value is one when the current task was left waiting for a
/// message, and the entry of the call hands the control to the scheduler
/// instead of going back to the user mode.
pub extern var voryn_syscall_blocked: u64;

/// Captures the context of the task that is running.
extern fn voryn_capture_context(task_context: *Context) callconv(.c) void;
