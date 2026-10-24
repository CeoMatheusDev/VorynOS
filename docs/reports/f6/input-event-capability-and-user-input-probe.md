# Relatório de incremento — F6.27: capability de entrada e sonda de entrada do modo usuário

**Tema:** primeira entrega de eventos de teclado ao modo usuário, com
capability própria, fila separada e apresentação dirigida por evento.

**Base:** commit `d0dfea4` (F6.26), árvore de trabalho de 2026-10-24.

**Estado:** TESTADO LOCALMENTE em QEMU; não testado em hardware físico.

## 1. Objetivo

O F6.26 provou que o modo usuário pode apresentar pixels sem mapear o
framebuffer. O F6.27 entrega o passo seguinte:

1. a capability de entrada, kind 3, sujeito 0, com os direitos `read` (16)
   e `delegate` (4);
2. a chamada 21, `input_poll`, que retira um evento da fila de entrada do
   serviço gráfico sem bloquear;
3. a separação entre a fila de diagnóstico do kernel e a fila do modo
   usuário, para que a sonda não roube a tecla que seleciona o modo
   interativo;
4. a aplicação nativa que consulta a fila e, ao receber a seta direita,
   apresenta um bloco de 16x16 em (16,0).

O F6.27 não é o compositor de usuário completo. Ele entrega o contrato de
entrada e uma sonda de apresentação dirigida por evento; o compositor, o
window manager, o foco, o cursor e a comparação de screenshot ficam para o
F6.28.

## 2. Contrato

### 2.1 `InputEvent`

A estrutura vive em `shared/input.zig`, é importada pelo kernel e pelo SDK e
tem 16 bytes e alinhamento 4:

| Offset | Campo | Tipo | Significado |
|-------:|-------|------|-------------|
| 0 | `version` | `u32` | `input_version`, atualmente 1 |
| 4 | `kind` | `u32` | `kind_key`, atualmente 1 |
| 8 | `code` | `u32` | código make do PS/2 set 1 |
| 12 | `flags` | `u32` | bit 0 pressionada, bit 1 estendida |

Os demais bits de `flags` são reservados e precisam ser zero. A validação
pura do SDK recusa versão desconhecida, kind desconhecido, flag desconhecida
e código fora do subconjunto suportado. O kernel preenche a estrutura; o
modo usuário valida o que recebeu antes de usar.

### 2.2 Chamada 21

| Item | Valor |
|------|-------|
| Número | 21 |
| Argumentos | `RDI` endereço do evento, `RSI` tamanho |
| Resultado | 1 quando escreveu um evento, 0 quando a fila está vazia, ou erro negativo |
| Privilégio | somente modo usuário |
| Capability | `input`, kind 3, sujeito 0, direito `read` (16) |

A ordem é deliberada:

1. o chamador está no modo usuário e é um processo;
2. o chamador possui a capability de entrada com `read`;
3. a faixa de saída é gravável e tem pelo menos 16 bytes;
4. a fila de usuário existe;
5. um evento é retirado da fila;
6. o evento é convertido para `InputEvent` e copiado para a faixa do
   chamador;
7. o resultado é 1.

A capability é verificada antes de a saída ser tocada, e a faixa de saída é
validada antes de a fila ser consumida. Um endereço inválido não perde um
evento. A chamada não bloqueia: fila vazia é resultado 0, não erro. O erro
novo é 25, `no_input`, para uma plataforma sem fila de entrada; nesta
plataforma a fila existe.

O contrato passa da versão 11 para a 12. A chamada 21 é aditiva; as
chamadas anteriores mantêm número e significado.

### 2.3 Capability

`kernel/security/capability.zig` ganhou o kind `input`, valor 3. O sujeito é
sempre 0, porque o kernel tem uma fila de entrada para o serviço gráfico.
Os direitos são:

| Direito | Valor | Significado |
|---------|------:|-------------|
| `read` | 16 | retirar um evento da fila |
| `delegate` | 4 | entregar a capability a outro processo |

O kernel é a autoridade raiz: cria a capability e a entrega ao processo de
toolchain (processo 4 nesta execução), que também recebeu a capability de
display no F6.26. Nenhum outro processo a recebe. O identificador do
processo não é a autoridade; sem a capability, a chamada é recusada com o
erro 10, `not_authorized`.

### 2.4 Duas filas no IRQ1

O controlador PS/2 decodifica cada byte uma vez e entrega o evento a duas
filas independentes:

- `queue`: fila de diagnóstico do kernel, consumida pelo boot pump e pelo
  laço interativo;
- `user_queue`: fila do serviço gráfico, consumida por `input_poll`.

O IRQ1 é o único produtor; cada fila é uma SPSC protegida por interrupções
locais desabilitadas no consumidor. A separação é necessária porque o teste
de boot envia `A` e `right` para o kernel e o teste interativo envia `I`
para selecionar o modo interativo. Se o modo usuário consumisse a única
fila, poderia roubar o `I` e impedir o laço interativo. Com duas filas, o
kernel continua recebendo sua cópia e o modo usuário recebe a dele.

A fila de usuário tem capacidade para 64 eventos e contabiliza descartes
quando enche. O F6.27 não tem fila por processo, não tem bloqueio e não tem
timestamp; a fila global é a primeira etapa do serviço de entrada.

## 3. Aplicação nativa

`user/hello.zig` continua consultando a metadata e apresentando o bloco de
16x16 em (0,0). Depois disso, escreve `input probe ready` e faz até 200.000
chamadas não bloqueantes a `sdk.inputPoll`.

- O teste de boot já envia `A` e `right` quando vê o marcador de teclado
  pronto. A fila de usuário recebe os dois eventos, além dos releases.
- A aplicação recebe o `A`, valida o evento e o ignora porque não é uma seta
  estendida. Recebe o `right` (scancode `0x4d`, estendido, pressionado),
  escreve `input event scancode=0x4d pressed=1 extended=1` e apresenta o
  mesmo padrão de 16x16 em (16,0).
- No teste interativo, a sonda recebe o `I` (scancode `0x17`, não
  estendido), encerra sem apresentar e deixa a cópia do kernel na fila de
  diagnóstico; o kernel seleciona o modo interativo normalmente.
- A apresentação passa pela chamada 20 já existente; o kernel lê de volta o
  primeiro pixel e registra `present 16x16 at 16,0 first=0xff`.
- A aplicação escreve `input present x=16 y=0` e segue para o teste de
  arquivos do SDK.
- Sem tecla, o laço termina e a aplicação escreve `input timeout`, sem
  falhar o boot. Sem capability, escreve `input unavailable`; um erro
  inesperado escreve `input error` e encerra a sonda.

As chamadas vazias de `input_poll` não são registradas no serial: o
resultado 0 é o caso comum da sonda e o log inundaria a saída. O kernel
registra apenas resultado 1 ou erro.

## 4. Ordem de boot e cena diagnóstica

O boot pump do kernel e a tarefa de toolchain rodam concorrentemente. O
teste de boot envia `A` e `right` depois do marcador
`[VNK] keyboard: ready for PS/2 input`; a sonda de usuário já está ativa e
recebe a cópia da fila de usuário. O kernel recebe a cópia da fila de
diagnóstico e continua o teste de movimento da janela.

Depois que a tarefa de toolchain termina, o kernel redesenha a cena
diagnóstica antes de `VORYN-KERNEL-READY`. O teste interativo começa na cena
que o kernel controla, não no bloco apresentado pela sonda. A evidência da
apresentação dirigida por entrada é o log serial, não a persistência do
bloco.

## 5. Evidência

### 5.1 Testes de host

| Verificação | Resultado |
|---|---|
| `zig build test --summary all` | 27/27 passos, 162/162 testes |
| `zig build` (Debug) | imagem gerada |
| `zig build qemu-test` | todos os checks, incluindo os marcadores de entrada |
| `zig build qemu-interactive-test` | 6/6 movimentos, pixels exatos |

Testes novos:

- layout, offsets e valores padrão da `InputEvent`;
- `keyEvent` marcando pressionada e estendida;
- evento válido aceito;
- versão, kind, flag e código inválidos recusados;
- capability de entrada autorizando somente o processo que a possui;
- kind 3 no fio, direito `read` permitido, direitos de outro kind
  recusados;
- números 21 e ABI 12 no SDK;
- erro 25, `no_input`, no catálogo do SDK.

### 5.2 QEMU

Saída serial relevante do `zig build qemu-test`:

```text
[VNK] capabilities: the input belongs to the process 4
[VNK] display: present 16x16 at 0,0 first=0xff
input probe ready
[VNK] syscall 21 from user input_poll result 0x1
[VNK] keyboard: key scancode=0x1e extended=0 pressed=1
[VNK] syscall 21 from user input_poll result 0x1
[VNK] keyboard: key scancode=0x1e extended=0 pressed=0
[VNK] syscall 21 from user input_poll result 0x1
input event scancode=0x4d pressed=1 extended=1
[VNK] display: present 16x16 at 16,0 first=0xff
input present x=16 y=0
[VNK] graphics: keyboard move x=704 y=512 redraw=87296 pixels
```

O teste de boot exige o marcador da capability de entrada, `input probe
ready`, o resultado 1 da chamada 21, o evento da seta direita, a
apresentação em (16,0) e o marcador `input present x=16 y=0`. O movimento da
janela do kernel prova que a fila de diagnóstico continuou recebendo a
mesma tecla.

O teste interativo continua passando com 6/6 movimentos. A tecla `I` entra
nas duas filas; a sonda de usuário a consome da fila de usuário e encerra
sem apresentar, enquanto o kernel a recebe da fila de diagnóstico e
seleciona o modo interativo.

## 6. Limitações

- Não há espera bloqueante de entrada, fila por processo, timestamp, mouse
  ou ponteiro, foco ou cursor.
- A fila de usuário é global e tem 64 posições; eventos podem ser
  descartados se o consumidor não acompanhar. O descarte é contabilizado,
  mas não há política de pressão ou de recuperação.
- A sonda consome a cópia de usuário de qualquer tecla, mas só apresenta a
  seta direita. O `A` e o `I` são usados para provar que a fila de
  diagnóstico não é afetada.
- A apresentação dirigida por entrada é um bloco de 16x16 em (16,0), não um
  quadro de compositor. Não há screenshot comparado, janela, decoração ou
  z-order.
- Não há um processo separado sem a capability de entrada no QEMU. A recusa
  é coberta pelo teste de host da capability e pela verificação no início da
  chamada.
- O caminho de entrada e a apresentação de 16x16 não foram medidos em
  latência ou throughput. O F6.27 prova correção e integração, não
  desempenho de quadro.
- Todos os resultados são de QEMU/TCG; não há teste em hardware físico.

## 7. Próxima etapa

O F6.28 deve iniciar o compositor de usuário:

1. mover a composição de janelas para um processo com as capabilities de
   display e entrada;
2. apresentar um quadro completo do compositor e comparar o screenshot com
   os pixels esperados;
3. adicionar um processo de teste sem a capability para exercitar a recusa
   de `present` e de `input_poll` no QEMU;
4. evoluir a fila de entrada para o modelo por processo, com uma forma
   bloqueante ou orientada a eventos;
5. medir a cópia e a composição com o mesmo instrumental de TSC do F6.24.

## 8. Arquivos alterados

- `shared/input.zig` (novo)
- `shared/root.zig`
- `kernel/input/ps2.zig`
- `kernel/security/capability.zig`
- `kernel/arch/x86_64/syscall.zig`
- `kernel/main.zig`
- `sdk/src/syscall.zig`
- `sdk/src/root.zig`
- `build.zig`
- `user/hello.zig`
- `tests/integration/boot-qemu.sh`
- `docs/specs/syscall-abi.md`
- `docs/adr/ADR-0015-user-space-graphics-service.md`
- `docs/architecture/overview.md`
- `docs/roadmap/phase-status.md`
- `README.md`
- `docs/reports/f6/input-event-capability-and-user-input-probe.md` (novo)
