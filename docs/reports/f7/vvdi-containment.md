# Contenção PCI/DMA do subsistema VVDI

- **Data:** 2026-10-28
- **Base:** `main` em `0c307f02019031edab23b628827df8584eb4d66d`
- **ADR:** [ADR-0022](../adr/ADR-0022-pci-dma-containment.md)
- **Dívida relacionada:** A-3 de [vvdi-debt.md](vvdi-debt.md)
- **Estado:** IMPLEMENTADO — TESTADO LOCALMENTE (host). Boot QEMU/OVMF **não executado
  neste ambiente** (ver seção *Validação*).

---

## 1. O problema, em uma frase

Depois que a fila era entregue ao dispositivo, uma falha envenenava o driver mas não o
dispositivo: ele continuava sendo *bus master* PCI, continuava podendo emitir DMA contra
páginas que o kernel retinha, e o kernel não tinha onde registrar esse estado.

## 2. Como o *bus master* é configurado hoje (levantamento)

| Pergunta | Resposta verificada |
| --- | --- |
| O VorynOS liga `Bus Master` em algum lugar? | **Não.** Nenhuma escrita no registrador `Command` existia em `kernel/` antes deste incremento. |
| O bootloader VNB liga? | **Não.** `boot/uefi/` não contém acesso a espaço de configuração PCI; usa apenas GOP e a tabela de configuração ACPI. |
| `probeBarSizes` escreve `Command`? | Não, escreve apenas os registradores de BAR (0x10–0x24). |
| Então quem liga o bit? | O firmware. No caminho UEFI, o `PciBus` do OVMF habilita `Memory Space` e `Bus Master` antes de `ExitBootServices`, e o kernel herda o estado. |
| O MMIO depende do bit 2? | **Não.** Depende do bit 1 (`Memory Space`). É por isso que revogar o bit 2 não derruba o BAR. |

### Consequências da mudança (requisito explícito da autorização)

1. **Não há regressão de MMIO.** A revogação preserva `Memory Space`, `I/O Space`,
   paridade, `SERR` e `INTx Disable`; só o bit 2 muda.
2. **Comportamento em falha muda de "passivo" para "ativo".** Antes, o dispositivo ficava
   como *bus master* até o reboot; agora ele é impedido de iniciar transações novas.
3. **Estado herdado do firmware passa a ser manipulado pelo kernel.** É a primeira escrita
   do VorynOS no registrador `Command`. Ela acontece somente em caminho de falha, sob o
   mesmo `IrqSpinlock` que serializa `CONFIG_ADDRESS`/`CONFIG_DATA`.
4. **`Status` não é escrito com 1.** A metade alta do DWORD sai zerada de propósito; um 1
   ali apagaria um erro lido por *read/write-1-to-clear*.
5. **Nada é prometido sobre DMA em voo.** A revogação impede transações futuras; não
   confirma o destino das anteriores.

## 3. Garantias efetivamente disponíveis (requisito 8)

| Garantia | Disponível? | Base |
| --- | --- | --- |
| O dispositivo não inicia **novas** transações DMA depois de uma revogação confirmada | **Sim**, condicionada à leitura de volta | PCI 3.0 §6.2.2 (`Command[2]`) |
| Transações já emitidas foram drenadas antes da revogação | **Não** | Não existe operação PCI/PCIe de drenagem |
| `resetDevice()` confirmado (status lido = 0) implica drenagem | **Não demonstrável** | VirtIO 1.2 §2.4 não define drenagem; não há barreira de *completion* no barramento |
| Um reset confirmado é condição **necessária** para devolver memória | **Sim**, por decisão de projeto | `Containment.permitsMemoryRelease` |
| O kernel continua capaz de tentar um reset depois da revogação | **Sim** | `Memory Space` preservado |
| A memória entregue ao dispositivo pode ser liberada sem reset | **Não**, sob nenhuma circunstância neste código | `QueueMemory` + `permitsMemoryRelease` |

O ponto 3 é o mais importante e o mais fácil de confundir: a leitura de volta zerada prova
que o **registrador** reflete o reset pedido. Ela não é uma barreira de memória. Em
plataformas com reordenação ou com *posted writes* pendentes no *root complex*, uma
escrita DMA anterior pode, em tese, chegar depois. O código não alega o contrário: mantém a
memória retida até um reset confirmado — a mesma política anterior — e agora nomeia a
condição em um único lugar, em vez de depender de `defer` ausentes.

## 4. O que mudou no código

### `kernel/arch/x86_64/pci.zig`

- Constantes `command_offset` (0x04), `command_bus_master` (0x0004) e
  `command_memory_space` (0x0002).
- `commandWithBusMaster(current, enabled)`: função pura, muda só o bit 2.
- `setBusMasterWith(access, enabled) -> BusMasterChange`: leitura, escrita com a metade alta
  zerada, leitura de volta e classificação em `confirmed` / `unconfirmed` / `absent`.
  Idempotente: pedir o estado já presente não escreve nada.
- `setBusMaster(bus, device, function, enabled)`: o mesmo, sob `config_lock`.

### `kernel/drivers/vvdi/containment.zig` (novo)

Máquina de estados com `arm`, `contain`, `noteReset`, `permitsMemoryRelease`,
`isQuarantined`, `revocationConfirmed` e `describe` (texto de diagnóstico sem alocação).
Sem importar `pci.zig`, sem laço, sem relógio, sem espera.

### `kernel/drivers/vvdi/block.zig`

- `init` recebe `device_containment: ?*containment.Containment`.
- `quarantine(why: containment.Reason)` envenena a instância **e** escala para o estado do
  dispositivo. Os sete pontos de chamada passaram a nomear a causa.
- `null` preserva exatamente o comportamento anterior.

### `kernel/main.zig`

- `virtio_bus_master_target` e `virtio_containment`: **estáticos**, porque a contenção é
  consultada depois que a função que a armou retornou. O `ctx` da revogação aponta para o
  alvo estático — nunca para a pilha.
- `arm` no ponto exato de `ownership.handOver()`, onde a memória passa a ser do dispositivo.
- `abandonVirtqueue` registra o resultado do reset (`noteReset`) e contém com motivo
  `reset_unconfirmed` quando ele não se confirma.
- `virtqueueMemoryMayBeReturned()` combina `QueueMemory.canReturnToAllocator()` com
  `Containment.permitsMemoryRelease()`; é a única porta para liberar a fila e para
  desmapear o BAR.
- **Correção do caminho pós-`DRIVER_OK`:** as três falhas de retenção de estado e a falha
  de `virtio_block_driver.init` agora emitem `FATAL` com o motivo e escalam para a
  contenção, em vez de retornar silenciosamente.

## 5. Invariantes preservados

| Invariante | Como |
| --- | --- |
| DMA lifetime | Nenhum caminho chama `Buffer.release`; a liberação exige reset confirmado. |
| Descriptor lifetime | A fila de um dispositivo contido não é reconstruída nem reutilizada. |
| Completion integrity | Nenhum caminho novo de sucesso foi introduzido. |
| Reset safety | Revogação ≠ reset ≠ liberação; três fatos distintos no estado. |
| Failure containment | O dispositivo é impedido de iniciar DMA nova e o driver recusa pedidos. |
| Resource ownership | O estado é nomeado, consultável e registrado em log. |
| Bounded execution | Nenhuma espera nova; `contain` é O(1) e sem repetição. |
| No false success | `unconfirmed` e `absent` não são tratados como `revoked`. |

## 6. Validação

| Comando | Resultado |
| --- | --- |
| `zig build test --summary all` | **PASS** — `39/39 steps succeeded; 587/587 tests passed` (`arch-tests` 91, `vvdi-tests` 139) |
| `zig build` | **PASS** — `vorynos.img` 128 MiB gerado |
| `zig fmt --check` (5 arquivos alterados) | **PASS** |
| `git diff --check` | **PASS** |
| `bash tests/integration/log-assertions-test.sh` | **PASS** — 7/7 |
| `zig build qemu-test` / `qemu-storage-test` / `qemu-interactive-test` / `check` | **BLOCKED** — sem `qemu-system-x86_64` e sem OVMF; espelho Debian inacessível neste ambiente |

Contagem anterior à mudança: 554 testes. Depois da contenção: 581 (+8 em `arch-tests` para o
registrador `Command`; +19 em `vvdi-tests`: 15 de contenção e 4 do driver de bloco). Depois da
correção R-3: **587** (+6 em `arch-tests`), ver seção 8.

Os testes de falha simulada cobrem: escrita ignorada pelo dispositivo (revogação não
confirmada), função ausente (`absent`, sem escrita), dispositivo que derruba `Memory Space`
(revogação recusada), idempotência sem escrita extra, falha que não é repetida, falha que
não é promovida a sucesso por uma chamada posterior, reset confirmado que não rearma, e
reset confirmado que não é rebaixado por uma tentativa posterior.

## 7. Correção R-3 — confirmação de escrita sobre todos os bits do `Command`

A primeira versão da revogação conferia, na leitura de volta, apenas o bit alvo e
`Memory Space`. Um dispositivo que alterasse **qualquer outro** bit do `Command` ao receber a
escrita seria aceito como revogado. A verificação passou a comparar o registrador inteiro,
excluindo apenas o bit alvo.

**Por que a comparação é relativa e não uma máscara fixa.** Cada bit do `Command`
(PCI 3.0 §6.2.2) é RW ou RO; **nenhum é RW1C ou se limpa na leitura**. Portanto qualquer bit
que seja RO, que seja fixo em zero (o `Wait Cycle Control` do PCI 3.0) ou que uma
implementação deixe preso em um continua idêntico antes e depois, e passa na verificação. O
que ela recusa é só o que não pode acontecer: o dispositivo mexer em outro bit do `Command`
como efeito colateral de uma escrita no próprio `Command`. O teste
*"bits that vary legitimately across implementations do not fail the check"* fixa esse
requisito com bits reservados em um e o bit 7 em um — a verificação aceita, como deve.

**`Status` não entra na comparação.** `before` e `after` são truncados para `u16` e a escrita
grava zero na metade alta; a semântica RW1C continua fora do caminho.

| Cenário | Teste |
| --- | --- |
| Outro bit do `Command` muda | *a change to any other command bit is reported unconfirmed* e *the preservation check rejects a single corrupted bit on its own* |
| Revogação confirmada | *revoking bus master preserves memory space and the status register*, *enabling bus master again is confirmed only by the read-back* |
| Escrita ignorada | *a device that ignores the write is reported unconfirmed, not revoked* |
| Dispositivo ausente | *an absent function is distinguished from an unconfirmed revocation*, mais os dois novos: antes e **depois** da escrita |
| `Memory Space` preservado | *revoking bus master preserves memory space…* e *a device that drops memory space fails…* |
| `Status` RW1C preservado | *the status half of the command dword is never written as one* |
| Nenhuma liberação indevida de DMA | *a confirmed revocation contains the device but never releases memory*, *a failed revocation is recorded distinctly and still holds the memory*, *a failed revocation still leaves the driver poisoned* |
| Nenhum desfecho ambíguo vira sucesso | *no confirmation outcome is ever equal to a confirmed revocation* |

## 8. Riscos residuais

- **A revogação pode não funcionar em hardware real.** Uma função que aceita a escrita e
  não a mantém é reportada como `contained_unrevoked`, mas nenhum caminho alternativo é
  tentado. Não há evidência em hardware físico.
- **O reset confirmado continua não sendo prova portável de drenagem** (seção 3). Se um
  *root complex* entregar uma escrita tardia depois do reset, a memória já devolvida ao
  alocador poderia ser alvo dela. Não foi reproduzido; permanece como hipótese de gravidade
  alta e probabilidade baixa, sem mitigação neste incremento.
- **Sem recuperação online.** Um dispositivo contido permanece contido, com BAR e DMA
  retidos, até a reinicialização.
- **A primeira escrita do kernel no `Command`** pode interagir com firmware que reescreva o
  registrador; não foi observado em QEMU (o caminho só executa em falha).
- **R-3 (fechado nesta revisão).** A confirmação passou a exigir preservação de todos os bits
  do `Command`, com comparação relativa justificada. Risco residual remanescente: um
  dispositivo que altere outro bit de forma *estável* (isto é, que já apareça alterado na
  primeira leitura) não é detectado — por construção, porque essa é exatamente a variação
  legítima que a verificação precisa aceitar.
