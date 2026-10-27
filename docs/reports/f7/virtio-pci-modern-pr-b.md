# F7 — PR B: transporte VirtIO PCI moderno funcional

- **Branch:** `arena/9207f83d-vorynos` (a branch do PR #11 foi encerrada pelo merge; este incremento não a reutiliza)
- **Base:** `main` em `f5f73eb` (merge do PR #11)
- **PR:** #12 — **sem merge** até autorização explícita
- **Especificação:** VirtIO 1.x (`oasis-tcs/virtio-spec`, `master`), seções 2.4 (device
  status), 3.1.1 (inicialização), 4.1.2 (descoberta PCI), 4.1.4.3 (configuração comum),
  4.1.4.4 (notificação) e 4.1.5 (validação de BAR)
- **Continuação de:** [`virtio-pci-modern-pr-a.md`](virtio-pci-modern-pr-a.md)
  (fundação: `types`, `status`, `features`, `caps`) e
  [`ADR-0018`](../../adr/ADR-0018-virtio-pci-modern-subsystem.md)
- **ADR deste incremento:** [`ADR-0019`](../../adr/ADR-0019-virtio-pci-modern-transport.md)

## Objetivo

Levar o subsistema do PR A até o último estado seguro antes das virtqueues:

```text
PCI -> descoberta do virtio-blk moderno -> capabilities validadas
    -> BAR mapeado sem cache -> configuração comum lida de verdade
    -> features negociadas -> FEATURES_OK confirmado
    -> "awaiting virtqueue setup"
```

O incremento termina **em** `FEATURES_OK`. `DRIVER_OK` não existe no código: não há
função que o escreva, e o teste de host prova pelo histórico de escritas do dispositivo
simulado que nenhuma escrita toca o bit 2 do status.

## Arquitetura

Três camadas, com a dependência apontando para dentro:

```text
kernel/main.zig                    orquestra o boot; fala com pci.zig e com paging.zig
   |
   +-- drivers/virtio/pci_transport.zig   layout 4.1.4.3 sobre `mmio.Region`
   |        |
   |        +-- drivers/virtio/mmio.zig   validação + acesso volátil + janela virtual
   |        +-- drivers/virtio/caps.zig   capabilities já validadas (PR A)
   |
   +-- drivers/virtio/transport.zig       sequência da 3.1.1 contra `Registers`
            |
            +-- drivers/virtio/status.zig  máquina de estados (PR A)
            +-- drivers/virtio/features.zig negociação de 64 bits (PR A)
```

`transport.zig` não conhece PCI nem MMIO: ele só sabe o que os registradores fazem.
`pci_transport.zig` não conhece portas de I/O: ele recebe uma `mmio.Region` já mapeada.
`mmio.zig` não conhece páginas de verdade: ele recebe um `Mapper`. Essa cadeia de
injeção é o que mantém os 36 testes novos rodando no host.

## Arquivos

### Criados

| Arquivo | Responsabilidade |
| --- | --- |
| `kernel/drivers/virtio/mmio.zig` | `Region` validada (limites, alinhamento, transbordo, permissão, estado do mapeamento), `Window` que reserva a faixa virtual e chama o `Mapper`, `Bus` com acesso volátil e barreira `mfence`. 12 testes. |
| `kernel/drivers/virtio/transport.zig` | Sequência `reset → ACKNOWLEDGE → DRIVER → features → FEATURES_OK`, contrato `Registers`, `Outcome` com etapa e erro. 13 testes. |
| `kernel/drivers/virtio/pci_transport.zig` | Layout completo da configuração comum (4.1.4.3), `attach` que transforma capabilities em `Region`, endereço de notificação (4.1.4.4), leitura da configuração do dispositivo e dos endereços de fila. 11 testes. |

### Modificados

| Arquivo | Mudança |
| --- | --- |
| `kernel/arch/x86_64/pci.zig` | `writeConfigDword` público, `probeBarSizes` (máscara do BAR sob o lock de configuração, com restauração do valor e tratamento de BAR de 64 bits) e `BarSizes`. |
| `kernel/main.zig` | Janela de MMIO reservada em `buildPageTables`; `identifyVirtioDevices` (somente leitura) substituída por `bringUpVirtioDevices`, que mapeia o BAR e negocia até `FEATURES_OK`. |
| `kernel/drivers/virtio/root.zig` | Exporta `mmio`, `transport` e `pci_transport` e os inclui no bloco de teste. |
| `build.zig` | Comentário do alvo `virtio-modern-tests` atualizado (o alvo já existia e roda em `zig build test`). |
| `tests/integration/boot-qemu.sh` | Dispositivo `virtio-blk-pci` explícito com `disable-legacy=on`; marcadores do PR B; falha explícita se o status chegar a `0x0f`. |

## MMIO próprio, sem segundo gerenciador de paginação

`mmio.zig` separa três coisas que normalmente aparecem misturadas:

- **`Region`** — uma faixa já mapeada: endereço virtual, endereço físico, comprimento
  *declarado*, permissões, estado de mapeamento e quantas páginas pertencem a ela.
- **`Window`** — a faixa virtual onde os BARs são mapeados. Guarda um mapa de bits de
  4096 páginas (16 MiB) e chama o `Mapper` injetado página a página.
- **`Bus`** — o acesso cru. No kernel é `volatile_bus`; nos testes é uma memória
  simulada ou, quando a faixa vem da janela, o próprio bloco estático alinhado.

A validação fica em `Region.address` e a ordem das verificações é deliberada:

1. `NotMapped` antes de qualquer comparação — depois de `unmap`, a faixa não pode ser
   usada nem para calcular limites;
2. `EmptyRegion` para comprimento zero;
3. `OutOfRange` para deslocamento que já começa fora da faixa (antes da aritmética:
   reportar como transbordo esconderia o erro real);
4. `Overflow` para `offset + largura`;
5. `OutOfRange` para acesso que termina depois do comprimento declarado;
6. `Misaligned` para deslocamento não múltiplo da largura;
7. `Overflow` para `virtual + offset`.

O mapeamento **não** é reimplementado: `main.zig` liga o `Mapper` a
`paging.mapDevicePage` (que já aplica `writable | cache_disabled | no_execute`) e
`paging.unmapKernelPage`. A janela de 16 MiB em `0x6000_0000` é reservada em
`buildPageTables`, pelo mesmo motivo da janela de DMA: os espaços de processo copiam a
tabela de nível 2, e uma tabela criada depois não apareceria nos espaços que já existem.

O acesso é `volatile` e cercado por `mfence`. A instrução está escrita como
`asm volatile ("mfence" ::: .{ .memory = true })`: em Zig 0.17.0 **não existe** `@fence`
nem `std.atomic.fence`, e as barreiras `sfence`/`lfence` ordenam apenas um sentido.

## Configuração comum (4.1.4.3)

Nenhuma `struct` Zig é sobreposta ao MMIO. Cada registrador é lido e escrito com a
largura e o offset da especificação, e a validação de faixa de cada acesso é a mesma
dos testes:

| Offset | Campo | Largura |
| --- | --- | --- |
| `0x00` | `device_feature_select` | 32 |
| `0x04` | `device_feature` | 32 |
| `0x08` | `driver_feature_select` | 32 |
| `0x0C` | `driver_feature` | 32 |
| `0x10` | `config_msix_vector` | 16 |
| `0x12` | `num_queues` | 16 |
| `0x14` | `device_status` | 8 |
| `0x15` | `config_generation` | 8 |
| `0x16` | `queue_select` | 16 |
| `0x18` | `queue_size` | 16 |
| `0x1A` | `queue_msix_vector` | 16 |
| `0x1C` | `queue_enable` | 16 |
| `0x1E` | `queue_notify_off` | 16 |
| `0x20` | `queue_desc` | 64 |
| `0x28` | `queue_driver` | 64 |
| `0x30` | `queue_device` | 64 |

`queue_device + 8 = 56` é exatamente `caps.common_config_min_length`, o mínimo que o
PR A exige da capability `common`.

O transporte expõe leitura de `queue_max_size` e `queue_notify_off` (via `transport.Device`)
e leitura dos três endereços da fila (via `Transport.queueAddresses`). **Nenhuma fila é
programada**: `queue_desc`, `queue_driver` e `queue_device` só são lidos. Programá-los
exige as três áreas alocadas e pertence ao incremento das virtqueues.

## Notificação (4.1.4.4)

`notifyAddress(queue_notify_off)` calcula `notify.virtual + off * multiplier` com
`std.math.mul`/`add` verificados e recusa a fila cujo endereço, mais os 2 bytes da
notificação, passa do comprimento da região. O multiplicador zero é aceito pela
especificação e faz todas as filas compartilharem o mesmo endereço; multiplicadores que
não sejam potência de dois pares já são recusados em `caps.zig`.

## Negociação real

`transport.Device.initialize` executa a sequência e devolve `Outcome` — união com
`initialized` ou `failed{stage, reason}`. Cada escrita de status é validada antes por
`status.transition` (contra o valor **lido** do dispositivo, não uma cópia local) e
confirmada depois por leitura; `Device.status` é sempre o último valor lido.

O conjunto que o VorynOS sabe conduzir continua sendo só `VIRTIO_F_VERSION_1`
(`features.supported`). Pedir `RING_PACKED`, `ACCESS_PLATFORM`, `EVENT_IDX` ou
descritores indiretos devolve erro nomeado, e não um dispositivo que responde de um
jeito que o driver não entende.

Falhas que a inicialização distingue, cada uma com a etapa em que ocorreu:

| Situação | Etapa | Erro |
| --- | --- | --- |
| dispositivo não zera o status no reset | `reset` | `DeviceDidNotReset` |
| escrita de ACKNOWLEDGE não aparece na leitura | `acknowledge` | `StatusNotConfirmed` |
| não oferece o bit 32 | `read_features` | `Version1NotOffered` |
| o driver não aceitaria o bit 32 | `read_features` | `Version1NotNegotiated` |
| pede feature que não implementa | `read_features` | `FeatureNotImplemented` |
| pede feature que o dispositivo não oferece | `read_features` | `FeatureNotOffered` |
| `driver_feature` não guarda o valor | `write_features` | `FeatureWriteNotConfirmed` |
| dispositivo recusa `FEATURES_OK` | `features_ok` | `StatusNotConfirmed` |
| leitura de registrador falha | etapa corrente | `RegisterAccess` |

## Descoberta e alvo

`bringUpVirtioDevices` percorre o barramento 0 (função 0, o mesmo escopo da sonda PCI
que já existia) e trata cada vendor `0x1AF4` explicitamente:

- identificador transicional → registrado e **ignorado** (este incremento não conduz o
  caminho legado);
- tipo diferente de `block` → registrado e ignorado;
- segundo virtio-blk → ignorado depois do primeiro;
- alvo: o primeiro `virtio-blk` com identificador moderno (`0x1042`).

O dispositivo de boot (o disco que o UEFI usou) não é tocado durante a descoberta: a
leitura de configuração não habilita o dispositivo, e o BAR só é mascarado quando o
alvo já foi escolhido. O reset de status acontece depois do handoff do firmware, quando
o UEFI já não usa mais o disco.

## BAR: tamanho, validação e mapeamento

`pci.probeBarSizes` executa o procedimento da especificação PCI: escreve
`0xFFFF_FFFF` no registrador do BAR sob o lock de configuração, lê a máscara de volta,
restaura o valor original e calcula `~mask + 1`. BAR de 64 bits mascara as duas
metades e consome dois índices; BAR ausente (`0` ou `0xFFFF_FFFF`) fica `null`.

O corpo da sonda é `probeBarSizesWith`, que recebe um `ConfigAccess` (leitura e
escrita de DWORD). No kernel ele é ligado às portas `0xCF8`/`0xCFC` sob o lock; no
teste, a uma imagem de configuração que devolve a máscara quando recebe todos os bits
em 1. É o mesmo código nos dois lugares, e o teste confere tamanho, par de 64 bits,
BAR ausente, restauração do valor e o número exato de escritas.

Antes de mapear, cada capability é validada contra o BAR real por
`pci.barSupportsRegion`: tipo (memória, não I/O), alinhamento do BAR ao próprio
tamanho, tamanho potência de dois, `offset + length` dentro do BAR e ausência de
transbordo. Um BAR de I/O, de tamanho desconhecido ou sem endereço atribuído é
recusado com mensagem própria.

O BAR é mapeado inteiro com `Permissions.read_write` (o driver escreve
`device_status` e `driver_feature`). As capabilities viram **visões** da faixa
mapeada; `attach` recusa região que não caiba no BAR e exige que as quatro regiões
estejam no mesmo BAR (limite deste incremento, registrado no ADR).

## Integração no boot

Em `kernel/main.zig`:

```text
installMemoryManager()      -> memória física
buildPageTables()           -> tabelas + janela de DMA + janela de MMIO (16 MiB)
activatePageTables()        -> tabelas ativas
installDma() / probeDmaWindow()
bringUpVirtioDevices()      -> PCI -> capabilities -> MMIO -> negociação
probePciBus()               -> sonda legada, sem mudança
```

Nada é lido por MMIO antes de as tabelas estarem ativas. Nenhum buffer de DMA é
alocado, porque nenhuma fila é programada.

## Diagnósticos

Cada linha só é impressa depois da operação correspondente:

```text
[VNK] virtio-pci: modern device detected 00:N.0 id=0x1042 type=block
[VNK] virtio-pci: 00:N.0 capabilities validated bar=B common=+0xA/L notify=+0xB/L multiplier=M
[VNK] virtio-pci: MMIO mapped 00:N.0 barB phys=0xP size=0xS virt=0xV common=0xC notify=0xD
[VNK] virtio-pci: 00:N.0 VERSION_1 negotiated features=0xF offered=0xO
[VNK] virtio-pci: 00:N.0 FEATURES_OK accepted status=0xb
[VNK] virtio-pci: 00:N.0 awaiting virtqueue setup queues=Q status=0xb; DRIVER_OK not written
```

Em falha, a linha diz a etapa, o erro tipado, o dispositivo e o recurso:

```text
[VNK] virtio-pci: 00:N.0 initialization failed at features_ok: StatusNotConfirmed (barB size=0xS)
[VNK] virtio-pci: 00:N.0 capabilities rejected: MissingNotifyConfiguration
[VNK] virtio-pci: 00:N.0 barB size could not be measured
```

Endereços impressos são de hardware (BAR físico e faixa virtual da janela, ambos
constantes de configuração do kernel); nenhum endereço de pilha, de heap ou de
processo é registrado.

## Testes

`zig build test` — 499 testes em 20 binários, todos passando:

| Binário | Antes | Agora |
| --- | --- | --- |
| `arch-tests` | 76 | **77** |
| `virtio-modern-tests` | 29 | **65** |
| total | 462 | **499** |

Os 37 testes novos: 12 em `mmio.zig`, 13 em `transport.zig`, 11 em `pci_transport.zig`
e 1 em `arch-tests` (a sonda de tamanho de BAR, exercitada sobre uma imagem de
configuração em memória).

### MMIO (12)

- larguras 8/16/32/64 e o tamanho de cada uma;
- janela: mapeamento, páginas reservadas, segunda faixa depois da primeira, `unmap`
  devolvendo as páginas, comprimento arredondado para páginas;
- recusa de faixa vazia, desalinhada ao tamanho da página e maior que a janela;
- rollback quando o mapeador recusa a segunda página;
- esgotamento do mapa estático;
- offsets válidos em todas as larguras, fim exato da faixa, fora dos limites,
  desalinhamento, transbordo de `offset + largura` e de `virtual + offset`;
- comprimento zero; leitura/escrita em todas as larguras com conferência de *little
  endian*; escrita de 32 bits que não alcança o vizinho;
- faixa somente-leitura recusando escrita e continuando legível; faixa desmapeada
  respondendo `NotMapped` (e não `NotWritable`);
- `view` validada contra a faixa de origem e compartilhando o mesmo barramento;
- todos os acessos recusados depois de `unmap`, e `unmap` duas vezes não devolvendo
  páginas duas vezes.

### Transporte (13)

Sequência completa com status final `0x0b` e histórico de escritas
`0, 0x01, 0x03, 0x0b`; ausência de `DRIVER_OK` provada pelo histórico; `VERSION_1`
ausente e não aceito; feature não implementada; feature não oferecida; `FEATURES_OK`
recusado pelo dispositivo; `driver_feature` não confirmado na leitura; reset que não
zera o status; status que fica atrás da escrita; status lido como fonte de verdade
(`DEVICE_NEEDS_RESET`); recusa de apagar bit; consulta de filas sem programá-las;
falha de registrador com etapa.

### Transporte PCI (11)

Offsets da 4.1.4.3 campo a campo; `attach` criando uma região por capability;
`attach` recusando regiões em BARs diferentes; acesso a registrador fora da faixa;
leitura/escrita de features pela janela de seleção; status, `num_queues`,
`queue_size` e `queue_notify_off` no BAR simulado; `notifyAddress` com multiplicador;
leitura da configuração do dispositivo dentro da região; capability obrigatória
ausente; negociação completa sobre o BAR (65º teste: `device_words` reais →
`features=0x1_0000_0004` → status `0x0b` → `queueMaxSize(0) = 256`); endereços de fila
lidos da fila selecionada.

Nenhum teste simula sucesso: o `Fake` só confirma o que foi escrito, e os testes de
falha existem para cada caminho do código.

## QEMU

`tests/integration/boot-qemu.sh` passou a criar o dispositivo explicitamente:

```text
-drive file=disk.img,format=raw,if=none,id=virtio-disk0
-device virtio-blk-pci,drive=virtio-disk0,disable-legacy=on
```

`disable-legacy=on` remove o caminho legado da função e deixa só o moderno, que é o
transporte exercitado. O teste exige:

- detecção: `modern device detected ... id=0x1042 type=block`;
- capabilities validadas com BAR, offsets e multiplicador;
- BAR mapeado com tamanho e endereço virtual;
- `VERSION_1 negotiated ... offered=...` (as features oferecidas foram lidas) e
  `FEATURES_OK accepted`;
- `awaiting virtqueue setup ... status=0xb; DRIVER_OK not written`;
- **falha** se alguma linha de `virtio-pci` trouxer `status=0xf` (DRIVER_OK antes das
  filas).

Nenhum setor é lido ou escrito: o teste não envia pedido de bloco.

## Validação local

```text
zig build test     -> 499 testes, 20 binários, todos passando
zig build          -> vorynos.img de 64 MiB
zig fmt --check    -> arquivos deste incremento formatados
git diff --check   -> sem espaço em branco pendente
```

QEMU e OVMF não existem no ambiente da sessão. `zig build qemu-test` e `zig build check`
rodam na CI, e os resultados são registrados na revisão do PR #12.

## Limitações conhecidas

1. **Uma função por varredura.** O escopo é o mesmo da sonda PCI: barramento 0, função
   0. Um dispositivo multifunção tem as funções adicionais ignoradas.
2. **Um BAR por dispositivo.** As quatro regiões precisam estar no mesmo BAR. É o
   layout do QEMU e o mais comum; um dispositivo que separe `common` e `notify` em
   BARs diferentes é recusado com `RegionsInDifferentBars`, não tratado pela metade.
3. **Sem IOMMU.** `VIRTIO_F_ACCESS_PLATFORM` é recusado com `AccessPlatformUnsupported`.
   Os endereços de fila serão físicos, e só farão sentido depois das virtqueues.
4. **BAR de I/O é recusado.** O transporte moderno exige memória mapeável; um BAR de
   portas não é mapeado e o dispositivo é registrado como não suportado.
5. **Sem MSI-X.** A configuração interrompe em `FEATURES_OK`; `config_msix_vector` e
   `queue_msix_vector` fazem parte do layout e não são escritos.
6. **Sem fila e sem DRIVER_OK.** Estado final: `awaiting virtqueue setup`. Não há
   split/packed queue, descritor, notificação efetiva, I/O de bloco nem driver Virtio
   Block.
7. **Confirmação de reset sem espera.** O reset é confirmado por uma leitura
   imediata do status. Um dispositivo que demore mais do que isso é reportado como
   `DeviceDidNotReset`; não há laço de espera com timeout neste incremento, porque a
   única fonte de tempo confiável do kernel hoje é o timer, que não existe no host e
   tornaria o módulo intestável. No QEMU o reset é síncrono.
8. **As visões herdam `read_write`.** `Region.view` mantém as permissões da faixa de
   origem, então o ISR (que é somente leitura pela especificação) pode ser escrito pela
   API. Nada o escreve hoje; restringir por capability entra quando houver consumo de
   interrupção.
9. **`virtio.zig` legado intocado.** A divergência de `BlockFeatures` continua
   registrada no relatório do PR A.

## Próximo incremento (PR C)

- alocar as três áreas da fila em memória física contígua (a janela de DMA já existe);
- programar `queue_size`, `queue_desc`, `queue_driver` e `queue_device` e confirmar por
  leitura;
- escrever `DRIVER_OK` **somente** depois disso, e só então enviar o primeiro pedido.
