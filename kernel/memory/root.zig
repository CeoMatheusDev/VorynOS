//! Aggregated entry point of the memory modules of the kernel.
//!
//! The modules are grouped so that they can be compiled for the host, where
//! their unit tests run.

pub const physical = @import("physical.zig");
pub const heap = @import("heap.zig");
