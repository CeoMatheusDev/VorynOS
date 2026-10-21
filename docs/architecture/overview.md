# Visão geral da arquitetura

Este documento descreve o estado **real** da arquitetura do VorynOS neste
incremento. Ele não descreve o sistema final: descreve o que existe, como as
partes se conectam e o que ainda não existe.

O modelo de componentes e seus custos estão em
[`../adr/ADR-0001-voryn-fabric.md`](../adr/ADR-0001-voryn-fabric.md).

## 1. Cadeia de boot

```text
   Firmware UEFI (OVMF)
            │
            │  ExitBootServices
            ▼
   ┌──────────────────────┐
   │  VNB — Voryn Native  │   aplicação UEFI (Zig, sem libc)
   │        Boot          │   1. console serial + console do firmware
   └──────────┬───────────┘   2. framebuffer (GOP)
              │               3. mapa de memória
              │               4. leitura da imagem do kernel
              │               5. validação ELF64 + realocações
              │               6. contrato de handoff
              │               7. ExitBootServices e salto
              ▼
   ┌──────────────────────┐
   │  VNK — Voryn Nucleus │   núcleo mínimo (Zig + Assembly)
   │        Kernel        │   1. validação do handoff
   └──────────┬───────────┘   2. relatório do estado da máquina
              │               3. prova de escrita no framebuffer
              ▼
          F2: GDT, IDT, memória, timer
```

## 2. Módulos

### `shared/` — contratos e primitivas compartilhadas

| Arquivo | Responsabilidade |
|---------|------------------|
| `handoff.zig` | Estrutura do contrato VNB → VNK e sua validação |
| `memmap.zig` | Operações sobre o mapa de memória (busca, resumo, região de carga) |
| `elf64.zig` | Leitor ELF64: cabeçalho, segmentos, realocações relativas, plano de carga |
| `arch/x86_64/port.zig` | Primitivas de E/S de porta (in, out, cli, hlt, rdtsc) |
| `arch/x86_64/serial.zig` | Driver da UART 16550 (COM1) e escritor formatado |

`shared/` é compilado para três alvos diferentes: UEFI (loader), freestanding
(kernel) e host (testes). Nenhum módulo depende de sistema operacional.

### `boot/uefi/` — o loader VNB

| Arquivo | Responsabilidade |
|---------|------------------|
| `main.zig` | Orquestração do boot e transição para o kernel |
| `vnb/protocols.zig` | Estruturas de protocolo UEFI e detecção de layout em tempo de execução |
| `vnb/console.zig` | Console duplo: serial e console do firmware |
| `vnb/framebuffer.zig` | Descoberta e seleção de modo gráfico |
| `vnb/memory.zig` | Leitura e normalização do mapa de memória do firmware |
| `vnb/fs.zig` | Acesso ao volume de boot e leitura do arquivo do kernel |
| `vnb/loader.zig` | Posicionamento da imagem e aplicação de realocações |

### `kernel/` — o núcleo VNK

| Arquivo | Responsabilidade |
|---------|------------------|
| `main.zig` | Entrada do kernel, sequência de inicialização, validação do handoff |
| `arch/x86_64/entry.s` | Trampolim de entrada, pilha de boot, regras de ABI |
| `arch/x86_64/cpu.zig` | Registradores de controle, `CPUID`, registradores de modelo |
| `arch/x86_64/segment.zig` e `.s` | Tabela de segmentos, segmento de tarefa, recarga dos registradores |
| `arch/x86_64/interrupt.zig` e `.s` | Tabela de interrupções, tratadores de exceção e de interrupção |
| `arch/x86_64/paging.zig` | Tabelas de página do núcleo e a troca de `CR3` |
| `arch/x86_64/timer.zig` | Temporizador 8254, controllers 8259, contagem de interrupções |
| `memory/physical.zig` | Gerenciador de memória física sobre o mapa do contrato |
| `memory/heap.zig` | Heap do núcleo com etiquetas de limite e verificação de corrupção |

### `tools/` — ferramentas de desenvolvimento

| Arquivo | Responsabilidade |
|---------|------------------|
| `fatimg.zig` | Construtor de volume FAT16 com o loader e o kernel |

### `scripts/` — automação de teste

| Arquivo | Responsabilidade |
|---------|------------------|
| `qemu-boot-test.sh` | Teste automatizado de boot: captura o console serial e verifica marcadores |
| `qemu-run.sh` | Boot interativo no QEMU |

## 3. Contratos entre módulos

| Contrato | Tipo | Onde |
|---------|------|------|
| Handoff VNB → VNK | estrutura `extern` versionada | `shared/handoff.zig` |
| Mapa de memória | array de `MemoryDescriptor` (40 bytes) | `shared/handoff.zig` |
| Imagem do kernel | ELF64 relocável (`ET_DYN`) | `shared/elf64.zig` |
| Console | escritor `std.Io.Writer` sobre a UART | `shared/arch/x86_64/serial.zig` |

Nenhum contrato usa ponteiro opaco sem descrição: todo campo tem layout
explícito e documentado.

## 4. Propriedades de segurança do incremento

1. O loader valida a imagem do kernel antes de executá-la: magic, classe,
   endianness, máquina, tipo, tabela de program headers, segmentos dentro do
   arquivo, entry point dentro de um segmento, e RAM convencional por trás de
   cada segmento.
2. A imagem é relocável, e as realocações aplicadas são apenas do tipo
   `R_X86_64_RELATIVE`; qualquer outro tipo é recusado.
3. O endereço de carga é escolhido acima de 1 MiB, para não sobrescrever as
   estruturas de dados do firmware na área baixa da PC.
4. O kernel verifica magic, versão e coerência do mapa de memória antes de
   usar qualquer campo.
5. O console do firmware é desacoplado antes de `ExitBootServices`.
6. A sonda de escrita no framebuffer só é executada quando o mapa de memória
   **não** reporta a região do framebuffer como RAM comum, para não
   corromper a memória que o kernel vai usar.

## 5. Limitações conhecidas

1. O heap do núcleo é uma região fixa de 256 KiB dentro da imagem, porque
   a região precisa continuar mapeada depois da troca das tabelas de página.
2. O bitmap do gerenciador de memória física cobre 4 GiB do espaço físico.
3. O tratador de exceções é fatal: a execução para no primeiro erro, sem
   tentativa de recuperação.
4. O índice de pilha de interrupção do segmento de tarefa está preparado,
   mas as portas da tabela de interrupções ainda não o usam.
5. O loader não localiza o RSDP do ACPI; o campo existe no contrato mas
   vale zero.
6. O volume de teste usa nomes FAT 8.3; não há suporte a nomes longos.
7. O sistema é single processor; não há suporte a SMP.
8. Não há detecção de hardware além do framebuffer: VNH ainda não existe.
9. O kernel é carregado a partir de um volume FAT através do protocolo de
   sistema de arquivos simples do firmware; não há driver de bloco próprio.

## 6. O que vem a seguir

O marco F3 (execução) implementa, nesta ordem: alternância entre tarefas
medida pelo temporizador, modo de usuário com a pilha de usuário e a
comutação de privilégio, a primeira chamada de sistema, o canal de
mensagens do VNX e as capacidades do VNC. Cada etapa tem critério de aceite
verificável e teste automatizado no QEMU.
