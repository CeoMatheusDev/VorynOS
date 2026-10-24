# Relatório de incremento — F6.25: metadata do display e alinhamento da pilha

**Tema:** primeira interface gráfica em modo usuário, sem acesso ao MMIO do
framebuffer.

**Base:** commit `5a8d352` (F6.24), árvore de trabalho de 2026-10-24.

**Estado:** TESTADO LOCALMENTE em QEMU; não testado em hardware físico.

## 1. Objetivo

O compositor do F6 continua no kernel. O próximo passo para um desktop
nativo é permitir que um processo de usuário descubra a geometria e o
formato do display e, em um incremento posterior, apresente pixels por uma
chamada validada.

O F6.25 entrega a primeira parte: a chamada 19, `display_info`, que escreve
uma estrutura versionada na memória do processo. A chamada é somente
leitura e **não** expõe o endereço físico do framebuffer, o tamanho do
mapeamento ou qualquer outro endereço de dispositivo.

## 2. Contrato

### 2.1 `DisplayInfo`

A estrutura vive em `shared/display.zig` e é importada pelo kernel e pelo
SDK. O layout é fixo, com 40 bytes e alinhamento 4:

| Offset | Campo | Tipo |
|-------:|-------|------|
| 0 | `version` | `u32` |
| 4 | `width` | `u32` |
| 8 | `height` | `u32` |
| 12 | `pitch` | `u32` |
| 16 | `bits_per_pixel` | `u32` |
| 20 | `pixel_format` | `u32` |
| 24 | `red_mask` | `u32` |
| 28 | `green_mask` | `u32` |
| 32 | `blue_mask` | `u32` |
| 36 | `red_shift` | `u8` |
| 37 | `green_shift` | `u8` |
| 38 | `blue_shift` | `u8` |
| 39 | `reserved` | `u8` |

Os formatos de pixel são 0 (RGB32), 1 (BGR32) e `0xFFFFFFFF` (desconhecido).
O campo `version` é 1. O campo `reserved` é zero nesta versão.

### 2.2 Chamada 19

| Item | Valor |
|------|-------|
| Número | 19 |
| Argumentos | `RDI` endereço da estrutura, `RSI` tamanho |
| Resultado | 40 (bytes escritos) ou erro negativo |
| Privilégio | somente modo usuário |
| Capability | nenhuma (metadata pública) |

O kernel valida, nesta ordem:

1. o chamador está no modo usuário;
2. `length >= 40` (um tamanho maior é aceito para compatibilidade futura);
3. a faixa `[address, address + 40)` é gravável no espaço do chamador;
4. existe um display registrado.

Depois copia exatamente 40 bytes e devolve 40. Um boot sem framebuffer
responde com o erro 22, `no_display`. O erro 22 e a chamada 19 são
aditivos; a versão do contrato passa de 9 para 10.

### 2.3 Registro no kernel

`kernel/graphics/display.zig` guarda uma cópia da `FramebufferInfo`
recebida no handoff, sem o endereço base e sem o tamanho do mapeamento.
`kernel/main.zig` instala o registro em `reportFramebuffer`, antes de
qualquer tarefa de usuário. O registro é escrito uma vez e somente lido
depois.

### 2.4 SDK e aplicação nativa

O SDK importa apenas o módulo `voryn_display` (o arquivo
`shared/display.zig`), e não a árvore inteira de `shared`, para não arrastar
o driver serial e as primitivas de porta para o programa de usuário.
`user/hello.zig` chama `sdk.displayInfo(&info)` e escreve um marcador
estável no console. O teste de boot exige:

```text
[VNK] syscall 19 from user display_info result 0x28
display metadata
```

## 3. Bug de alinhamento da pilha

A primeira execução do aplicativo nativo com a nova estrutura falhou com
`EXCEPTION 13: general protection fault` em `rip=0x1fc353`, antes de a
chamada 19 chegar ao kernel.

A desmontagem mostrou:

```text
132c: push   %rbp
132d: mov    %rsp,%rbp
1330: sub    $0x30,%rsp
...
134f: lea    -0x30(%rbp),%rdi
1353: movaps %xmm0,0x10(%rdi)
```

O kernel iniciava a tarefa de usuário com `RSP` alinhado a 16 bytes
(`0x200000`). A convenção de chamada x86_64 espera que, na entrada de uma
função, `RSP + 8` seja múltiplo de 16, porque uma instrução `call` teria
empilhado o endereço de retorno. Sem esse ajuste, o prólogo `push %rbp`
deixava `RSP` em 8 mod 16 e o `movaps` gerava #GP.

A correção está em `kernel/task/scheduler.zig`: as tarefas de usuário e de
kernel começam em `top - 8`, emulando o quadro de uma chamada. O aplicativo
não foi alterado para contornar o problema, e a correção vale para qualquer
programa freestanding que use spills SSE alinhados.

Esse defeito estava latente desde a criação das tarefas de usuário; a
estrutura de 40 bytes apenas mudou o quadro o suficiente para o compilador
escolher a instrução alinhada.

## 4. Validação

| Verificação | Resultado |
|---|---|
| `zig build test --summary all` | 27/27 passos, 137/137 testes |
| `zig build` (Debug) | imagem gerada |
| `zig build qemu-test` | todos os checks, incluindo os dois novos marcadores |
| `zig build qemu-interactive-test` | 6/6 movimentos, pixels exatos |

Os testes de host novos são:

- layout de 40 bytes e offsets da `DisplayInfo`;
- valores padrão explícitos;
- registro do display copiando geometria, formato e máscaras;
- registro rejeitando framebuffer vazio;
- registro rejeitando framebuffer sem mapeamento (base ou tamanho zero).

## 5. Limitações

- A chamada é somente leitura; não há `present`, superfície, janela, foco,
  cursor, texto ou mouse.
- A aplicação nativa apenas consulta a metadata; ela não desenha.
- O compositor continua no kernel.
- Os números e a validação são de QEMU/TCG; não há teste em hardware.
- O modo GOP de 2048x2048 continua sendo o maior disponível no OVMF.

## 6. Próxima etapa

O desenho completo está em
[`ADR-0015`](../../adr/ADR-0015-user-space-graphics-service.md). O próximo
incremento (F6.26) deve:

1. adicionar a capability `display` (kind 2) com os direitos `write` e
   `delegate`;
2. adicionar a chamada 20, `present`, com uma estrutura versionada que
   contenha buffer, comprimento, retângulo, stride e formato;
3. validar geometria, overflow, faixa de usuário e formato antes de
   qualquer cópia;
4. testar no host a validação pura e no QEMU a apresentação de um padrão
   conhecido, comparando o framebuffer com os pixels esperados;
5. recusar um processo sem a capability.

## 7. Arquivos alterados

- `shared/display.zig` (novo)
- `shared/root.zig`
- `kernel/graphics/display.zig` (novo)
- `kernel/main.zig`
- `kernel/arch/x86_64/syscall.zig`
- `kernel/task/scheduler.zig`
- `sdk/src/syscall.zig`
- `sdk/src/root.zig`
- `user/hello.zig`
- `build.zig`
- `tests/integration/boot-qemu.sh`
- `docs/specs/syscall-abi.md`
- `docs/adr/ADR-0015-user-space-graphics-service.md` (novo)
- `docs/architecture/overview.md`
- `docs/roadmap/phase-status.md`
- `README.md`
- `docs/reports/f6/display-metadata-and-user-stack-alignment.md` (novo)
