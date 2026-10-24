# Relatório de incremento — F6.22.2, F6.23 e F6.24

**Tema:** latência de entrada, instrumentação do kernel e dano por faixas
expostas.

**Base:** commit `5462ddd` (F6.22.2), árvore de trabalho de 2026-10-24.

**Estado:** TESTADO LOCALMENTE em QEMU; não testado em hardware físico.

## 1. Ambiente

| Item | Valor |
|------|-------|
| Distribuição | Fedora 44, kernel 7.2.10-200.fc44.x86_64 |
| Zig | 0.17.0 |
| QEMU | 10.2.2 |
| Firmware | OVMF (`/usr/share/edk2/ovmf/OVMF_CODE.fd`) |
| Máquina QEMU | `q35`, 256 MiB, `-smp 1`, sem KVM (TCG) |
| Framebuffer | GOP 2048x2048, 32 bpp, pitch 8192, base `0x80000000` |
| Imagem | `zig-out/bin/vorynos.img` |

O framebuffer de 2048x2048 é o maior modo 32 bpp oferecido pelo OVMF em
QEMU e é escolhido pelo carregador. Ele amplifica o custo de escrita no
framebuffer, mas não é a causa do problema investigado.

## 2. F6.22.2 — instrumentação do harness

O teste passou a medir, no processo de teste:

- o tempo acumulado das idas e voltas ao monitor HMP;
- a conclusão de cada janela de oito ACKs;
- o intervalo entre o primeiro e o último ACK observado;
- a vazão ponta a ponta.

Resultados da linha de base, com o build Debug e o framebuffer de
2048x2048:

| Eventos | Ponta a ponta | Intervalo de ACKs | HMP total | Janelas de ACK |
|---:|---:|---:|---:|---|
| 16 | 35,984 s (0,4 ev/s) | 33,623 s | 0,003 s | 2, média 16,822 s, máx. 17,987 s |
| 64 | 143,243 s (0,4 ev/s) | 140,885 s | 0,012 s | 8, média 17,613 s, máx. 18,093 s |
| 128 | 290,369 s (0,4 ev/s) | 287,979 s | 0,024 s | 16, média 18,000 s, máx. 18,522 s |
| 256 | 587,010 s (0,4 ev/s) | 584,496 s | 0,047 s | 32, média 18,266 s, máx. 18,939 s |

O monitor HMP responde em milissegundos. Praticamente todo o tempo está
entre o envio da tecla e a observação do ACK, ou seja, no kernel e na
emulação do framebuffer.

### 2.1 Regressão do padrão de movimento

A validação inicial de 16 eventos falhou depois de receber os 16 ACKs:

```text
FAIL: timeout waiting for interactive state burst, step 1,
burst sent=16/16, acks=16/16, movements=0
```

O commit `8668609` (F6.22.1) passou a exigir `\r?\n` imediatamente depois
de `y=(\d+)`:

```python
r"\[VNK\] graphics: keyboard move x=(\d+) y=(\d+)\r?\n"
```

Mas a linha real do kernel continua depois de `y`:

```text
[VNK] graphics: keyboard move x=704 y=512 redraw=1396736 pixels
```

O padrão nunca podia casar, então o teste esperava até o timeout com os
ACKs corretos e zero movimentos reconhecidos. A correção inclui o sufixo:

```python
r"\[VNK\] graphics: keyboard move x=(\d+) y=(\d+) redraw=\d+ pixels\r?\n"
```

Uma execução de 256 eventos da linha de base terminou com todos os checks
impressos, mas o processo externo retornou 127 porque o arquivo do teste
foi editado enquanto o Bash ainda o lia. Os números da tabela são os que o
próprio teste imprimiu antes do artefato; a matriz otimizada foi executada
sem edição concorrente e retornou 0.

## 3. F6.23 — instrumentação interna do kernel

### 3.1 Implementação

- `kernel/arch/x86_64/cpu.zig`: `readTimestamp()` com `rdtsc`.
- `kernel/input/ps2.zig`: acumula interrupções, bytes e ciclos da IRQ1;
  `takeIrqStatsIrqsDisabled()` lê e zera com interrupções desabilitadas.
- `kernel/main.zig`: calibra o TSC contra o PIT durante a espera de cinco
  ticks já existente no boot e publica `[VNK] perf: timestamp counter N Hz`.
- Cada seta pressionada é medida em cinco fases: setup da superfície e da
  lista de janelas, movimento, escrita do ACK, composição/redraw e escrita
  do log de movimento. O total é a soma até o fim do log.
- O resumo é publicado a cada oito setas, alinhado às janelas do teste:

```text
[VNK] perf: 8 arrows total=...us setup=...us motion=...us ack=...us
render=...us log=...us pixels=... irq_interrupts=... irq_bytes=... irq=...us
```

- O teste relê o log depois do screenshot final para não perder a última
  janela, cujo resumo é escrito depois da última linha de movimento.

### 3.2 Medição de 16 setas (Debug, antes do F6.24)

| Fase | Total | Por seta | Fração |
|---|---:|---:|---:|
| Render | 35.724.912 us | 2.232.807 us | 99,93% |
| ACK serial | 22.203 us | 1.387 us | 0,06% |
| IRQ1 | 1.328 us | 83 us | 0,004% |
| Log de movimento | 2.317 us | 145 us | 0,006% |
| Setup | 572 us | 36 us | 0,002% |
| Movimento | 377 us | 24 us | 0,001% |
| **Total** | **35.750.384 us** | **2.234.399 us** | 100% |

Cada seta redesenhou 1.396.736 pixels. A hipótese passou a ser precisa: o
custo está na composição de duas geometrias completas da janela, não no
teclado, no escalonador, no monitor ou no log serial.

## 4. F6.24 — dano por faixas expostas

### 4.1 Hipótese

Uma janela opaca que apenas se desloca mantém intacta a interseção entre a
geometria antiga e a nova. Repintar essa interseção não muda nenhum pixel.
Somente as faixas expostas precisam ser recompostas.

### 4.2 Implementação

`kernel/graphics/damage.zig`:

- `clipRect` recorta um retângulo aos limites da tela;
- `invalidateDifference` decompõe `rect \ covered` em até quatro retângulos
  disjuntos, sem sobreposição;
- `updateWindow` usa a diferença somente quando visibilidade, largura,
  altura e cor não mudaram; caso contrário, invalida as duas geometrias
  completas, preservando o comportamento genérico do compositor;
- novo teste de host: um deslocamento de duas colunas em uma janela 3x2
  invalida 8 pixels, não 12, e o resultado é comparado com a composição
  completa.

Para uma janela de 1024x682 e passo de 64 pixels, o desenho cai de
1.396.736 para:

- 87.296 pixels em movimento horizontal;
- 131.072 pixels em movimento vertical;
- média de 109.184 pixels na rota alternada do burst.

### 4.3 Resultados (Debug)

| Eventos | Antes | Depois | Ganho |
|---:|---:|---:|---:|
| 16 | 35,984 s | 2,379 s | 15,1x |
| 64 | 143,243 s | 9,275 s | 15,4x |
| 128 | 290,369 s | 18,453 s | 15,7x |
| 256 | 587,010 s | 36,641 s | 16,0x |

Vazão ponta a ponta: 0,4 ev/s -> 6,7 a 7,0 ev/s. Render médio por seta:
2.232,8 ms -> 141,1 ms (15,8x). Pixels médios: 1.396.736 -> 109.184
(12,8x). O ganho de tempo é ligeiramente maior que o de pixels porque as
faixas expostas também reduzem o número de camadas recompostas por pixel.

### 4.4 ReleaseFast

O mesmo binário com `-Doptimize=ReleaseFast` muda a ordem de grandeza:

| Métrica (16 setas) | Debug | ReleaseFast |
|---|---:|---:|
| Kernel total | 2.262.092 us | 65.719 us |
| Render | 2.256.891 us | 60.631 us |
| Render por seta | 141.055 us | 3.789 us |
| ACK por seta | 133 us | 166 us |
| Ponta a ponta | 2,379 s | 1,610 s |
| Vazão ponta a ponta | 6,7 ev/s | 9,9 ev/s |

No ReleaseFast o kernel gasta 4,1 ms por seta; 1,61 s de ponta a ponta
significam que o harness domina. Cada `sendkey key 50` mantém a tecla por
50 ms, e o teste só reabastece a janela depois de oito ACKs. O intervalo
observado de aproximadamente 95 ms por seta é compatível com o
escalonamento de make/break do QEMU, não com o redraw do kernel.

Conclusões separadas:

1. o F6.24 elimina trabalho algorítmico real: 12,8x menos pixels e 15,8x
   menos tempo de render no build Debug;
2. o build ReleaseFast elimina o custo de código não otimizado no caminho
   de pixel: mais 37x no render por seta, mantendo os mesmos pixels;
3. depois do F6.24 e do ReleaseFast, o limite do teste é a injeção de
   teclas do QEMU, não o kernel.

## 5. Validação de correção

| Verificação | Resultado |
|---|---|
| `zig build test --summary all` | 25/25 passos, 13 testes de dano/raster/compositor |
| `zig build` (Debug) | imagem gerada |
| `zig build -Doptimize=ReleaseFast` | imagem gerada e executada |
| `zig build qemu-test` | todos os checks de boot, exceção e ELF nativo |
| `zig build qemu-interactive-test` | 6/6 movimentos, pixels exatos, dentro do timeout padrão |
| `--bounds` | 70/70 passos, incluindo no-ops grampeados sem alteração de pixel |
| `--stress` | 48/48 movimentos, comparação de framebuffer por segmento |
| burst 16/64/128/256 | ACKs ordenados, geometria exata, exit 0 |

O comparador de framebuffer foi reescrito para validar cada linha como
bytes, em vez de visitar cada pixel em Python. Ele continua verificando
todos os pixels contra a cena esperada (fundo, janela de trás e janela da
frente), mas deixou de distorcer a vazão ponta a ponta. O número de pixels
alterados agora é calculado geometricamente pela diferença simétrica das
duas posições da janela.

## 6. Limitações

- Todos os números são de QEMU/TCG, com build Debug salvo quando indicado;
  não há medição em hardware físico.
- O modo GOP de 2048x2048 é o maior disponível e amplifica o custo por
  pixel; um hardware real ou um modo menor mudaria os valores absolutos.
- A janela de perf agrega oito setas; não há distribuição por evento.
- O teste ponta a ponta no ReleaseFast mede o escalonamento de teclas do
  QEMU, não a vazão máxima do kernel.
- O compositor continua no kernel; não há serviço gráfico em modo usuário,
  gerenciador de janelas, foco, cursor, texto ou mouse.

## 7. Próxima etapa

1. Medir o kernel sem o limite de 50 ms do `sendkey`, com uma opção de
   benchmark que injete teclas com hold curto ou direto no dispositivo.
2. Avaliar um modo GOP máximo configurável no handoff, para que o teste não
   pague 2048x2048 quando 1024x768 é suficiente.
3. Antes de F7, levar a composição para um serviço em modo usuário com
   superfícies compartilhadas e syscalls de apresentação e entrada; essa é
   a condição para um desktop nativo de verdade.
4. Só depois avançar para F7 (drivers, rede, áudio e hardware físico).

## 8. Arquivos alterados

- `kernel/arch/x86_64/cpu.zig`
- `kernel/input/ps2.zig`
- `kernel/main.zig`
- `kernel/graphics/damage.zig`
- `tests/integration/interactive-qemu.sh`
- `tests/integration/compare-framebuffer.py`
- `docs/roadmap/phase-status.md`
- `docs/reports/f6/input-latency-and-exposed-strip-damage.md`
