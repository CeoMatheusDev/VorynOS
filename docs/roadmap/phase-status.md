# Roadmap e estado de implementação

| Campo | Valor |
|-------|-------|
| **Estado** | VIVO |
| **Data** | 2026-10-21 |

O estado abaixo reflete o **código existente e verificado**, não a
intenção. Um item só é marcado como concluído quando atende a todos os
critérios de "definição de concluído" do `AGENTS.md`.

## Marcos

### F0 — Fundação — CONCLUÍDO

| Objetivo | Estado | Evidência |
|----------|--------|-----------|
| Auditoria de ambiente | CONCLUÍDO | Zig 0.17.0, QEMU 10.2.2, OVMF, Fedora 44 verificados |
| Toolchain e convenções | CONCLUÍDO | ADR-0003, VN-NAMES-0001 |
| Estrutura mínima | CONCLUÍDO | `boot/`, `kernel/`, `shared/`, `tools/`, `scripts/`, `docs/`, `tests/` |
| Build reproduzível | CONCLUÍDO | `build.zig` + `build.zig.zon` |
| Documentação | CONCLUÍDO | README, AGENTS, ADRs, especificações, roadmap, estratégia de teste |
| ADRs | CONCLUÍDO | ADR-0001, ADR-0002, ADR-0003 |
| Git | CONCLUÍDO | branch `main`, commits descritivos, sem publicação |
| Testes iniciais | CONCLUÍDO | `zig build test` (unidade) e `zig build qemu-test` (boot) |

### F1 — Boot — TESTADO LOCALMENTE

| Objetivo | Estado | Evidência |
|----------|--------|-----------|
| Aplicação UEFI mínima | CONCLUÍDO | `boot/uefi/main.zig`, alvo `x86_64-uefi` |
| Entrada UEFI válida | CONCLUÍDO | `EfiMain` conforme ABI, `RDI` = contrato |
| Diagnóstico por console | CONCLUÍDO | console do firmware, visível na tela do OVMF |
| Saída serial | CONCLUÍDO | UART 16550 em COM1, `shared/arch/x86_64/serial.zig` |
| Descoberta de framebuffer | CONCLUÍDO | GOP, seleção de modo 32 bpp, máscara e deslocamento de canal |
| Mapa de memória | CONCLUÍDO | leitura e normalização, tolerante ao tamanho de descritor |
| Carregamento da imagem do kernel | CONCLUÍDO | volume EFI, arquivo `VORYNK.ELF` |
| Validação dos segmentos | CONCLUÍDO | `shared/elf64.zig`, com testes de unidade |
| Contrato bootloader-kernel | CONCLUÍDO | `shared/handoff.zig`, especificado em `docs/specs/` |
| `ExitBootServices` correto | CONCLUÍDO | mapa final capturado antes da chamada, repetição em caso de mapa alterado |
| Transferência de controle | CONCLUÍDO | salto para `voryn_kernel_entry` com o contrato em `RDI` |

Estado do núcleo: **EM DESENVOLVIMENTO** — o núcleo executa, valida o
contrato e prova a escrita no framebuffer. Ainda não possui GDT, IDT,
memória própria nem escalonador.

### F2 — Kernel — PROPOSTO

Objetivos: GDT, IDT, TSS, exceções, memória física, memória virtual, heap,
timer.

Primeiro incremento do F2, critérios de aceite propostos:

1. O kernel instala GDT e TSS próprios e continua executando.
2. Uma exceção deliberada (#DE, divisão por zero) é tratada pelo kernel e
   impressa no console serial, sem travar.
3. O kernel constrói suas próprias tabelas de página, com a região do kernel
   mapeada por identidade e o resto sem mapeamento.
4. O gerenciador de memória física reserva as regiões do contrato e permite
   alocar e liberar páginas.
5. Um heap do kernel aloca e libera blocos de tamanho variável, com
   verificação de corrompimento.
6. O temporizador programável dispara o handler de tick a 100 Hz.

### F3 a F10 — PROPOSTO

| Marco | Conteúdo | Estado |
|-------|----------|--------|
| F3 | Threads, scheduler, processos, user mode, syscalls, IPC, capacidades | PROPOSTO |
| F4 | Drivers de bloco, VNV, VFSX inicial, persistência, recuperação | PROPOSTO |
| F5 | VEX, VLIB, VPK, runtime, SDK, aplicações nativas | PROPOSTO |
| F6 | Input, rasterizador, compositor, janelas, VSH | PROPOSTO |
| F7 | Virtio, rede, áudio, hardware físico, GPU | PROPOSTO |
| F8 | ELF, ABI Linux, PE, Win32, formatos externos | PROPOSTO |
| F9 | VAI, backends, permissões, API, execução local | PROPOSTO |
| F10 | Instalação, atualização, recuperação, hardening, benchmarks, outras arquiteturas | PROPOSTO |

## Riscos em aberto

| Risco | Impacto | Tratamento |
|-------|---------|------------|
| Ausência de paginação própria | Alto | F2 é o próximo marco; o kernel depende hoje do firmware |
| Exceções tratadas pela UEFI | Médio | IDT própria no F2 |
| Nomes FAT 8.3 no volume | Baixo | VIMG no F4 |
| Sem ACPI | Médio | RSDP no F2, CPU no F3 |
| Ausência de medição de desempenho | Médio | Benchmarks no F10, com métricas desde o início do F3 |
