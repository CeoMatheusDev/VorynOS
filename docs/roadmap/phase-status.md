# Roadmap e estado de implementação

| Campo | Valor |
|-------|-------|
| **Estado** | VIVO |
| **Data** | 2026-10-22 |
| **Versão publicada** | `v0.1.0-dev.1` — marco inicial consolidado |

O estado abaixo reflete o **código existente e verificado**, não a
intenção. Um item só é marcado como concluído quando atende a todos os
critérios de "definição de concluído" do `AGENTS.md`.

A versão publicada é registrada aqui, e as notas oficiais da versão estão
em [`../releases/v0.1.0-dev.1.md`](../releases/v0.1.0-dev.1.md). A
reorganização dos marcos públicos de versionamento está registrada em
[`../releases/VERSIONING-RESET-2026.md`](../releases/VERSIONING-RESET-2026.md).

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
| Isolamento | CONCLUÍDO | cada processo tem um espaço de endereço próprio; o núcleo e o framebuffer são mapeados em todos os espaços, e o resto da memória não é acessível |

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
- O tratador de exceções é fatal **no núcleo**: a execução para no primeiro
  erro do núcleo, porque o estado do núcleo depois do erro é desconhecido.
  A exceção que veio do modo de usuário mata o processo, e o núcleo
  continua.

### F3 — Execução — EM DESENVOLVIMENTO

Objetivos: threads, scheduler, processos, user mode, syscalls, IPC,
capacidades.

| Objetivo | Estado | Evidência |
|----------|--------|-----------|
| Escalonador preemptivo | CONCLUÍDO | alternância verificada pelo temporizador |
| Tarefas do kernel | CONCLUÍDO | duas tarefas de trabalho, 20 trocas medidas |
| Custo de troca de contexto | CONCLUÍDO | medido a cada troca, com o menor e a média no console |
| Política sem fome | CONCLUÍDO | a visita continua depois da tarefa atual |
| Preparação do coprocessor | CONCLUÍDO | o firmware o deixa desabilitado |
| Tabelas de página com modo de usuário | CONCLUÍDO | o bit de usuário existe em todos os níveis |
| Contexto completo da tarefa | CONCLUÍDO | os quinze registradores são preservados a cada troca |
| Pilha do núcleo separada da pilha do código | CONCLUÍDO | o quadro do processador nunca fica em uma página do usuário |
| Chamada de sistema | CONCLUÍDO | a instrução `syscall`, com o tratador em Zig |
| Contrato da chamada de sistema | CONCLUÍDO | oito chamadas, com o contrato em `docs/specs/syscall-abi.md` |
| Conferência das faixas do usuário | CONCLUÍDO | uma chamada com um endereço do núcleo é recusada |
| Modo de usuário | CONCLUÍDO | a tarefa escreve na sua página e a resposta da chamada volta |
| Segmento de tarefa do modo de 64 bits | CONCLUÍDO | o layout é verificado em tempo de compilação |
| Tolerância da sobreposição na cópia | CONCLUÍDO | uma cópia com faixas sobrepostas é respondida, e não levanta um pânico |
| Verificação do conteúdo da cópia | CONCLUÍDO | o conteúdo é conferido byte a byte, e não só o comprimento |
| Janela do usuário mode | CONCLUÍDO | o endereço é escolhido fora da imagem do núcleo e entregue à tarefa |
| Espaços de endereço por processo | CONCLUÍDO | cada processo tem tabelas próprias, e o escalonador troca o espaço |
| Isolamento entre processos | CONCLUÍDO | dois processos escrevem valores diferentes no mesmo endereço virtual |
| Cópia entre processos | CONCLUÍDO | o bloco vai de um processo para o outro, e o espaço de quem chamou não muda |
| Canal do VNX | CONCLUÍDO | a mensagem sai de um processo e chega ao outro, e a resposta volta |
| Latência da entrega | CONCLUÍDO | o intervalo entre a mensagem sair e a mensagem chegar, medido no relógio do processador |
| Espera que não ocupa o processador | CONCLUÍDO | a tarefa fica bloqueada, o escalonador escolhe outra, e a mensagem a acorda |
| Entrega direta ao contexto da tarefa | CONCLUÍDO | a mensagem não fica na fila, e a tarefa continua depois da chamada |
| Quadro da chamada com o formato do quadro da interrupção | CONCLUÍDO | o mesmo switch serve ao bloqueio e à preempção |
| Quadro do processador com uma forma só | CONCLUÍDO | o stub normaliza o quadro, e o tratador e o switch leem a mesma forma |
| Tratamento das exceções por tipo | CONCLUÍDO | a exceção do modo de usuário mata o processo, e a do núcleo para a máquina |
| Recuperação do processo que falhou | CONCLUÍDO | o processo morre, os outros continuam, e a máquina chega ao fim do boot |
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

O incremento dos processos corrigiu três defeitos que vinham do desenho
anterior, e que o diagnóstico do ADR-0005 não tinha alcançado: a troca de
contexto não guardava os registradores que a arquitetura não salva entre
chamadas, o quadro do processador da volta era montado sobre a pilha do
código interrompido, e a janela do usuário mode tinha endereço fixo dentro
da imagem do núcleo. O diagnóstico completo, com as medições e a
conclusão, está em ADR-0006.

Critérios de aceite do restante do marco:

1. Uma tarefa em modo de usuário executa, o que prova a tabela de segmentos,
   a pilha de usuário e a comutação de privilégio. **Cumprido.**
2. A primeira chamada de sistema copia um bloco de memória do usuário.
   **Cumprido:** a chamada `memcpy` copia um bloco entre duas páginas do
   usuário, depois de conferir as duas faixas nas tabelas de página, e uma
   chamada com um endereço do núcleo é recusada. A cópia **entre processos**
   também existe: a chamada `copy_to` leva um bloco do espaço de um
   processo para o espaço de outro, e o espaço de quem chamou não muda.
3. O canal de mensagens do VNX entrega uma mensagem entre dois processos e
   mede a latência. **Cumprido:** o processo de papel zero manda a
   mensagem, o processo de papel um a recebe e responde, e a resposta volta
   pelo mesmo canal. A latência medida é o intervalo entre a mensagem sair
   e a mensagem chegar, lido no relógio do processador, e não a espera de um
   turno do escalonador.
4. A espera por uma mensagem **não ocupa o processador**. **Cumprido:** a
   chamada que bloqueia marca a tarefa como bloqueada, o escalonador
   escolhe outra, e a mensagem acorda a tarefa. O resultado da chamada
   chega no contexto salvo da tarefa, e a tarefa continua depois da
   chamada, como se ela tivesse respondido de imediato. A entrega é
   direta, e por isso a latência relatada é a da entrega. O diagnóstico e
   a medição estão em ADR-0007.
5. Uma exceção do modo de usuário **mata o processo**, e não a máquina.
   **Cumprido:** um terceiro processo escreve em um endereço que não está
   mapeado, e a falta de página é tratada: o processo é morto, o console
   diz que o núcleo continua, o temporizador continua contando, a
   conversa entre os outros dois processos completa o ida e volta, e a
   máquina chega à marca `VORYN-KERNEL-READY`. O incremento também
   corrigiu um defeito que já existia: o quadro do processador tem duas
   formas, e a que tem código de erro é oito bytes maior. O diagnóstico
   está em ADR-0008.

O que ainda falta no marco:

1. **As capacidades do VNC.** A pergunta aberta do ADR-0001 continua
   aberta: a chamada não carrega capacidades, e o processo tem acesso ao
   espaço inteiro do modo de usuário.
2. **Mais processos.** O núcleo cria três processos, e dois deles é que
   conversam: o terceiro existe para provar que um processo que falha não
   derruba os outros. O número de espaços de endereço é limitado por uma
   constante do módulo de paginação.
3. **A espera com prazo.** A chamada que bloqueia espera para sempre, e
   não existe um prazo de espera.
4. **O heap dinâmico** com o VNM, o **sinal no processo**, com um
   tratador no espaço do usuário, e a **política por tipo de exceção**,
   que hoje é a mesma para todas as exceções do modo de usuário.
5. **A medição do custo de troca de contexto** sob carga representativa,
   com mais tarefas e mais processos.

O canal de mensagens ensinou uma regra de inicialização que vale para o
núcleo inteiro: tudo o que as tarefas podem usar tem de existir **antes**
do temporizador, porque o temporizador é o que começa a executar as
tarefas. A inicialização dos canais vinha depois, e reiniciava as filas,
e apagava a mensagem que a tarefa do usuário mode tinha mandado no seu
primeiro turno. O diagnóstico e a regra estão em ADR-0005.

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
| Ausência de capacidades | Alto | O modelo de capacidade do ADR-0001 continua aberto |
| Heap fixo na imagem do núcleo | Médio | Heap dinâmico com o VNM no F3 |
| Exceções fatais | Médio | Resolvido no F3: a exceção do usuário mata o processo, e a do núcleo continua fatal |
| Número fixo de processos | Médio | O limite de espaços de endereço é uma constante do módulo de paginação |
| Ausência de teste de hardware | Médio | Marcado como não verificado até existir máquina de referência |
