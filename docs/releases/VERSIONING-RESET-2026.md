# VERSIONING-RESET-2026 — Reorganização do versionamento público

| Campo | Valor |
|-------|-------|
| **Estado** | CONCLUÍDO |
| **Data** | 2026-10-22 |
| **Escopo** | Marcos públicos de versionamento do repositório |
| **Natureza** | Reorganização de referências Git e de documentação |

## 1. Objetivo

Estabelecer `v0.1.0-dev.1` como o **marco inicial oficial** do
desenvolvimento público do VorynOS, aproveitando integralmente o estado
corrente da branch `main`, e descontinuar os dois marcos experimentais
publicados anteriormente.

**Esta operação não é um reinício do código-fonte.** O histórico de
commits da `main` é preservado, o código existente é preservado, e nenhuma
funcionalidade foi removida.

## 2. O que foi descontinuado

| Identificador | Título do release | Commit apontado | Objeto da tag | Publicado em |
|---|---|---|---|---|
| `v0.1.0-dev.2` | VorynOS v0.1.0-dev.2 — Native UEFI Boot & Kernel Bring-Up | `42c3e62fbf84798d07cf36c3461d6b73e51cbb0f` | `91e1e06d481b6b793b9b4fe25ff7b34e30868d06` | 2026-10-21T20:58:00Z |
| `v0.1.0-dev.3` | VorynOS v0.1.0-dev.3 — User-Mode Execution Milestone | `5dd258830823ca8a9d9a257460643c7924ee23d9` | `0b2cbd33449141f79f1404000af26ae387095e8a` | 2026-10-21T22:57:46Z |

Os dois commits acima **não foram reescritos, descartados nem apagados**.
Eles continuam preservados na branch de arquivo
`archive/versioning-reset-2026`, que aponta para o topo da linhagem
antiga e é alcançável a partir de qualquer cópia do repositório. Eles são
a referência técnica original de cada marco.

**A branch de arquivo não substitui o histórico da `main`.** A `main` tem o
histórico completo da linha atual, com a integração do trabalho paralelo, e
a `archive/versioning-reset-2026` existe apenas para que os commits dos
marcos descontinuados continuem alcançáveis depois da remoção das tags que
os apontavam.

## 3. Estado técnico registrado de cada marco

### v0.1.0-dev.2 — Native UEFI Boot & Kernel Bring-Up

Estado técnico registrado na data de publicação, em 21/10/2026:

- Carregador de inicialização UEFI nativo, em Zig, sem dependência de
  libc.
- Carregamento do kernel em ELF64, com o contrato de boot versionado.
- Validação de boot ponta a ponta com QEMU e OVMF.
- Inicialização do núcleo x86_64, com GDT, TSS e IDT.
- Gerenciamento de memória física e virtual, com tabelas de página
  próprias.
- Heap do núcleo com fusão de blocos e verificação de integridade.
- Escalonador preemptivo circular, movido por um temporizador de 100 Hz.
- Infraestrutura de testes automatizados, com testes no hospedeiro e
  verificação de boot no emulador.
- Infraestrutura inicial de modo de usuário, **desabilitada** na data da
  publicação, à espera da correção do tratamento de exceções.

### v0.1.0-dev.3 — User-Mode Execution Milestone

Estado técnico registrado na data de publicação, em 21/10/2026:

- Execução verificada no terceiro nível de privilégio, com ida e volta do
  modo de usuário.
- Páginas do espaço de usuário com os atributos de acesso do usuário.
- Chamadas de sistema nativas pela instrução `syscall`, com o tratador no
  núcleo escrito em Zig.
- Pilha de kernel por tarefa, para a execução privilegiada.
- Correção do layout do segmento de tarefa do modo de 64 bits, que era a
  causa raiz da falha de entrega de exceção vinda do usuário.
- Retorno ao modo de usuário com `iretq`, preservando as flags de quem
  chamou.
- Escalonamento preemptivo por temporizador, integrado ao caminho verificado
  de execução do usuário mode.
- Teste de boot no QEMU exigindo evidência explícita da execução no modo de
  usuário, e a sequência de interrupções do emulador sem nenhuma exceção
  registrada.

**O que o marco `v0.1.0-dev.3` afirmava e esta reorganização não altera:**
ele afirmava a execução no modo de usuário e o caminho da chamada de
sistema. Ele **não** afirmava a existência de processos, de threads, de
comunicação entre processos, nem de capacidades. O marco `v0.1.0-dev.1`
mantém essa distinção explícita.

## 4. Motivo da descontinuação

1. Os dois marcos foram publicados como **experimentos parciais**, com o
   canal `dev` e sem garantia de contrato, e cada um deles cobria apenas
   uma fatia do caminho de inicialização.
2. A numeração do canal `dev` passou a sugerir uma ordem de progresso que
   não correspondia ao estado real do código: o `dev.3` era anterior ao
   estado atual, e o estado atual é o consolidado.
3. A reorganização dá ao projeto **uma linha de base única e coerente**,
   a partir da qual a numeração volta a ter sentido, e a partir da qual
   cada próximo lançamento corresponde a um incremento técnico verificável.

**O que não motivou a descontinuação:** nenhuma falha técnica, nenhuma
regressão, e nenhum problema de qualidade do código publicado. Os marcos
antigos foram verificados na época, e o registro acima preserva o que
eles afirmavam.

## 5. Procedimento realizado

1. Registro do identificador, do commit e da data de publicação de cada um
   dos dois marcos, e transcrição do estado técnico de cada um para este
   documento.
2. **Integração do trabalho paralelo que estava na branch `main` remota.**
   A branch remota continha 34 commits que a cópia local não tinha: 35
   padronizações de cabeçalho de código-fonte, uma regra nova no
   `AGENTS.md`, e uma nota preparatória da `v0.1.0-dev.1`. O trabalho foi
   integrado por **merge**, que preserva os dois históricos, sem
   reescrita e sem força. A nota preparatória foi substituída pelas notas
   oficiais desta versão, e os cabeçalhos foram preservados.
3. **Correção do cabeçalho padronizado nos arquivos Zig.** A padronização
   remota escrevia o cabeçalho como comentário de bloco `/* ... */`, e no
   Zig 0.17.0 um comentário de bloco antes de um comentário de
   documentação `//!` é um **erro de sintaxe**: o arquivo inteiro era
   recusado pelo compilador, e `zig build` falhava em `build.zig:1:1`. O
   cabeçalho dos arquivos Zig passou a usar comentários de linha `//`, que
   preservam a caixa visual, a identidade, o endereço do repositório, o
   copyright e o SPDX, e que o compilador aceita. A forma de bloco
   permanece nos arquivos Assembly, onde não há comentário de documentação
   de arquivo. A regra e a restrição estão registradas na seção 14 do
   `AGENTS.md`.
4. Atualização das constantes de versão do projeto — o pacote
   `build.zig.zon`, o carregador e o núcleo — para `0.1.0-dev.1`.
5. Criação das notas oficiais da nova versão em
   [`v0.1.0-dev.1.md`](v0.1.0-dev.1.md).
6. Registro da exceção extraordinária na
   [VVS-0001](../standards/VVS-0001.md).
7. Atualização do README, do roadmap e das referências do repositório.
8. Verificação do código, com `zig build`, `zig build test`,
   `zig build qemu-test` e `zig build check`.
9. Publicação do commit, da tag anotada `v0.1.0-dev.1` e do release
   correspondente, marcado como pré-lançamento.
10. **Depois** da confirmação da existência da nova tag e do novo release,
    exclusão dos releases `v0.1.0-dev.2` e `v0.1.0-dev.3`, e exclusão
    das tags remotas com os mesmos dois identificadores, uma operação por
    vez.
11. Verificação final do repositório e da comparação de integridade do
    código.

## 6. O que foi preservado

- A branch `main` **não** foi apagada, reescrita ou reposicionada, e
  nenhum `push` forçado foi executado.
- O histórico de commits da `main` é **intacto**: a integração do trabalho
  paralelo foi feita por merge, que preserva os dois históricos.
- Os dois commits dos marcos descontinuados continuam alcançáveis, na
  branch de arquivo `archive/versioning-reset-2026`.
- Nenhum arquivo de código-fonte foi apagado, e nenhuma funcionalidade foi
  descartada.
- A documentação histórica dos dois marcos está neste documento e no
  histórico do Git.
- Nenhum outro release ou tag foi removido.

## 7. Comparação de integridade do código

A reorganização **não** alterou nenhuma lógica. As diferenças nos arquivos
funcionais de `boot/`, `kernel/`, `shared/`, `tools/`, `scripts/` e `tests/`
são de duas naturezas, e as duas estão declaradas:

1. **As constantes de versão**, que passam a identificar o novo marco:

   ```diff
   -const loader_version = "0.1.0-dev.3";
   +const loader_version = "0.1.0-dev.1";
   ```

   ```diff
   -const kernel_version = "0.1.0-dev.3";
   +const kernel_version = "0.1.0-dev.1";
   ```

   E, fora do conjunto verificado, o manifesto do pacote:

   ```diff
   -    .version = "0.1.0-dev.3",
   +    .version = "0.1.0-dev.1",
   ```

2. **O cabeçalho visual padronizado** dos 29 arquivos Zig, que veio do
   trabalho paralelo da branch `main` remota e foi **preservado** pela
   integração. A correção aplicada nele foi apenas a forma do comentário,
   de bloco para de linha, porque a forma de bloco quebrava a compilação
   (seção 5, item 3).

A verificação é feita pela comparação das somas de verificação SHA-256 de
todos os 36 arquivos desses diretórios. O **conjunto de arquivos** é
idêntico ao estado anterior à reorganização, e a diferença de conteúdo
está limitada às duas naturezas acima. Nenhuma instrução de máquina, nenhuma
lógica, nenhuma tabela, nenhum contrato e nenhum teste foi alterado.

## 8. Referência Git original

| Identificador | Commit | Tag anotada | Onde o commit permanece |
|---|---|---|---|
| `v0.1.0-dev.1` (novo) | `1c47f505b766538398214f1b5c8ee473c4c96527` | tag anotada `v0.1.0-dev.1` | branch `main` |
| `v0.1.0-dev.2` (descontinuado) | `42c3e62fbf84798d07cf36c3461d6b73e51cbb0f` | `91e1e06d481b6b793b9b4fe25ff7b34e30868d06` | branch `archive/versioning-reset-2026` |
| `v0.1.0-dev.3` (descontinuado) | `5dd258830823ca8a9d9a257460643c7924ee23d9` | `0b2cbd33449141f79f1404000af26ae387095e8a` | branch `archive/versioning-reset-2026` |

## 9. A republicação da mesma versão

A primeira publicação de `v0.1.0-dev.1` apontou para o commit
`1539547cf6e6f213a53db75148cbd7cc88cee256`, que é o estado do projeto
antes da auditoria e da curadoria do pacote de distribuição.

A auditoria posterior encontrou inconsistências comprovadas entre a
documentação e o código publicado: a contagem de chamadas de sistema, a
contagem de verificações do teste de boot e o estado do recebimento
bloqueante estavam desatualizados, e o pacote de código-fonte gerado a
partir da tag antiga carregava os documentos internos de desenvolvimento.

A pedido explícita do proprietário, a mesma versão foi **republicada**:

1. O release antigo e a tag antiga foram removidos, depois de o commit
   antigo ser preservado em uma referência de backup identificada como
   histórica.
2. A tag `v0.1.0-dev.1` foi recriada, anotada, sobre o commit final
   validado da `main`.
3. Um novo release, com o mesmo identificador e com as notas reescritas,
   foi publicado com o pacote oficial filtrado como anexo.

**A republicação não altera o histórico da `main`**, e a árvore de
commits do projeto é a mesma antes e depois: a republicação removeu uma
referência de versão, e não uma linha de desenvolvimento.

A política de versionamento registra a exceção na seção 8 da
[VVS-0001](../standards/VVS-0001.md).

## 10. Política de versionamento a partir de agora

A sequência oficial começa em `v0.1.0-dev.1`:

```text
v0.1.0-dev.1
      |
      | Próximas alterações reais
      v
v0.1.0-dev.2
      |
      | Novos incrementos
      v
v0.1.0-dev.3
      |
      v
v0.1.0-alpha.1
```

Cada novo lançamento corresponde a um **incremento técnico verificável**, e
o identificador de um lançamento aponta para um commit **diferente** do
commit de qualquer marco antigo.

A exceção registrada na VVS-0001 é **extraordinária e única**. Ela não
estabelece permissão geral para reutilizar um identificador publicado: a
proibição continua valendo para o futuro, e a exceção só vale para os dois
identificadores aqui descontinuados.
