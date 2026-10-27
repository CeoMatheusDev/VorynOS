//************************************************************************//
//  build.zig                                                             //
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

//! VorynOS build system.
//!
//! The build produces three artifacts:
//!
//!   * `voryn-boot.efi`  - the Voryn Native Boot loader (UEFI application);
//!   * `voryn-kernel`    - the Voryn Nucleus Kernel (freestanding ELF64);
//!   * `vorynos.img`     - a bootable EFI system partition that contains both.
//!
//! Steps:
//!
//!   * `zig build`              - build everything;
//!   * `zig build test`         - run the host unit tests;
//!   * `zig build qemu`         - boot the image in QEMU, interactively;
//!   * `zig build qemu-test`    - run the automated boot test in QEMU;
//!   * `zig build qemu-storage-test` - verify VirtIO Block I/O across two boots;
//!   * `zig build check`        - unit, boot, and two-boot storage tests.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ------------------------------------------------------------------
    // Shared module: contracts and architecture support used by both the
    // bootloader and the kernel.
    // ------------------------------------------------------------------
    const shared = b.createModule(.{
        .root_source_file = b.path("shared/root.zig"),
    });

    // ------------------------------------------------------------------
    // Voryn Native Boot, the UEFI loader.
    // ------------------------------------------------------------------
    const boot_target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .uefi,
        .abi = .none,
    });
    const boot_module = b.createModule(.{
        .root_source_file = b.path("boot/uefi/main.zig"),
        .target = boot_target,
        .optimize = optimize,
        .single_threaded = true,
        // The trace of the errors is a feature of the development, and it
        // reads a register that the caller of a function that does not
        // return an error does not set. The bootloader and the kernel do
        // not have a runtime that can report a trace, and the mechanism
        // itself is able to raise a fault in the middle of a message of
        // the console.
        .error_tracing = false,
    });
    boot_module.addImport("voryn_shared", shared);
    const boot_executable = b.addExecutable(.{
        .name = "voryn-boot",
        .root_module = boot_module,
    });
    b.installArtifact(boot_executable);

    // ------------------------------------------------------------------
    // Native application produced by the toolchain.
    //
    // The application is a freestanding PIE, compiled by Zig. A small tool
    // turns the resulting ELF into a Zig source file that exports the
    // bytes, and the kernel imports that module to write the file into the
    // RamFS. The loader does not know that the image came from a compiler.
    // ------------------------------------------------------------------
    const user_target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .freestanding,
        .abi = .none,
    });
    // The display metadata is a public contract shared by the kernel and
    // the SDK. The SDK imports only this module, not the whole shared tree
    // with the serial and port drivers.
    const display_contract = b.createModule(.{
        .root_source_file = b.path("shared/display.zig"),
        .target = user_target,
        .optimize = .ReleaseSmall,
    });
    const input_contract = b.createModule(.{
        .root_source_file = b.path("shared/input.zig"),
        .target = user_target,
        .optimize = .ReleaseSmall,
    });
    const compositor_contract = b.createModule(.{
        .root_source_file = b.path("shared/compositor.zig"),
        .target = user_target,
        .optimize = .ReleaseSmall,
    });
    const sdk_module = b.createModule(.{
        .root_source_file = b.path("sdk/src/root.zig"),
        .target = user_target,
        .optimize = .ReleaseSmall,
    });
    sdk_module.addImport("voryn_display", display_contract);
    sdk_module.addImport("voryn_input", input_contract);
    sdk_module.addImport("voryn_compositor", compositor_contract);
    const user_module = b.createModule(.{
        .root_source_file = b.path("user/hello.zig"),
        .target = user_target,
        .optimize = .ReleaseSmall,
        .single_threaded = true,
        .pic = true,
    });
    user_module.addImport("voryn_sdk", sdk_module);
    user_module.addImport("voryn_input", input_contract);
    user_module.addAssemblyFile(b.path("user/start.s"));
    const user_executable = b.addExecutable(.{
        .name = "voryn-native-hello",
        .root_module = user_module,
    });
    user_executable.pie = true;

    const client_module = b.createModule(.{
        .root_source_file = b.path("user/client.zig"),
        .target = user_target,
        .optimize = .ReleaseSmall,
        .single_threaded = true,
        .pic = true,
    });
    client_module.addImport("voryn_sdk", sdk_module);
    client_module.addImport("voryn_input", input_contract);
    client_module.addAssemblyFile(b.path("user/start.s"));
    const client_executable = b.addExecutable(.{
        .name = "voryn-native-client",
        .root_module = client_module,
    });
    client_executable.pie = true;

    const converter_module = b.createModule(.{
        .root_source_file = b.path("tools/bin2zig.zig"),
        .target = b.resolveTargetQuery(.{}),
        .optimize = .ReleaseFast,
    });
    const converter = b.addExecutable(.{
        .name = "bin2zig",
        .root_module = converter_module,
    });

    const conversion = b.addRunArtifact(converter);
    conversion.addFileArg(user_executable.getEmittedBin());
    const native_app_output = conversion.addOutputFileArg("native_app.zig");

    const client_conversion = b.addRunArtifact(converter);
    client_conversion.addFileArg(client_executable.getEmittedBin());
    const client_app_output = client_conversion.addOutputFileArg("client_app.zig");

    // ------------------------------------------------------------------
    // Voryn Nucleus Kernel.
    // ------------------------------------------------------------------
    const kernel_target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .freestanding,
        .abi = .none,
    });
    const kernel_module = b.createModule(.{
        .root_source_file = b.path("kernel/main.zig"),
        .target = kernel_target,
        .optimize = optimize,
        .single_threaded = true,
        .pic = true,
        // The trace of the errors is a feature of the development, and it
        // reads a register that the caller of a function that does not
        // return an error does not set. The kernel does not have a runtime
        // that can report a trace, and the mechanism itself is able to
        // raise a fault in the middle of a message of the console.
        .error_tracing = false,
    });
    const block_kernel_module = b.createModule(.{
        .root_source_file = b.path("kernel/storage/block.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    kernel_module.addImport("voryn_block", block_kernel_module);

    const kernel_keyboard_module = b.createModule(.{
        .root_source_file = b.path("kernel/input/keyboard.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    kernel_module.addImport("voryn_keyboard", kernel_keyboard_module);
    // The VPK container codec is pure and shared with the SDK/toolchain;
    // the kernel instance compiles for the freestanding target.
    const vpk_kernel_module = b.createModule(.{
        .root_source_file = b.path("formats/vpk.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    kernel_module.addImport("voryn_vpk", vpk_kernel_module);
    // The VEX executable container is imported by the ELF loader; both the
    // kernel and the host test root compile their own instance.
    const vex_kernel_module = b.createModule(.{
        .root_source_file = b.path("formats/vex.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    kernel_module.addImport("voryn_vex", vex_kernel_module);
    kernel_module.addAssemblyFile(b.path("kernel/arch/x86_64/entry.s"));
    kernel_module.addAssemblyFile(b.path("kernel/arch/x86_64/cpu.s"));
    kernel_module.addAssemblyFile(b.path("kernel/arch/x86_64/segment.s"));
    kernel_module.addAssemblyFile(b.path("kernel/arch/x86_64/interrupt.s"));
    kernel_module.addAssemblyFile(b.path("kernel/arch/x86_64/task.s"));
    kernel_module.addAssemblyFile(b.path("kernel/arch/x86_64/syscall.s"));
    kernel_module.addAssemblyFile(b.path("kernel/arch/x86_64/ap_trampoline.s"));
    kernel_module.addImport("voryn_shared", shared);
    kernel_module.addAnonymousImport("native_app", .{
        .root_source_file = native_app_output,
    });
    kernel_module.addAnonymousImport("client_app", .{
        .root_source_file = client_app_output,
    });
    const kernel_executable = b.addExecutable(.{
        .name = "voryn-kernel",
        .root_module = kernel_module,
    });
    kernel_executable.entry = .{ .symbol_name = "voryn_kernel_entry" };
    kernel_executable.pie = true;
    kernel_executable.step.dependOn(&conversion.step);
    kernel_executable.step.dependOn(&client_conversion.step);
    b.installArtifact(kernel_executable);

    // ------------------------------------------------------------------
    // Host tools.
    // ------------------------------------------------------------------
    const fsimg_module = b.createModule(.{
        .root_source_file = b.path("tools/fatimg.zig"),
        .target = target,
        .optimize = optimize,
    });
    const fsimg_executable = b.addExecutable(.{
        .name = "voryn-fsimg",
        .root_module = fsimg_module,
    });
    b.installArtifact(fsimg_executable);

    // ------------------------------------------------------------------
    // Boot image.
    // ------------------------------------------------------------------
    const image_step = b.addRunArtifact(fsimg_executable);
    image_step.addPrefixedFileArg("--efi=", boot_executable.getEmittedBin());
    image_step.addPrefixedFileArg("--kernel=", kernel_executable.getEmittedBin());
    // The image is written into the installation directory. It is not
    // declared as a build output because the build system would then compare
    // the content of a file that embeds the kernel binary on every rebuild.
    const image_path = b.path("zig-out/bin/vorynos.img");
    image_step.addPrefixedFileArg("--output=", image_path);
    image_step.has_side_effects = true;

    const image_build_step = b.step("image", "Build the bootable EFI system partition image");
    image_build_step.dependOn(&image_step.step);

    // ------------------------------------------------------------------
    // Tests.
    // ------------------------------------------------------------------
    const unit_test_step = b.step("test", "Run the host unit tests");
    // The root module of a compilation needs a known target, therefore the
    // host unit tests use their own instance of the shared module.
    const shared_test_module = b.createModule(.{
        .root_source_file = b.path("shared/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const shared_tests = b.addTest(.{
        .name = "shared-tests",
        .root_module = shared_test_module,
    });
    unit_test_step.dependOn(&b.addRunArtifact(shared_tests).step);

    // SDK: testes de contratos e decodificação de erros no host.
    const sdk_test_module = b.createModule(.{
        .root_source_file = b.path("sdk/src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const display_host_module = b.createModule(.{
        .root_source_file = b.path("shared/display.zig"),
        .target = target,
        .optimize = optimize,
    });
    const input_host_module = b.createModule(.{
        .root_source_file = b.path("shared/input.zig"),
        .target = target,
        .optimize = optimize,
    });
    const compositor_host_module = b.createModule(.{
        .root_source_file = b.path("shared/compositor.zig"),
        .target = target,
        .optimize = optimize,
    });
    sdk_test_module.addImport("voryn_display", display_host_module);
    sdk_test_module.addImport("voryn_input", input_host_module);
    sdk_test_module.addImport("voryn_compositor", compositor_host_module);
    const sdk_tests = b.addTest(.{
        .name = "sdk-tests",
        .root_module = sdk_test_module,
    });
    unit_test_step.dependOn(&b.addRunArtifact(sdk_tests).step);

    // F5: container VPK, codec puro testado no host.
    const vpk_test_module = b.createModule(.{
        .root_source_file = b.path("formats/vpk.zig"),
        .target = target,
        .optimize = optimize,
    });
    const vpk_tests = b.addTest(.{
        .name = "vpk-tests",
        .root_module = vpk_test_module,
    });
    unit_test_step.dependOn(&b.addRunArtifact(vpk_tests).step);

    // F5: container VEX (executável nativo), codec puro testado no host.
    const vex_test_module = b.createModule(.{
        .root_source_file = b.path("formats/vex.zig"),
        .target = target,
        .optimize = optimize,
    });
    const ai_test_module = b.createModule(.{
        .root_source_file = b.path("kernel/ai/model.zig"),
        .target = target,
        .optimize = optimize,
    });
    const ai_tests = b.addTest(.{
        .name = "ai-tests",
        .root_module = ai_test_module,
    });
    unit_test_step.dependOn(&b.addRunArtifact(ai_tests).step);
    const vex_tests = b.addTest(.{
        .name = "vex-tests",
        .root_module = vex_test_module,
    });
    unit_test_step.dependOn(&b.addRunArtifact(vex_tests).step);

    // F6: rasterizador puro, testado sem hardware de vídeo.
    const raster_test_module = b.createModule(.{
        .root_source_file = b.path("kernel/graphics/raster.zig"),
        .target = target,
        .optimize = optimize,
    });
    const raster_tests = b.addTest(.{
        .name = "raster-tests",
        .root_module = raster_test_module,
    });
    unit_test_step.dependOn(&b.addRunArtifact(raster_tests).step);

    // F6: compositor opaco sobre rasterizador puro.
    const compositor_test_module = b.createModule(.{
        .root_source_file = b.path("kernel/graphics/compositor.zig"),
        .target = target,
        .optimize = optimize,
    });
    const compositor_tests = b.addTest(.{
        .name = "compositor-tests",
        .root_module = compositor_test_module,
    });
    unit_test_step.dependOn(&b.addRunArtifact(compositor_tests).step);

    // F6.28: composição de janelas no buffer do modo usuário, sem syscalls
    // nem acesso ao framebuffer.
    const user_composition_test_module = b.createModule(.{
        .root_source_file = b.path("user/composition.zig"),
        .target = target,
        .optimize = optimize,
    });
    user_composition_test_module.addImport("voryn_input", input_host_module);
    const user_composition_tests = b.addTest(.{
        .name = "user-composition-tests",
        .root_module = user_composition_test_module,
    });
    unit_test_step.dependOn(&b.addRunArtifact(user_composition_tests).step);

    // F6.4: rastreamento de regiões modificadas e mutações de janelas.
    const damage_test_module = b.createModule(.{
        .root_source_file = b.path("kernel/graphics/damage.zig"),
        .target = target,
        .optimize = optimize,
    });
    const damage_tests = b.addTest(.{
        .name = "damage-tests",
        .root_module = damage_test_module,
    });
    unit_test_step.dependOn(&b.addRunArtifact(damage_tests).step);

    // F6.25: registro da metadata do display, sem tocar no framebuffer.
    const display_test_module = b.createModule(.{
        .root_source_file = b.path("kernel/graphics/display.zig"),
        .target = target,
        .optimize = optimize,
    });
    display_test_module.addImport("voryn_shared", shared_test_module);
    const display_tests = b.addTest(.{
        .name = "display-tests",
        .root_module = display_test_module,
    });
    unit_test_step.dependOn(&b.addRunArtifact(display_tests).step);

    const motion_module = b.createModule(.{
        .root_source_file = b.path("kernel/graphics/keyboard_motion.zig"),
        .target = target,
        .optimize = optimize,
    });
    const motion_keyboard_module = b.createModule(.{
        .root_source_file = b.path("kernel/input/keyboard.zig"),
        .target = target,
        .optimize = optimize,
    });
    motion_module.addImport("voryn_keyboard", motion_keyboard_module);
    const motion_tests = b.addTest(.{
        .name = "keyboard-motion-tests",
        .root_module = motion_module,
    });
    unit_test_step.dependOn(&b.addRunArtifact(motion_tests).step);

    // F6.6: fila de eventos e decodificação de teclado PS/2 no host.
    const keyboard_test_module = b.createModule(.{
        .root_source_file = b.path("kernel/input/keyboard.zig"),
        .target = target,
        .optimize = optimize,
    });
    const keyboard_tests = b.addTest(.{
        .name = "keyboard-tests",
        .root_module = keyboard_test_module,
    });
    unit_test_step.dependOn(&b.addRunArtifact(keyboard_tests).step);

    // The memory managers of the kernel are free of architecture specific
    // code and are tested on the host as well.
    const kernel_test_module = b.createModule(.{
        .root_source_file = b.path("kernel/memory/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    kernel_test_module.addImport("voryn_shared", shared);
    const kernel_tests = b.addTest(.{
        .name = "kernel-tests",
        .root_module = kernel_test_module,
    });
    unit_test_step.dependOn(&b.addRunArtifact(kernel_tests).step);

    // The security modules of the kernel are free of architecture specific
    // code and are tested on the host as well.
    const security_test_module = b.createModule(.{
        .root_source_file = b.path("kernel/security/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    security_test_module.addImport("voryn_shared", shared);
    const security_tests = b.addTest(.{
        .name = "security-tests",
        .root_module = security_test_module,
    });
    unit_test_step.dependOn(&b.addRunArtifact(security_tests).step);

    // The architecture modules that do not touch the hardware are tested on
    // the host as well.
    const arch_test_module = b.createModule(.{
        .root_source_file = b.path("kernel/arch/x86_64/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    arch_test_module.addImport("voryn_shared", shared);
    const arch_tests = b.addTest(.{
        .name = "arch-tests",
        .root_module = arch_test_module,
    });
    unit_test_step.dependOn(&b.addRunArtifact(arch_tests).step);

    // VVDI (Voryn Virtual Device Interface) — transporte moderno e virtqueue
    // dividida (VirtIO 1.2): tipos, identificadores, estados, features,
    // capabilities, MMIO, transporte e a virtqueue dividida. Os modulos sao
    // puros: o acesso a memoria de dispositivo e injetado, o mapeamento e
    // injetado, a configuracao comum e lida por um `Registers` que os testes
    // implementam sobre memoria e a fila roda sobre um buffer comum. Por isso
    // os testes rodam no host, sem port I/O e sem hardware. A raiz fica em
    // `kernel/drivers/vvdi/root.zig` porque a raiz de um modulo Zig precisa
    // estar acima de todos os arquivos importados.
    const vvdi_test_module = b.createModule(.{
        .root_source_file = b.path("kernel/drivers/vvdi/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const block_vvdi_test_module = b.createModule(.{
        .root_source_file = b.path("kernel/storage/block.zig"),
        .target = target,
        .optimize = optimize,
    });
    vvdi_test_module.addImport("voryn_block", block_vvdi_test_module);
    const vvdi_tests = b.addTest(.{
        .name = "vvdi-tests",
        .root_module = vvdi_test_module,
    });
    unit_test_step.dependOn(&b.addRunArtifact(vvdi_tests).step);

    // The IPC modules of the kernel are free of architecture specific code
    // and are tested on the host as well. The root lives at the top of the
    // kernel tree because the channel uses the context of the tasks.
    const ipc_test_module = b.createModule(.{
        .root_source_file = b.path("kernel/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    ipc_test_module.addImport("voryn_shared", shared);
    const ipc_tests = b.addTest(.{
        .name = "ipc-tests",
        .root_module = ipc_test_module,
    });
    unit_test_step.dependOn(&b.addRunArtifact(ipc_tests).step);

    // The RamFS and the ELF64 load planner are free of architecture
    // specific code. They share a root at the top of the kernel tree
    // because the loader imports the file system.
    const host_test_module = b.createModule(.{
        .root_source_file = b.path("kernel/host_root.zig"),
        .target = target,
        .optimize = optimize,
    });
    host_test_module.addImport("voryn_shared", shared);
    const block_host_module = b.createModule(.{
        .root_source_file = b.path("kernel/storage/block.zig"),
        .target = target,
        .optimize = optimize,
    });
    host_test_module.addImport("voryn_block", block_host_module);
    const vex_host_module = b.createModule(.{
        .root_source_file = b.path("formats/vex.zig"),
        .target = target,
        .optimize = optimize,
    });
    host_test_module.addImport("voryn_vex", vex_host_module);
    const host_tests = b.addTest(.{
        .name = "fs-loader-tests",
        .root_module = host_test_module,
    });
    unit_test_step.dependOn(&b.addRunArtifact(host_tests).step);

    // The steps that use the image depend on the step that builds it: the
    // test has to run against the image of the tree, and not against the
    // image that a previous run left in the installation directory.
    const qemu_test_step = b.step("qemu-test", "Run the automated boot test in QEMU");
    const qemu_test = b.addSystemCommand(&.{ "bash", "tests/integration/boot-qemu.sh" });
    qemu_test.addPrefixedFileArg("--image=", image_path);
    qemu_test.has_side_effects = true;
    // The command reads the image, and the dependency on the step that
    // groups the two commands does not order them: without the edge below
    // the build system may run the test against the image of the previous
    // build.
    qemu_test.step.dependOn(&image_step.step);
    qemu_test_step.dependOn(&image_step.step);
    qemu_test_step.dependOn(&qemu_test.step);

    const storage_test_step = b.step("qemu-storage-test", "Verify VirtIO Block I/O and persistence across two QEMU boots");
    const storage_test = b.addSystemCommand(&.{ "bash", "tests/integration/virtio-block-persistence.sh" });
    storage_test.addPrefixedFileArg("--image=", image_path);
    storage_test.has_side_effects = true;
    storage_test.step.dependOn(&image_step.step);
    storage_test_step.dependOn(&image_step.step);
    storage_test_step.dependOn(&storage_test.step);

    const interactive_test_step = b.step("qemu-interactive-test", "Verify persistent PS/2 graphics input in QEMU");
    const interactive_test = b.addSystemCommand(&.{ "bash", "tests/integration/interactive-qemu.sh" });
    interactive_test.addPrefixedFileArg("--image=", image_path);
    interactive_test.has_side_effects = true;
    interactive_test.step.dependOn(&image_step.step);
    interactive_test_step.dependOn(&interactive_test.step);

    const qemu_run_step = b.step("qemu", "Boot the image in QEMU");
    const qemu_run = b.addSystemCommand(&.{ "bash", "scripts/qemu-run.sh" });
    qemu_run.addPrefixedFileArg("--image=", image_path);
    qemu_run.has_side_effects = true;
    qemu_run.step.dependOn(&image_step.step);
    qemu_run_step.dependOn(&image_step.step);
    qemu_run_step.dependOn(&qemu_run.step);

    const check_step = b.step("check", "Run the unit tests and the automated boot test");
    check_step.dependOn(unit_test_step);
    check_step.dependOn(qemu_test_step);
    check_step.dependOn(storage_test_step);

    // ------------------------------------------------------------------
    // Default step.
    // ------------------------------------------------------------------
    b.getInstallStep().dependOn(&image_step.step);
}
