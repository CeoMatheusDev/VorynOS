const std = @import("std");
pub fn main() void {
    // Try inline assembly with different format
    var ret: u64 = undefined;
    // Using the format from Zig documentation
    asm ("syscall"
        : "=a"(ret)
        :
        : "rcx", "r11"
    );
    std.debug.print("ret = {d}\n", .{ret})
}
