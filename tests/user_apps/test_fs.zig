fn syscall(num: u64, arg1: u64, arg2: u64, arg3: u64) u64 {
    var ret: u64 = undefined;
    asm volatile (
        "syscall"
        : [ret] "={rax}" (ret)
        : [num] "{rax}" (num),
          [arg1] "{rdi}" (arg1),
          [arg2] "{rsi}" (arg2),
          [arg3] "{rdx}" (arg3)
        : "rcx r11 memory"
    );
    return ret;
}

export fn _start() noreturn {
    const SYS_FS_OPEN = 13;
    const SYS_FS_WRITE = 15;
    const SYS_FS_READ = 14;
    const SYS_FS_CLOSE = 16;

    const msg = "Ola VorynOS F4!";
    var read_buf: [16]u8 = undefined;
    const filename = "test.txt\x00";

    // 1. OPEN (Modo escrita = 2)
    const fd_write_res = syscall(SYS_FS_OPEN, @intFromPtr(&filename), 2, 0);
    const fd_write = fd_write_res;
    if (fd_write_res >= (u64)-1) {
        // Error opening file - loop forever
        while(true) {}
    }

    // 2. WRITE
    _ = syscall(SYS_FS_WRITE, fd_write, @intFromPtr(&msg), msg.len);
    
    // 3. CLOSE
    _ = syscall(SYS_FS_CLOSE, fd_write, 0, 0);

    // 4. OPEN para leitura
    const fd_read_res = syscall(SYS_FS_OPEN, @intFromPtr(&filename), 1, 0); // 1 = read_only
    if (fd_read_res >= (u64)-1) {
        // Error opening file - loop forever
        while(true) {}
    }
    const fd_read = fd_read_res;

    // 5. READ
    const bytes_read = syscall(SYS_FS_READ, fd_read, @intFromPtr(&read_buf), read_buf.len);
    
    // 6. CLOSE
    _ = syscall(SYS_FS_CLOSE, fd_read, 0, 0);

    // 7. VERIFICAÇÃO
    if (bytes_read == msg.len) {
        // SUCESSO - loop infinito para não sair
        while(true) {}
    }

    while(true) {}
}