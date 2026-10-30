# F6.31 — A barra da shell e o foco entre clientes

| Campo | Valor |
|-------|-------|
| **Data** | 2026-10-30 |
| **Base** | `a418ad334bb9912e3c0460eced5949174a747bcd` + a árvore de trabalho do incremento F5/VLIB |
| **Estado** | TESTADO LOCALMENTE (host) — autoteste de boot **IMPLEMENTADO — NÃO TESTADO** neste ambiente |
| **Escopo** | Barra de tarefas do desktop, troca de foco por teclado e a raiz de testes que faltava |

---

## 1. O que a auditoria do repositório encontrou

Duas divergências, as duas na mesma direção: a documentação **subestimava** o
que existe e **superestimava** o que é verificado.

### 1.1 Foco entre clientes já existia — e a documentação dizia que não

`README.md` (F6) e `docs/roadmap/phase-status.md` afirmavam "sem foco entre
clientes" / "focus … pending". O código diz o contrário:

- `kernel/graphics/window_manager.zig` mantém `focused: ?Handle`, com
  `hitTest`, `raise` e reposição de foco ao destruir a janela;
- `kernel/graphics/session.zig` entrega o teclado **exclusivamente** à janela
  em foco (`keyboard events follow focus and do not leak to other clients`);
- `kernel/graphics/frame.zig` só muda o foco quando o clique é entregue;
- `kernel/graphics/window_renderer.zig` desenha a janela em foco com a cor
  ativa.

O foco existia, portanto, **e nunca era exercitado** (ver §1.2).

### 1.2 Vinte e dois testes existiam e nunca rodavam

Nenhum destes arquivos estava em um binário de `zig build test`:

| Arquivo | Testes |
|---|---:|
| `kernel/graphics/frame.zig` | 5 |
| `kernel/graphics/session.zig` | 6 |
| `kernel/graphics/window_manager.zig` | 3 |
| `kernel/graphics/window_renderer.zig` | 2 |
| `kernel/graphics/pointer_input.zig` | 2 |
| `kernel/graphics/event_queue.zig` | 3 |
| `kernel/graphics/desktop.zig` | 5 |
| `kernel/graphics/framebuffer_bridge.zig` | 3 |
| **Total** | **29** |

Os binários existentes cobriam `raster.zig`, `compositor.zig`, `damage.zig`,
`display.zig` e `keyboard_motion.zig` — nunca a camada que os usa. É o mesmo
defeito que a auditoria de 2026-10-30 registrou em D7 para
`f4_physblk_vnv_integration.zig`: código de teste compilado por ninguém e
contado por nenhum resumo. "Existir no repositório" não é "rodar".

A raiz nova (`kernel/graphics/desktop.zig`, binário `desktop-tests`) coleta
**49** provas: as **29** que nunca rodavam, **11** novas deste incremento
(6 da barra, 2 de `focusNext`, 3 do desktop com shell) e **9** que repetem
provas já cobertas por `raster-tests`/`compositor-tests` — repetição inócua,
registrada aqui para que o total não surpreenda.

## 2. O que este incremento acrescenta

### 2.1 `kernel/graphics/taskbar.zig` — o modelo da barra

Um módulo puro, sem alocação e sem hardware:

- `Bar.layout(manager, width, out)` distribui **um botão por janela visível**,
  na ordem do z-order, dividindo a largura em partes iguais com uma calha de
  1 px. Janelas invisíveis não ganham botão; janelas além de `max_buttons`
  (8) continuam existindo e recebendo foco, mas ficam sem botão;
- `Bar.buttonAt(manager, w, h, x, y)` responde qual janela está sob um ponto.
  Um ponto na calha, acima da barra ou em coluna vazia devolve `null`: clicar
  no vazio não muda o foco;
- `Bar.paint(surface, manager, palette)` pinta o fundo e os botões, com o
  botão da janela em foco na cor ativa, e recorta pela superfície. O retorno é
  a **área coberta**, não a soma das escritas — um botão sobrescreve o fundo,
  e somar as duas escritas inflaria o número.

A barra **não é uma janela**: não entra no z-order nem no compositor. O
desktop a pinta depois das janelas, e é isso que impede que uma janela a cubra
ou dispute foco com ela.

### 2.2 `Desktop`: shell opcional e troca de foco

- `enableShell(shell)` liga a barra e invalida o quadro;
- `paintShellMapping(mapping)` pinta a barra sobre uma superfície validada;
- `present()` pinta a barra **depois** das janelas, inclusive quando nenhum
  quadro novo foi composto (a primeira apresentação tem de mostrá-la);
- `moveFrontAndPresentTimed` repinta a barra ao final do caminho incremental:
  uma janela arrastada até as linhas de baixo é desenhada e depois a barra
  volta por cima, sem custo de recompor o quadro inteiro;
- `cycleFocusAndPresent(mapping)` troca o foco e repinta tudo — mudar o foco
  muda a cor de duas janelas, então não há recorte parcial que sirva.

A shell é **opcional** (`shell: ?Shell = null`). Um desktop sem shell é
exatamente o de antes, e é isso que mantém válidos os testes existentes que
comparam a composição incremental com `renderer.render`.

### 2.3 `window_manager.focusNext()`

Passa o foco para a próxima janela visível na ordem do z-order, de forma
circular, **sem alterar a ordem**: trocar de foco pelo teclado não deve
reordenar as janelas na tela. Janela invisível é pulada; um gerenciador sem
janelas visíveis devolve `null` sem mudar nada.

### 2.4 O que roda no boot

`presentGraphicsDesktop()` liga a barra (`height / 32`, mínimo 1 linha),
apresenta a cena, e então executa o autoteste da shell:

```text
[VNK] shell: bar height=33 buttons=2 windows=2              # 1080 / 32
[VNK] shell: the first button answers a click at x=0 y=1079
[VNK] shell: focus cycled to slot=1 frame=1920x1080
```

O kernel **mata o boot** (`FATAL: …`) se o primeiro botão não responder ao
clique, se a calha pertencer a um botão ou se a troca de foco não mudar de
janela. O segundo `cycleFocusAndPresent` devolve o foco à janela da frente,
para que a cena termine no estado em que começou.

## 3. O que continua não existindo

- **Texto.** Não há fonte no kernel: os botões são retângulos, sem título.
  Uma barra sem rótulo é feia, mas não é uma mentira sobre o que existe;
- **Cursor.** Não há cursor desenhado nem plano de hardware;
- **Driver de mouse.** O caminho `pointer_input` → `buttonAt` → foco está
  implementado e testado, mas **nenhum dispositivo o alimenta**: o PS/2 do
  kernel lê teclado (IRQ1), não mouse (IRQ12). A troca de foco que roda no
  boot é a do teclado;
- **Lançador, área de notificação, shell em espaço de usuário.** Nada disso
  está aqui.

## 4. Verificação

| Comando | Resultado |
|---|---|
| `zig test kernel/graphics/taskbar.zig` | 14/14 (6 da barra + 3 do gerenciador + 5 do rasterizador) |
| `zig test kernel/graphics/desktop.zig` | 49/49 |
| `zig build test --cache-dir /tmp/cache-c --summary all` | **670/670, 43/43 passos** (`desktop-tests` 49; antes 621) |
| `zig build` | kernel, boot e imagem de 128 MiB |
| `bash -n tests/integration/boot-qemu.sh` | sintaxe ok |
| `tests/integration/log-assertions-test.sh` | 7/7 |
| `zig build qemu-test` | **não executado**: sem QEMU/OVMF neste ambiente (CI) |

As três asserções novas (`the shell taskbar`, `the click target of the first
shell button`, `the focus cycle of the shell`) estão no teste de boot e
**não foram executadas** aqui. O estado do autoteste de boot é
**IMPLEMENTADO — NÃO TESTADO**.
