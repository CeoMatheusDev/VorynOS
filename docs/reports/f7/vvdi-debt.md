# Registro de Dívida Técnica — Subsistema VVDI

- **Data:** 2026-10-27
- **Subsistema:** `kernel/drivers/vvdi/` e orquestração de boot em `kernel/main.zig`
- **ADR relacionado:** [`ADR-0021 — Identidade nativa VVDI`](../../adr/ADR-0021-vvdi-virtual-device-interface.md)
- **Escopo deste documento:** catalogar com precisão técnica os riscos e dívidas arquiteturais remanescentes após PR A, PR B, PR C, PR VVDI e a auditoria do PR D. A-3 foi mitigada no código do PR D; D-6 e D-7 permanecem abertas.

---

## Sumário das dívidas registradas

| ID | Título | Localização principal | Severidade / Natureza | Estado |
| --- | --- | --- | --- | --- |
| **A-3** | Contenção após falha de reset durante configuração da virtqueue | `kernel/main.zig` (`bringUpVirtioFunction`, `programVirtqueue`, `abandonVirtqueue`) | Risco operacional; memória e BAR retidos sem recuperação online | Mitigada no código do PR D; sem recuperação online ou validação em hardware físico |
| **D-6** | Tamanho excessivo do ELF `Debug` do kernel por preenchimento/alinhamento de segmentos | `voryn-kernel` (ligador / layout ELF), contorno em `tools/fatimg.zig` | Dívida de build, imagem e pegada de artefato | Aberto (registrado, não corrigido neste PR) |
| **D-7** | Coexistência das implementações moderna e legada de *split virtqueue* | `kernel/drivers/vvdi/virtqueue.zig` vs. `kernel/arch/x86_64/virtio.zig` | Duplicação estrutural transitória | Aberto (registrado, não corrigido neste PR) |

---

## Detalhamento técnico

### A-3 — Contenção após falha de reset durante configuração da virtqueue

#### Mecanismo atual no código

Em `kernel/main.zig`, a posse da memória DMA da fila 0 é transferida antes da primeira escrita
de configuração (`virtqueue_state.ownership.handOver()`). Se `configureQueue`, `enableQueue`,
`queueEnabled`, `markQueueReady`, `target.finish()` ou a confirmação pós-`DRIVER_OK` falhar,
`programVirtqueue` invoca `abandonVirtqueue(target, device)`. Essa rotina tenta resetar o
dispositivo e libera DMA somente após confirmação de `device_status == 0`.

Na falha de `programVirtqueue`, `bringUpVirtioFunction` agora consulta
`virtqueue_state.ownership.canReturnToAllocator()`: com reset confirmado (ou sem entrega da
fila), desmapeia o BAR; sem confirmação, mantém o BAR e a memória DMA reservados, retém os
metadados do transporte e registra a contenção como `FATAL`. Isso impede perder o caminho
MMIO enquanto o dispositivo ainda pode possuir endereços da fila.

#### Avaliação e limitação residual

A correção mitiga o risco de um dispositivo potencialmente ativo ficar sem acesso MMIO e
impede que DMA em uso retorne ao alocador. Ela **não** implementa recuperação: se o reset não
for confirmado, o dispositivo permanece em quarentena, sem novas operações, e a janela MMIO
mais as páginas DMA ficam retidas até reinicialização. O kernel ainda não revoga explicitamente
o bit *Bus Master* do registrador `Command` PCI. Para merge, a CI deve passar no SHA exato que
contém a correção; CI de SHA anterior não é evidência desse estado. Nenhuma alegação de
recuperação online ou de contenção em hardware físico é feita.

#### Diretriz para resolução futura

Um incremento futuro pode implementar recuperação controlada (por exemplo, repetir reset e/ou
revogar explicitamente *Bus Master*), preservando o estado de contenção até que o dispositivo
confirme que não acessa mais a memória.
---

### D-6 — Tamanho excessivo do ELF `Debug` devido a preenchimento e alinhamento

#### Mecanismo atual no código e na build

Na compilação padrão (`Debug`), o artefato `zig-out/bin/voryn-kernel` apresenta cerca de
**63 MB a 72 MB** em disco (por exemplo, 65,8 MB em build limpa na `main` após o PR C, onde
apenas ~21,2 MB correspondem a conteúdo carregável/estático e mais de 41 MB decorrem de vãos
de alinhamento entre segmentos `PT_LOAD` emitidos pelo ligador, somados a estruturas estáticas
volumosas e seções DWARF).

No PR C ([ADR-0020](../../adr/ADR-0020-split-virtqueue.md)), esse crescimento esgotou a
partição EFI FAT16 de 64 MiB (`StreamTooLong`), exigindo ampliar `vorynos.img` para **128 MiB**
em `tools/fatimg.zig` como medida de contorno.

#### Impacto

- Maior tempo de cópia/leitura da imagem do kernel pelo bootloader UEFI (`VNB`) durante o
  boot e nos testes em QEMU.
- Consumo desnecessário de espaço na imagem `vorynos.img` (128 MiB) causado majoritariamente
  por preenchimento (*padding*) de arquivo entre segmentos, e não por código executável real.
- Risco de atingir novamente o teto do volume FAT16 conforme novos módulos de kernel forem
  adicionados se o layout ELF e as reservas estáticas em arquivo não forem revistos.

#### Diretriz para resolução futura

Investigar e ajustar em PR dedicado o alinhamento de páginas/segmentos do ligador para o
alvo `x86_64-freestanding` e a separação entre seções `.bss` (`p_filesz = 0`, `p_memsz > 0`)
e dados inicializados que hoje ocupam espaço físico no arquivo ELF, sem sacrificar símbolos
de depuração nem invalidar baselines de desempenho sem nova medição.

---

### D-7 — Coexistência das implementações moderna e legada de `virtqueue`

#### Mecanismo atual no código

Existem atualmente duas implementações distintas de fila dividida (*split virtqueue*) no
repositório:

1. **Implementação moderna nativa (`kernel/drivers/vvdi/virtqueue.zig`):** segue VirtIO 1.2
   com `VIRTIO_F_VERSION_1` (alinhamentos 16 / 2 / 4), *free list* O(1) sobre `next`, dois
   bitsets por descritor (livre, alocado, em voo), rastreamento de elos encadeados
   (`DescriptorNotChainHead`) e barreiras explícitas (`release` + `mfence` e `acquire`),
   coberta por `vvdi-tests`.
2. **Implementação legada (`kernel/arch/x86_64/virtio.zig`):** define `DeviceQueue` e
   `splitQueueLayout` com alinhamento legado de 4096 bytes para o anel `used`, utilizada
   apenas pela sonda de inicialização `probeVirtqueueLayout()` (`[VNK] virtio: split queue
   layout ok`), pelos testes em `arch-tests` e pelo stub incompleto `virtio_net.zig`. Os
   pontos de entrada provisórios em `kernel/arch/x86_64/virtio_blk.zig` continuam retornando
   `error.NotImplemented`.

#### Impacto

- Duplicação conceitual de estruturas de descritor e anéis (`available`/`used`) em dois
  diretórios distintos (`kernel/drivers/vvdi/` e `kernel/arch/x86_64/`).
- Risco de novos módulos importarem acidentalmente `arch/x86_64/virtio.zig` em vez de
  `drivers/vvdi/virtqueue.zig` enquanto o código legado permanecer na árvore.

#### Diretriz para resolução futura

Manter `kernel/arch/x86_64/virtio*.zig` congelado até que o driver de bloco real sobre VVDI
esteja implementado e validado; em seguida, migrar ou aposentar os consumidores restantes da
fila legada em PR próprio de limpeza, atualizando explicitamente a sonda de boot e
`arch-tests`.
