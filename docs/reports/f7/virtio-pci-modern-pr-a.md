# F7 — PR A: fundação do subsistema VirtIO PCI moderno

| Campo | Valor |
|-------|-------|
| **Data** | 2026-10-26 |
| **Base** | `298023eb41e19417aadbbb6793c59fdcc6c8a0d1` (`main`, merge do PR #10) |
| **Branch** | `arena/9207f83d-vorynos` |
| **Estado** | IMPLEMENTADO — TESTADO LOCALMENTE (host); boot QEMU entregue à CI |
| **Toolchain** | Zig 0.17.0 |
| **Escopo** | `kernel/arch/x86_64/pci.zig`, `kernel/drivers/virtio/*`, `kernel/main.zig`, `build.zig` |

## Objetivo

Preparar a infraestrutura genérica do subsistema VirtIO PCI moderno, sem
inicializar dispositivo algum: percurso seguro da lista de capabilities PCI,
validação de BARs, tipos e identificadores, estados de inicialização, features
de transporte e parsing das capabilities VirtIO.

Os quatro incrementos seguintes continuam fora deste PR: transporte PCI
(MMIO e configuração comum), virtqueues e DMA, driver VirtIO Block e
persistência física.

## O que foi implementado

### 1. `kernel/arch/x86_64/pci.zig` (ampliado, não substituído)

O mecanismo de acesso (portas `0xCF8`/`0xCFC`, `IrqSpinlock`, extração byte a
byte) foi **reaproveitado**. O que entrou é a camada pura de inspeção:

- `Reader`: interface de leitura de bytes do espaço de configuração, com
  `readByte`/`readWord`/`readDword` little-endian. `functionReader` liga a
  interface às portas reais; `ConfigImage` é um espaço de configuração
  simulado de 256 bytes usado nos testes. A mesma lógica de percurso roda nos
  dois casos.
- `CapabilityIterator`: percurso da lista de capabilities com validação de
  ponteiro (região `0x40..0xFF`, espaço para o cabeçalho, alinhamento em
  DWORD), de identificador (`0x00` e `0xFF` são reservados), de `cap_len`
  (mínimo de dois bytes e dentro do espaço), e detecção de ciclo.
- `capability_vendor_specific` (`0x09`), offsets do cabeçalho PCI e os bits de
  status usados pela lista.
- `barKind`, `barSize`, `BarTable`/`readBarTable` e `barSupportsRegion`:
  validação dos BARs que o transporte moderno vai mapear, incluindo o par de
  64 bits, o tipo reservado, o último índice e o transbordo da soma
  `offset + length`.

**Limite de iteração.** O percurso termina por construção: um ponteiro válido
é um dos 48 offsets alinhados de `0x40` a `0xFC`, e um mapa de bits de 256
posições impede revisitar qualquer offset. Não existe lista aberta; o teste
`pci capability walk is bounded by the alignment grid` percorre a cadeia
máxima e exige exatamente 48 entradas.

**Decisão de ordem do ciclo.** Um ciclo `A -> B -> C -> A` não repete o passo
anterior, por isso a detecção usa o mapa de bits, e não a comparação com o
offset anterior. Há testes para o ciclo de três saltos e para a capability
que aponta para si mesma.

### 2. `kernel/drivers/virtio/`

| Arquivo | Responsabilidade |
|---------|------------------|
| `root.zig` | raiz do módulo, reexportações e integração dos testes |
| `types.zig` | vendor, faixas de identificadores, tipos de dispositivo e erros de identificação |
| `status.zig` | bits do campo `device status`, estados e transições válidas |
| `features.zig` | features de transporte de 64 bits, seleção de palavra e negociação |
| `caps.zig` | decodificação e validação das capabilities VirtIO PCI modernas |

Todos os módulos são puros: recebem bytes e valores já lidos do espaço de
configuração. Nenhum abre porta de I/O, mapeia BAR ou escreve em dispositivo.

### 3. Integração com o kernel

`kernel/main.zig` trocou a função `initVirtioDevice()`, que registrava
`virtio: device init complete block_type=block` **sem nenhuma inicialização
real** — um falso sucesso da mesma família do PR #10 —, por
`identifyVirtioDevices()`. A nova sonda:

1. procura funções de vendor `0x1AF4` no barramento 0;
2. identifica o tipo pelo identificador PCI (`types.identify`);
3. percorre a lista de capabilities (`pci.CapabilityIterator`);
4. lê e decodifica cada capability vendor-specific (`caps.parse`) e valida o
   conjunto (`caps.build`);
5. registra o resultado e **declara explicitamente** que nada foi
   inicializado (`no BAR mapped, no feature negotiated, no virtqueue
   programmed`).

A sonda nunca interrompe o boot: qualquer falha vira uma linha de diagnóstico
com o erro nomeado.

## Valores normativos confirmados

Os valores foram conferidos na fonte normativa (repositório
`oasis-tcs/virtio-spec`), e não deduzidos:

| Item | Valor | Origem |
|------|-------|--------|
| Vendor ID | `0x1AF4` | §4.1.2 PCI Device Discovery |
| Identificador moderno | `0x1040 + tipo`, faixa `0x1040..0x107F` | §4.1.2 |
| Identificadores transicionais | `0x1000` net, `0x1001` block, `0x1002` balloon, `0x1003` console, `0x1004` scsi, `0x1005` entropy, `0x1009` 9P | §4.1.2 |
| Tipos de dispositivo | net 1, block 2, console 3, entropy 4, balloon 5, scsi 8, gpu 16, input 18, socket 19, crypto 20, memory 24, sound 25, fs 26, pmem 27 | §5 Device Types |
| `VIRTIO_F_VERSION_1` | **bit 32** | §2.2 / Reserved Feature Bits |
| `VIRTIO_F_INDIRECT_DESC` / `VIRTIO_F_EVENT_IDX` | bits 28 / 29 | idem |
| `ACCESS_PLATFORM`, `RING_PACKED`, `IN_ORDER`, `ORDER_PLATFORM`, `SR_IOV`, `NOTIFICATION_DATA`, `NOTIF_CONFIG_DATA`, `RING_RESET` | bits 33, 34, 35, 36, 37, 38, 39, 40 | idem |
| Status: ACKNOWLEDGE, DRIVER, DRIVER_OK, FEATURES_OK, SUSPEND, DEVICE_NEEDS_RESET, FAILED | `0x01, 0x02, 0x04, 0x08, 0x10, 0x40, 0x80` | §2.4 Device Status Field |
| `struct virtio_pci_cap` | 16 bytes; `cfg_len` em 0x02, `cfg_type` 0x03, `bar` 0x04, `id` 0x05, `offset` 0x08, `length` 0x0C | §4.1.4 Virtio Structure PCI Capabilities |
| `cfg_type` | common 1, notify 2, ISR 3, device 4, PCI 5, shared memory 8, vendor 9 | idem |
| `virtio_pci_notify_cap` | 20 bytes, `notify_off_multiplier` em 0x10 | §4.1.4.4 Notification capability |
| Alinhamento | common 4 B, device 4 B, notify 2 B, ISR sem exigência | §4.1.4.3 / 4.1.4.4 / 4.1.4.5 |

Também vieram da especificação três decisões de comportamento que mudam o que
o driver aceita:

- **ignorar** capability com `cfg_type` ou `bar` reservados, em vez de falhar;
- usar a **primeira instância utilizável** de cada tipo, e não a única;
- aceitar `cap_len` maior que o necessário (padding e extensões).

## `cap_len` só existe nas capabilities que o definem

A primeira execução de `zig build qemu-test` na CI recusou o disco do QEMU com
`capability list is invalid: TruncatedCapability`. A causa estava no percurso,
não no dispositivo: o código tratava o byte 2 de **toda** capability como
`cap_len`.

O cabeçalho comum de uma capability PCI tem dois bytes: o identificador e o
ponteiro para a próxima. O byte de tamanho é opcional e só existe nos formatos
que o definem. No disco de teste (virtio-blk transicional no `q35`) a lista é:

| Offset | ID | Byte 2 | O que o byte 2 realmente é |
|--------|----|--------|-----------------------------|
| `0x40` | `0x10` PCI Express | `0x00` | início do PCI Express Capabilities Register |
| `0x80` (aprox.) | `0x11` MSI-X | `0x02` | Message Control (número de vetores) |
| `0x9c`..`0xd8` | `0x09` vendor | `0x10`/`0x14` | **`cap_len`**, agora sim |

Ler o byte 2 de uma capability PCI Express produz `0x00`, que era interpretado
como "capability truncada". A correção é `declaresLength`: o tamanho só é
validado para a capability vendor-specific (`0x09`), a única cujo formato este
módulo interpreta. Um identificador desconhecido é percorrido sem validação de
tamanho, e o percurso continua limitado pela validação de ponteiro, pelo mapa
de offsets visitados e pelo fim do espaço de configuração.

O campo `pci.Capability.length` passou a ser `?u8`: `null` significa "esta
capability não declara tamanho", e não "tamanho zero". Dois testes cobrem o
caso com o layout real (PCI Express com `0x00` e MSI-X com `0x02`) e um
terceiro garante que a capability vendor-specific continua sendo recusada
quando o `cap_len` declarado não cabe no espaço.

## Divergência documentada — `BlockFeatures` do módulo legado

`kernel/arch/x86_64/virtio.zig` define:

```zig
pub const BlockFeatures = struct {
    pub const geometry: u32 = 1 << 0;
    pub const ro: u32 = 1 << 1;
    pub const blk_size: u32 = 1 << 2;
    pub const flush: u32 = 1 << 3;
    pub const topology: u32 = 1 << 4;
    pub const discard: u32 = 1 << 13;
};
```

A especificação (§5.2, `device-types/blk/description.tex`) define
`VIRTIO_BLK_F_GEOMETRY (4)`, `VIRTIO_BLK_F_RO (5)`, `VIRTIO_BLK_F_BLK_SIZE
(6)`, `VIRTIO_BLK_F_FLUSH (9)`, `VIRTIO_BLK_F_TOPOLOGY (10)` e
`VIRTIO_BLK_F_DISCARD (13)`. Cinco das seis constantes do módulo legado
**não correspondem** aos bits da especificação: os bits 0, 1, 2, 3 e 4 são de
outras features (barrier obsoleta, `SIZE_MAX`, `SEG_MAX`, `CONFIG_WCE`...),
enquanto `discard` está correto.

Consequência se fosse usado em negociação: o driver pediria `SEG_MAX` e
`CONFIG_WCE` acreditando pedir `geometry` e `topology`, e o dispositivo
recusaria `FEATURES_OK` ou operaria com semântica diferente.

**Este PR não altera o código legado.** A correção depende do driver
VirtIO Block real (PR D), que vai definir as features do tipo de bloco no
subsistema novo, com teste de valor contra a especificação. Registrado aqui
para não ser esquecido e para não ser "consertado" por suposição.

## Testes

Nenhum teste depende de hardware. Os testes de `pci.zig` entram em
`arch-tests` (o mesmo binário que já executava os testes do módulo) e os do
subsistema entram em `virtio-modern-tests`, criado em `build.zig` e ligado ao
passo `test`.

Casos cobertos, conforme o escopo pedido:

| Caso pedido | Teste |
|-------------|-------|
| Capability list válida | `pci capability list walk reads every entry in order` |
| Capability list vazia | `pci capability list accepts an empty list and rejects a missing one` |
| Ponteiro inválido | `pci capability list rejects invalid and unaligned pointers` |
| Ponteiro desalinhado | idem (e o ponteiro seguinte, não só o primeiro) |
| Ciclo na lista | `pci capability list detects cycles that skip a step` |
| Capability truncada/malformada | `pci capability list rejects truncated and malformed entries` |
| Limite de iterações | `pci capability walk is bounded by the alignment grid` |
| BAR inválido | `pci bar table decodes ... and rejects malformed tables`, `pci bar region validation rejects overflow and unaligned bars`, `pci bar size is derived from the all ones mask` |
| Identificadores modernos | `virtio modern identifiers are the device type plus 0x1040`, `virtio transitional identifiers follow the table of the specification`, `virtio identification rejects other vendors and undefined types`, `virtio device types map back to their pci identifiers` |
| Estados válidos | `virtio status requires the documented sequence`, `virtio status bits match the specification` |
| Transições inválidas | `virtio status rejects skipped, backwards and reserved values`, `virtio status never accepts the device bit from the driver`, `virtio status reset and failure are always available` |
| Features compatíveis e incompatíveis | `virtio feature negotiation accepts only the supported transport set`, `virtio feature negotiation rejects legacy devices and unknown bits`, `virtio feature negotiation names the transport it cannot honour`, `virtio feature word selection puts version 1 in the second word` |
| Capabilities VirtIO inválidas | `virtio capability rejects truncated and malformed structures`, `virtio capability validation enforces the alignment of each region`, `virtio capability validation rejects short regions and bad multipliers` |
| Composição da fundação | `a modern virtio block device reaches the feature and status plan`, `a device without the required regions cannot build the transport` |

Contagem observada nos binários de teste: `arch-tests` 63 → **76** testes
(13 novos em `pci.zig`), `virtio-modern-tests` **27** testes novos.

### Layout do dispositivo de teste (QEMU)

Para que o teste de boot não dependa de suposições sobre o dispositivo, o
layout do `virtio-blk-pci` foi conferido no código do QEMU
(`hw/virtio/virtio-pci.c`, `virtio_pci_realize`):

| Região | BAR | Offset | Tamanho |
|--------|-----|--------|---------|
| configuração comum | 4 (64 bits, prefetchable) | `0x0000` | `0x1000` |
| ISR | 4 | `0x1000` | `0x1000` |
| configuração do dispositivo | 4 | `0x2000` | `0x1000` |
| notificação | 4 | `0x3000` | `0x20000` (4 × `0x8000` filas) |

O `notify_off_multiplier` é 4 (`virtio_pci_queue_mem_mult` sem
`page-per-vq`), e o `cap_len` é 16 nas regiões comuns e 20 na notificação. O
BAR 4 é dimensionado por `pow2ceil(notify.offset + notify.size)`, isto é,
`pow2ceil(0x23000) = 0x40000`, e não por `0x1000` por fila: o tamanho da
região de notificação é `4 × 0x8000` filas. O mínimo exigido pelo módulo
(`length >= 2`) é atendido com folga em qualquer das duas leituras, e por isso
a validação não depende desse detalhe — mas o número registrado aqui é o do
código do emulador, e não uma suposição.

Isso confirma que o mínimo de 56 bytes exigido para a configuração comum é
atendido com folga e que o alinhamento das quatro regiões passa nas regras
aplicadas por `caps.build`. O mesmo dispositivo apresenta uma segunda
capability de notificação em um BAR de I/O, com multiplicador 0; ela é
utilizável, mas o driver usa a primeira instância, conforme a especificação.

## Validação executada

| Comando | Resultado |
|---------|-----------|
| `zig version` | `0.17.0` (instalado no ambiente a partir do pacote `ziglang` 0.17.0) |
| `zig fmt --check` (`pci.zig`, `build.zig`, `drivers/virtio/*`) | sem alterações pendentes |
| `zig build test` | passa; `arch-tests` 76/76, `virtio-modern-tests` 27/27 |
| `zig build` | passa; `zig-out/bin/vorynos.img` (64 MiB) gerado |
| `git diff --check` | sem espaços em branco defeituosos |
| `zig build qemu-test` | **não executado localmente**: o ambiente da sessão não tem QEMU nem OVMF. Executado na CI (`.github/workflows/ci.yml`), que instala `ovmf` e `qemu-system-x86`; o passo de boot passou depois da correção do `cap_len`. |
| `zig build check` | idem: depende do passo de boot, e passa na CI |

O teste de boot ganhou duas verificações: a linha da sonda de capabilities no
disco (`type=block regions=... common=barN+0x...`) e a linha que declara a
ausência de inicialização. As duas juntas provam que o percurso rodou no
dispositivo real do QEMU e que o kernel não anuncia um dispositivo pronto.

O histórico da CI neste PR, porque ele explica uma correção que só o boot
revelaria:

| Execução | Resultado | Causa |
|----------|-----------|-------|
| primeira | falhou antes de compilar | `Instalar OVMF`: `apt-get` estourou o limite de 5 min do próprio passo (infraestrutura) |
| segunda a quarta | `qemu-boot-test: 2 check(s) failed` | o percurso recusava o disco do QEMU como `TruncatedCapability` — ver a seção do `cap_len` |
| quinta a sexta | passa no boot; a sexta caiu de novo em `Instalar OVMF` | infraestrutura: `apt-get` do runner sem resposta dentro do limite do passo |
| sétima | **todos os passos verdes** | correção do `cap_len`, diagnóstico do script de boot e repetição da instalação do OVMF |

O script de boot passou a repetir, no fim do relatório, os nomes dos checks que
falharam e as últimas linhas das sondas de PCI e VirtIO: a anotação da CI é
truncada em 4096 caracteres e mantém o início do texto, então o diagnóstico
tem de estar no começo da anotação. Nenhuma verificação foi enfraquecida para
o teste passar.

O passo `Instalar OVMF` também foi endurecido: duas execuções falharam ali, sem
compilar uma linha, porque o `apt-get update` do runner não respondeu dentro do
limite do passo. Cada tentativa continua limitada por `timeout`, e o passo só
desiste depois de três, com uma anotação de erro explícita.

## Limitações (explícitas)

- Não há transporte: nenhum BAR é mapeado, nenhum registrador é escrito.
- Não há negociação real: `features.negotiate` é uma função pura usada pelos
  testes; `VIRTIO_F_VERSION_1` ainda não é lido do dispositivo.
- Não há virtqueue: `kernel/arch/x86_64/virtio.zig` continua sendo a única
  implementação do layout, e não foi alterado.
- O validador de BAR injetado em `caps.build` recebe `null` no kernel, porque
  descobrir o tamanho de um BAR exige escrever nele. Essa verificação entra
  com o mapeamento do BAR, no PR B.
- `kernel/arch/x86_64/virtio_blk.zig` continua devolvendo
  `error.NotImplemented`; nenhuma operação de bloco passou a ter sucesso.

## Próximo incremento (PR B)

Transporte PCI moderno: mapear o BAR da configuração comum, ler
`device_feature` em duas palavras, executar `features.negotiate`, escrever
`FEATURES_OK` com `status.transition` e conferir a leitura de volta, além de
validar o tamanho dos BARs com `pci.barSize`/`pci.barSupportsRegion` antes de
qualquer acesso.
