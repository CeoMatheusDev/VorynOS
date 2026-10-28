# Injeção de falhas da VVDI e verificação da contenção DMA

- **Data:** 2026-10-28
- **Base:** `main` em `70486f2d8900f041948762b51ef76d70e2d19227` (merge do PR #18)
- **Branch:** `arena/036b0b28-vorynos`
- **ADR relacionado:** [ADR-0022](../../adr/ADR-0022-pci-dma-containment.md)
- **Relatório anterior:** [vvdi-containment.md](vvdi-containment.md)
- **Estado:** **TESTADO LOCALMENTE** (host, Zig 0.17.0). QEMU/OVMF e hardware físico
  **não executados** neste ambiente (ver §6).

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
| Testes | 17 cenários de fluxo real e de falha | `block.Driver.device()` (API pública de bloco) |

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
- a única "regra" duplicada é a que o próprio dispositivo precisa ter: o
  comprimento usado é `1` para uma cadeia sem buffer `write` e `513` quando os
  512 bytes de dados foram escritos (§2.7.13.2, §5.2.6). Ela é aplicada no lado
  do dispositivo, e o driver a valida por conta própria.

## 3. Os testes de falha implementados (17)

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

## 4. O que cada teste mede (e o que não mede)

Mede, em todos os caminhos: `queue.freeCount()`, `queue.availableIndex()`,
`queue.inFlightCount()`, `queue.isInFlight(head)`, o estado e o motivo da
contenção, o resultado da revogação, `QueueMemory.canReturnToAllocator()`,
`Containment.permitsMemoryRelease()` e os **bytes integrais** da memória de DMA
(4 KiB) antes e depois de tentar novos pedidos com o driver em quarentena.

Não mede: nada que dependa de hardware. O MMIO é um vetor de bytes; o DMA é
memória comum; não há IOMMU, não há *posted writes* pendentes e não há
reordenação de barramento. Toda conclusão sobre "quiescência" continua sendo a
mesma do ADR-0022: a revogação impede transações novas e **não** prova o destino
das antigas.

## 5. Costura de teste: nenhuma foi necessária

O laço de espera tem `block.timeout_polls = 10_000_000` iterações e **não** foi
alterado. Medição no host (build `Debug`, x86-64):

| Medida | Valor |
| --- | --- |
| Um timeout completo (10 000 000 iterações de `pollUsed` + `spinLoopHint`) | **≈ 207 ms** (mínimo de 5 execuções: 207,2 ms; mediana 211,9 ms) |
| Teste com uma leitura de bloco, sem timeout, para comparação | ≈ 3,3 ms |
| `vvdi-tests` inteiro (165 testes, 7 timeouts) | **≈ 1,7 s** |

Como o custo é absorvível, **não foi introduzida nenhuma costura**: nem `pub var`,
nem campo de orçamento no `Driver`, nem parâmetro de tempo. A semântica de
produção está intacta e o orçamento de 10 milhões de iterações é o que o teste
exercita de fato.

## 6. Validação

### 6.1 Executado neste ambiente (Zig 0.17.0, host Linux x86-64)

| Comando | Resultado |
| --- | --- |
| `zig build test --summary all` | **PASS** — 613/613 testes (antes: 596/596); `vvdi-tests` 148 → **165** (+17), `arch-tests` 91 sem alteração |
| `zig build` | **PASS** — `voryn-boot.efi`, `voryn-kernel` (65,8 MB em `Debug`) e `vorynos.img` de 128 MiB gerados |
| `zig fmt --check` nos arquivos alterados | **PASS** |
| `bash tests/integration/log-assertions-test.sh` | **PASS** — 7/7 cenários |
| `git diff --check` | **PASS** |

Contagem por binário em `zig build test`: `shared-tests` 55, `sdk-tests` 4,
`vpk-tests` 9, `ai-tests` 3, `vex-tests` 7, `raster-tests` 5,
`compositor-tests` 9, `user-composition-tests` 22, `damage-tests` 15,
`display-tests` 7, `keyboard-motion-tests` 13, `keyboard-tests` 4,
`kernel-tests` 22, `security-tests` 18, `arch-tests` 91, **`vvdi-tests` 165**,
`ipc-tests` 6, `fs-loader-tests` 154, `block-api-tests` 4.

### 6.2 Os testes detectam regressões (mutação real, em cópia fora do repositório)

Cada mutação foi aplicada sobre uma cópia do branch em `/tmp` e o teste indicado
foi executado com `--test-filter`. Nenhuma mutação foi deixada no repositório.

| # | Mutação aplicada ao código de produção | Teste que falhou | Mensagem |
| --- | --- | --- | --- |
| M1 | `block.quarantine` deixa de envenenar a instância | *a device that never completes…* | `TestUnexpectedResult` |
| M2 | `submit` libera a cadeia no timeout **e** a guarda `DescriptorInFlight` de `Queue.release` é removida | *a device that never completes…* | `expected 5, found 8` |
| M3 | `Containment.contain` reporta `revoked` sem chamar a revogação | *an unconfirmed revocation…* | `expected .contained_unrevoked, found .contained` |
| M4 | `permitsMemoryRelease` devolve `true` com o dispositivo contido | *the PCI, the containment and the DMA retention compose…* | `TestUnexpectedResult` |
| M6 | `validCompletion` deixa de conferir `used.length` | *invalid completions quarantine…* | `expected error.DeviceFailure, found void` |
| M7 | `transfer` deixa de fazer read-modify-write na escrita parcial | *a full sector write and a partial one…* | `slices differ… at index 0` |
| M8 | `Queue.publish` marca apenas a cabeça como posse do dispositivo | *no injected failure returns queue memory…* | `expected 0, found 1` |

**Limite encontrado:** a mutação que remove apenas a validação de status dentro
de `validCompletion` (M5) **não** é detectada, porque `submit` já recusa status
não documentados no `switch` seguinte, com o mesmo desfecho observável
(`InvalidCompletion` + quarentena + retenção). Os testes medem o contrato, e não
qual das duas verificações dispara; isso é defesa em profundidade redundante, não
cobertura ausente.

### 6.3 Não executado

| Item | Motivo |
| --- | --- |
| `zig build qemu-test` | `qemu-system-x86_64` e OVMF ausentes neste ambiente |
| `zig build qemu-storage-test` | idem |
| `zig build check` | depende dos dois anteriores |
| Hardware físico | indisponível |

Nenhum desses itens é declarado PASS. A CI do SHA que contiver este incremento é
a única evidência possível para o caminho de boot.

## 7. Invariantes verificados

| Invariante | Como foi verificado |
| --- | --- |
| **Ownership DMA** | Nenhuma falha aumenta `freeCount()`; `QueueMemory.canReturnToAllocator()` só vira verdadeiro com `deviceReleased()` |
| **Vida útil dos descritores** | Cadeia publicada continua alocada em toda falha; `isInFlight` da cabeça permanece marcado no caso de `id` errado, e `Queue.release(head)` responde `DescriptorInFlight` |
| **Integridade das conclusões** | `id` da cabeça, comprimento (`1` ou `513`) e status documentado são exigidos; três mutações diferentes de conteúdo foram recusadas com `invalid_completion` |
| **Revogação PCI** | Confirmada só pela leitura de volta do `Command`; `contained_unrevoked` quando o dispositivo descarta a escrita; `Memory Space` preservado |
| **Reset seguro** | Reset confirmado é a **única** condição de liberação; reset não confirmado mantém `queue_enable` e os endereços da fila gravados no dispositivo |
| **Quarentena irreversível na sessão** | Segundo evento não repete a revogação, não troca o motivo, não rearma, e `beginNewLifecycle` responde `DeviceQuarantined` |
| **Execução limitada** | Nenhuma espera nova; os timeouts exercitam o orçamento real de 10 milhões de iterações (≈ 207 ms cada) |
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

## 9. Recomendação sobre publicação

O incremento está **TESTADO LOCALMENTE** e não altera código de produção: os
arquivos afetados são um arquivo de teste novo e uma linha de importação no bloco
`test` de `root.zig`. A publicação fica condicionada a:

1. autorização explícita (esta sessão **não** autoriza push, PR nem merge);
2. CI verde no SHA exato do commit local, porque `qemu-test` e
   `qemu-storage-test` não rodaram neste ambiente.
