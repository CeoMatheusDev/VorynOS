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

Esta seção separa o que foi executado **no ambiente de desenvolvimento** do que foi executado
**na CI**. São evidências diferentes sobre SHAs diferentes.

### 6.1 Executado localmente (Zig 0.17.0)

Vale para o conteúdo do branch em que cada linha foi medida; a contagem acompanha a seção 8.

| Comando | Resultado |
| --- | --- |
| `zig build test --summary all` | **PASS** — 587/587 (`arch-tests` 91, `vvdi-tests` 139) antes da correção F-1; 596/596 (`arch-tests` 91, `vvdi-tests` 148) depois |
| `zig build` | **PASS** — `vorynos.img` 128 MiB gerado |
| `zig fmt --check` (arquivos alterados) | **PASS** |
| `git diff --check` | **PASS** |
| `bash tests/integration/log-assertions-test.sh` | **PASS** — 7/7 |
| `zig build qemu-test` / `qemu-storage-test` / `qemu-interactive-test` / `check` | **BLOCKED** — sem `qemu-system-x86_64` e sem OVMF; espelho Debian inacessível neste ambiente. Nunca executados aqui, e portanto nunca declarados PASS. |

### 6.2 Executado na CI

| Item | Valor |
| --- | --- |
| SHA | `470c5f887f80c0cabb417f2c03dc4cc004bea293` |
| Run | [40662431437](https://github.com/CeoMatheusDev/VorynOS/actions/runs/40662431437) |
| Resultado | **SUCCESS** — 12/12 passos |
| O que a CI executou | `zig build test`, `log-assertions-test.sh`, `zig build`, `zig build qemu-test` e `zig build check` (que inclui `qemu-storage-test`, os dois boots) |
| O que a CI **não** executa | `zig build qemu-interactive-test` — não existe no workflow e não faz parte de `check` |
| Limitação | nenhum caminho de falha PCI/DMA é injetado. A CI verde comprova o caminho normal e a persistência, **não** o comportamento em falha de dispositivo |

O log bruto do run não pôde ser baixado do ambiente da sessão (armazenamento de artefatos fora
dos hosts permitidos); a evidência acima é de conclusão por passo, obtida pela API.

Contagem anterior à mudança: 554 testes. Depois da contenção: 581 (+8 em `arch-tests` para o
registrador `Command`; +19 em `vvdi-tests`: 15 de contenção e 4 do driver de bloco). Depois da
correção R-3: 587 (+6 em `arch-tests`). Depois da correção F-1: 596 (+9 em `vvdi-tests`), ver
seção 9. **Nenhuma dessas contagens posteriores a 587 foi validada pela CI no momento em que
foram escritas.**

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

## 9. Correção F-1 — isolamento entre ciclos de vida

### Defeito demonstrado

`Containment.arm` era no-op sobre uma instância já usada, `reset_confirmed` era pegajoso e a
instância global nunca era reinicializada. Numa segunda rodada de bring-up, duas coisas
aconteciam ao mesmo tempo:

- `permitsMemoryRelease()` autorizava devolver DMA ao alocador **sem nenhum reset daquela
  rodada**, com base na confirmação da rodada anterior;
- `contain()` devolvia o resultado da revogação anterior e **não revogava** o bus master.

Reprodução executada na auditoria, sobre uma cópia exata do arquivo:

```text
rodada2: state=armed reset_confirmed=true permitsMemoryRelease=true
contain() na rodada2 -> revoked (nenhuma revogação nova)
```

Alcance no código do PR #18: **nenhum**. `bringUpVirtioFunction` é chamado uma única vez
(`main.zig:1277`), para um único dispositivo. O defeito se tornaria vivo no primeiro
incremento de multi-dispositivo ou de repetição de bring-up.

### Correção

`Containment.beginNewLifecycle(facts)` comprova, antes de apagar qualquer coisa:

| Prova | Origem | Recusa |
| --- | --- | --- |
| A fila deixou de pertencer ao dispositivo | `QueueMemory.canReturnToAllocator()` | `QueueStillOwnedByDevice` |
| Não sobrou alocação nem mapeamento de DMA | `virtqueue_state.buffer/mapped/queue == null` | `MemoryStillDependent` |
| Nenhum driver ativo aponta para a instância | `block_dev.defaultDevice() == null` | `DriverStillAttached` |
| O ciclo anterior foi fechado | estado interno | `ResetNotConfirmed` |
| O dispositivo não está contido | estado interno | `DeviceQuarantined` |

Só com todas as provas o estado é apagado, e a rodada nova começa com `reset_confirmed`
falso. Qualquer recusa **preserva** o estado e emite `FATAL` em `main.zig`
(`beginVirtioLifecycle`), nunca libera memória. A reinicialização não rearma: o alvo da rodada
nova continua sendo registrado por `arm`, no ponto de `handOver`, como antes.

### Testes de regressão (9 novos)

| Cenário exigido | Teste |
| --- | --- |
| Primeira rodada com reset confirmado | *F-1: the single initial lifecycle is unchanged* |
| Segunda rodada com `reset_confirmed = false` | *F-1: a second round does not inherit the reset confirmation* |
| Segunda rodada exigindo sua própria revogação | *F-1: a second round performs its own revocation* |
| Falha de reset impedindo reutilização | *F-1: a failed reset blocks reuse instead of being forgotten* |
| Reinicialização com DMA ainda entregue | *F-1: restart is refused while the device still owns the queue*, *… while DMA memory is still dependent* |
| Driver ativo conservando ponteiros | *F-1: restart is refused while a driver still points at the instance* |
| Dispositivo contido não reinicia | *F-1: a contained device is never restarted by a new lifecycle* |
| Ausência de liberação prematura | *F-1: a refused restart never releases memory* |

O primeiro teste da lista **reproduz o defeito**: com `beginNewLifecycle` reduzido a no-op, ele
falha com `expected .disarmed, found .armed`; com a correção, passa. Verificado em cópia fora
do repositório.

### Limitações de ciclo de vida (permanecem)

- **Dispositivo único:** uma instância global de contenção; sem enumeração nem contenção por
  função PCI.
- **Sem recuperação online:** `DeviceQuarantined` é recusa permanente até a reinicialização,
  mesmo com reset confirmado.
- **Sem repetição de revogação:** uma revogação que falhou não é tentada de novo.
