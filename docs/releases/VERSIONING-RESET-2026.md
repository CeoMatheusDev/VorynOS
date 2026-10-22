# VERSIONING-RESET-2026 — Reorganization of the public versioning

| Field | Value |
|-------|-------|
| **State** | COMPLETED |
| **Date** | 2026-10-22 |
| **Scope** | Public versioning milestones of the repository |
| **Nature** | Reorganization of Git references and of documentation |

## 1. Objective

Establish `v0.1.0-dev.1` as the **official initial milestone** of the
public development of the VorynOS, taking full advantage of the current
state of the `main` branch, and discontinue the two experimental milestones
published earlier.

**This operation is not a restart of the source code.** The commit history
of `main` is preserved, the existing code is preserved, and no feature was
removed.

## 2. What was discontinued

| Identifier | Release title | Pointed commit | Tag object | Published at |
|---|---|---|---|---|
| `v0.1.0-dev.2` | VorynOS v0.1.0-dev.2 — Native UEFI Boot & Kernel Bring-Up | `42c3e62fbf84798d07cf36c3461d6b73e51cbb0f` | `91e1e06d481b6b793b9b4fe25ff7b34e30868d06` | 2026-10-21T20:58:00Z |
| `v0.1.0-dev.3` | VorynOS v0.1.0-dev.3 — User-Mode Execution Milestone | `5dd258830823ca8a9d9a257460643c7924ee23d9` | `0b2cbd33449141f79f1404000af26ae387095e8a` | 2026-10-21T22:57:46Z |

The two commits above **were not rewritten, discarded nor erased**. They
remain preserved in the archive branch `archive/versioning-reset-2026`,
which points to the top of the old lineage and is reachable from any copy
of the repository. They are the original technical reference of each
milestone.

**The archive branch does not replace the history of `main`.** The `main`
has the full history of the current line, with the integration of the
parallel work, and the `archive/versioning-reset-2026` exists only so that
the commits of the discontinued milestones remain reachable after the
removal of the tags that pointed to them.

## 3. Technical state registered for each milestone

### v0.1.0-dev.2 — Native UEFI Boot & Kernel Bring-Up

Technical state registered at the date of the publication, on 21/10/2026:

- Native UEFI bootloader, in Zig, without a dependency on libc.
- Loading of the kernel in ELF64, with the versioned boot contract.
- End to end boot validation with QEMU and OVMF.
- Initialization of the x86_64 kernel, with GDT, TSS and IDT.
- Management of physical and virtual memory, with own page tables.
- Kernel heap with block merging and integrity verification.
- Circular preemptive scheduler, driven by a 100 Hz timer.
- Infrastructure of automated tests, with tests on the host and boot
  verification in the emulator.
- Initial user mode infrastructure, **disabled** at the date of the
  publication, waiting for the correction of the handling of exceptions.

### v0.1.0-dev.3 — User-Mode Execution Milestone

Technical state registered at the date of the publication, on 21/10/2026:

- Verified execution in the third privilege level, with the round trip of
  the user mode.
- Pages of the user space with the access attributes of the user.
- Native system calls through the `syscall` instruction, with the handler
  in the kernel written in Zig.
- Kernel stack per task, for the privileged execution.
- Correction of the layout of the task segment of the 64 bit mode, which was
  the root cause of the failure of the delivery of an exception that came
  from the user.
- Return to the user mode with `iretq`, preserving the flags of the caller.
- Preemptive scheduling by timer, integrated with the verified path of the
  execution of the user mode.
- Boot test in QEMU that requires explicit evidence of the execution in the
  user mode, and the interrupt sequence of the emulator without any
  exception registered.

**What the `v0.1.0-dev.3` milestone claimed and that this reorganization
does not change:** it claimed the execution in the user mode and the path
of the system call. It **did not** claim the existence of processes, of
threads, of communication between processes, nor of capabilities. The
`v0.1.0-dev.1` milestone keeps that distinction explicit.

## 4. Reason of the discontinuation

1. The two milestones were published as **partial experiments**, with the
   `dev` channel and without a contract guarantee, and each one of them
   covered only a slice of the boot path.
2. The numbering of the `dev` channel came to suggest an order of progress
   that did not correspond to the real state of the code: the `dev.3` was
   earlier than the current state, and the current state is the
   consolidated one.
3. The reorganization gives the project **one single and coherent
   baseline**, from which the numbering makes sense again, and from which
   every next release corresponds to a verifiable technical increment.

**What did not motivate the discontinuation:** no technical failure, no
regression, and no quality problem of the published code. The old
milestones were verified at the time, and the record above preserves what
they claimed.

## 5. Procedure that was carried out

1. Registration of the identifier, of the commit and of the publication date
   of each one of the two milestones, and transcription of the technical
   state of each one into this document.
2. **Integration of the parallel work that was in the remote `main` branch.**
   The remote branch contained 34 commits that the local copy did not have:
   35 standardizations of the source code header, a new rule in the
   `AGENTS.md`, and a preparatory note of the `v0.1.0-dev.1`. The work was
   integrated by **merge**, which preserves both histories, without
   rebase and without force. The preparatory note was replaced by the
   official notes of this version, and the headers were preserved.
3. **Correction of the standardized header in the Zig files.** The remote
   standardization wrote the header as a block comment `/* ... */`, and in
   Zig 0.17.0 a block comment before a documentation comment `//!` is a
   **syntax error**: the whole file was refused by the compiler, and
   `zig build` failed at `build.zig:1:1`. The header of the Zig files now
   uses line comments `//`, which preserve the visual frame, the identity,
   the address of the repository, the copyright and the SPDX, and that the
   compiler accepts. The block form remains in the Assembly files, where
   there is no file documentation comment. The rule and the restriction are
   registered in section 14 of the `AGENTS.md`.
4. Update of the version constants of the project — the `build.zig.zon`
   package, the loader and the kernel — to `0.1.0-dev.1`.
5. Creation of the official notes of the new version in
   [`v0.1.0-dev.1.md`](v0.1.0-dev.1.md).
6. Registration of the extraordinary exception in the
   [VVS-0001](../standards/VVS-0001.md).
7. Update of the README, of the roadmap and of the references of the
   repository.
8. Verification of the code, with `zig build`, `zig build test`,
   `zig build qemu-test` and `zig build check`.
9. Publication of the commit, of the annotated tag `v0.1.0-dev.1` and of
   the corresponding release, marked as a pre-release.
10. **After** the confirmation of the existence of the new tag and of the
    new release, removal of the releases `v0.1.0-dev.2` and `v0.1.0-dev.3`,
    and removal of the remote tags with the same two identifiers, one
    operation at a time.
11. Final verification of the repository and of the integrity comparison of
    the code.

## 6. What was preserved

- The `main` branch was **not** erased, rewritten or repositioned, and no
  forced `push` was executed.
- The commit history of `main` is **intact**: the integration of the
  parallel work was done by merge, which preserves both histories.
- The two commits of the discontinued milestones remain reachable, in the
  archive branch `archive/versioning-reset-2026`.
- No source file was erased, and no feature was discarded.
- The historical documentation of the two milestones is in this document and
  in the history of Git.
- No other release or tag was removed.

## 7. Integrity comparison of the code

The reorganization **did not change any logic**. The differences in the
functional files of `boot/`, `kernel/`, `shared/`, `tools/`, `scripts/` and
`tests/` are of two natures, and both are declared:

1. **The version constants**, which now identify the new milestone:

   ```diff
   -const loader_version = "0.1.0-dev.3";
   +const loader_version = "0.1.0-dev.1";
   ```

   ```diff
   -const kernel_version = "0.1.0-dev.3";
   +const kernel_version = "0.1.0-dev.1";
   ```

   And, outside the verified set, the manifest of the package:

   ```diff
   -    .version = "0.1.0-dev.3",
   +    .version = "0.1.0-dev.1",
   ```

2. **The standardized visual header** of the 29 Zig files, which came from
   the parallel work of the remote `main` branch and was **preserved** by
   the integration. The correction applied to it was only the form of the
   comment, from block to line, because the block form broke the build
   (section 5, item 3).

The verification is done by the comparison of the SHA-256 checksums of all
the 36 files of those directories. The **set of files** is identical to the
state before the reorganization, and the difference of content is limited to
the two natures above. No machine instruction, no logic, no table, no
contract and no test was changed.

## 8. Original Git reference

| Identifier | Commit | Annotated tag | Where the commit remains |
|---|---|---|---|
| `v0.1.0-dev.1` (new) | `1c47f505b766538398214f1b5c8ee473c4c96527` | annotated tag `v0.1.0-dev.1` | branch `main` |
| `v0.1.0-dev.2` (discontinued) | `42c3e62fbf84798d07cf36c3461d6b73e51cbb0f` | `91e1e06d481b6b793b9b4fe25ff7b34e30868d06` | branch `archive/versioning-reset-2026` |
| `v0.1.0-dev.3` (discontinued) | `5dd258830823ca8a9d9a257460643c7924ee23d9` | `0b2cbd33449141f79f1404000af26ae387095e8a` | branch `archive/versioning-reset-2026` |

## 9. The republication of the same version

The first publication of `v0.1.0-dev.1` pointed to the commit
`1539547cf6e6f213a53db75148cbd7cc88cee256`, which is the state of the
project before the audit and the curation of the distribution package.

The later audit found proven inconsistencies between the documentation and
the published code: the count of the system calls, the count of the checks
of the boot test and the state of the blocking receive were outdated, and
the source package generated from the old tag carried the internal
development documents.

At the explicit request of the owner, the same version was
**republished**:

1. The old release and the old tag were removed, after the old commit was
   preserved in a backup reference identified as historical.
2. The `v0.1.0-dev.1` tag was recreated, annotated, over the final validated
   commit of `main`.
3. A new release, with the same identifier and with the rewritten notes,
   was published with the official filtered package as an asset.

**The republication does not change the history of `main`**, and the commit
tree of the project is the same before and after: the republication removed
one version reference, and not one line of development.

The versioning policy registers the exception in section 8 of the
[VVS-0001](../standards/VVS-0001.md).

## 10. Versioning policy from now on

The official sequence begins at `v0.1.0-dev.1`:

```text
v0.1.0-dev.1
      |
      | Real next changes
      v
v0.1.0-dev.2
      |
      | New increments
      v
v0.1.0-dev.3
      |
      v
v0.1.0-alpha.1
```

Every new release corresponds to a **verifiable technical increment**, and
the identifier of a release points to a commit **different** from the
commit of any old milestone.

The exception registered in the VVS-0001 is **extraordinary and unique**. It
does not establish a general permission to reuse a published identifier:
the prohibition remains in force for the future, and the exception only
holds for the two identifiers discontinued here.
