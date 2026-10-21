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
//!   * `zig build check`        - unit tests and automated boot test.

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
    });
    boot_module.addImport("voryn_shared", shared);
    const boot_executable = b.addExecutable(.{
        .name = "voryn-boot",
        .root_module = boot_module,
    });
    b.installArtifact(boot_executable);

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
    });
    kernel_module.addAssemblyFile(b.path("kernel/arch/x86_64/entry.s"));
    kernel_module.addAssemblyFile(b.path("kernel/arch/x86_64/segment.s"));
    kernel_module.addAssemblyFile(b.path("kernel/arch/x86_64/interrupt.s"));
    kernel_module.addImport("voryn_shared", shared);
    const kernel_executable = b.addExecutable(.{
        .name = "voryn-kernel",
        .root_module = kernel_module,
    });
    kernel_executable.entry = .{ .symbol_name = "voryn_kernel_entry" };
    kernel_executable.pie = true;
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

    const qemu_test_step = b.step("qemu-test", "Run the automated boot test in QEMU");
    const qemu_test = b.addSystemCommand(&.{"bash", "tests/integration/boot-qemu.sh"});
    qemu_test.addPrefixedFileArg("--image=", image_path);
    qemu_test.has_side_effects = true;
    qemu_test_step.dependOn(&qemu_test.step);

    const qemu_run_step = b.step("qemu", "Boot the image in QEMU");
    const qemu_run = b.addSystemCommand(&.{"bash", "scripts/qemu-run.sh"});
    qemu_run.addPrefixedFileArg("--image=", image_path);
    qemu_run.has_side_effects = true;
    qemu_run_step.dependOn(&qemu_run.step);

    const check_step = b.step("check", "Run the unit tests and the automated boot test");
    check_step.dependOn(unit_test_step);
    check_step.dependOn(qemu_test_step);

    // ------------------------------------------------------------------
    // Default step.
    // ------------------------------------------------------------------
    b.getInstallStep().dependOn(&image_step.step);
}
