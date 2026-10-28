# Injeção de falhas da VVDI e verificação da contenção DMA

- **Data:** 2026-10-28
- **Base:** `main` em `70486f2d8900f041948762b51ef76d70e2d19227` (merge do PR #18)
- **Branch:** `arena/036b0b28-vorynos`
- **ADR relacionado:** [ADR-0022](../../adr/ADR-0022-pci-dma-containment.md)
- **Relatório anterior:** [vvdi-containment.md](vvdi-containment.md)
- **Revisão:** 2026-10-28, depois da auditoria adversarial deste PR. As
  correções estão em §6.4; os números de §5, §6.1 e §6.2 são os **medidos nesta
  revisão**, e não os da primeira versão do relatório.
- **Estado:** **TESTADO LOCALMENTE** (host, Zig 0.17.0). QEMU/OVMF e hardware físico
  **não executados** neste ambiente (ver §6.3).

---

## 1. O problema, em uma frase

A auditoria do PR #18 mostrou que os testes de `block.zig` exercitavam
principalmente `quarantine()` de forma isolada: nenhum deles executava
`Driver.init`, `transfer`, `submit` e o processamento de conclusões contra um
dispositivo que respondesse — ou que deixasse de responder — pelo barramento.
Sem isso, "o timeout retém os descritores" era uma afirmação sobre uma função
que não tinha sido chamada no caminho real.

Este incremento fecha essa lacuna **sem tocar em código de produção**: acrescenta
um dispositivo VirtIO Block simulado, atrás do transporte PCI real, e injeta as
falhas que o driver precisa distinguir.

## 2. O que foi acrescentado

Um arquivo novo, `kernel/drivers/vvdi/fault_injection.zig`, importado **apenas**
dentro do bloco `test` de `root.zig` — o kernel não o referencia:

| Componente | O que é | O que reusa da produção |
| --- | --- | --- |
| `Device` | Dispositivo VirtIO Block moderno em memória: registradores da configuração comum (§4.1.4.3), configuração do tipo bloco (§5.2.4), anel `available` lido e anel `used` escrito por bytes | nada; é o outro lado do barramento |
| `Device.bus()` | Barramento MMIO injetado em `mmio.Region` | `mmio.Bus`, `mmio.Region` |
| `PciFunction` | Registrador `Command` com escrita e leitura de volta | contrato `containment.BusMaster` |
| `deviceCapabilities()` | Bytes de `struct virtio_pci_cap` codificados e interpretados | `caps.parse`, `caps.build` |
| `bringUpToDriverOk()` | A ordem de `programVirtqueue` em `main.zig` | `Transport.attach`, `transport.Device`, `pci_transport.configureQueue`/`enableQueue`, `virtqueue.Queue`, `transport.QueueMemory`, `containment.Containment` |
| `bringUp()` | O mesmo, mais o driver | `block.Driver.init` |
| Testes | 19 cenários de fluxo real, de falha e de contrato do dispositivo | `block.Driver.device()` (API pública de bloco) |

### Por que não tornar `FakeBar` público

`pci_transport.zig` já tem um `FakeBar` privado, e ele é suficiente para o que
aquele arquivo testa: registradores e programação de fila. Exportá-lo teria três
custos:

1. transformaria um detalhe de teste em contrato público do módulo;
2. obrigaria `block.zig`/`fault_injection.zig` a depender do formato interno de
   outro arquivo de teste (BAR de 0x2000, quatro regiões sobrepostas, sem
   configurador de tipo bloco nem anel `used`);
3. deixaria os dois arquivos acoplados justamente na parte que precisa ser
   independente: a visão que cada teste tem do dispositivo.

A alternativa escolhida foi compor o dispositivo a partir dos tipos públicos que
o kernel usa (`mmio.Bus`, `mmio.Region`, `caps.Capability`). `FakeBar` continua
privado, e `pci_transport.zig` não foi alterado.

### Por que não há lógica de produção duplicada

- Descritores, anéis e buffers são lidos e escritos **por bytes**, com os
  deslocamentos da especificação. O simulador não chama `Queue.publish`,
  `Queue.pollUsed`, `Queue.descriptor`, `Queue.release` nem `Driver.transfer`;
- a fila é programada pelo `pci_transport` de produção, e o driver é o mesmo
  `block.Driver` que roda no boot;
- as únicas "regras" duplicadas são as que o próprio dispositivo precisa ter:
  o comprimento usado é `1` para uma cadeia sem buffer `write` e `513` quando os
  512 bytes de dados foram escritos (§2.7.13.2, §5.2.6); e uma notificação só
  é aceita no endereço `queue_notify_off × notify_off_multiplier`, com 16 bits
  e com o índice de uma fila existente (§4.1.4.4). As duas são aplicadas no
  lado do dispositivo, e o driver as valida por conta própria.

## 3. Os testes de falha implementados (19)

### 3.1 Fluxo real do driver

| Cenário | Teste |
| --- | --- |
| `Driver.init` → `device()` → `readBytes` com o setor vindo do dispositivo, e a cadeia voltando à free list | *a real virtio block read crosses the PCI transport and the virtqueue* |
| Escrita de setor inteiro (um `OUT`) e escrita parcial (read-modify-write: `IN` + `OUT`), com o resto do setor preservado byte a byte | *a full sector write and a partial one reach the medium through the device* |
| `FLUSH` publicado quando a feature foi negociada; recusado **antes de publicar** quando não foi, sem notificação e sem descritor retirado | *FLUSH is only published when the device offered the feature* |

### 3.2 Timeout, conclusão tardia e quarentena

| Cenário | Teste |
| --- | --- |
| Dispositivo que recebe o pedido e não responde: `Timeout`, quarentena `timeout`, revogação confirmada, cadeia publicada e nenhum descritor liberado | *a device that never completes quarantines the driver and retains the descriptors* |
| Conclusão que chega **depois** do timeout: o anel `used` avança, nada é consumido, a cadeia continua publicada, o motivo original sobrevive a um segundo evento e os bytes de DMA não mudam | *a completion that arrives after the timeout changes no invariant* |
| Notificação recusada depois da publicação: `notify_failure`, dispositivo nunca notificado, cadeia retida | *a refused notification quarantines and keeps the published chain* |
| Conclusão com `id` que não é a cabeça, comprimento curto ou status fora da especificação: `invalid_completion`, nada devolvido à free list | *invalid completions quarantine without returning a descriptor* |
| Dispositivo que responde `VIRTIO_BLK_S_IOERR`: falha do pedido **sem** contenção, cadeia liberada, próximo pedido funciona | *a device reported I/O error fails the request without containment* |
| `VIRTIO_BLK_S_UNSUPP` traduzido para `NotImplemented` | *an unimplemented request status is reported as NotImplemented* |
| Fila sem descritores livres: recusa local, sem publicar, sem notificar e sem conter o dispositivo | *an exhausted queue fails the request locally without containment* |
| Dispositivo que publica `no_notify` em `used.flags`: o driver não escreve no registro de notificação e o pedido fica retido | *a device that suppresses notifications is not notified and retains the chain* |

### 3.3 Reset e falhas depois de `DRIVER_OK`

| Cenário | Teste |
| --- | --- |
| Reset não confirmado (o dispositivo ignora a escrita de zero): `reset_unconfirmed`, revogação confirmada **e** memória retida | *an unconfirmed reset keeps the DMA memory retained* |
| Reset confirmado: a liberação passa nas duas provas, mas o dispositivo **não** rearma, o novo ciclo de vida é recusado e o driver continua envenenado | *a confirmed reset releases the memory but never rearms the device* |
| Três falhas de configuração depois de `DRIVER_OK` — `config_generation` instável, capacidade vazia e memória de fila diferente da programada — contidas com `configuration_failure` e DMA retido | *a block configuration failure after DRIVER_OK contains the device* |

### 3.4 Composição e invariantes

| Cenário | Teste |
| --- | --- |
| PCI → contenção → retenção, com os passos nomeados: capabilities do espaço de configuração, `DRIVER_OK`, posse da memória, revogação confirmada pela leitura de volta e `Memory Space` preservado | *the PCI, the containment and the DMA retention compose in that order* |
| Revogação **não** confirmada: `contained_unrevoked`, sem retry, sem máscara, memória retida | *an unconfirmed revocation still contains and still retains the memory* |
| Varredura: nenhuma falha injetada devolve descritor à free list, publica um segundo pedido ou autoriza liberar memória | *no injected failure returns queue memory to the allocator* |

### 3.5 Contrato do dispositivo e vida útil da cadeia

| Cenário | Teste |
| --- | --- |
| Notificação aceita **somente** no endereço da fila, com 16 bits e com o índice de uma fila existente; `scaled + 4`, largura errada e índice inexistente são recusados; `notify_off` não nulo desloca o endereço efetivo e invalida o anterior | *a notification is only accepted at the queue address, width and index* |
| Cadeia de pedido expirado: tentativa de liberação recusada com `DescriptorInFlight` e sem efeito na free list; os três descritores continuam alocados e em voo; a cadeia só volta a ser alocável depois que a conclusão tardia é consumida | *a timed out request keeps its chain out of the free list* |

## 4. O que cada teste mede (e o que não mede)

Mede, em todos os caminhos: `queue.freeCount()`, `queue.availableIndex()`,
`queue.inFlightCount()`, `queue.isInFlight(head)`, o estado e o motivo da
contenção, o resultado da revogação, `QueueMemory.canReturnToAllocator()`,
`Containment.permitsMemoryRelease()` e os **bytes integrais** da memória de DMA
(4 KiB) antes e depois de tentar novos pedidos com o driver em quarentena.

Simplificação declarada: o simulador **não** implementa `EVENT_IDX` nem
`used.avail_event`. O driver também não habilita a feature, então o caminho não
existe dos dois lados; o que os testes exercitam é `avail.flags.no_notify`
(§2.7.7), que é a única supressão que o driver consulta.

Não mede: nada que dependa de hardware. O MMIO é um vetor de bytes; o DMA é
memória comum; não há IOMMU, não há *posted writes* pendentes e não há
reordenação de barramento. Toda conclusão sobre "quiescência" continua sendo a
mesma do ADR-0022: a revogação impede transações novas e **não** prova o destino
das antigas.

## 5. Costura de teste: nenhuma foi necessária

O laço de espera tem `block.timeout_polls = 10_000_000` iterações e **não** foi
alterado. Medição no host (build `Debug`, x86-64, binário já compilado, 5
execuções por linha):

| Medida | Valor |
| --- | --- |
| Um timeout completo (10 000 000 iterações de `pollUsed` + `spinLoopHint`) | **≈ 297 ms** (mínimo 296,6 ms; mediana 299,6 ms; máximo 323,4 ms) |
| Teste com uma leitura de bloco, sem timeout, para comparação | ≈ 4,5 ms (mínimo 4,5 ms; mediana 4,8 ms) |
| `vvdi-tests` inteiro (167 testes, 8 timeouts) | **≈ 2,36 s** (mínimo 2359,7 ms; mediana 2369,1 ms) |

Os números da primeira versão deste relatório (207 ms, 3,3 ms e 1,7 s) estavam
abaixo do medido e foram substituídos pelos desta revisão.

Como o custo é absorvível, **não foi introduzida nenhuma costura**: nem `pub var`,
nem campo de orçamento no `Driver`, nem parâmetro de tempo. A semântica de
produção está intacta e o orçamento de 10 milhões de iterações é o que o teste
exercita de fato.

## 6. Validação

### 6.1 Executado neste ambiente (Zig 0.17.0, host Linux x86-64)

| Comando | Resultado |
| --- | --- |
| `zig build test --summary all` | **PASS** — 615/615 testes; `vvdi-tests` **167** (+2 nesta revisão; 165 na primeira versão) |
| `zig build` | **PASS** — 13/13 etapas; `voryn-boot.efi`, `voryn-kernel` (65,8 MB em `Debug`) e `vorynos.img` de 128 MiB gerados |
| `zig fmt --check` nos arquivos alterados | **PASS** |
| `bash tests/integration/log-assertions-test.sh` | **PASS** — 7/7 cenários |
| `git diff --check` | **PASS** |

Contagem por binário em `zig build test`: `shared-tests` 55, `sdk-tests` 4,
`vpk-tests` 9, `ai-tests` 3, `vex-tests` 7, `raster-tests` 5,
`compositor-tests` 9, `user-composition-tests` 22, `damage-tests` 15,
`display-tests` 7, `keyboard-motion-tests` 13, `keyboard-tests` 4,
`kernel-tests` 22, `security-tests` 18, `arch-tests` 91, **`vvdi-tests` 167**,
`ipc-tests` 6, `fs-loader-tests` 154, `block-api-tests` 4.

### 6.2 Os testes detectam regressões (mutação real, em cópia fora do repositório)

Cada mutação foi aplicada sobre uma cópia do branch em `/tmp`, e a suíte
`vvdi-tests` inteira (167 testes) foi executada. Nenhuma mutação foi deixada no
repositório. "Testes que falharam" conta testes distintos com `FAIL`; um aborto
por pânico é anotado à parte, porque interrompe o restante da suíte.

| # | Mutação aplicada ao código | Testes que falharam | Desfecho |
| --- | --- | --- | --- |
| M1 | `block.quarantine` deixa de envenenar a instância | 9 | detectada |
| M2 | `submit` libera a cadeia no ramo de timeout, **com a guarda intacta** | **0** | **inerte** (§6.2.1) |
| M2b | M2 **e** remoção da guarda `DescriptorInFlight` de `Queue.release` | 8 | detectada |
| M3 | `Containment.contain` reporta `revoked` sem chamar a revogação | 13 | detectada |
| M4 | `permitsMemoryRelease` devolve `true` com o dispositivo contido | 10 | detectada |
| M5 | `validCompletion` deixa de conferir a lista de status | 3 | detectada (§6.2.2) |
| M6 | `validCompletion` deixa de conferir `used.length` | 3 | detectada |
| M7 | `transfer` deixa de fazer read-modify-write na escrita parcial | 1 | detectada |
| M8 | `Queue.publish` marca apenas a cabeça como posse do dispositivo | 6 | detectada |
| M9 | `pollUsed` deixa de devolver a posse da cadeia | 14 | detectada |
| M10 | `notifyQueue` escreve em `scaled + 4`: endereço errado, dentro da região | 12 | detectada (§6.2.3) |
| M11 | `submit` libera a cadeia antes de validar a conclusão | 9 | detectada |
| M12 | quarentena envenena o driver mas não escala para o dispositivo | 2 + aborto | detectada |

M9 a M12 não fazem parte da primeira versão do relatório: foram acrescentadas na
auditoria para testar caminhos que a tabela original não cobria.

#### 6.2.1 M2 isolada é inerte, não é uma regressão não detectada

Com a guarda de posse intacta, `Queue.release(head)` responde
`error.DescriptorInFlight` para uma cadeia publicada, e o `catch {}` do ramo de
timeout descarta esse erro. O estado da fila **não muda**: a mutação não altera
nenhum comportamento observável, e por isso a suíte passa por ela. Isso é
diferente de "regressão que os testes não pegam": a invariante está garantida
por uma segunda barreira, e o preço é que uma única mutação não a derruba.

Ainda assim, a proteção passa a ter prova dedicada: o teste
*a timed out request keeps its chain out of the free list* afirma que a
liberação de uma cadeia em voo é **recusada** (`DescriptorInFlight`), que a free
list não muda e que os três descritores continuam alocados e em voo. Com a
guarda removida (M2b), esse teste falha — e 7 outros falham junto.

#### 6.2.2 M5 é detectada, e a recusa é atribuível ao status

A primeira versão deste relatório afirmava que remover a lista de status de
`validCompletion` (M5) não era detectado. A medição mostra o contrário:

- o teste unitário *used completions validate request identity, byte count and
  status* (`block.zig`) falha, porque verifica o predicado direto com o par
  `status = 0xFF` e comprimento `1` — o comprimento que a própria regra de
  comprimento já espera para um status desconhecido;
- a falha `corrupt_status` do dispositivo simulado passou a publicar
  **comprimento 1** junto do status `0xFF`. Antes ela reaproveitava o
  comprimento da leitura bem-sucedida (`513`), e a recusa vinha da regra de
  comprimento — o teste de integração não provava nada sobre a lista de status.
  Com o comprimento certo, M5 derruba também *invalid completions quarantine
  without returning a descriptor* (`expected 5, found 8`: o driver devolveria a
  cadeia ao ver um status que não conhece) e *no injected failure returns queue
  memory to the allocator*.

#### 6.2.3 M10: o endereço da notificação

A primeira versão do simulador aceitava qualquer escrita dentro da região de
notificação, ignorando endereço, largura e índice. Com isso, escrever em
`scaled + 4` — endereço de outra fila, nunca usado por este dispositivo —
passava por todos os 165 testes: zero detecção.

O simulador agora aplica §4.1.4.4: aceita somente escrita de 16 bits em
`queue_notify_off × notify_off_multiplier`, com o índice de uma fila existente.
Escritas fora disso são contadas em `rejected_notify_count` e **não** servem
fila alguma. M10 passa a derrubar 12 testes, entre eles o teste novo
*notification is only accepted at the queue address, width and index*.

Para provar que cada cláusula do contrato tem prova própria, foram aplicadas
três mutações no **simulador** (não no código de produção), uma por cláusula:

| # | Cláusula removida do simulador | Testes que falharam |
| --- | --- | --- |
| M13 | validação do endereço | 1 (*notification is only accepted…*) |
| M14 | validação da largura (16 bits) | 1 (*notification is only accepted…*) |
| M15 | validação do índice de fila | 1 (*notification is only accepted…*) |

### 6.3 Não executado

| Item | Motivo |
| --- | --- |
| `zig build qemu-test` | `qemu-system-x86_64` e OVMF ausentes neste ambiente |
| `zig build qemu-storage-test` | idem |
| `zig build check` | depende dos dois anteriores |
| Hardware físico | indisponível |

Nenhum desses itens é declarado PASS. A CI do SHA que contiver este incremento é
a única evidência possível para o caminho de boot. `qemu-test`,
`qemu-storage-test` e `check` ficam **BLOCKED** neste ambiente.

### 6.4 Correções aplicadas depois da auditoria adversarial

| Achado | Correção | Onde |
| --- | --- | --- |
| A1 — tabela de mutações incompatível com o experimento | §6.2 substituída pelos resultados medidos; M2 isolada declarada inerte e M5 declarada detectada | este relatório |
| A2 — notificação aceita sem validar endereço, largura e índice | validação de §4.1.4.4 no simulador, contadores de aceitas/recusadas, teste dedicado; M10 deixa de sobreviver | `fault_injection.zig` (`write`, `acceptsNotification`, `expectedNotifyAddress`) |
| B1 — vida útil da cadeia de um pedido expirado sem prova dedicada | teste novo que separa tentativa indevida de liberação, liberação efetiva e reutilização | `fault_injection.zig` |
| B2 — a falha de status era atribuível ao comprimento | `corrupt_status` publica comprimento 1; o teste unitário do predicado ganhou o par que isola status e o par que isola comprimento | `fault_injection.zig`, `block.zig` |
| B3 — nome do teste prometia `Driver.init` | renomeado para *quarantine closes the gate without a transport or a queue*, com o escopo declarado no comentário | `block.zig` |
| C1 — tempos subestimados | §5 refeita com 5 execuções por linha | este relatório |
| C2 — índice do BAR sem checagem explícita | `barOffset` valida janela e largura antes de indexar | `fault_injection.zig` |
| C3 — campo morto | `Request.type` removido (escrito e nunca lido) | `fault_injection.zig` |
| C4 — largura da notificação não validada | coberto por A2 | `fault_injection.zig` |
| C5 — `EVENT_IDX` não documentado | declarado em §4 | este relatório |

Nenhuma linha de código de produção foi alterada nesta revisão: `block.zig`
mudou apenas dentro de `test`, e `fault_injection.zig` é código de teste.

## 7. Invariantes verificados

| Invariante | Como foi verificado |
| --- | --- |
| **Ownership DMA** | Nenhuma falha aumenta `freeCount()`; `QueueMemory.canReturnToAllocator()` só vira verdadeiro com `deviceReleased()` |
| **Vida útil dos descritores** | Cadeia publicada continua alocada em toda falha; `isInFlight` da cabeça permanece marcado no caso de `id` errado, e `Queue.release(head)` responde `DescriptorInFlight` |
| **Integridade das conclusões** | `id` da cabeça, comprimento (`1` ou `513`) e status documentado são exigidos; três mutações diferentes de conteúdo foram recusadas com `invalid_completion`; a falha de status usa o comprimento que a regra de comprimento já aceita, para que a recusa seja atribuível à lista de status |
| **Contrato de notificação** | O dispositivo só serve a fila na escrita de 16 bits, no endereço `queue_notify_off × notify_off_multiplier` e com índice válido (§4.1.4.4); endereço, largura e índice têm prova própria (M13–M15) |
| **Vida útil da cadeia expirada** | `Queue.release` de uma cadeia em voo responde `DescriptorInFlight`, a free list não muda, e a cadeia só volta a ser alocável depois da conclusão tardia |
| **Revogação PCI** | Confirmada só pela leitura de volta do `Command`; `contained_unrevoked` quando o dispositivo descarta a escrita; `Memory Space` preservado |
| **Reset seguro** | Reset confirmado é a **única** condição de liberação; reset não confirmado mantém `queue_enable` e os endereços da fila gravados no dispositivo |
| **Quarentena irreversível na sessão** | Segundo evento não repete a revogação, não troca o motivo, não rearma, e `beginNewLifecycle` responde `DeviceQuarantined` |
| **Execução limitada** | Nenhuma espera nova; os timeouts exercitam o orçamento real de 10 milhões de iterações (≈ 297 ms cada) |
| **Nenhuma memória volta ao alocador** | Comparação de `freeCount`, `QueueMemory` e do estado de contenção em todas as falhas; bytes de DMA idênticos antes e depois de novos pedidos com o driver em quarentena |

## 8. Lacunas restantes

- **Host-side apenas.** Sem QEMU/OVMF e sem hardware físico, este incremento não
  prova o comportamento em boot nem a existência de DMA em voo.
- **`main.zig` não é host-testável.** A composição verificada é a dos **fatos**
  que `virtqueueMemoryMayBeReturned()` combina (`canReturnToAllocator` e
  `permitsMemoryRelease`), não a função em si. O `and` entre elas continua
  verificado apenas por leitura de código.
- **A revogação PCI real não é exercitada aqui.** O `Command` é um registrador em
  memória; o caminho real (`pci.setBusMaster`) está coberto por `arch-tests`.
- **Sem IOMMU, sem *posted writes* e sem reordenação.** A conclusão do ADR-0022
  continua valendo: revogação não é quiescência.
- **Um dispositivo, uma fila.** Não há enumeração, multi-dispositivo nem
  contenção por função PCI; nenhum teste aqui exercita duas instâncias.
- **Sem recuperação online.** `DeviceQuarantined` continua sendo recusa
  permanente até a reinicialização.
- **`queue_max_size = 8` no simulador.** Filas maiores (até 32768) só são
  exercitadas pelos testes próprios de `virtqueue.zig`.
- **Uma fila, sem `EVENT_IDX`.** `num_queues = 1` e a feature não é negociada
  dos dois lados; `used.avail_event` não é modelado. O `notify_off` é
  configurável por teste, e o deslocamento não nulo é exercitado, mas não há
  duas filas com deslocamentos distintos.
- **M2 isolada continua inerte.** A garantia de que a cadeia de um pedido
  expirado não circula vem da guarda de `Queue.release`, não de uma segunda
  checagem no ramo de timeout. Uma mutação única nesse ramo não muda
  comportamento; derrubar a proteção exige mexer na guarda (M2b), e aí oito
  testes falham.

## 9. Recomendação sobre publicação

O incremento está **TESTADO LOCALMENTE** e não altera código de produção: os
arquivos afetados são um arquivo de teste novo, uma linha de importação no bloco
`test` de `root.zig` e um arquivo de teste existente (`block.zig`, só dentro de
`test`). A publicação fica condicionada a:

1. autorização explícita (esta sessão **não** autoriza push, PR nem merge);
2. CI verde no SHA exato do commit local, porque `qemu-test` e
   `qemu-storage-test` não rodaram neste ambiente.
