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
| ADRs | CONCLUÍDO | ADR-0001 a ADR-0004 |
| Git | CONCLUÍDO | branch `main`, commits descritivos, sem publicação |
| Testes iniciais | CONCLUÍDO | `zig build test` (unidade) e `zig build qemu-test` (boot) |

### F1 — Boot — CONCLUÍDO

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

### F2 — Kernel — TESTADO LOCALMENTE

| Objetivo | Estado | Evidência |
|----------|--------|-----------|
| Entrada do kernel | CONCLUÍDO | `kernel/arch/x86_64/entry.s`, pilha própria, ABI documentada |
| GDT | CONCLUÍDO | tabela própria com código e dados dos níveis 0 e 3, verificada por `sgdt` |
| TSS | CONCLUÍDO | segmento de tarefa carregado, com pilha de interrupção para a falha dupla |
| IDT | CONCLUÍDO | 256 portas, verificada por `sidt` |
| Exceções | CONCLUÍDO | tratador com o vetor, o código de erro, o RIP e os registradores |
| Interrupções de hardware | CONCLUÍDO | portas 32 a 47, controllers 8259 reprogramados |
| Temporizador | CONCLUÍDO | 8254 no modo 3, 100 Hz, contagem verificada |
| Memória física | CONCLUÍDO | `kernel/memory/physical.zig`, bitmap de 4 GiB, 51551 páginas |
| Memória virtual | CONCLUÍDO | `kernel/arch/x86_64/paging.zig`, tabelas próprias, `CR3` trocado |
| Heap do kernel | CONCLUÍDO | `kernel/memory/heap.zig`, etiquetas de limite, fusão de blocos, verificação de corrupção |
| Isolamento | PARCIAL | só o núcleo e o framebuffer estão mapeados; o resto da memória não é acessível |

Sequência verificada no console serial:

```text
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

Limitações conhecidas do marco:

- O heap é uma região fixa de 256 KiB dentro da imagem do núcleo, porque a
  região precisa estar mapeada depois da troca das tabelas de página.
- O bitmap do gerenciador de memória física cobre 4 GiB do espaço físico.
- O segmento de tarefa é carregado, e o índice de pilha de interrupção é
  usado pela pilha da falha dupla.
- O modo de usuário existe: os segmentos de usuário estão na tabela, as
  páginas do usuário têm o bit de usuário, e a tarefa de usuário executa,
  chama o núcleo e recebe a resposta.
- O tratador de exceções é fatal: a execução para no primeiro erro.

### F3 — Execução — EM DESENVOLVIMENTO

Objetivos: threads, scheduler, processos, user mode, syscalls, IPC,
capacidades.

| Objetivo | Estado | Evidência |
|----------|--------|-----------|
| Escalonador preemptivo | CONCLUÍDO | alternância verificada pelo temporizador |
| Tarefas do kernel | CONCLUÍDO | duas tarefas de trabalho, 20 trocas medidas |
| Custo de troca de contexto | CONCLUÍDO | 358 ciclos no melhor caso, média de 8 mil |
| Política sem fome | CONCLUÍDO | a visita continua depois da tarefa atual |
| Preparação do coprocessor | CONCLUÍDO | o firmware o deixa desabilitado |
| Tabelas de página com modo de usuário | CONCLUÍDO | o bit de usuário existe em todos os níveis |
| Chamada de sistema | CONCLUÍDO | a instrução `syscall`, com o tratador em Zig |
| Modo de usuário | CONCLUÍDO | a tarefa escreve na sua página e a resposta da chamada volta |
| Segmento de tarefa do modo de 64 bits | CONCLUÍDO | o layout é verificado em tempo de compilação |
| Pilha do núcleo por tarefa | CONCLUÍDO | o tratador nunca roda sobre a pilha do usuário |
| Processos | PROPOSTO | — |
| Canal do VNX | PROPOSTO | — |
| Capacidades do VNC | PROPOSTO | — |

O modo de usuário está **implementado e verificado**. A tarefa de usuário
executa no terceiro nível de privilégio, escreve na sua própria página de
dados, chama o núcleo pela instrução `syscall` e recebe a resposta no mesmo
registrador. O traço de interrupções do emulador **não registra nenhuma
exceção** durante a execução inteira.

O defeito que bloqueava o marco era o **layout do segmento de tarefa**: o
núcleo usava o layout do modo protegido, e no modo de 64 bits a pilha de
ring 3 está no deslocamento 4, a tabela de pilhas de interrupção começa no
36, e a estrutura tem 104 bytes. O processador lia o ponteiro de pilha no
deslocamento errado, e a entrega de toda exceção vinda do usuário falhava
com uma falta de pilha e uma falha dupla. O diagnóstico completo, com as
medições e a conclusão que se mostrou errada, está em ADR-0005.

A chamada de sistema usa a instrução `syscall`, o caminho previsto pela
arquitetura para o modo de 64 bits, porque a porta de interrupção é um
caminho herdado e porque o tratador passa a rodar na pilha do núcleo da
tarefa, e não na pilha do usuário.

Critérios de aceite do restante do marco:

1. Uma tarefa em modo de usuário executa, o que prova a tabela de segmentos,
   a pilha de usuário e a comutação de privilégio. **Cumprido.**
2. A primeira chamada de sistema copia um bloco de memória entre processos.
3. O canal de mensagens do VNX entrega uma mensagem entre dois processos e
   mede a latência.

### F4 a F10 — PROPOSTO

| Marco | Conteúdo | Estado |
|-------|----------|--------|
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
| Ausência de processos | Alto | Primeiro incremento do F3 depois do modo de usuário |
| Heap fixo na imagem do núcleo | Médio | Heap dinâmico com o VNM no F3 |
| Exceções fatais | Médio | Tratamento por tipo no F3, com teste de recuperação |
| Ausência de medição de desempenho | Médio | Latência de troca de contexto e de syscall no F3 |
| Ausência de teste de hardware | Médio | Marcado como não verificado até existir máquina de referência |
