<div align="center">

# VorynOS

### Liberdade • Desempenho • Controle

**Um sistema operacional independente, desenvolvido do zero para x86_64 e UEFI.**

[![Zig](https://img.shields.io/badge/Zig-0.17.0-F7A41D?logo=zig&logoColor=white)](https://ziglang.org/)
[![Arquitetura](https://img.shields.io/badge/arquitetura-x86__64-64748B)](#arquitetura)
[![Estado](https://img.shields.io/badge/estado-em%20desenvolvimento-EAB308)](#estado-do-projeto)
[![Licença](https://img.shields.io/badge/licença-GPL--3.0--only-22C55E)](LICENSE)

[Visão geral](#visão-geral) ·
[Estado](#estado-do-projeto) ·
[Compilação e testes](#compilação-e-testes) ·
[Arquitetura](#arquitetura) ·
[Documentação](#documentação)

![Logo do VorynOS](assets/branding/logos/Logos_VorynOS.png)

</div>

---

## Visão geral

O **VorynOS** é um sistema operacional independente cuja implementação inclui
bootloader UEFI, kernel, contratos próprios entre componentes e ferramentas de
desenvolvimento. O kernel e o bootloader são escritos principalmente em Zig,
com Assembly x86_64 onde o acesso direto à arquitetura é necessário.

O VorynOS **não é** uma distribuição Linux, um fork de Windows ou BSD, nem uma
interface executada sobre outro kernel. O projeto usa ferramentas externas de
desenvolvimento e padrões estabelecidos, como UEFI e ELF, sem incorporá-los
como base oculta do sistema.

O projeto ainda está em desenvolvimento e **não é adequado para uso diário**.
Os resultados locais em QEMU não constituem validação em hardware físico.

## Estado do projeto

O branch `main` contém a linha de desenvolvimento atual. Os marcos e suas
evidências são mantidos no [roadmap técnico](docs/roadmap/phase-status.md);
implementação não significa, por si só, que uma funcionalidade tenha sido
validada.

### Progresso dos marcos

| Marco | Descrição | Estado atual |
|---|---|---|
| F0 | Fundação, toolchain, sistema de build e documentação | ✅ Concluído |
| F1 | Bootloader UEFI e inicialização do kernel | ✅ Concluído |
| F2 | Estruturas do processador, interrupções e memória | 🟢 Testado localmente |
| F3 | Threads, escalonador, processos, syscalls e IPC | 🟡 Em desenvolvimento — capacidades genéricas de dispositivos, heap dinâmico e expansão de processos ainda pendentes |
| F4 | Armazenamento e sistemas de arquivos | 🟡 Em desenvolvimento — RamFS/VFSX e persistência VNV em dispositivo de memória; driver físico e montagem automática pendentes |
| F5 | Runtime, SDK e aplicações nativas | 🟡 Em desenvolvimento — ELF nativo e SDK presentes; VLIB ainda pendente |
| F6 | Gráficos e ambiente desktop | 🟡 Em desenvolvimento — caminho experimental validado em QEMU; serviço gráfico e desktop completo não implementados |
| F7 | Drivers, rede, áudio e hardware físico | 🟡 Em desenvolvimento — base PCI/Virtio parcial; drivers funcionais e validação física pendentes |
| F8 | Compatibilidade com formatos externos e APIs | 🟡 Em desenvolvimento — base ELF/VEX e ABI própria implementadas; compatibilidade ampla ainda incompleta |
| F9 | Infraestrutura de inteligência artificial | ✅ Concluído no escopo atual — inferência nativa em CPU e testes locais; sem aceleração por GPU |
| F10 | Instalação, segurança, recuperação e prontidão para produção | 🟡 Parcial — correções de hardening e auditoria realizadas; instalação, atualização e recuperação de produção continuam pendentes |

“Concluído” indica o escopo documentado do marco, não que o VorynOS como um
todo esteja pronto para uso diário. A validação em QEMU não equivale a testes
em hardware físico; consulte o [roadmap](docs/roadmap/phase-status.md) e os
relatórios para critérios, evidências e limitações de cada incremento.

## Compilação e testes

### Requisitos

- Linux x86_64 para o ambiente de desenvolvimento de referência.
- Zig **0.17.0**.
- Bash e utilitários básicos do sistema.
- Para os testes de boot: `qemu-system-x86_64` e firmware UEFI OVMF/edk2.

Clone o repositório e confira a versão do compilador:

```bash
git clone https://github.com/CeoMatheusDev/VorynOS.git
cd VorynOS
zig version
```

O comando `zig version` deve informar `0.17.0`.

### Construir e validar

```bash
# Testes de unidade executados no host
zig build test

# Compila os componentes e gera a imagem inicializável
zig build

# Inicializa a imagem em QEMU e verifica o boot automaticamente
zig build qemu-test

# Executa os testes de unidade e o teste automatizado de boot
zig build check
```

O teste de boot usa QEMU e OVMF para verificar a cadeia de inicialização e os
marcadores de comportamento emitidos pelo kernel. Ele não substitui testes em
hardware físico.

Para iniciar o sistema manualmente no QEMU:

```bash
zig build qemu
```

No modo de console serial, encerre o QEMU com `Ctrl+A` e depois `X`. Existe
também `zig build qemu-interactive-test`, um teste separado para o caminho
experimental de entrada e gráficos; consulte o [roadmap](docs/roadmap/phase-status.md)
para o escopo e o estado de validação.

A imagem gerada fica em `zig-out/bin/vorynos.img`. Para consultar todos os
passos disponíveis, execute `zig build --help`.

## Arquitetura

A plataforma inicial é **x86_64 com firmware UEFI**. O fluxo de boot é:

```text
Firmware UEFI
    │
    ▼
VNB — aplicação de boot UEFI
    │ valida e carrega o kernel ELF64
    │ prepara o contrato de transferência
    ▼
ExitBootServices
    │
    ▼
VNK — kernel independente
```

O projeto organiza os mecanismos do sistema na arquitetura Voryn Fabric. Os
nomes abaixo descrevem componentes e objetivos arquiteturais; nem todos têm
implementação funcional:

| Sigla | Componente | Responsabilidade |
|---|---|---|
| VNB | Voryn Native Boot | Inicialização UEFI e carregamento do kernel |
| VNK | Voryn Nucleus Kernel | Mecanismos privilegiados do kernel |
| VNH / VND | Hardware Nexus / Device Fabric | Descoberta de hardware e infraestrutura de dispositivos |
| VNM | Voryn Nexus Memory | Gerenciamento de memória |
| VNT | Voryn Task Fabric | Tarefas e escalonamento |
| VNX / VNC | Voryn Exchange / Capability Fabric | Comunicação entre processos e controle de acesso por capacidades |
| VSN | Voryn Service Node | Serviços e supervisão |

Mais detalhes da decisão arquitetural estão em [ADR-0001 — Voryn Fabric](docs/adr/ADR-0001-voryn-fabric.md).

## Organização do repositório

```text
boot/       Bootloader UEFI
kernel/     Kernel, memória, execução, filesystem, gráficos e drivers
shared/     Contratos e estruturas compartilhados
sdk/        Interfaces para aplicações nativas
user/       Aplicações nativas e código de entrada
tools/      Ferramentas de build e imagem
tests/      Testes de unidade e integração
docs/       Especificações, decisões, roadmap e relatórios
```

## Documentação

- [Roadmap e estado dos marcos](docs/roadmap/phase-status.md)
- [Estratégia de testes](docs/testing/testing-strategy.md)
- [Especificação da ABI de chamadas de sistema](docs/specs/syscall-abi.md)
- [Contrato de transferência do boot](docs/specs/boot-handoff-spec.md)
- [Registros de decisões arquiteturais](docs/adr/)
- [Política de versionamento](docs/releases/VERSIONING-RESET-2026.md)
- [Instruções para agentes de engenharia](AGENTS.md)

## Contribuição e segurança

Antes de propor uma alteração, consulte as convenções e critérios técnicos em
[AGENTS.md](AGENTS.md), a [estratégia de testes](docs/testing/testing-strategy.md)
e as especificações relacionadas ao componente. Relate vulnerabilidades de
forma responsável conforme [SECURITY.md](SECURITY.md).

## Licença

O código próprio do VorynOS é disponibilizado sob a licença
[GPL-3.0-only](LICENSE). Avisos e licenças de terceiros devem ser preservados.

---

*README revisado em 26 de outubro de 2026.*
