# SDK nativo VorynOS — F5.1

Estado: **implementado, aguardando compilação e validação em Zig 0.17.0 e QEMU**.

Este módulo é uma interface independente do kernel para aplicações
`x86_64-freestanding`. Baseia-se exclusivamente em
`docs/specs/syscall-abi.md` (VSC-0001, versão 9).

- `sdk/src/syscall.zig`: passagem de argumentos via RAX/RDI/RSI/RDX/R8,
  retorno em RAX e retorno secundário em RDX, números e erros da ABI.
- `sdk/src/root.zig`: operações de console, processo, IPC, capacidades
  e arquivos. Os valores retornados são os bits da ABI; use
  `syscall.errorCode(status)` para identificar erros.
- `user/hello.zig`: primeira aplicação migrada para a interface pública.

O SDK não implementa alocador, libc, POSIX, criação dinâmica de processos
nem descoberta de serviços. Nenhum novo número de syscall foi introduzido.

**Validação pendente no Fedora:**

```sh
zig version
zig build
zig build test
zig build qemu-test
```

Não publicar como versão estável antes de validar esses comandos.

## Incrementos F4–F6 publicados nesta branch

- **F4:** `user/hello.zig` exercita `fs_open`, `fs_read` e
  `fs_close` sobre `/apps/hello.txt` por meio do SDK.
  A aplicação encerra com código não zero em caso de falha.
- **F5:** teste de `ping` na aplicação nativa; catálogo tipado dos
  códigos de erro da ABI em `sdk/src/syscall.zig`.
- **F6:** `kernel/graphics/raster.zig` oferece desenho em superfícies
  lineares de 32 bits e testes host de limites e clipping.
  Ainda não está conectado ao framebuffer do boot.

### Critérios para revisão

Executar no Fedora, com Zig 0.17.0:

```sh
git switch feat/native-sdk
git pull --ff-only origin feat/native-sdk
zig build
zig build test
zig build qemu-test
```

Verificar que `toolchain ELF` continua aparecendo no console e que a
aplicação termina com código zero. O teste de boot atual verifica a
execução, mas não identifica separadamente cada falha do SDK.
**Não considerar F4–F6 concluídas** com base apenas neste incremento:
faltam persistência, VFSX, compositor, entrada e janelas.

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
