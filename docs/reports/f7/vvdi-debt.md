# Registro de Dívida Técnica — Subsistema VVDI

- **Data:** 2026-10-27 (atualizado em 2026-10-28)
- **Subsistema:** `kernel/drivers/vvdi/` e orquestração de boot em `kernel/main.zig`
- **ADRs relacionados:** [`ADR-0021 — Identidade nativa VVDI`](../../adr/ADR-0021-vvdi-virtual-device-interface.md) e [`ADR-0022 — Contenção PCI/DMA`](../../adr/ADR-0022-pci-dma-containment.md)
- **Escopo deste documento:** catalogar com precisão técnica os riscos e dívidas arquiteturais remanescentes após PR A, PR B, PR C, PR VVDI, a auditoria do PR D e a contenção PCI/DMA. A-3 foi **parcialmente resolvida** em 2026-10-28 (ver ADR-0022 e [vvdi-containment.md](vvdi-containment.md)); a recuperação online e a prova de quiescência continuam fora de escopo. Em 2026-10-28 os caminhos de falha de A-3 passaram a ser exercitados no host por injeção de falhas ([vvdi-fault-injection.md](vvdi-fault-injection.md)); QEMU e hardware físico continuam sem cobertura. D-6 e D-7 permanecem abertas.

---

## Sumário das dívidas registradas

| ID | Título | Localização principal | Severidade / Natureza | Estado |
| --- | --- | --- | --- | --- |
| **A-3** | Contenção após falha de reset durante configuração da virtqueue | `kernel/main.zig` (`bringUpVirtioFunction`, `programVirtqueue`, `abandonVirtqueue`), `kernel/drivers/vvdi/containment.zig`, `kernel/arch/x86_64/pci.zig` | Risco operacional; memória e BAR retidos sem recuperação online | **Parcialmente resolvida (2026-10-28):** revogação de *bus master* com leitura de volta, estado de contenção consultável e diagnóstico no caminho pós-`DRIVER_OK`. Recuperação online e prova de quiescência continuam ausentes; sem validação em hardware físico |
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
mais as páginas DMA ficam retidas até reinicialização. Para merge, a CI deve passar no SHA exato
que contém a correção; CI de SHA anterior não é evidência desse estado. Nenhuma alegação de
recuperação online ou de contenção em hardware físico é feita.

**Atualização de 2026-10-28 (ADR-0022).** A revogação explícita do bit *Bus Master* foi
implementada, junto com um estado de contenção por dispositivo
(`kernel/drivers/vvdi/containment.zig`). O que isso resolve e o que **não** resolve:

- resolvido: o kernel passa a desligar o bit 2 do `Command` (preservando `Memory Space` e
  os demais bits) quando um dispositivo entra em quarentena, e registra em log o motivo, o
  estado e o resultado da revogação; a falha de configuração **depois** de `DRIVER_OK`, que
  antes retornava sem diagnóstico nem estado, agora contém o dispositivo e mantém a
  propriedade dos recursos retidos explícita;
- não resolvido: revogar *Bus Master* não prova que transações DMA já emitidas terminaram.
  Não existe operação PCI/PCIe de drenagem, e o reset confirmado do VirtIO é a condição
  *disponível* para devolver memória, não uma garantia portável de quiescência. O estado
  `contained_unrevoked` existe justamente porque a revogação pode falhar;
- não resolvido: continua não havendo recuperação online, repetição de reset ou restauração
  do *bus master*. Um dispositivo contido permanece contido até a reinicialização.

**Atualização de 2026-10-28 (PR #19, injeção de falhas).** Os caminhos de falha
descritos acima passaram a ser **executados** no host, e não apenas revisados:
`kernel/drivers/vvdi/fault_injection.zig` coloca um dispositivo VirtIO Block
simulado atrás do transporte PCI de produção e injeta timeout com conclusão
tardia, notificação recusada, conclusões inválidas, erro de dispositivo, fila
esgotada, reset não confirmado e falhas de configuração depois de `DRIVER_OK`.
O que isso muda neste registro:

- **verificado**: nenhuma falha devolve descritor à free list; a cadeia
  publicada permanece alocada; `QueueMemory.canReturnToAllocator()` e
  `Containment.permitsMemoryRelease()` nunca ficam verdadeiros juntos sem reset
  confirmado; os 4 KiB de DMA ficam byte a byte idênticos depois de novas
  tentativas com o driver em quarentena; uma revogação não confirmada continua
  produzindo `contained_unrevoked` sem retry;
- **não verificado**: nada disso em QEMU/OVMF nem em hardware físico, e a função
  `virtqueueMemoryMayBeReturned()` de `main.zig` continua sem teste host-side —
  o que se verifica são os dois fatos que ela combina com `and`;
- **inalterado**: não há recuperação online, repetição de reset nem restauração
  do *bus master*; a revogação continua não sendo prova de quiescência.

Ver [vvdi-fault-injection.md](vvdi-fault-injection.md).

#### Diretriz para resolução futura

Um incremento futuro pode implementar recuperação controlada (por exemplo, repetir reset),
preservando o estado de contenção até que o dispositivo confirme que não acessa mais a
memória. A revogação de *Bus Master* já foi feita; o que falta é o caminho de volta:
reconstruir a fila, restaurar o *bus master* e só então rearmar o dispositivo. Qualquer
incremento desse tipo precisa lidar com a fila que ficou com descritores em voo — hoje o
`Queue` de uma instância contida não é reconstruído nem reutilizado.
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
