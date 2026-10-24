# Relatório de incremento — F6.26: apresentação de pixels e capability de display

**Tema:** primeira escrita de pixels a partir do modo usuário, sem mapear o
framebuffer no processo.

**Base:** commit `dbff8a6` (F6.25), árvore de trabalho de 2026-10-24.

**Estado:** TESTADO LOCALMENTE em QEMU; não testado em hardware físico.

## 1. Objetivo

O F6.25 expôs a geometria e o formato do display, mas o modo usuário ainda
não podia desenhar. O F6.26 entrega o segundo passo do serviço gráfico:

1. a capability de display, kind 2, sujeito 0, com os direitos `write` (8)
   e `delegate` (4);
2. a chamada 20, `present`, que copia um retângulo validado da memória do
   processo para o framebuffer;
3. a primeira aplicação nativa que apresenta pixels e comprova a cópia por
   leitura de volta do primeiro pixel.

O endereço físico do framebuffer e o tamanho do mapeamento continuam
privados do kernel. A capability autoriza a operação, não o acesso ao
dispositivo.

## 2. Contrato

### 2.1 `PresentRequest`

A estrutura vive em `shared/display.zig`, é importada pelo kernel e pelo
SDK e tem 48 bytes e alinhamento 8:

| Offset | Campo | Tipo |
|-------:|-------|------|
| 0 | `version` | `u32` |
| 4 | `x` | `u32` |
| 8 | `y` | `u32` |
| 12 | `width` | `u32` |
| 16 | `height` | `u32` |
| 20 | `stride` | `u32` |
| 24 | `pixel_format` | `u32` |
| 28 | `reserved` | `u32` |
| 32 | `buffer` | `u64` |
| 40 | `length` | `u64` |

`version` é 1. `stride` é a distância entre duas linhas do buffer do
chamador; o destino usa o pitch do framebuffer, portanto as duas distâncias
podem ser diferentes. `buffer` é somente lido. `length` não pode passar de
64 MiB.

### 2.2 Chamada 20

| Item | Valor |
|------|-------|
| Número | 20 |
| Argumentos | `RDI` endereço da requisição, `RSI` tamanho |
| Resultado | 0 no sucesso, ou erro negativo |
| Privilégio | somente modo usuário |
| Capability | `display`, kind 2, sujeito 0, direito `write` |

A ordem de validação é deliberada:

1. o chamador está no modo usuário e é um processo;
2. o chamador possui a capability do display com `write`;
3. a faixa da requisição é legível e tem pelo menos 48 bytes;
4. a requisição é copiada para o kernel;
5. a versão, a geometria, o formato, o stride e o comprimento são validados
   pela função pura `validatePresent`;
6. o buffer de pixels é uma faixa legível do processo;
7. o retângulo cabe no framebuffer mapeado;
8. somente então as linhas são copiadas.

A capability é verificada **antes** de a requisição ser lida. Um processo
sem o direito não consegue usar a chamada para sondar o framebuffer.

A validação pura recusa:

- versão desconhecida;
- campo `reserved` não zero;
- retângulo vazio ou que sai do display;
- display que não é 32 bpp;
- formato diferente do display ou diferente de RGB32/BGR32;
- `stride < width * 4`;
- `length < stride * height`;
- `length > 64 MiB`.

Os erros novos são 23, `invalid_geometry`, e 24, `invalid_format`. Versão,
stride ou comprimento inválidos usam o erro 3, `invalid_length`; faixas
inválidas usam o erro 2, `invalid_address`; falta de capability usa o erro
10, `not_authorized`; ausência de display ou framebuffer menor que o
retângulo usa o erro 22, `no_display`.

O contrato passa da versão 10 para a 11. A chamada 20 é aditiva; as
chamadas anteriores mantêm número e significado.

### 2.3 Capability

`kernel/security/capability.zig` ganhou o kind `display`, valor 2. O sujeito
é sempre 0, porque o kernel tem um display visível. Os direitos são:

| Direito | Valor | Significado |
|---------|------:|-------------|
| `write` | 8 | apresentar pixels |
| `delegate` | 4 | entregar a capability a outro processo |

O kernel é a autoridade raiz: cria a capability e a entrega ao processo de
toolchain (processo 4 nesta execução), que é o compositor substituto do
incremento. Nenhum outro processo a recebe. O identificador do processo não
é a autoridade; sem a capability, a chamada é recusada.

### 2.4 Superfície privada

`kernel/graphics/display.zig` agora guarda duas visões:

- `info()`: a `DisplayInfo` pública, sem base nem tamanho do mapeamento;
- `surface()`: a estrutura privada `Surface`, com base, tamanho, pitch,
  formato e dimensões, usada somente pelo caminho de apresentação.

`present` valida o retângulo contra a `DisplayInfo` e, antes de copiar,
confere que o último byte do retângulo está dentro do tamanho mapeado da
superfície. A base nunca é copiada para a memória do processo.

## 3. Aplicação nativa

`user/hello.zig` consulta a metadata e, quando o display é 32 bpp e o
formato é RGB32 ou BGR32, monta um buffer de 16x16 pixels com o valor
`0x000000FF`, preenche uma `PresentRequest` e chama `sdk.present`. O
resultado precisa ser zero; caso contrário, a aplicação termina com o
código 9. No sucesso, escreve `display present`.

O padrão é `@splat(0x000000FF)` em um `[256]u32`. O compilador gera um
array constante de 1 KiB; o kernel valida a faixa legível e copia as 16
linhas de 64 bytes para o framebuffer.

## 4. Ordem de boot e cena diagnóstica

A cena do compositor do kernel é desenhada antes das tarefas de usuário. O
aplicativo de toolchain apresenta o bloco de 16x16 em (0,0) durante o boot.
Se a cena não fosse redesenhada, o teste interativo usaria o bloco azul como
cor de fundo em (0,0) e compararia o restante da cena contra essa cor,
falhando em (16,0).

Por isso, `kernel/main.zig` redesenha a cena depois que a tarefa de
toolchain termina e antes de `VORYN-KERNEL-READY`. O teste interativo começa
na cena que o kernel controla; a apresentação é comprovada pela leitura de
volta do primeiro pixel no log serial, não pela persistência do retângulo.
O redesenho é uma decisão do boot diagnóstico, não uma parte do contrato de
`present`.

## 5. Evidência

### 5.1 Testes de host

| Verificação | Resultado |
|---|---|
| `zig build test --summary all` | 27/27 passos, 153/153 testes |
| `zig build` (Debug) | imagem gerada |
| `zig build qemu-test` | todos os checks, incluindo os quatro marcadores novos |
| `zig build qemu-interactive-test` | 6/6 movimentos, pixels exatos |

Testes novos:

- layout, offsets e valores padrão da `PresentRequest`;
- requisição válida aceita;
- versão desconhecida recusada;
- campo `reserved` não zero recusado;
- retângulo fora do display, vazio ou no limite recusado;
- stride menor que uma linha recusado;
- buffer menor que as linhas recusado;
- formato diferente do display, ou display desconhecido, recusado;
- display de 16 bpp recusado pela apresentação;
- comprimento acima de 64 MiB recusado;
- capability de display autorizando somente o processo que a possui,
  incluindo transferência sem delegação e revogação;
- kind 2 no fio, direitos permitidos e nome do kind;
- superfície privada copiando base, tamanho e pitch do handoff;
- registro privado mantendo a metadata de um modo de 16 bpp;
- registro privado rejeitando pitch menor que uma linha, mapeamento menor
  que as linhas e base que estoura com o tamanho do mapeamento.

### 5.2 QEMU

Saída serial relevante:

```text
[VNK] capabilities: the display belongs to the process 4
[VNK] syscall 19 from user display_info result 0x28
display metadata
[VNK] display: present 16x16 at 0,0 first=0xff
[VNK] syscall 20 from user present result 0x0
display present
```

O primeiro pixel lido de volta é `0xff`, o byte baixo do padrão
`0x000000FF`. O log prova que o caminho de cópia alcançou o framebuffer;
como o padrão é uniforme, o primeiro pixel representa o bloco de 16x16. O
teste de boot exige os quatro marcadores. O teste interativo continua
passando com os seis movimentos e a restauração de fundo.

## 6. Limitações

- Não há um segundo processo de usuário chamando `present` sem a capability
  no QEMU. A recusa é coberta pelo teste de host da capability e pela mesma
  verificação no início da chamada; um processo separado para o teste de
  recusa fica para o F6.27.
- Não há screenshot do retângulo apresentado. A cena é redesenhada para
  manter o teste interativo estável; a evidência da cópia é a leitura de
  volta do primeiro pixel.
- A cópia é síncrona, sem fila, double buffering ou vsync. Tearing é
  possível.
- O aplicativo de toolchain é um substituto do compositor, não o serviço
  gráfico de usuário. O compositor, as janelas, o foco, o cursor e os
  eventos de entrada continuam no kernel ou propostos.
- O caminho de apresentação do modo usuário ainda não foi medido em
  latência ou throughput; o F6.26 prova correção, não desempenho.
- Todos os resultados são de QEMU/TCG; não há teste em hardware físico.
- O modo GOP de 2048x2048 continua sendo o maior disponível no OVMF.

## 7. Próxima etapa

O F6.27 deve iniciar o serviço gráfico de usuário:

1. mover a composição de janelas para um processo com a capability de
   display;
2. criar a chamada de eventos de entrada, com fila limitada e capability
   própria;
3. apresentar um quadro completo do compositor e comparar o screenshot com
   os pixels esperados;
4. adicionar um processo de teste sem a capability para exercitar a recusa
   de `present` no QEMU;
5. medir a cópia e a composição com o mesmo instrumental de TSC do F6.24.

## 8. Arquivos alterados

- `shared/display.zig`
- `kernel/security/capability.zig`
- `kernel/graphics/display.zig`
- `kernel/arch/x86_64/syscall.zig`
- `kernel/main.zig`
- `sdk/src/syscall.zig`
- `sdk/src/root.zig`
- `user/hello.zig`
- `tests/integration/boot-qemu.sh`
- `docs/specs/syscall-abi.md`
- `docs/adr/ADR-0015-user-space-graphics-service.md`
- `docs/architecture/overview.md`
- `docs/roadmap/phase-status.md`
- `README.md`
- `docs/reports/f6/display-presentation-and-display-capability.md` (novo)
