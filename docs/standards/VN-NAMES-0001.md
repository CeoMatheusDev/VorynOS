# VN-NAMES-0001 — Convenções de nomes do VorynOS

| Campo | Valor |
|-------|-------|
| **Estado** | ACEITO |
| **Data** | 2026-10-21 |
| **Escopo** | Código, diretórios, artefatos e formatos nativos |

## 1. Princípio

O nome de um artefato do VorynOS deve permitir identificar, pela leitura do
nome, **o que é**, **a qual componente pertence** e, quando aplicável, **em
que formato ou camada vive**. Nomes não descrevem implementação: `VNC` é o
componente, não a sua versão.

## 2. Componentes do Voryn Fabric

Siglas de três letras, prefixo `V` + inicial do nome em inglês:

| Sigla | Nome | Significado |
|-------|------|-------------|
| VNB | Voryn Native Boot | Loader UEFI |
| VNK | Voryn Nucleus Kernel | Núcleo privilegiado |
| VNH | Voryn Hardware Nexus | Descoberta de hardware |
| VNM | Voryn Nexus Memory | Gerência de memória |
| VNT | Voryn Task Fabric | Tarefas e escalonamento |
| VNX | Voryn Exchange | Comunicação entre processos |
| VNC | Voryn Capability Fabric | Capacidades |
| VND | Voryn Device Fabric | Drivers |
| VSN | Voryn Service Node | Serviços |

A sigla de um componente não pode ser reutilizada por outro componente.

## 3. Formatos nativos

| Formato | Extensão | Conteúdo |
|---------|----------|----------|
| VEX | `.vex` | Executável |
| VLIB | `.vlb` | Biblioteca |
| VPK | `.vpk` | Pacote de aplicação |
| VDRV | `.vdr` | Pacote de driver |
| VCFG | `.vcfg` | Configuração estruturada |
| VARC | `.varc` | Contêiner de arquivos |
| VIMG | `.vimg` | Imagem de volume |

## 4. Identificadores de código

Em inglês técnico, para manter interoperabilidade com o ecossistema Zig e
com ferramentas externas.

| Elemento | Convenção | Exemplo |
|----------|-----------|---------|
| Função, método | `camelCase` | `planLoad`, `exitBootServices` |
| Variável local, campo | `camelCase` | `loadBias`, `memoryMapEntries` |
| Constante de compilação | `snake_case` | `max_memory_descriptors` |
| Tipo, estrutura, union | `PascalCase` | `BootHandoff`, `MemoryDescriptor` |
| Enumeração | `PascalCase` | `PixelFormat` |
| Variante de enumeração | `camelCase` | `runtimeServicesData` |
| Sigla, tipo ou constante em CAIXA ALTA | `SCREAMING_SNAKE_CASE` | `PT_LOAD`, `EFI_REVISION` |
| Módulo, arquivo | `snake_case` | `memmap.zig`, `loader.zig` |
| Diretório | `snake_case` | `shared/`, `boot/uefi/` |

Regras adicionais:

1. Um identificador que represente um valor do firmware ou de uma
   especificação preserva a grafia original (`PT_LOAD`, `EFI_FILE_PROTOCOL`).
2. Nomes de tipo não usam prefixo de módulo (`Memmap.MemoryDescriptor` e
   `handoff.MemoryDescriptor` são o mesmo tipo).
3. Funções públicas de um módulo têm o verbo no início: `open`, `read`,
   `fetch`, `place`, `validate`, `summarize`.

## 5. Estrutura de diretórios

```text
VorynOS/
├── boot/uefi/        loader VNB
├── kernel/           núcleo VNK
│   ├── arch/x86_64/  código específico da arquitetura
│   ├── memory/       VNM
│   ├── task/         VNT
│   ├── ipc/          VNX
│   ├── syscall/      interface de syscall
│   └── security/     VNC
├── drivers/          VND
├── services/         VSN
├── storage/          VNV
├── formats/          leitores e escritores dos formatos nativos
├── runtime/          runtime de usuário
├── libraries/        bibliotecas nativas
├── graphics/         VGR
├── desktop/          VSH
├── apps/             aplicações nativas
├── ai/               VAI
├── compatibility/    VCB
├── sdk/              SDK e Ferramentas de desenvolvimento
├── shared/           contratos e código compartilhado entre loader e kernel
├── tools/            ferramentas de desenvolvimento (executáveis de host)
├── tests/            testes que não pertencem a um módulo
├── docs/
│   ├── adr/          decisões de arquitetura
│   ├── architecture/ visão geral da arquitetura
│   ├── standards/    padrões (VVS, VN-NAMES)
│   ├── specs/        especificações normativas
│   ├── roadmap/      marcos e estado
│   └── testing/      estratégia de teste
└── scripts/          scripts de automação
```

`shared/` contém **apenas** o que é realmente compartilhado entre o loader
e o kernel (contratos e primitivas de arquitetura). Reutilização acidental
entre módulos de kernel não justifica uma dependência em `shared/`.

## 6. Nomes de arquivo

- `snake_case` com extensão de acordo com o conteúdo:
  - `.zig` para Zig;
  - `.c` / `.h` para C23;
  - `.s` para Assembly (sem extensão específica de montador, para não
    confundir o montador integrado do Zig com o GNU as);
  - `.md` para documentação;
  - `.sh` para scripts.
- Um arquivo de teste acompanha o módulo testado: `elf64.zig` contém seus
  próprios testes; testes de integração ficam em `tests/`.
- Nomes de artefatos gerados usam o prefixo `voryn-`: `voryn-boot.efi`,
  `voryn-kernel`, `voryn-fsimg`.

## 7. Nomes de volume de boot

O volume EFI de inicialização do VorynOS usa nomes curtos, compatíveis com
FAT 8.3, porque o firmware de muitas plataformas só garante a leitura de
volume FAT com nomes curtos:

| Caminho | Conteúdo |
|---------|----------|
| `/EFI/BOOT/BOOTX64.EFI` | Loader VNB |
| `/BOOT/VORYNK.ELF` | Imagem do kernel |

O VFSX (marco F4) substituirá esse volume por uma imagem **VIMG**, com
suporte a nomes longos e metadados próprios.

## 8. Nomes de símbolos exportados

Símbolos globais exportados por um binfreware usam o prefixo do componente:

```text
voryn_kernel_entry          trampolim de entrada do VNK
voryn_kmain                 ponto de entrada em Zig do VNK
voryn_boot_stack            pilha de boot do kernel
```

Nenhum símbolo exportado entra em conflito com o firmware, o que importa
porque o loader e o kernel coexistem no mesmo espaço de endereços durante a
transição.
