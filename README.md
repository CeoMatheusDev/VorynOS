# VorynOS

> **Liberdade • Performance • Seu Controle**

Sistema operacional independente, escrito do zero em Zig 0.17.0, com C23 e
Assembly quando a tarefa exigir controle direto da máquina.

O VorynOS não é uma distribuição Linux, um fork do Windows, uma modificação
de BSD, nem uma interface gráfica sobre outro kernel. O kernel, o runtime, as
APIs e os mecanismos centrais são próprios e implementados neste repositório.

![Logo do VorynOS](Logos_VorynOS.png)

---

## Estado atual

| Marco | Escopo | Estado |
|-------|---------|--------|
| F0 | Fundação: auditoria de ambiente, toolchain, estrutura, build, documentação, ADRs | **CONCLUÍDO** |
| F1 | Boot: VNB em UEFI, carga do kernel, saída serial, framebuffer, handoff controlado | **TESTADO LOCALMENTE** |
| F2 | Kernel: GDT, TSS, IDT, exceções, interrupções, memória física e virtual, heap, timer | **TESTADO LOCALMENTE** |
| F3 | Execução: threads, scheduler, processos, user mode, syscalls, IPC, capacidades | PROPOSTO |
| F4–F10 | Armazenamento, ecossistema, desktop, drivers, compatibilidade, IA, produção | PROPOSTO |

O que existe hoje, de fato e verificado:

- **VNB (Voryn Native Boot)**: aplicação UEFI x86_64 própria, escrita em Zig.
  Descobre o framebuffer (GOP), adquire o mapa de memória do firmware, lê a
  imagem do kernel do volume de boot, valida a imagem ELF64, posiciona os
  segmentos em memória física, aplica as realocações de uma imagem
  relocável, monta o contrato de handoff e executa `ExitBootServices` com
  nova tentativa em caso de mapa de memória alterado.
- **VNK (Voryn Nucleus Kernel)**: núcleo mínimo, em Zig e Assembly, que
  valida o contrato de handoff, instala as estruturas do processador (tabela
  de segmentos, segmento de tarefa, tabela de interrupções, tabelas de
  página), gerencia a memória física e o heap, programa o temporizador e
  relata as exceções com o estado completo do processador.
- **Contrato de handoff** (`shared/handoff.zig`): estrutura versionada e
  verificada nos dois lados da fronteira firmware/kernel.
- **Ferramenta de imagem de disco** (`tools/fatimg.zig`): construtor de volume
  FAT16 próprio, sem dependência de ferramentas externas de disco.
- **Testes**: suíte de unidade no host (`zig build test`) e teste automatizado
  de boot no QEMU/OVMF (`zig build qemu-test`).

O que **não** existe ainda: escalonador, processos, modo de usuário,
syscalls, IPC, capacidades, sistema de arquivos, drivers, interface gráfica.
Nenhuma dessas funcionalidades é declarada como implementada.

---

## Requisitos

| Componente | Versão | Observação |
|------------|---------|------------|
| Zig | 0.17.0 | Obrigatória. Verifique com `zig version`. |
| QEMU | 10.x | `qemu-system-x86_64` com OVMF. |
| OVMF | edk2 | `/usr/share/edk2/ovmf/OVMF_CODE.fd` e `OVMF_VARS.fd`. |
| Bash, utilitários coreutils | qualquer | Usados apenas pelos scripts de teste. |

Ambiente de desenvolvimento de referência: Fedora Linux 44, x86_64.

---

## Construção

```bash
zig build                 # build completo: bootloader, kernel, ferramentas e imagem
zig build test            # testes de unidade no host
zig build qemu-test       # teste automatizado de boot (QEMU + OVMF)
zig build qemu            # boot interativo no QEMU com console serial
zig build check           # testes de unidade + teste de boot
```

Artefatos produced:

```text
zig-out/bin/voryn-boot.efi   aplicação UEFI do Voryn Native Boot
zig-out/bin/voryn-kernel     imagem ELF64 relocável do Voryn Nucleus Kernel
zig-out/bin/voryn-fsimg      construtor de imagem de disco
zig-out/vorynos.img          volume EFI inicializável com os dois anteriores
```

### Execução manual

```bash
zig build qemu
```

O console serial é o canal de diagnóstico primário. Pressione `Ctrl+a x` para
sair do emulador.

---

## Execução verificada

Saída real do teste automatizado de boot (`zig build qemu-test`):

```text
[VNB] VorynOS 0.1.0-dev.1 - Voryn Native Boot
[VNB] framebuffer 2048x2048 bpp=32 pitch=8192 size=0x1000000 base=0x80000000
[VNB] memory map: 86 regions
[VNB] kernel image: 3374370 bytes
[VNB] kernel placed: base=0x200000 end=0x2858c0 entry=0x24b660 segments=4 relocations=165
[VNB] leaving firmware, entering kernel at 0x24b660
[VNK] Voryn Nucleus Kernel 0.1.0-dev.1
[VNK] handoff ok: version=1 flags=0xf
[VNK] cpu: family=15 model=21 stepping=177 cores=1 phys_bits=40 virt_bits=48
[VNK] memory: 87 regions, 203 MiB RAM
[VNK] framebuffer: 2048x2048 bpp=32 pitch=8192 base=0x80000000
[VNK] segments: gdt installed and verified
[VNK] interrupts: idt installed and verified
[VNK] segments: task state segment loaded
[VNK] memory: 51551 pages, 360 used, 51191 free
[VNK] paging: cr3 0xf401000 -> 0x355000
[VNK] heap: 256 KiB region, 0 allocations, 0 bytes used
[VNK] timer: 100 Hz, 5 ticks
[VNK] framebuffer: write probe succeeded
VORYN-KERNEL-READY
[VNK] EXCEPTION 6: invalid opcode
```

---

## Arquitetura

O modelo de componentes é o **Voryn Fabric**, documentado em
[`docs/adr/ADR-0001-voryn-fabric.md`](docs/adr/ADR-0001-voryn-fabric.md):

| Componente | Nome | Responsabilidade |
|------------|------|------------------|
| VNB | Voryn Native Boot | Loader UEFI, fronteira firmware/kernel |
| VNK | Voryn Nucleus Kernel | Mecanismos privilegiados mínimos |
| VNH | Voryn Hardware Nexus | Descoberta e interface de hardware |
| VNM | Voryn Nexus Memory | Memória física, virtual, alocadores |
| VNT | Voryn Task Fabric | Tarefas e escalonamento |
| VNX | Voryn Exchange | Comunicação entre processos |
| VNC | Voryn Capability Fabric | Segurança por capacidades |
| VND | Voryn Device Fabric | Drivers isoláveis |
| VSN | Voryn Service Node | Serviços, supervisão, recuperação |

Mapa dos módulos e contratos: [`docs/architecture/overview.md`](docs/architecture/overview.md).

---

## Documentação

| Documento | Conteúdo |
|-----------|----------|
| [`AGENTS.md`](AGENTS.md) | Protocolo de engenharia e regras de trabalho |
| [`docs/adr/`](docs/adr/) | Decisões de arquitetura e seus custos |
| [`docs/specs/`](docs/specs/) | Especificações normativas de contratos e formatos |
| [`docs/standards/`](docs/standards/) | Padrões de versionamento e de nomes |
| [`docs/roadmap/`](docs/roadmap/) | Marcos, estado e critérios de aceite |
| [`docs/testing/`](docs/testing/) | Estratégia de teste e evidências |

---

## Repositório

- Branch principal: `main`
- Commits pequenos e descritivos, escritos em português brasileiro.
- Nenhuma publicação (push, tag, release) é feita sem autorização explícita.

---

## Licença

**GPL-3.0-only.** Todo o código deste repositório é original e escrito para o
projeto; nenhuma implementação proprietária foi copiada. Contribuições são
aceitas nos termos descritos em [CONTRIBUTING.md](CONTRIBUTING.md). Relatos de
vulnerabilidade seguem [SECURITY.md](SECURITY.md).
