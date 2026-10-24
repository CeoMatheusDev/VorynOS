# Relatório de incremento — F6.28: composição no modo usuário, validação visual e recusa sem capability

**Tema:** primeiro quadro composto pela própria aplicação, comparação exata
do screenshot P6 do QEMU e prova de que `present` e `input_poll` são
recusados antes de tocar no pedido quando o processo não tem a capability.

**Base:** commit `f0eee59` (F6.27), árvore de trabalho de 2026-10-24.

**Estado:** TESTADO LOCALMENTE em QEMU; não testado em hardware físico.

## 1. Objetivo

O F6.27 entregou a capability de entrada, a chamada 21 e uma sonda que
apresentava um bloco de 16x16 dirigido por evento. O F6.28 continua o F6,
sem saltar para o F7 e sem transformar a sonda em um compositor completo.
O incremento entrega três partes verificáveis:

1. um módulo puro de composição de janelas opacas no modo usuário, com
   clipping, ordem z e checksum;
2. um quadro de 32x24 composto pela aplicação nativa e apresentado pela
   chamada 20 já existente, comparado pixel a pixel com um screenshot P6
   capturado pelo QEMU;
3. a recusa de `present` e de `input_poll` em um processo de usuário que
   não possui as capabilities de display e de entrada.

O F6.28 **não** é o compositor de usuário completo. Ele é a preparação
arquitetural e a primeira validação visual de um quadro composto no espaço
do processo. Compartilhamento de superfícies entre clientes, processo de
compositor separado, window manager, foco, cursor, fila por processo e
entrada bloqueante continuam propostos.

## 2. Arquitetura

### 2.1 Composição no espaço do processo

`user/composition.zig` é um módulo puro: não chama syscalls, não acessa o
framebuffer, não recebe endereços do kernel e não aloca memória. Ele
define:

- `Window`: retângulo opaco com posição, dimensões e cor de 32 bits;
- `Surface`: largura, altura, `stride` e uma fatia de pixels;
- `Surface.init`: valida a geometria e o tamanho do buffer antes de
  qualquer escrita;
- `Surface.compose`: preenche o fundo e desenha as janelas na ordem da
  lista, com a última na frente;
- `Surface.checksum`: FNV-1a de 64 bits sobre o byte baixo de cada pixel
  visível, na ordem das linhas.

O clipping usa aritmética de 64 bits para que uma coordenada `u32` extrema
não dê a volta e faça a janela aparecer no lado oposto. O `stride` pode ser
maior que a largura; o preenchimento entre as linhas não é escrito nem
entra no checksum.

A aplicação nativa mantém o quadro em um buffer local de 32x24 pixels
(3 KiB) na própria pilha. Ela compõe três janelas em tons de cinza:

| Elemento | Retângulo | Cor |
|---|---|---|
| fundo | 32x24 | `0x00202020` |
| janela de trás | (0,0) 20x16 | `0x00606060` |
| janela da frente | (12,8) 20x16 | `0x00C0C0C0` |
| marcador | (2,2) 4x4 | `0x00F0F0F0` |

O quadro é apresentado como **um único retângulo validado** pela chamada
20. O kernel não recebe a lista de janelas, a ordem z ou um mapeamento do
framebuffer; ele continua sabendo apenas que um processo com a capability
de display pediu para copiar um retângulo de pixels legível. Essa é a
preparação para o compositor de usuário: a política de janelas fica no
processo, e o kernel permanece uma fronteira de validação.

### 2.2 Por que tons de cinza

O screenshot do QEMU é P6/RGB24. O framebuffer do GOP pode ser RGB32 ou
BGR32, e a ordem dos canais não deve tornar o teste dependente da máquina.
Como todas as cores do quadro têm `R = G = B`, o PPM mostra o mesmo valor
nos três canais. O comparador verifica essa igualdade e calcula o mesmo
FNV-1a sobre o canal vermelho; o checksum publicado pela aplicação é
comparado com o checksum do screenshot. Um retângulo deslocado, um
`stride` errado, uma cor trocada ou um pixel perdido mudam o hash.

### 2.3 Ajuste do layout da janela de usuário

O primeiro quadro de 64x48 foi colocado em BSS e fez o segmento gravável do
ELF terminar em `0x7088`; o materializer recusou a imagem com
`SegmentOutsideWindow`. O quadro foi reduzido para 32x24 e movido para a
pilha, mas o segmento gravável ainda terminava em `0x4000`, no início da
pilha antiga em `0x3000`. O ajuste de layout foi então deliberado:

- `stack_offset` passou de `0x3000` para `0x4000`;
- `window_size` passou de `0x5000` para `0x6000`;
- a pilha continua com duas páginas, agora em `0x4000` e `0x5000`.

O materializer continua recusando qualquer segmento ou página de pilha
que saia da janela. A mudança é de **layout de memória do modo usuário**,
não do contrato de syscalls: a ABI continua na versão 12, sem nova
chamada, novo kind de capability ou novo código de erro.

O buffer do quadro fica na pilha, e não em BSS. Isso evita um novo
segmento gravável e mantém a imagem dentro da janela sem aumentar a pilha
além das duas páginas existentes.

## 3. Validação visual

### 3.1 Fluxo da aplicação

1. A aplicação consulta `display_info` e apresenta o bloco de 16x16 em
   (0,0), como no F6.26.
2. Escreve `input probe ready` e aguarda a seta direita.
3. Ao receber a seta, apresenta o bloco de 16x16 em (16,0), como no F6.27.
4. Compõe o quadro de 32x24, calcula o checksum, chama `present` em (0,0)
   e escreve:

   ```text
   composition ready frame=32x24 at=0,0 checksum=0x...
   ```

5. No boot automatizado, aguarda a tecla `Q` por até 20.000.000 de
   chamadas não bloqueantes a `input_poll`. O teste captura o screenshot e
   então envia `Q`; a aplicação escreve `composition released`.
6. No teste interativo, a aplicação já viu `I` na sonda de entrada,
   registra `interactive_requested` e **não** entra na espera. Ela
   apresenta o quadro, sai e deixa o kernel redesenhar a cena diagnóstica.

O teste de boot captura o screenshot **antes** de enviar `Q`. Assim, os
pixels do processo estão visíveis no momento da captura; depois da saída
da aplicação, o kernel pode redesenhar a cena sem invalidar a evidência.

### 3.2 Captura e comparação

`tests/integration/boot-qemu.sh` usa o monitor HMP do QEMU:

1. espera o marcador `composition ready`;
2. envia `screendump` para um arquivo P6 no diretório temporário;
3. espera o arquivo e o prompt do monitor;
4. envia `sendkey q 50` para liberar a aplicação;
5. depois de encerrar o QEMU, executa
   `tests/integration/compare-presentation.py`.

O comparador lê o PPM, recorta exatamente 32x24 pixels em (0,0), verifica
que todos os pixels são cinza e calcula o FNV-1a. O checksum esperado é
extraído do próprio serial da aplicação. O teste falha se o screenshot não
foi capturado, se o checksum não aparece ou se os pixels não coincidem.

## 4. Recusa sem capability

O processo de papel 2 (`kernel/arch/x86_64/task.s`) não possui a capability
de display nem a de entrada. Antes do page fault deliberado, ele chama:

- `present` (20) com endereço 0 e comprimento 0;
- `input_poll` (21) com endereço 0 e comprimento 0.

Os argumentos são inválidos de propósito. A ordem do kernel é verificada:
a capability é checada **antes** do pedido e da faixa de saída. Se a
implementação lesse o pedido primeiro, a resposta seria um erro de
endereço ou de comprimento, não o erro 10. Os resultados são gravados nos
offsets `0xB0` e `0xB8` da página de dados, e `reportCapabilities` os lê
depois que o processo é morto pelo page fault.

Marcadores exigidos pelo teste de boot:

```text
[VNK] user: the presentation without the display capability was refused with the error 10
[VNK] user: the input without the input capability was refused with the error 10
```

A recusa é exercitada no QEMU, não apenas no teste de host da capability.
Ela cobre os dois caminhos de autoridade que o F6.28 usa e confirma que o
erro é o mesmo `not_authorized` (10) do modelo.

## 5. Evidência

### 5.1 Host

```text
zig build test --summary all --cache-dir /tmp/opencode/voryn-test-cache-f628
Build Summary: 29/29 steps succeeded; 167/167 tests passed
```

Os 5 testes novos de `user-composition-tests` cobrem fundo, ordem z,
clipping com coordenadas extremas, checksum e rejeição de superfícies
inválidas. O total anterior era 162; o total atual é 167.

`zig build` gerou `zig-out/bin/vorynos.img`.

### 5.2 QEMU — boot, screenshot e recusas

```text
[VNK] display: present 32x24 at 0,0 first=0x606060
composition ready frame=32x24 at=0,0 checksum=0xd6baff86f4575725
composition released
[VNK] user: the presentation without the display capability was refused with the error 10
[VNK] user: the input without the input capability was refused with the error 10
ok: QEMU screenshot matches the user-space composition
qemu-boot-test: all checks passed
```

O primeiro pixel do quadro é `0x606060` porque (0,0) pertence à janela de
trás. O checksum `0xd6baff86f4575725` foi calculado pela aplicação e
reproduzido pelo comparador a partir do PPM.

### 5.3 QEMU — modo interativo

```text
ok: movement 1/6 right (640, 512)->(704, 512)
ok: movement 2/6 down (704, 512)->(704, 576)
ok: movement 3/6 left (704, 576)->(640, 576)
ok: movement 4/6 up (640, 576)->(640, 512)
ok: movement 5/6 left (640, 512)->(576, 512)
ok: movement 6/6 right (576, 512)->(640, 512)
qemu-interactive-test: all checks passed
```

O modo interativo continua com 6/6 movimentos e comparações exatas. A
aplicação reconhece `I`, não espera `Q` e não atrasa o `VORYN-KERNEL-READY`.

## 6. Limitações

- O F6.28 é um **quadro de uma única aplicação**, não um serviço de
  composição. Não há cliente, superfície compartilhada, memória
  compartilhada, foco, cursor, decoração, window manager ou desktop shell.
- O kernel não recebe a lista de janelas; a composição é local ao processo.
  Um compositor separado que receba superfícies de clientes exige uma
  capability de memória que a ABI 12 não possui.
- O screenshot valida 32x24 pixels em (0,0). Ele prova a composição e a
  cópia, mas não uma cena de tela cheia nem a composição de vários
  processos.
- A espera por `Q` é um handshake de teste. Um boot manual sem `Q` termina
  a espera depois do limite e continua; o teste de boot sempre envia `Q`
  depois da captura.
- O caminho de composição e a cópia de 3 KiB não foram medidos com TSC. O
  F6.28 prova correção e pixels exatos, não desempenho.
- O layout da janela de usuário mudou para `0x6000`; o espaço do segmento
  gravável do ELF ainda é apertado e precisa ser revisto quando a aplicação
  crescer.
- Todos os resultados são de QEMU/TCG; não há teste em hardware físico.

## 7. Próxima etapa

O próximo incremento deve mover a composição para um processo de compositor
separado, com as capabilities de display e entrada, e definir o contrato de
superfície compartilhada:

1. capability de memória ou de superfície para entregar pixels de clientes
   ao compositor sem expor o framebuffer;
2. lista de janelas, foco, ordem z e cursor no processo de compositor;
3. retângulos de dano e apresentação incremental, não apenas um quadro
   completo;
4. fila de entrada por processo ou uma forma bloqueante de espera;
5. medição da composição e da cópia com o mesmo instrumental de TSC do
   F6.22.2/F6.23;
6. screenshot de uma cena maior, com mais de uma janela e mais de um
   cliente.

O window manager e o desktop shell continuam depois desse contrato; o F6.28
não os antecipa.

## 8. Arquivos alterados

- `user/composition.zig` (novo)
- `user/hello.zig`
- `shared/usermode.zig`
- `kernel/arch/x86_64/task.s`
- `kernel/main.zig`
- `tests/integration/boot-qemu.sh`
- `tests/integration/compare-presentation.py` (novo)
- `build.zig`
- `docs/reports/f6/user-space-composition-and-presentation-refusal.md` (novo)
- `docs/adr/ADR-0015-user-space-graphics-service.md`
- `docs/roadmap/phase-status.md`
- `docs/specs/syscall-abi.md`
- `docs/testing/testing-strategy.md`
- `README.md`
