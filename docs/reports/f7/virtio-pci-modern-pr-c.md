# F7 — PR C: split virtqueue nativa e ativação do virtio-blk moderno

- **Branch:** `arena/eb8e8a07-vorynos` (sessão nova; a branch do PR #12 ficou em `pr_merged` e não foi reutilizada)
- **Base:** `main` em `0aed542` (merge do PR #12)
- **PR:** #13 — **sem merge** até autorização explícita
- **Especificação:** VirtIO 1.2 — 2.7.3 (barreiras), 2.7.4 a 2.7.9 (descritores e anéis),
  2.7.13 (publicação e consumo), 3.1.1 (sequência de inicialização) e 4.1.4.3.2
  (programação da fila no transporte PCI)
- **Continuação de:** [`virtio-pci-modern-pr-b.md`](virtio-pci-modern-pr-b.md)
- **ADR deste incremento:** [`ADR-0020`](../../adr/ADR-0020-split-virtqueue.md)

## Objetivo

Levar o subsistema do último estado seguro do PR B até o dispositivo **ativo**:

```text
FEATURES_OK -> fila 0 em memoria DMA -> layout validado -> queue_size
            -> queue_desc/queue_driver/queue_device -> queue_enable confirmado
            -> DRIVER_OK (status 0x0f)
```

O incremento termina com a fila pronta e **vazia**: nenhum pedido é publicado, nenhuma
conclusão é consumida e nenhum setor é lido ou escrito.

## Arquitetura

```text
kernel/main.zig                       orquestra o boot; fala com pci.zig, paging.zig e dma.zig
   |
   +-- drivers/virtio/pci_transport.zig    layout 4.1.4.3 + configureQueue/enableQueue
   |        |
   |        +-- drivers/virtio/mmio.zig    faixa validada, acesso volatil, mfence
   |
   +-- drivers/virtio/transport.zig        sequencia 3.1.1 + DRIVER_OK com fechadura
   |
   +-- drivers/virtio/virtqueue.zig        tabela de descritores + aneis available/used
```

As dependências continuam apontando para dentro: `virtqueue.zig` recebe memória
(`Memory{physical, bytes}`), `transport.zig` recebe registradores (`Registers`) e
`mmio.zig` recebe um mapeador (`Mapper`). Nenhum deles conhece `paging.zig`, `dma.zig` ou
`pci.zig`, e é isso que mantém os testes no host.

## Arquivos

### Criados

| Arquivo | Responsabilidade |
| --- | --- |
| `kernel/drivers/virtio/virtqueue.zig` | Layout de 2.7.4–2.7.8 (descritores 16 B alinhados a 16, `available` a 2, `used` a 4), free list O(1) no campo `next`, dois bitsets por descritor (livre/alocado/publicado), publicação com `release` em `avail.idx` + `mfence`, consumo com `acquire` em `used.idx`, flags de interrupção. 19 testes. |
| `docs/adr/ADR-0020-split-virtqueue.md` | Decisões, alternativas descartadas e limites. |
| `docs/reports/f7/virtio-pci-modern-pr-c.md` | Este relatório. |

### Modificados

| Arquivo | Mudança |
| --- | --- |
| `kernel/drivers/virtio/pci_transport.zig` | `configureQueue` (índice contra `num_queues`, tamanho contra o máximo lido, alinhamento 16/2/4, três endereços de 64 bits em dois DWORDs, relê `queue_size`), `enableQueue` (escreve e **confirma** `queue_enable`), `queueEnabled`. Erros `QueueSizeTooLarge` e `QueueEnableNotConfirmed`. 4 testes. |
| `kernel/drivers/virtio/transport.zig` | `ready_queues`, `markQueueReady`, `activate` (recusa `NoQueueConfigured` e `NotReadyForDriverOk`), `finish` com a etapa `driver_ok`. O caminho para `DRIVER_OK` deixou de não existir: passou a existir com fechadura. 3 testes. |
| `kernel/drivers/virtio/root.zig` | Importa `virtqueue` e atualiza o doc do subsistema (o que existe e o que não existe). |
| `kernel/main.zig` | `programVirtqueue`: tamanho negociado → layout → DMA → `Queue.init` → programação → habilitação confirmada → `DRIVER_OK`, com diagnóstico por etapa e devolução da memória só antes de `queue_enable`. |
| `build.zig` | Comentário do bloco de testes do VirtIO moderno (PR C incluído). |
| `tools/fatimg.zig` | Imagem de 64 MiB → 128 MiB; limite de leitura dos arquivos embarcados acompanha o tamanho da imagem. Ver "Infraestrutura de build". |
| `tests/integration/boot-qemu.sh` | Exige as três linhas da fila e do `DRIVER_OK`, na ordem correta; a regra antiga ("qualquer `status=0xf` reprova") foi substituída por "`status=0xf` só na linha do `DRIVER_OK`, depois da fila habilitada". |
| `docs/roadmap/phase-status.md` | Estado da F7. |

## Testes

`virtio-modern-tests` (raiz `kernel/drivers/virtio/root.zig`): **65 → 105** testes
(91 na abertura do PR, 105 depois das correções da auditoria).

`virtqueue` (25):

- layout de 256 descritores com os offsets da especificação (4096 / 4096+518 / 4616) e
  alinhamento de cada área; fila de 1 e de 32768 descritores;
- recusa de tamanho zero, não potência de dois e acima de 32768;
- negociação de tamanho (3 → 2, 255 → 128, 65535 → 32768);
- endereços físicos das três áreas a partir da base, com base desalinhada e nula;
- `init` zera anéis, monta a free list e recusa memória curta, física/virtual desalinhada,
  fila acima da capacidade do tipo;
- alocação e liberação O(1), reuso da cabeça, esgotamento em `QueueFull`;
- cadeia de três descritores com `NEXT`, buffers físicos, flag `write`;
- publicação única, recusa de publicação dupla, de mutação em voo e de liberação em voo;
- consumo de conclusão e devolução da cadeia inteira à free list;
- 40 iterações em fila de 2 descritores provando a volta do índice de 16 bits contra a
  máscara do anel;
- `avail.flags` de não-interrupção e `used.flags` de não-notificação;
- recusa de `id` não publicado, `id` fora da tabela e `used.idx` além do anel;
- cadeia com ciclo recusada na publicação e **recuperada** na liberação sem duplicar elos;
- alocação de cadeia que falha pela metade devolve o que tomou.

Testes de regressão de D-1 (6 novos):

- os três elos de uma cadeia publicada ficam em voo, e não só a cabeça;
- elo do meio em voo recusa `setBuffer`, `setWritable` e `release`, sem mudar o estado;
- a conclusão devolve os três elos, e a mesma cadeia pode ser descrita e publicada de novo;
- elo do meio recusado depois da conclusão (`DescriptorNotChainHead`), sem tocar na cadeia
  seguinte nem no `freeCount`;
- conclusão duplicada recusada (`UsedIdNotInflight`) sem alterar a posse de nenhum elo;
- cadeia recusada por ciclo não deixa elo marcado como do dispositivo.

`pci_transport` (7 novos, 3 deles de D-3):

- programação de `queue_size` e dos três endereços de 64 bits (metade alta conferida);
- recusa de fila inexistente, tamanho zero, tamanho acima do máximo, endereços
  desalinhados — e o dispositivo não é tocado nas recusas;
- `queue_enable` confirmado e dispositivo que descarta a escrita recusado;
- região comum curta (`queue_desc` fora da faixa) recusada;
- fila que já se apresenta habilitada recusada **antes** da escrita (registrador em 2
  continua 2), e habilitação repetida recusada;
- cada operação (`configureQueue`, `enableQueue`, `queueEnabled`) seleciona a fila em que
  age, sem herdar a seleção da chamada anterior.

`transport` (8 novos, 5 deles de D-2 e D-4):

- `DRIVER_OK` recusado sem fila registrada (`NoQueueConfigured`, `finish` com etapa);
- `DRIVER_OK` escrito depois de `markQueueReady`, com o histórico de escritas do
  dispositivo simulado provando que o bit 2 aparece uma única vez e por último;
- `DRIVER_OK` recusado fora de `FEATURES_OK` e recusado quando o dispositivo não mantém a
  escrita (`StatusNotConfirmed`);
- filas prontas por índice: fila 1 não fica pronta por causa da 0 nem da 2, índice repetido
  é recusado, e o reset zera o conjunto;
- índice acima do limite do transporte recusado (`TooManyQueues`) em vez de ignorado;
- `QueueMemory`: memória do driver antes da entrega, presa depois dela, e liberada só com o
  reset confirmado — uma nova entrega rearma a proibição;
- dispositivo em `DRIVER_OK` que confirma o reset devolve a posse; dispositivo que ignora o
  reset (`ignore_reset`) mantém a memória reservada.

## Validação executada

| Comando | Resultado |
| --- | --- |
| `zig version` | `0.17.0` |
| `zig build test` | **passa** — 539 testes; `virtio-modern-tests` 105 (91 antes das correções), `arch-tests` 77, `kernel-tests` 22, `fs-loader-tests` 158 |
| `zig build` | **passa** — `voryn-boot.efi`, `voryn-kernel` (65,8 MB nesta build) e `vorynos.img` (128 MiB, 32731 clusters, FAT16) |
| `zig build qemu-test` | **bloqueado pelo ambiente** — `qemu-boot-test: no OVMF firmware found`, saída 2; não há `qemu-system-x86_64` nem OVMF na sessão |
| `zig build check` | **bloqueado pelo ambiente** — depende do `qemu-test` |

### Evidência da CI (após a abertura do PR)

Run [`40478940990`](https://github.com/CeoMatheusDev/VorynOS/actions/runs/40478940990), job
`122104063600`, commit `f550190`, tentativa 1: **conclusão `success`** em 1min11s, com os
onze passos verdes, inclusive:

- *Testes de unidade* — `zig build test` (525 testes);
- *Construir* — `zig build` (imagem de 128 MiB);
- *Teste de boot no QEMU* — `zig build qemu-test` com OVMF. O passo só passa porque os
  três `require_pattern` da fila e do `DRIVER_OK` casaram, porque o `DRIVER_OK` está
  depois da linha `virtqueue 0 enabled` e porque nenhuma outra linha de `virtio-pci`
  trouxe `status=0xf`;
- *Verificação agregada* — `zig build check`;
- *Verificar os artefatos* — `file`/`readelf` do bootloader e do kernel.

Ou seja: o requisito 9 (boot no QEMU até `0x0f`) foi verificado na CI, não apenas no host.

O ambiente da sessão não traz Zig nem QEMU instalados. O toolchain 0.17.0 foi obtido do
pacote `ziglang` do PyPI (`zig version` → `0.17.0`); o QEMU e o OVMF não estão disponíveis
e não há rede para instalá-los (o `apt` não responde e o acesso é limitado a GitHub,
npm e PyPI). A validação de boot fica para a CI do PR, como aconteceu nos PR A e PR B.

### O que a CI deve mostrar

```text
[VNK] virtio-pci: 00:N.0 FEATURES_OK accepted status=0xb
[VNK] virtio-pci: 00:N.0 awaiting virtqueue setup queues=1 status=0xb
[VNK] virtio-pci: 00:N.0 virtqueue 0 dma phys=0x... virt=0x... size=256 bytes=6672 desc=0x... avail=0x... used=0x...
[VNK] virtio-pci: 00:N.0 virtqueue 0 enabled size=256 queues=1 free=256 avail=0 used=0
[VNK] virtio-pci: 00:N.0 DRIVER_OK status=0xf queues_ready=1 virtqueue=0
```

E o teste de boot reprova se qualquer uma faltar, se o `DRIVER_OK` vier antes da fila ou
se outra linha de `virtio-pci` trouxer `status=0xf`.

## Infraestrutura de build: imagem de 64 MiB para 128 MiB

O ELF do kernel em Debug mede **63,6 MB** na `main` e **72,0 MB** com este incremento —
19,7 MB de dados estáticos (`fs.fs.extra_ramfs_states`, pilhas, pools de paginação),
~5 MB de seções de depuração e os vãos que o ligador deixa entre os segmentos
carregáveis. A imagem FAT de 64 MiB estava a 1% do limite, e o primeiro módulo novo
derrubou `zig build` com `StreamTooLong`.

A imagem passou a 128 MiB, com o limite de leitura dos arquivos embarcados igual ao
tamanho do volume. O volume continua FAT16 (32731 clusters de 4 KiB) e legível pelo
firmware. Alternativas descartadas:

- **`strip` no kernel** — `zig objcopy --strip-debug` responde `unimplemented` em 0.17.0;
  `strip = true` no módulo removeria a informação de depuração do artefato instalado e
  economizaria 14 MB de 72 MB, sem resolver a causa;
- **compilar o kernel otimizado por padrão** — mudaria o artefato e o objeto de todos os
  perfis de desempenho já registrados.

Esta é a única mudança do PR fora do subsistema VirtIO, e ela é consequência direta do
tamanho do kernel que já existia.

Medição posterior, com cache limpo: o mesmo kernel Debug sai com **65,8 MB** (21,2 MB
carregáveis e 41,6 MB de vãos entre segmentos), contra 70,1 MB numa build incremental
anterior. A diferença de 4 MB não é código — é a folga que o ligador deixa entre os
segmentos carregáveis, que muda com o alinhamento de página. Isso confirma que o limite de
64 MiB era atingido por **enchimento**, e não por conteúdo: a dívida real é o layout do ELF,
não o tamanho da imagem.

## Correções da auditoria (D-1 a D-4)

A auditoria do PR encontrou quatro defeitos. As correções estão neste PR, com testes de
regressão que reproduzem cada um.

### D-1 — posse por descritor em cadeias publicadas (`virtqueue.zig`)

`publish` marcava `inflight` apenas na cabeça; os elos do meio ficavam parecendo livres e
`setBuffer`/`release` os aceitavam em voo. Reproduzido antes da correção: `setBuffer(1)`
sobrescrevia o endereço de um descritor já publicado e `release(1)` devolvia o resto da
cadeia à free list com o dispositivo ainda lendo, permitindo liberação cruzada entre
cadeias.

- `publish` marca **todos** os elos (`markChain`), e `pollUsed` desmarca **todos** — a
  conclusão devolve a cadeia inteira ao driver;
- `linked` registra quais descritores são `next` de outro, e `release` recusa elo do meio
  (`error.DescriptorNotChainHead`) mesmo depois da conclusão, o que fecha a liberação
  cruzada entre cadeias;
- um `publish` recusado (ciclo, `next` fora da tabela) não deixa nenhum elo marcado.

Reprodução da auditoria, refeita contra o código corrigido:

```text
posse depois de publish: [0]=true [1]=true [2]=true
setBuffer(1) recusado: DescriptorAlreadyPublished
release(1) recusado: DescriptorInFlight
free apos os ataques: 5 (esperado 5)
apos a conclusao: inflight(1)=false free=5
release(1) pos-conclusao recusado: DescriptorNotChainHead
free final: 5 (esperado 5)
```

A hipótese da auditoria de que `setBuffer` também descartava o `next` do elo **não se
confirmou**: a função escreve apenas `address` e `length`. O defeito era só a marca de
posse, e o teste novo fixa esse comportamento.

### D-4 — ciclo de vida da memória de DMA (`main.zig`, `transport.zig`)

`programmed` era marcado **depois** de `enableQueue` e da verificação seguinte: uma falha
em `queueEnabled` devolvia ao alocador páginas que o dispositivo já podia estar lendo, e
nenhum caminho de falha resetava o dispositivo.

- `transport.QueueMemory` guarda duas marcas independentes — `handed_over` (a memória foi
  entregue ao dispositivo) e `device_released` (o reset foi confirmado). Só
  `canReturnToAllocator` autoriza a liberação;
- `handOver()` é chamado imediatamente depois de `enableQueue` retornar sucesso, antes da
  leitura de volta;
- toda falha a partir de `configureQueue` passa por `abandonVirtqueue`: reset do
  dispositivo, leitura de volta em zero, e só então a liberação. Se o reset não for
  confirmado, **a memória fica reservada** e o boot registra `FATAL`.

### D-2 — filas prontas por índice (`transport.zig`)

`ready_queues` contava chamadas: `markQueueReady(0)` duas vezes anunciava duas filas
prontas num dispositivo de duas filas. O limite `contador >= filas` acertava o número pelo
motivo errado, e o teste existente consagrava a semântica.

- `ready: std.StaticBitSet(max_tracked_queues)`, com um bit por índice;
- índice repetido é recusado (`error.QueueAlreadyReady`) em vez de contar;
- índice acima do limite é recusado (`error.TooManyQueues`), e não ignorado;
- `readyQueues()` e `isQueueReady()` expõem o conjunto; o teste que esperava o segundo
  registro da fila 0 ser aceito foi reescrito para exigir a recusa.

### D-3 — `queue_enable` lido antes de ser escrito (`pci_transport.zig`)

A confirmação pós-escrita já existia; faltava a leitura prévia. Uma fila que já se
apresentasse habilitada era habilitada de novo às cegas.

- `enableQueue` lê `queue_enable` e recusa com `error.QueueAlreadyEnabled` se não for 0;
- o teste prova que nada foi escrito: um registrador em `2` continua `2` depois da recusa;
- o contrato de `queue_select` está documentado nas três funções que dependem dele, com
  teste de que cada operação seleciona a fila em que age.

## Limitações

- A fila está pronta e vazia: não há publicação de pedido, consumo de conclusão em uso nem
  notificação ao dispositivo.
- Sem MSI-X e sem interrupção do dispositivo; `pollUsed` é o caminho previsto.
- `VIRTIO_F_INDIRECT_DESC`, `VIRTIO_F_EVENT_IDX` e `VIRTIO_F_RING_PACKED` continuam fora da
  negociação; `setIndirect` recusa por construção.
- Capacidade da fila fixa em 256 descritores no kernel.
- O kernel continua sem driver de bloco: `virtio_blk.zig` segue devolvendo
  `error.NotImplemented`, e o backend de bloco verificado é o ramdisk.
- `kernel/arch/x86_64/virtio.zig` (o `DeviceQueue` legado, usado pela sonda
  `probeVirtqueueLayout` e pelos stubs de rede) não foi alterado. Ele será removido quando
  o driver de bloco migrar para `virtqueue.zig`; manter os dois por enquanto é
  deliberado, para não misturar a migração com a implementação.
- A validação de QEMU é feita pela CI; a sessão local não tem firmware OVMF.

## Próxima etapa

Driver de bloco sobre a fila: publicar pedidos de leitura e escrita com descritores de
requisição e de dados, consumir `used`, tratar a notificação (MSI-X ou polling com
orçamento) e conectar o dispositivo a `storage/block.zig`, com a geometria lida de
`readDeviceConfig`. Nenhum desses passos existe hoje.
