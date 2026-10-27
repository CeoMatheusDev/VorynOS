# Registro de Dívida Técnica — Subsistema VVDI

- **Data:** 2026-10-27
- **Subsistema:** `kernel/drivers/vvdi/` e orquestração de boot em `kernel/main.zig`
- **ADR relacionado:** [`ADR-0021 — Identidade nativa VVDI`](../../adr/ADR-0021-vvdi-virtual-device-interface.md)
- **Escopo deste documento:** catalogar com precisão técnica os riscos e dívidas arquiteturais
  remanescentes após a integração dos incrementos PR A, PR B, PR C e PR VVDI, **sem
  implementar suas correções no PR VVDI**.

---

## Sumário das dívidas registradas

| ID | Título | Localização principal | Severidade / Natureza | Estado |
| --- | --- | --- | --- | --- |
| **A-3** | BAR MMIO desmapeado após falha de reset com dispositivo potencialmente ativo | `kernel/main.zig` (`bringUpVirtioFunction`, `programVirtqueue`, `abandonVirtqueue`) | Risco operacional e de contenção de hardware | Aberto (registrado, não corrigido neste PR) |
| **D-6** | Tamanho excessivo do ELF `Debug` do kernel por preenchimento/alinhamento de segmentos | `voryn-kernel` (ligador / layout ELF), contorno em `tools/fatimg.zig` | Dívida de build, imagem e pegada de artefato | Aberto (registrado, não corrigido neste PR) |
| **D-7** | Coexistência das implementações moderna e legada de *split virtqueue* | `kernel/drivers/vvdi/virtqueue.zig` vs. `kernel/arch/x86_64/virtio.zig` | Duplicação estrutural transitória | Aberto (registrado, não corrigido neste PR) |

---

## Detalhamento técnico

### A-3 — Quando o reset falha, a memória DMA permanece reservada, mas o BAR é desmapeado enquanto o dispositivo pode permanecer habilitado

#### Mecanismo atual no código

Em `kernel/main.zig`, a posse da memória DMA da fila 0 é transferida antes da primeira escrita
de configuração no dispositivo (`virtqueue_state.ownership.handOver()`, antes de
`configureQueue`). Caso ocorra falha em `configureQueue`, `enableQueue`, `queueEnabled`,
`markQueueReady`, `target.finish()` ou na confirmação pós-`DRIVER_OK`, `programVirtqueue`
invoca `abandonVirtqueue(target, device)`:

1. `abandonVirtqueue` executa `target.resetDevice()` (escrita `0` em `device_status` seguida
   de leitura de confirmação em `0`).
2. Se `resetDevice()` **falhar** (por exemplo, `StatusNotConfirmed` ou falha de acesso),
   `deviceReleased()` **não** é chamado, `canReturnToAllocator()` permanece `false`, o kernel
   registra `FATAL` no log serial e `releaseVirtqueueMemory()` mantém as páginas físicas e o
   mapeamento virtual da fila **reservados**.
3. Em seguida, `programVirtqueue` retorna `false` para `bringUpVirtioFunction`.
4. Ao receber `false`, `bringUpVirtioFunction` executa imediatamente `window.unmap(&region)`,
   desfazendo o mapeamento virtual do BAR MMIO do dispositivo.

#### Avaliação de risco (não classificar como ausência de risco)

A-3 **não deve ser classificado como ausência de risco**:

- **O que está protegido:** a memória física de DMA da virtqueue **não** retorna ao alocador
  físico (`physical.manager`), evitando corrupção silenciosa de memória (*DMA use-after-free*)
  sobre páginas reatribuídas a outros subsistemas ou processos.
- **O risco real que permanece:** como `window.unmap(&region)` desmapeia o BAR enquanto o
  reset não foi confirmado, o dispositivo PCI pode continuar **habilitado e operacional** no
  barramento (com `queue_enable = 1`, endereços de anéis configurados ou mesmo `DRIVER_OK`
  parcialmente aceito), ao mesmo tempo em que o kernel **perde o acesso MMIO de controle**
  aos registradores do dispositivo. Nessa condição, o kernel fica sem caminho acessível para
  inspecionar `device_status`/`isr`, repetir o reset ou conter o dispositivo de forma
  controlada, além de não desabilitar *Bus Master* no registrador `Command` do espaço de
  configuração PCI.

#### Diretriz para resolução futura

Em incremento próprio (fora deste PR), acoplar o ciclo de vida do mapeamento MMIO (`region`)
ao estado de contenção do dispositivo — mantendo o BAR acessível quando o reset falhar e/ou
revogando explicitamente o bit *Bus Master* no espaço de configuração PCI antes de encerrar a
recuperação de erro.

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
