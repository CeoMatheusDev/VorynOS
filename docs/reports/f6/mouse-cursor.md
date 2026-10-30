# F6.32 — O cursor e o mouse PS/2

| Campo | Valor |
|-------|-------|
| **Data** | 2026-10-30 |
| **Base** | `a418ad33` + os incrementos de F9, VLIB e F6.31 desta branch |
| **Estado** | **TESTADO NO CI** — 22 provas novas no host e boot em QEMU/OVMF com as asserções do mouse, run 41015197816, SHA `4183778` |
| **Escopo** | Decodificador do mouse PS/2, handshake do 8042, IRQ12, cursor do desktop |

---

## 1. Objetivo

A barra da shell (F6.31) existia sem ponteiro: o caminho
`pointer_input → buttonAt → foco` estava implementado e testado, mas **nenhum
dispositivo o alimentava**. O boot só movia janelas por seta do teclado.

Este incremento fecha essa lacuna em duas metades, e mantém a fronteira entre
elas explícita:

- **o dispositivo**: o mouse PS/2, do handshake do controlador até o pacote
  decodificado;
- **a interface**: a seta desenhada pelo kernel, com o retângulo a recompor
  calculado a partir do modelo das janelas.

## 2. O caminho do byte até o pixel

```text
movimento físico
    │
    ▼
i8042 (porta 0x64 de status, 0x60 de dados)  ── bit 5 do status diz se o byte é o teclado ou o auxiliar
    │
    ▼
IRQ12 ──► ps2.drainOutputBuffer()  ── encaminha cada byte ao dono pelo bit 5
    │
    ▼
mouse.Decoder (3 bytes: flags, X, Y)  ── sincronismo, sinais, overflow, inversão de Y
    │
    ▼
mouse.Queue (32 pacotes, descarte do mais novo quando cheia)
    │
    ▼
applyMouseGraphics ──► Desktop.movePointerAndPresent(dx, dy)
    │
    ▼
cursor.Cursor.paint ──► framebuffer
```

## 3. `kernel/input/mouse.zig` — o decodificador (puro)

Sete provas de host cobrem:

- **pacote completo**: movimento e estado dos três botões;
- **sinais**: `0x10` inverte X, `0x20` inverte Y;
- **orientação**: no fio, Y positivo é *para cima*; o kernel usa Y crescente
  *para baixo*, como o framebuffer. A inversão acontece uma vez, no
  decodificador, e o chamador recebe `dy` na orientação da tela;
- **sincronismo**: um primeiro byte sem o bit 3 é descartado e contado
  (`resyncs`). Aceitá-lo deslocaria todos os pacotes seguintes;
- **overflow**: com o bit 6 ou o bit 7 ligado, a magnitude de 8 bits não
  representa o deslocamento. O valor é **saturado** em 255 e o evento é
  contado (`overflows`), em vez de inventar um número que pareça exato;
- **fila**: FIFO de 32 pacotes; quando cheia, descarta o **mais novo**. Um
  movimento fora de ordem é pior que um movimento perdido.

## 4. `kernel/input/ps2.zig` — o controlador (hardware)

- `initAuxiliaryIrqsDisabled()` faz o handshake: habilita o dispositivo
  auxiliar (`0xA8`), lê a configuração do 8042 (`0x20`), liga o bit da
  interrupção do auxiliar e desliga o do relógio travado, escreve de volta
  (`0x60`), e envia ao mouse `0xF6` (padrões) e `0xF4` (habilitar relatório),
  exigindo **ACK** nos dois;
- **toda espera é limitada** (100 000 giros). O protocolo não promete tempo,
  e um laço aberto em um controlador ausente prenderia o boot para sempre.
  Cada desistência vira um `reason` textual publicado no console;
- `drainOutputBuffer()` é chamado pelos **dois** IRQs e roteia por byte. Um
  byte do auxiliar que chegue durante o IRQ1 precisa ir para o mouse: perder
  um byte do meio de um pacote de três desalinha todos os seguintes;
- um ACK pode vir acompanhado de bytes de um pacote em trânsito; os bytes do
  auxiliar que não são ACK vão para o decodificador em vez de serem
  descartados.

## 5. `kernel/graphics/cursor.zig` — a seta (pura)

A seta é definida como **texto** (`#` contorno, `o` preenchimento, `.`
transparente), para que a forma seja legível no código. Cinco provas cobrem:

- o sprite é retangular e só usa os três caracteres; a ponta é o pixel (0,0);
- `paint` escreve contorno e preenchimento e **não toca** nos pixels
  transparentes;
- `paint` recorta na borda direita e inferior sem sair dos limites;
- `clamp` mantém a seta inteira dentro da superfície e `moved` satura nas
  bordas;
- o retângulo devolvido bate com o que `paint` tocaria.

### Por que não há "salvar e restaurar"

Guardar os pixels embaixo da seta parece mais barato, mas o que foi salvo
envelhece a cada janela desenhada por cima: restaurar um retângulo velho
espalharia pixels de uma cena que já não existe. A regra adotada é recompor o
retângulo a partir do **modelo** das janelas e desenhar a seta por último —
mais caro em pixels, e correto em qualquer ordem de eventos.

## 6. Integração no desktop

- `Desktop.enablePointer` / `placePointer` / `paintPointerMapping`;
- `present()` pinta, nesta ordem: janelas → barra da shell → **ponteiro**;
- `movePointerAndPresent(dx, dy)` recompõe o retângulo da seta antiga e o da
  nova (mais a barra, que pode estar embaixo delas) e redesenha a seta. Se o
  cursor já está no limite e o movimento não muda nada, devolve 0 e não
  escreve um pixel.

Três provas novas no `desktop-tests` (57 no total):

1. a seta é pintada por cima das janelas e da barra, e só onde ela está;
2. **dois movimentos parciais produzem byte a byte o mesmo framebuffer** que
   uma apresentação completa na posição final — o caminho incremental não
   deixa rastro da posição antiga;
3. nas bordas o cursor para, e repetir o movimento não escreve nada.

## 7. Boot

```text
[VNK] pointer: arrow drawn at x=960 y=540 over the desktop
[VNK] mouse: controller ready config=0x47->0x47 acks=2
[VNK] mouse: ready for PS/2 movement
[VNK] mouse: cursor moved x=1000 y=570 dx=20 dy=10     # após movimento injetado
[VNK] mouse: 2 moves, 2 packets, 6 bytes, 0 packets dropped, 0 resyncs, 2 irqs
```

A linha `config=0x47->0x47` mostra o byte de configuração do 8042 antes e
depois do ajuste (bit 1 ligado, bit 5 desligado). `acks=2` é a prova de que os
dois comandos do mouse foram reconhecidos — um dispositivo presente mas mudo
falharia aqui.

Um mouse ausente **não** impede o boot: o kernel publica
`[VNK] mouse: unavailable (<motivo>) config=0x..` e o teclado continua sendo a
entrada. A interrupção só é desmascarada depois do ACK.

## 8. O que continua não existindo

- **aceleração e suavização** do ponteiro: um contador do PS/2 é um pixel.
  Aceleração é política de interface, e inventá-la tornaria o teste do cursor
  dependente de uma curva;
- **clique do mouse**: o pacote traz o estado dos três botões, e o
  decodificador o reporta, mas nenhum caminho do kernel usa os botões para
  arrastar ou focar janelas. O arrasto por ponteiro continua sendo o do
  adaptador `pointer_input`, sem dispositivo por trás;
- **scroll**, roda de rolagem, resolução e taxa configuráveis, outros
  protocolos (IntelliMouse, 4 bytes) e mouse USB/HID;
- **foco por clique**: `taskbar.buttonAt` continua pronto e testado, e
  continua sem receber botão nenhum.

## 9. Verificação

| Comando | Resultado |
|---|---|
| `zig test kernel/input/mouse.zig` | 7/7 |
| `zig test kernel/graphics/cursor.zig` | 14/14 (5 do cursor + 9 do rasterizador/compositor) |
| `zig test kernel/graphics/desktop.zig` | 57/57 |
| `zig build test --cache-dir /tmp/cache-g --summary all` | **704/704, 45/45 passos** (`input-tests` 7, `desktop-tests` 57; antes 689) |
| `zig build` | kernel, boot e imagem de 128 MiB |
| `bash -n tests/integration/boot-qemu.sh` | sintaxe ok |
| `tests/integration/log-assertions-test.sh` | 7/7 |
| `zig build qemu-test` | **pass** no CI: run [41015197816](https://github.com/CeoMatheusDev/VorynOS/actions/runs/41015197816), passo *Teste de boot no QEMU* `success` no SHA `4183778`. Localmente continua **BLOQUEADO** (sem QEMU/OVMF) |

As quatro asserções do boot são **incondicionais**, e o passo de boot do run
[41015197816](https://github.com/CeoMatheusDev/VorynOS/actions/runs/41015197816) (SHA
`4183778`) passou. A conclusão é direta e vale registrar por quê: se o
handshake do 8042 não tivesse recebido os dois ACKs, a linha
`mouse: controller ready …` não existiria e o teste falharia; se o movimento
injetado por HMP (`mouse_move`) não chegasse ao PS/2 virtual, a linha
`mouse: cursor moved …` não existiria e o teste também falharia. O run verde
é, portanto, a prova de que o byte entrou pelo IRQ12, foi decodificado e
virou pixel.

O que isso **não** prova: nada sobre hardware físico, nem sobre o
comportamento do ponteiro sob movimento contínuo rápido (a CI injeta dois
pacotes).
