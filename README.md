<div align="center">

# VorynOS

### Liberdade • Performance • Seu Controle

**Um sistema operacional independente, desenvolvido do zero para oferecer controle direto sobre o hardware, eficiência e liberdade tecnológica.**

[![Zig](https://img.shields.io/badge/Zig-0.17.0-F7A41D?logo=zig&logoColor=white)](https://ziglang.org/)
[![Release](https://img.shields.io/badge/release-v0.1.0--dev.1-2563EB)](https://github.com/CeoMatheusDev/VorynOS/releases/tag/v0.1.0-dev.1)
[![License](https://img.shields.io/badge/license-GPL--3.0--only-22C55E)](LICENSE)
[![Architecture](https://img.shields.io/badge/architecture-x86__64-64748B)](#arquitetura)
[![Status](https://img.shields.io/badge/status-em%20desenvolvimento-EAB308)](#estado-do-projeto)

[**Visão geral**](#visão-geral) ·
[**Estado atual**](#estado-do-projeto) ·
[**Compilação**](#compilação) ·
[**Arquitetura**](#arquitetura) ·
[**Documentação**](#documentação) ·
[**Notas da versão**](docs/releases/v0.1.0-dev.1.md)

![Logo do VorynOS](Logos_VorynOS.png)

</div>

---

## Visão geral

O **VorynOS** é um projeto de sistema operacional independente, desenvolvido principalmente em **Zig**, utilizando **Assembly x86_64** para operações que exigem controle direto da arquitetura do processador.

O projeto prioriza:

- **Independência:** kernel, bootloader, contratos e mecanismos fundamentais desenvolvidos especificamente para o VorynOS.
- **Performance:** controle explícito sobre memória, execução, interrupções e comunicação entre componentes.
- **Eficiência:** redução de abstrações desnecessárias, dependências externas e sobrecarga operacional.
- **Segurança:** arquitetura orientada ao isolamento e ao controle de acesso por capacidades, com implementação progressiva.
- **Modularidade:** componentes com responsabilidades e interfaces documentadas.
- **Transparência:** desenvolvimento aberto, documentação técnica e distinção entre funcionalidades existentes e planejadas.

O VorynOS **não é uma distribuição Linux, um fork do Windows, uma variante de BSD ou uma interface construída sobre outro sistema operacional**.

Seu bootloader e kernel são implementações próprias.

O projeto encontra-se em desenvolvimento inicial e **ainda não constitui um sistema operacional completo para uso cotidiano**.

---

## Estado do projeto

> **Versão publicada:** `v0.1.0-dev.1` — [notas da versão](docs/releases/v0.1.0-dev.1.md)  
> **Arquitetura inicial:** `x86_64`  
> **Linguagem principal:** Zig 0.17.0  
> **Firmware de inicialização:** UEFI  
> **Licença:** GPL-3.0-only  
> **Última revisão documental:** 22/10/2026

A versão publicada é o **marco inicial consolidado** do projeto: ela
carrega todo o progresso técnico já verificado, e a partir dela a numeração
das versões volta a ter sentido. A reorganização dos marcos públicos está
registrada em
[VERSIONING-RESET-2026](docs/releases/VERSIONING-RESET-2026.md).

O desenvolvimento está organizado em marcos incrementais, com critérios técnicos de aceitação e documentação das evidências de funcionamento.

### Progresso dos marcos

| Marco | Descrição | Estado |
|:---:|---|:---:|
| F0 | Fundação, toolchain, build e documentação | ✅ Concluído |
| F1 | Bootloader UEFI e inicialização do kernel | ✅ Concluído |
| F2 | Estruturas do processador, interrupções e memória | 🟢 Testado localmente |
| F3 | Threads, scheduler, processos, syscalls e IPC | 🟡 Em desenvolvimento |
| F4 | Armazenamento e sistemas de arquivos | 📋 Proposto |
| F5 | Runtime, SDK e aplicações nativas | 📋 Proposto |
| F6 | Subsistema gráfico e ambiente desktop | 📋 Proposto |
| F7 | Drivers, rede, áudio e hardware físico | 📋 Proposto |
| F8 | Compatibilidade com formatos e APIs externas | 📋 Proposto |
| F9 | Infraestrutura de inteligência artificial | 📋 Proposto |
| F10 | Instalação, segurança, recuperação e produção | 📋 Proposto |

**Importante:** os estados representam o conteúdo documentado e publicado na branch `main`. Funcionalidades desenvolvidas apenas localmente não são consideradas implementadas no repositório público.

Consulte o [roadmap técnico](docs/roadmap/phase-status.md) para conhecer os objetivos, critérios de aceitação, limitações e riscos de cada marco.

---

## Funcionalidades implementadas

### VNB — Voryn Native Boot

Bootloader UEFI independente, implementado em Zig para a arquitetura x86_64.

Responsabilidades implementadas:

- Inicialização como aplicação UEFI.
- Comunicação com os serviços do firmware.
- Diagnóstico por console UEFI e porta serial.
- Descoberta do framebuffer utilizando GOP.
- Identificação do formato de pixels e das propriedades do framebuffer.
- Obtenção e normalização do mapa de memória UEFI.
- Leitura da imagem do kernel a partir do volume EFI.
- Validação da estrutura ELF64.
- Carregamento dos segmentos do kernel em memória.
- Aplicação das realocações necessárias à imagem relocável.
- Preparação do contrato de inicialização.
- Encerramento dos serviços de boot por `ExitBootServices`.
- Nova tentativa de encerramento quando o mapa de memória é alterado.
- Transferência controlada da execução para o kernel.

**Implementação:** `boot/uefi/`

### VNK — Voryn Nucleus Kernel

Kernel independente, implementado em Zig e Assembly.

O núcleo possui uma infraestrutura inicial funcional para gerenciamento do processador, memória e interrupções.

**Inicialização e arquitetura x86_64**

- Ponto de entrada próprio.
- Configuração da pilha inicial.
- Validação do contrato recebido do bootloader.
- Identificação de características do processador por CPUID.
- Configuração da Global Descriptor Table (GDT).
- Configuração da Task State Segment (TSS).
- Configuração da Interrupt Descriptor Table (IDT).
- Tratamento de exceções com diagnóstico dos registradores.
- Configuração inicial das interrupções de hardware.
- Remapeamento dos controladores 8259.
- Programação do temporizador 8254 a 100 Hz.
- Preparação do coprocessor, que o firmware deixa desabilitado.

**Execução de tarefas**

- Escalonador preemptivo acionado pelo temporizador.
- Contexto de tarefa com o quadro completo do processador: os quinze
  registradores de uso geral são preservados a cada troca.
- Política circular, que não produz fome entre tarefas.
- Tarefas do kernel em pilhas próprias, e pilha do núcleo separada da
  pilha do código, para que o quadro do processador nunca fique em uma
  página que o usuário mode possa reescrever.
- Estrutura de tarefa preparada para o terceiro nível de privilégio.
- Mapeamento de páginas de usuário nas tabelas de página próprias.
- Chamada de sistema pela instrução `syscall`, com o tratador em Zig.
- Contrato da chamada de sistema com sete chamadas, e conferência das
  faixas do usuário nas tabelas de página do espaço do processo antes de o
  núcleo tocar a memória do usuário.
- Medição do custo da troca de contexto pelo contador de tempo.

**Processos**

- Espaço de endereço próprio por processo, com as tabelas do núcleo
  copiadas para dentro dele, e a janela do modo de usuário como única
  região que o processo possui.
- Troca do espaço de endereço junto com a troca do contexto da tarefa.
- Isolamento entre processos: dois processos usam o mesmo endereço virtual
  e não veem as mesmas páginas.
- Janela do modo de usuário sem endereço fixo, escolhida fora da imagem do
  núcleo e entregue à tarefa no momento de sua criação.
- Cópia de um bloco de memória de um processo para outro, com a leitura da
  origem e a escrita do destino feitas no espaço de cada um.
- Canal de mensagens do VNX com a entrega entre dois processos, e a
  latência da entrega medida no relógio do processador.
- Chamada de sistema que **bloqueia** à espera de uma mensagem: a tarefa
  que espera não é executada, o escalonador escolhe outra, e a mensagem
  acorda a tarefa com o resultado no contexto salvo dela.
**Gerenciamento de memória**

- Gerenciador de memória física baseado em bitmap.
- Controle inicial de páginas físicas.
- Construção de tabelas de páginas próprias.
- Substituição das tabelas de páginas por meio de CR3.
- Mapeamento do kernel e do framebuffer, com a imagem do(kernel descrita
  inteira, e não só os seus primeiros dois megabytes.
- Heap com metadados de blocos.
- Divisão e fusão de blocos de memória.
- Verificação básica de corrupção do heap.

**Diagnóstico**

- Comunicação serial pela UART 16550.
- Registro de eventos de inicialização.
- Diagnóstico de exceções do processador.
- Verificação de estruturas críticas durante o boot.
- Teste de escrita no framebuffer.

**Implementação:** `kernel/`

### Contrato de inicialização

O VorynOS utiliza um contrato próprio para transferir informações entre o bootloader e o kernel.

Esse contrato permite comunicar:

- Informações do framebuffer.
- Mapa de memória.
- Informações necessárias à inicialização do núcleo.
- Identificadores e dados de validação do contrato.

A estrutura possui versionamento e verificações de integridade estrutural.

**Implementação:** `shared/handoff.zig`

**Especificação:** [Boot Handoff Specification](docs/specs/boot-handoff-spec.md)

### Ferramenta de imagem de disco

O projeto inclui um construtor próprio de imagem FAT16, implementado em Zig.

Essa ferramenta prepara o volume inicializável utilizado nos testes do sistema.

**Implementação:** `tools/fatimg.zig`

---

## Limitações atuais

O VorynOS está em estágio de desenvolvimento de infraestrutura.

As seguintes limitações são conhecidas e documentadas:

| Subsistema | Limitação |
|---|---|
| Memória física | Bitmap com cobertura de até 4 GiB |
| Heap | Região fixa de 256 KiB |
| Memória virtual | Imagem do núcleo e framebuffer mapeados, com a janela de cada processo |
| Processos | Dois processos, e o limite de espaços de endereço é uma constante do módulo de paginação |
| TSS | Estrutura do modo de 64 bits, com o layout verificado em tempo de compilação |
| Exceções | Tratamento fatal, sem recuperação |
| Syscalls | Oito chamadas, e a volta ao usuário é verificada |
| IPC | A entrega e a espera entre dois processos são verificadas, e não há ordenação, nem entrega garantida, nem sincronização |
| Espera | A espera não tem prazo, e uma tarefa espera por um canal e por um lado |
| Capacidades | Não implementadas, e o processo tem acesso a todo o seu espaço |
| Armazenamento | Sem sistema de arquivos operacional no kernel |
| Drivers | Sem infraestrutura geral de drivers |
| Interface gráfica | Não implementada |
| Hardware físico | Sem validação documentada |

O processo de usuário executa no terceiro nível de privilégio, escreve na sua própria página de dados, chama o núcleo pela instrução `syscall` e recebe a resposta de volta no mesmo registrador. Cada processo tem um espaço de endereço próprio, e dois processos que usam o mesmo endereço virtual não veem as mesmas páginas. O canal de mensagens do VNX entrega uma mensagem de um processo para outro, e a resposta volta pelo mesmo canal. A cópia de memória entre os dois processos é uma cópia de verdade: o espaço de quem chamou não muda.

O que ainda não existe são as threads, a espera com prazo, o modelo de
capacidades do VNC, e a validação em hardware físico.

Esses recursos pertencem aos próximos incrementos de desenvolvimento.

---

## Requisitos

### Ambiente de desenvolvimento

| Componente | Requisito |
|---|---|
| Sistema de referência | Fedora Linux 44 |
| Arquitetura | x86_64 |
| Zig | 0.17.0 |
| QEMU | 10.x |
| Firmware | OVMF / edk2 |
| Shell | Bash |
| Utilitários | Coreutils |

O projeto utiliza o sistema de compilação nativo do Zig.

O ambiente principal de desenvolvimento é Linux, mas o kernel produzido é independente do sistema operacional utilizado para compilá-lo.

### Verificar a toolchain

```bash
zig version
qemu-system-x86_64 --version
```

No ambiente Fedora de referência, os arquivos do OVMF são encontrados em:

```text
/usr/share/edk2/ovmf/OVMF_CODE.fd
/usr/share/edk2/ovmf/OVMF_VARS.fd
```

Os scripts de execução utilizam o QEMU e o firmware OVMF para inicializar o sistema.

---

## Compilação

### 1. Obter o código-fonte

```bash
git clone https://github.com/CeoMatheusDev/VorynOS.git
cd VorynOS
```

Para obter exatamente o marco publicado:

```bash
git checkout v0.1.0-dev.1
```

**Sobre os artefatos:** o release `v0.1.0-dev.1` publica **apenas o código
fonte**. Nenhum binário é distribuído junto dele, porque o projeto não
mantém uma cadeia de construção reproduzível o bastante para que um
artefato binário possa ser declarado oficial. A imagem de inicialização é
construída localmente pelo próprio projeto, e é ela que o teste de boot
verifica.

### 2. Compilar o projeto

```bash
zig build
```

O processo constrói:

- O bootloader UEFI.
- O kernel ELF64.
- A ferramenta de criação da imagem.
- A imagem de inicialização.

### 3. Executar os testes

```bash
zig build test
```

Executa os testes de unidade no ambiente host.

```bash
zig build qemu-test
```

Executa o teste automatizado de inicialização utilizando QEMU e OVMF.

```bash
zig build check
```

Executa os testes de unidade e o teste automatizado de boot.

### 4. Inicializar o sistema

```bash
zig build qemu
```

Inicializa o VorynOS no QEMU em modo interativo.

O console serial constitui o canal principal de diagnóstico.

Para encerrar o QEMU no modo de terminal serial, utilize:

```text
Ctrl+A, X
```

### Comandos disponíveis

| Comando | Finalidade |
|---|---|
| `zig build` | Compilar os componentes e gerar a imagem |
| `zig build image` | Construir a imagem de inicialização |
| `zig build test` | Executar os testes de unidade |
| `zig build qemu` | Inicializar o sistema interativamente |
| `zig build qemu-test` | Executar o teste automatizado de boot |
| `zig build check` | Executar a verificação integrada |

### Artefatos

Após a compilação, os principais artefatos são:

```text
zig-out/
└── bin/
    ├── voryn-boot.efi
    ├── voryn-kernel
    ├── voryn-fsimg
    └── vorynos.img
```

| Artefato | Descrição |
|---|---|
| `voryn-boot.efi` | Aplicação UEFI do Voryn Native Boot |
| `voryn-kernel` | Kernel ELF64 relocável |
| `voryn-fsimg` | Ferramenta de construção de imagem FAT16 |
| `vorynos.img` | Imagem de volume EFI inicializável |

---

## Arquitetura

A arquitetura do projeto é organizada em torno do modelo denominado **Voryn Fabric**.

Esse modelo define componentes com responsabilidades específicas e contratos explícitos de comunicação.

A arquitetura está documentada na decisão:

[ADR-0001 — Voryn Fabric](docs/adr/ADR-0001-voryn-fabric.md)

### Componentes

| Sigla | Componente | Responsabilidade |
|:---:|---|---|
| VNB | Voryn Native Boot | Inicialização UEFI e carregamento do kernel |
| VNK | Voryn Nucleus Kernel | Mecanismos privilegiados do núcleo |
| VNH | Voryn Hardware Nexus | Descoberta e interfaces de hardware |
| VNM | Voryn Nexus Memory | Gerenciamento de memória |
| VNT | Voryn Task Fabric | Tarefas, threads e escalonamento |
| VNX | Voryn Exchange | Comunicação entre processos |
| VNC | Voryn Capability Fabric | Controle de acesso por capacidades |
| VND | Voryn Device Fabric | Infraestrutura de drivers |
| VSN | Voryn Service Node | Serviços e supervisão |

**Os nomes acima representam a arquitetura planejada. Nem todos os componentes possuem implementação funcional.**

Atualmente, as implementações publicadas concentram-se no VNB, no VNK, nas rotinas iniciais de memória e nos contratos compartilhados.

### Fluxo de inicialização

```text
                 ┌─────────────────────┐
                 │    Firmware UEFI    │
                 └──────────┬──────────┘
                            │
                            ▼
                 ┌─────────────────────┐
                 │ VNB                 │
                 │ Voryn Native Boot   │
                 └──────────┬──────────┘
                            │
                   Carregamento ELF64
                   Mapa de memória
                   Framebuffer GOP
                   Contrato de handoff
                            │
                            ▼
                 ┌─────────────────────┐
                 │  ExitBootServices   │
                 └──────────┬──────────┘
                            │
                            ▼
                 ┌─────────────────────┐
                 │ VNK                 │
                 │ Voryn Nucleus Kernel│
                 └──────────┬──────────┘
                            │
              ┌─────────────┼─────────────┐
              │             │             │
              ▼             ▼             ▼
          ┌───────┐    ┌─────────┐    ┌────────┐
          │GDT/TSS│    │   IDT   │    │ Memória│
          └───────┘    └─────────┘    └────────┘
              │             │             │
              └─────────────┼─────────────┘
                            │
                            ▼
                 ┌─────────────────────┐
                 │ Infraestrutura      │
                 │ inicial do kernel   │
                 └─────────────────────┘
```

Esse fluxo representa a infraestrutura atualmente implementada, sem pressupor a existência de processos, serviços ou ambiente gráfico.

### Organização do código-fonte

```text
VorynOS/
├── .github/
│   └── workflows/
│       └── ci.yml
│
├── boot/
│   └── uefi/
│       ├── main.zig
│       └── vnb/
│
├── kernel/
│   ├── arch/
│   │   └── x86_64/
│   ├── memory/
│   └── main.zig
│
├── shared/
│   ├── arch/
│   ├── elf64.zig
│   ├── handoff.zig
│   ├── memmap.zig
│   └── root.zig
│
├── tools/
│   └── fatimg.zig
│
├── scripts/
│   └── qemu-run.sh
│
├── tests/
│   └── integration/
│       └── boot-qemu.sh
│
├── docs/
│   ├── adr/
│   ├── architecture/
│   ├── roadmap/
│   ├── specs/
│   ├── standards/
│   └── testing/
│
├── AGENTS.md
├── CONTRIBUTING.md
├── SECURITY.md
├── LICENSE
├── build.zig
├── build.zig.zon
└── README.md
```

A organização separa código dependente da arquitetura, contratos compartilhados, ferramentas do host e testes de integração.

---

## Testes e validação

O projeto utiliza diferentes níveis de verificação.

### Testes de unidade

Executados no ambiente host para validar componentes que não dependem diretamente da execução privilegiada.

Entre eles:

- Estruturas compartilhadas.
- Validação de formatos.
- Contratos de inicialização.
- Gerenciadores de memória.

### Testes de integração

A inicialização é testada em uma máquina virtual x86_64 com firmware OVMF.

O teste automatizado verifica **33 marcadores** de progresso emitidos pelo
bootloader e pelo kernel, e identifica condições de falha durante a
inicialização.

Os marcadores do núcleo verificam o **conteúdo** e não só a execução: o
marcador da página de dados de cada processo é conferido, e os dois
processos escrevem valores diferentes no mesmo endereço virtual, o que
prova o isolamento; o conteúdo da cópia com faixas sobrepostas é conferido
byte a byte; e o espaço de endereço de quem chamou a cópia entre processos
é conferido depois da cópia, o que prova que a cópia é uma cópia e não um
compartilhamento de página.

O console serial é o canal verificado, e a escrita nele é atômica: uma
tarefa que escreve desliga as interrupções enquanto a mensagem é montada.
Sem essa garantia, o console deixaria de ser uma evidência, porque
relataria linhas que ninguém escreveu.

### Integração contínua

O repositório possui um workflow de GitHub Actions:

`.github/workflows/ci.yml`

O workflow executa:

1. Preparação da toolchain Zig.
2. Instalação das dependências de emulação.
3. Testes de unidade.
4. Compilação dos artefatos.
5. Teste automatizado de boot.
6. Inspeção dos binários gerados.

A existência do workflow não implica que todas as funcionalidades futuras estejam implementadas ou que o sistema tenha sido validado em hardware físico.

### Evidências e critérios

A estratégia de testes está documentada em:

[Testing Strategy](docs/testing/testing-strategy.md)

O estado de cada marco é registrado no:

[Roadmap](docs/roadmap/phase-status.md)

---

## Próximos passos

O objetivo arquitetural em curso é o **F3 — Execução**, e ele tem três
partes: o modo de usuário, os processos, e a comunicação entre eles. As
três estão implementadas e verificadas, e a comunicação entre processos
tem a entrega de uma mensagem e a espera por ela.

Os objetivos que faltam no marco são:

1. O modelo de **capacidades** do VNC, que decide o que um processo pode
   alcançar, e que a pergunta aberta do ADR-0001 deixou em suspenso.
2. A **espera com prazo**, e a espera por mais de um canal ao mesmo tempo.
3. O **tratamento por tipo** das exceções, com um teste de recuperação, e
   o **heap dinâmico** com o VNM.
4. A medição do custo de troca de contexto sob **carga representativa**,
   com mais tarefas e mais processos.

A implementação desses recursos deverá respeitar os contratos arquiteturais e os critérios de validação definidos pelo projeto.

**Nenhum desses objetivos deve ser interpretado como funcionalidade concluída enquanto não houver implementação e evidências correspondentes.**

---

## Documentação

O VorynOS mantém documentação técnica junto ao código-fonte.

| Documento | Descrição |
|---|---|
| [AGENTS.md](AGENTS.md) | Protocolo de engenharia e desenvolvimento |
| [Architecture Overview](docs/architecture/overview.md) | Organização e contratos arquiteturais |
| [ADR-0001](docs/adr/ADR-0001-voryn-fabric.md) | Modelo Voryn Fabric |
| [ADR-0002](docs/adr/ADR-0002-boot-chain-and-uefi-abi.md) | Cadeia de inicialização e ABI UEFI |
| [ADR-0003](docs/adr/ADR-0003-toolchain-and-build.md) | Toolchain e sistema de compilação |
| [ADR-0004](docs/adr/ADR-0004-x86_64-abi-pitfalls.md) | Particularidades e problemas de ABI x86_64 |
| [ADR-0005](docs/adr/ADR-0005-task-model-and-user-mode.md) | Modelo de tarefa e modo de usuário |
| [ADR-0006](docs/adr/ADR-0006-address-spaces-and-processes.md) | Espaços de endereço por processo e o quadro do processador |
| [ADR-0007](docs/adr/ADR-0007-blocking-receive.md) | A chamada que bloqueia à espera de uma mensagem |
| [Boot Handoff](docs/specs/boot-handoff-spec.md) | Especificação do contrato de inicialização |
| [Syscall ABI](docs/specs/syscall-abi.md) | Contrato da chamada de sistema |
| [Notas da v0.1.0-dev.1](docs/releases/v0.1.0-dev.1.md) | Notas oficiais do marco inicial consolidado |
| [VERSIONING-RESET-2026](docs/releases/VERSIONING-RESET-2026.md) | Histórico dos marcos descontinuados e procedimento da reorganização |
| [Roadmap](docs/roadmap/phase-status.md) | Estado e planejamento dos marcos |
| [Testing Strategy](docs/testing/testing-strategy.md) | Estratégia de validação |
| [VVS-0001](docs/standards/VVS-0001.md) | Política de versionamento |
| [VN-NAMES-0001](docs/standards/VN-NAMES-0001.md) | Convenções de nomenclatura |

As decisões arquiteturais são registradas por meio de ADRs, incluindo suas justificativas, alternativas e consequências.

---

## Desenvolvimento

O VorynOS segue uma abordagem de engenharia incremental.

As alterações devem priorizar:

- Correção e previsibilidade.
- Controle explícito de recursos.
- Eficiência de memória.
- Baixa sobrecarga de execução.
- Interfaces e contratos documentados.
- Testes reproduzíveis.
- Organização consistente do código-fonte.
- Ausência de dependências desnecessárias.

### Política do repositório

- Branch principal: `main`.
- Commits descritivos em português brasileiro.
- Alterações incrementais e verificáveis.
- Documentação atualizada junto às implementações.
- Publicação de alterações somente mediante autorização explícita do responsável pelo projeto.

---

## Contribuição

Contribuições são bem-vindas.

Antes de propor alterações, consulte:

- [CONTRIBUTING.md](CONTRIBUTING.md) — orientações para contribuições.
- [AGENTS.md](AGENTS.md) — padrões e procedimentos de engenharia.
- [SECURITY.md](SECURITY.md) — diretrizes para comunicação de vulnerabilidades.

Contribuições devem respeitar a arquitetura existente, os contratos documentados e os critérios de qualidade definidos pelo projeto.

---

## Segurança

O VorynOS ainda está em desenvolvimento inicial.

Mecanismos avançados de isolamento, controle de capacidades, proteção entre processos e recuperação de falhas permanecem em planejamento.

**Não utilize o sistema como ambiente de produção ou para processamento de informações sensíveis.**

Para comunicar vulnerabilidades, consulte [SECURITY.md](SECURITY.md).

---

## Licença

O VorynOS é disponibilizado sob a licença **GNU General Public License, versão 3, exclusivamente (GPL-3.0-only)**.

Consulte o arquivo [LICENSE](LICENSE) para conhecer os termos completos.

As contribuições estão sujeitas às condições estabelecidas em [CONTRIBUTING.md](CONTRIBUTING.md).

---

<div align="center">

### VorynOS

**Liberdade • Performance • Seu Controle**

*Construindo um sistema operacional independente, um componente de cada vez.*

[Repositório](https://github.com/CeoMatheusDev/VorynOS) ·
[Documentação](docs/) ·
[Contribuir](CONTRIBUTING.md) ·
[Licença](LICENSE)

</div>
