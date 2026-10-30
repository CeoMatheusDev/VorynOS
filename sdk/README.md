# SDK nativo VorynOS — F5.1

Estado: **implementado e compilado**. As imagens `hello` e `client` são
construídas pelo grafo normal de `zig build` e a suíte `sdk-tests` (5 testes)
roda em `zig build test`. A validação em QEMU depende do CI (QEMU/OVMF não
existem neste ambiente).

Este módulo é uma interface independente do kernel para aplicações
`x86_64-freestanding`. Baseia-se exclusivamente em
`docs/specs/syscall-abi.md` (VSC-0001, **versão 13**). O valor de
`syscall.abi_version` em `sdk/src/syscall.zig` é o mesmo que o kernel publica
em `kernel/arch/x86_64/syscall.zig`; o contêiner VLIB declara essa versão e
recusa uma biblioteca construída para outra.

- `sdk/src/syscall.zig`: passagem de argumentos via RAX/RDI/RSI/RDX/R8,
  retorno em RAX e retorno secundário em RDX, números e erros da ABI. Cobre
  as chamadas 1–11, 13–24 (12 é reservado), incluindo `fs_truncate` (22),
  `input_wait` (23) e `ai_infer` (24).
- `sdk/src/root.zig`: operações de console, processo, IPC, capacidades
  e arquivos. Os valores retornados são os bits da ABI; use
  `syscall.errorCode(status)` para identificar erros.
- `user/hello.zig`: primeira aplicação migrada para a interface pública.

O SDK não implementa alocador, libc, POSIX, criação dinâmica de processos
nem descoberta de serviços. Nenhum número de syscall nasce no SDK: todos vêm
de `docs/specs/syscall-abi.md`, e uma chamada nova exige a especificação e os
testes correspondentes no kernel.

**Validação local (Zig 0.17.0):**

```sh
zig build          # constrói o kernel e as imagens nativas `hello` e `client`
zig build test     # `sdk-tests` 5/5 entre as 621 provas do host
zig build qemu-test  # CI: QEMU/OVMF ausentes neste ambiente
```

Não publicar como versão estável antes de a CI confirmar o boot.

## Incrementos F4–F6 publicados nesta branch

- **F4:** `user/hello.zig` exercita `fs_open`, `fs_read` e
  `fs_close` sobre `/apps/hello.txt` por meio do SDK.
  A aplicação encerra com código não zero em caso de falha.
- **F5:** teste de `ping` na aplicação nativa; catálogo tipado dos
  códigos de erro da ABI em `sdk/src/syscall.zig`.
- **F6:** `kernel/graphics/raster.zig` oferece desenho em superfícies
  lineares de 32 bits e testes host de limites e clipping.
  Já conectado ao framebuffer do boot pela cena estática de
  `presentGraphicsDemo()`; shell, cursor e foco continuam ausentes.
- **F5 / VLIB:** `formats/vlib.zig` é o contêiner de biblioteca nativa
  (`docs/specs/vlib.md`). É codec puro: não liga nem carrega bibliotecas.
  O SDK ainda não produz `.vlb` — o exemplo de boot é montado pelo kernel.

### Critérios para revisão

Executar com Zig 0.17.0, na branch em revisão:

```sh
git switch <branch-em-revisão>
git pull --ff-only
zig build
zig build test
zig build qemu-test
```

Verificar que `toolchain ELF` continua aparecendo no console e que a
aplicação termina com código zero. O teste de boot atual verifica a
execução, mas não identifica separadamente cada falha do SDK.
**Não considerar F4–F6 concluídas** com base apenas neste documento: F5
segue em desenvolvimento (sem linker) e F6 ainda não tem shell, cursor nem
foco entre clientes. O estado vigente é o de
`docs/roadmap/phase-status.md`; este arquivo descreve apenas o SDK.

### F6.1 — Compositor de janelas opacas

O módulo `kernel/graphics/compositor.zig` implementa composição
determinística de retângulos opacos em uma `raster.Surface`. A última
janela visível na lista tem prioridade de desenho. Não há alocação dinâmica
nem dependência de dispositivos; a superfície de destino precisa ter sido
validada e mapeada pelo chamador.

Os testes de sobreposição, visibilidade e clipping estão ligados ao
`zig build test`. Ainda faltam o driver de apresentação, a composição
incremental (dirty rectangles), eventos de entrada e uma API de janelas
para processos usuários. **Não confundir o compositor de host com uma
interface gráfica em execução no VorynOS.**

### F6.2 — Apresentação no framebuffer UEFI

O kernel agora chama `presentGraphicsDemo()` imediatamente após
`paging.activate()` e a sondagem de escrita no framebuffer. A rotina
valida dimensões, limites da região mapeada, formato de 32 bpp e máscaras
BGRA antes de desenhar uma cena estática com duas janelas sobrepostas.

A saída esperada em hardware compatível é:

```text
[VNK] graphics: framebuffer scene presented (2048x2048)
```

Caso a geometria ou as máscaras não sejam suportadas, o kernel registra
o motivo e continua sem tentar desenhar. O teste automatizado atual não
inspeciona pixels; verificar visualmente em `zig build qemu` e executar
`zig build test` e `zig build qemu-test`. Esta integração não foi
compilada nem executada no ambiente do agente.

## F6.3 — Composição incremental (em desenvolvimento)

O compositor em `kernel/graphics/compositor.zig` oferece agora
`composeDirty(surface, background, windows, dirty)`, que recompõe apenas a
interseção de um retângulo com o framebuffer e retorna o número de pixels
redesenhados. A ordem de composição das janelas permanece estável; regiões
fora do retângulo não são modificadas. Há testes host para sobreposição,
clipping e dimensões extremas. O caminho de boot ainda usa `compose` para
apresentar a cena inicial completa.

Validação pendente no Fedora com Zig 0.17.0:

```sh
zig build test
zig build
zig build qemu-test
```

A F6.3 não inclui ainda rastreamento automático de regiões danificadas,
movimentação de janelas ou dispositivos de entrada.
