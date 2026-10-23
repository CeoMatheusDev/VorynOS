# Relatório de Incremento — F5.2: materialização ELF64, NX e aplicação nativa

## 1. Inspecionar

Arquivos lidos antes da implementação:

- `AGENTS.md` — protocolo normativo;
- `kernel/main.zig` — sequência de inicialização, processos e relatórios;
- `kernel/arch/x86_64/paging.zig` — mapeamento, flags e espaços de endereço;
- `kernel/arch/x86_64/cpu.zig` — controle de registradores e CPUID;
- `kernel/elf_loader.zig` e `shared/elf64.zig` — planejador e parser;
- `kernel/task/scheduler.zig` — `spawnUser` e contagem de tarefas;
- `kernel/fs/fs.zig` e `kernel/fs/ramfs.zig` — instalação do arquivo ELF;
- `kernel/host_root.zig` e `build.zig` — testes de host;
- `tests/integration/boot-qemu.sh` — marcadores de boot;
- `docs/roadmap/phase-status.md`, `docs/adr/ADR-0011-elf64-load-plan.md`,
  `README.md` e `docs/reports/f5/elf64-materialization-nx.md` — estado documentado.

Estado encontrado:

- F5.1 estava verificado: RamFS, fachada e planejador de carga existiam e
  passavam os testes de host;
- o planejador era puro e não alocava, mapeava nem executava nada;
- o programa de modo usuário era copiado para uma página gravável e
  executável, sem W^X no hardware;
- não existia suporte a NX em `cpu.zig` nem a permissões explícitas em
  `paging.zig`;
- o boot criava três processos e o teste esperava `tasks: 6 created`;
- a tabela de descritores do RamFS era global, e a imagem do kernel não
  continha aplicação nativa;
- `zig build check` passava, mas apenas porque o caminho de hardware do
  planejador não existia.

## 2. Planejar

Objetivo do incremento:

1. habilitar o bit no-execute do processador e torná-lo obrigatório no
   boot;
2. dar permissões explícitas às páginas do modo usuário, com código R+X e
   dados/pilha R+W+NX;
3. materializar um `LoadPlan`: alocar páginas físicas, mapear, copiar o
   conteúdo, zerar o BSS, aplicar realocações relativas, mapear a pilha e
   restaurar o CR3;
4. construir uma imagem ELF64 nativa mínima, gravá-la no RamFS e carregá-la
   de volta pelo mesmo caminho do boot;
5. criar um quarto processo a partir do plano e executá-lo no QEMU;
6. verificar no console as permissões das tabelas, o marcador, a
   realocação e o código de saída;
7. atualizar a documentação: README, roadmap, ADR-0011, ADR-0013 e este
   relatório.

Fora do escopo deste incremento:

- SDK, toolchain, biblioteca padrão ou formato de pacote nativo;
- driver de bloco, VNV, VFSX, persistência e recuperação;
- tabela de descritores por processo;
- carregador dinâmico além de uma realocação relativa;
- mais de quatro espaços de endereço.

Critérios de aceitação:

1. `zig build test --summary all` executa as seis suítes e todos os testes
   passam;
2. `zig build` compila o materializador, a imagem nativa e o suporte a NX
   no kernel;
3. `zig build qemu-test` passa e o console mostra NX habilitado, a imagem
   instalada, as permissões verificadas, o marcador, a realocação, a saída
   0 e `native ELF`;
4. nenhuma regressão em F3 e F5.1;
5. a documentação distingue o verificado do pendente.

## 3. Implementar

### 3.1 `kernel/arch/x86_64/cpu.zig` e `cpu.s`

- detecção de NX por `CPUID` folha `0x80000001`, bit 20 do `EDX`;
- habilitação de `EFER.NXE` (MSR `0xC0000080`, bit 11), com releitura
  do registrador;
- `invlpg` movido para `kernel/arch/x86_64/cpu.s`, porque o assembler
  inline recusava a instrução em build de depuração.

### 3.2 `kernel/arch/x86_64/paging.zig`

- constante `no_execute` (bit 63) e `address_mask`
  (`0x000F_FFFF_FFFF_F000`);
- tipo `UserPageFlags` com `writable` e `executable`;
- `mapUserPageInFlags`, `protectUserPageIn`, `unmapUserPageIn` e
  `permissionsIn`;
- `mapUserPageIn` passa a usar as flags explícitas;
- testes de host para separação de código e dados e para leitura/remoção
  de mapeamento.

### 3.3 `kernel/elf_materializer.zig`

Novo módulo, dependente de hardware, com:

- validação da janela, da imagem e da pilha antes de alocar;
- ativação do espaço do processo e restauração do CR3;
- alocação, mapeamento e zeragem de páginas com permissões temporárias;
- cópia segmento a segmento, com BSS já zerado;
- proteção final: código R+X, dados e pilha R+W+NX;
- aplicação de `R_X86_64_RELATIVE` como `load_bias + addend`;
- desfazimento dos mapeamentos parciais em caso de erro.

### 3.4 `kernel/native_image.zig`

Construtor de uma imagem ET_DYN válida, montada em memória:

- código em `0x0000`, R+X, 64 bytes;
- dados em `0x1000`, R+W, 56 bytes, com marcador no deslocamento 16;
- tabela de realocações no deslocamento 24 e alvo no deslocamento 48;
- seção dinâmica com `DT_RELA` e `DT_RELASIZE`;
- uma realocação relativa com addend zero;
- código que escreve `native ELF\n`, grava o marcador e termina com a
  chamada 4;
- testes de host para cabeçalho, segmentos, realocação e buffer pequeno.

### 3.5 `kernel/main.zig`

- `installFs()` passou a rodar antes da criação dos processos, para que
  `/apps/hello.elf` exista quando o materializador o ler;
- `installFs()` constrói a imagem nativa e a grava no RamFS;
- `installUserTask()` passa a mapear código R+X e dados/pilha R+W+NX nos
  três processos embutidos;
- `installNativeProcess()` lê a imagem do RamFS, planeja, materializa,
  verifica as permissões das tabelas e registra entrada e pilha;
- `installScheduler()` cria a quarta tarefa, com papel 3;
- `reportNativeTask()` espera marcador, realocação e término com código 0;
- o boot habilita NX antes de montar as tabelas e recusa a máquina sem
  suporte.

### 3.6 `kernel/host_root.zig` e `shared/elf64.zig`

- importação de `native_image` e teste de ida e volta pelo RamFS;
- métodos `isWritable` e `isReadable` em `elf64.Segment`.

### 3.7 `tests/integration/boot-qemu.sh`

- expectativa de sete tarefas;
- marcadores de NX, imagem instalada, processo, tarefa, permissões,
  marcador, realocação, saída 0 e execução a partir do RamFS;
- saída bruta `native ELF`.

## 4. Compilar

```text
$ zig build
info: wrote ./zig-out/bin/vorynos.img: 64 MiB, 16363 clusters, FAT at sector 1, data at sector 161
```

O materializador, a imagem nativa e o suporte a NX compilam no kernel.
A imagem cresceu para 12571978 bytes no boot mais recente, sem alterar o
endereço da janela do modo usuário.

## 5. Testar

```text
$ zig build test --summary all
Build Summary: 13/13 steps succeeded; 89/89 tests passed
test success
+- run test shared-tests 17 pass (17 total)
+- run test kernel-tests 13 pass (13 total)
+- run test security-tests 16 pass (16 total)
+- run test arch-tests 13 pass (13 total)
+- run test ipc-tests 5 pass (5 total)
+- run test fs-loader-tests 25 pass (25 total)
```

A suíte de host cobre RamFS, fachada, planejador, imagem nativa e
permissões de página. As demais suítes continuam verdes.

```text
$ zig build qemu-test
...
[VNK] paging: no-execute enabled
[VNK] fs: /apps/hello.elf installed (8304 bytes)
[VNK] native: page permissions verified, code R+X, data and stack R+W+NX
[VNK] native: the ELF task wrote 0x464c456e79726f56 in its data page
[VNK] native: the relative relocation holds the load bias 0x1fc000
[VNK] native: the ELF task terminated with code 0
[VNK] native: /apps/hello.elf ran from the RamFS
native ELF
[VNK] tasks: 7 created
...
qemu-boot-test: all checks passed
```

```text
$ zig build check
Build Summary: 20/20 steps succeeded
check success
```

O teste de boot também continua verificando o modo usuário, as chamadas
1–11, o canal, as capacidades, o timeout e a recuperação do processo que
provoca a exceção.

```text
$ zig fmt --check build.zig kernel/main.zig kernel/elf_loader.zig \
    kernel/elf_materializer.zig kernel/native_image.zig kernel/host_root.zig \
    kernel/arch/x86_64/cpu.zig kernel/arch/x86_64/paging.zig \
    kernel/fs/ramfs.zig kernel/fs/fs.zig kernel/fs/inode.zig \
    kernel/fs/superblock.zig kernel/fs/dir_entry.zig shared/elf64.zig
(sem saída)

$ git diff --check
(sem saída)
```

## 6. Documentar

- `README.md` — F5 passa a descrever a aplicação nativa, W^X, NX, quatro
  processos e as limitações atualizadas;
- `docs/roadmap/phase-status.md` — materialização, W^X, aplicação nativa e
  testes passam para COMPLETED; riscos de NX e imagem bootstrap;
- `docs/adr/ADR-0011-elf64-load-plan.md` — as duas camadas existem, e a
  materialização é descrita;
- `docs/adr/ADR-0013-elf-materialization-and-nx.md` — decisão de NX, W^X,
  materializador, imagem bootstrap e verificação de boot;
- este relatório.

## 7. Limitações verificadas

1. **NX obrigatório.** O kernel não tem modo degradado: sem o bit, o boot
   para com erro fatal. A verificação foi feita no QEMU/OVMF padrão.
2. **Imagem bootstrap.** A aplicação nativa é montada pelo kernel, não por
   um SDK. Não há biblioteca padrão, carregador dinâmico nem formato de
   pacote.
3. **Quatro espaços de endereço.** O processo nativo consome o último. Um
   runtime real precisa de limite maior ou dinâmico.
4. **RamFS sem persistência.** Os dados vivem na imagem do kernel e somem
   ao desligar. Não há driver de bloco, VNV, VFSX, journaling ou
   recovery.
5. **Limites do RamFS.** 1 MiB, 32 inodes, 64 entradas de diretório,
   48 KiB por arquivo e 16 descritores globais.
6. **Uma realocação.** Apenas `R_X86_64_RELATIVE` com addend zero é
   provada; não há carregador dinâmico.
7. **Materializador não testável no host.** Ele depende do alocador físico
   e das tabelas de página; a prova de hardware é o boot.
8. **Tabela de descritores global.** Dois processos compartilham os mesmos
   descritores.
9. **Tag não atualizada.** O incremento está no working tree; nenhuma tag,
   release ou push foi feito sem autorização.

## 8. Próximo incremento (F5.2)

1. Substituir a imagem bootstrap por uma aplicação produzida por toolchain.
2. Adicionar `stat` e chamadas de arquivo ao contrato, se necessários para
   o runtime.
3. Aumentar ou tornar dinâmico o limite de espaços de endereço.
4. Implementar persistência real: driver de bloco, VNV, VFSX, journaling e
   recovery.
5. Adicionar testes de host para o materializador, se a camada de hardware
   for abstraída.

---

# Incremento F5.3 — descritores por processo

## 1. Implementar

- `kernel/fs/fs.zig` passou a manter uma tabela por processo, com 16
  descritores cada e limite de 8 processos na fachada;
- `create`, `open`, `close`, `read`, `write`, `seek` e `tell` recebem o
  identificador do processo;
- operações por caminho continuam globais;
- `kernel/arch/x86_64/syscall.zig` resolve o chamador e passa o
  identificador;
- `kernel/main.zig` instala os arquivos pelo processo 0;
- teste de host para independência de descritores e processo desconhecido.

## 2. Verificar

```text
$ zig build test --summary all
Build Summary: 13/13 steps succeeded; 90/90 tests passed
```

```text
$ zig build
info: wrote ./zig-out/bin/vorynos.img: 64 MiB, 16363 clusters, FAT at sector 1, data at sector 161
```

```text
$ zig build qemu-test
qemu-boot-test: all checks passed
```

## 3. Documentar

- `README.md` — descritores por processo;
- `docs/roadmap/phase-status.md` — objetivo concluído;
- `docs/adr/ADR-0014-per-process-descriptors.md` — decisão;
- este relatório.

---

# Incremento F5.4 — aplicação produzida pelo toolchain

## 1. Implementar

- `user/hello.zig` — programa freestanding em Zig, sem biblioteca padrão,
  que chama `write` e `exit` diretamente;
- `tools/bin2zig.zig` — converte o ELF produzido pelo Zig em um módulo Zig
  que exporta os bytes;
- `build.zig` — compila a aplicação como PIE, converte o binário e injeta
  o módulo `native_app` no kernel;
- `kernel/main.zig` — grava `/apps/toolchain.elf` no RamFS, planeja,
  materializa, verifica as permissões de cada página e executa a tarefa;
- `shared/usermode.zig` — janela aumentada para 5 páginas, para acomodar
  o segmento de dados da aplicação real;
- `tests/integration/boot-qemu.sh` — marcador da aplicação do toolchain e
  saída `toolchain ELF`.

## 2. Verificar

```text
$ zig build test --summary all
Build Summary: 13/13 steps succeeded; 90/90 tests passed
```

```text
$ zig build
info: wrote ./zig-out/bin/vorynos.img: 64 MiB, 16363 clusters, FAT at sector 1, data at sector 161
```

```text
$ zig build qemu-test
qemu-boot-test: all checks passed
```

## 3. Documentar

- `README.md` — aplicação do toolchain;
- `docs/roadmap/phase-status.md` — objetivo concluído;
- este relatório.