# ADR-0022 — Contenção PCI/DMA de dispositivo virtual em estado desconhecido

- **Estado:** IMPLEMENTADO — TESTADO LOCALMENTE no host e **TESTADO NA CI** para o SHA `470c5f887f80c0cabb417f2c03dc4cc004bea293` (run [40662431437](https://github.com/CeoMatheusDev/VorynOS/actions/runs/40662431437), 12/12 passos, incluindo `qemu-test` e `check` com o teste de persistência de dois boots). Os incrementos posteriores a esse SHA têm apenas a validação local registrada no relatório; nenhum deles é coberto por essa execução.
- **Data:** 2026-10-28
- **Escopo:** `kernel/arch/x86_64/pci.zig`, `kernel/drivers/vvdi/containment.zig`,
  `kernel/drivers/vvdi/block.zig`, `kernel/drivers/vvdi/root.zig`, `kernel/main.zig`,
  `docs/reports/f7/vvdi-containment.md`, `docs/reports/f7/vvdi-debt.md`
- **Especificação de referência:** PCI Local Bus 3.0 §6.2.2 (`Command`/`Status`),
  §7.5.1.1.2 (`Status` RW1C); PCI Express 2.0 §2.9; VirtIO 1.2 §2.4 e §4.1.4.3
- **Continua:** [ADR-0020](ADR-0020-split-virtqueue.md) e
  [ADR-0021](ADR-0021-vvdi-virtual-device-interface.md)
- **Dívida relacionada:** [`../reports/f7/vvdi-debt.md`](../reports/f7/vvdi-debt.md) (A-3)

## Contexto

O driver de bloco VVDI (`kernel/drivers/vvdi/block.zig`) já recusava publicar sucesso sem
uma conclusão válida e já se envenenava em timeout, notificação falha ou conclusão inválida.
Essa contenção, porém, era inteiramente local: um `bool poisoned` que impedia o driver de
reutilizar a fila. O dispositivo continuava sendo *bus master* PCI e podia emitir novas
transações DMA contra páginas que o kernel mantinha reservadas justamente por isso.

O registro de dívida A-3 documentava a ausência da revogação explícita de *bus master* e a
ausência de um estado de contenção consultável. A auditoria de 2026-10-28 confirmou a
dívida no código: `pci.zig` não escrevia o registrador `Command` em nenhum caminho, e a
única escrita em espaço de configuração era a sondagem de tamanho de BAR.

A auditoria também encontrou um caminho sem diagnóstico nem proprietário: falha de
`virtio_block_driver.init` **depois** de `DRIVER_OK`. Nesse estado o dispositivo está
ativo, a fila 0 está habilitada, o BAR está mapeado e a DMA está retida, mas o kernel
imprimia apenas `block device configuration failed` e retornava, sem `FATAL`, sem estado
de contenção e sem tentativa de revogação.

## Decisão

### 1. A contenção é do dispositivo, e não do pedido

`kernel/drivers/vvdi/containment.zig` introduz um estado por dispositivo com quatro valores
— `disarmed`, `armed`, `contained`, `contained_unrevoked` — e um conjunto fechado de
motivos (`timeout`, `invalid_completion`, `notify_failure`, `queue_failure`,
`activation_failure`, `reset_unconfirmed`, `configuration_failure`). O driver de bloco
escala cada envenenamento para esse estado; a orquestração de boot o consulta antes de
devolver qualquer memória ao alocador.

O módulo **não** importa `pci.zig`: o alvo da revogação chega como ponteiro de função com
contexto, do mesmo modo que `mmio.Mapper` recebe o mapeador. Isso preserva a propriedade
estabelecida no ADR-0021 de que a VVDI compila e é testada sozinha, a partir de
`kernel/drivers/vvdi/`.

### 2. Revogação de *bus master* não é quiescência

O bit 2 (dois) do `Command` autoriza a função a iniciar transações de barramento.
Desligá-lo impede transações **novas**. Não existe, no PCI nem no PCIe, operação que
confirme a drenagem de transações já despachadas. Por isso:

- `Containment.permitsMemoryRelease()` **ignora** o resultado da revogação e exige um reset
  confirmado;
- uma revogação confirmada não rearma o dispositivo nem libera nada;
- o estado distinguindo `contained` de `contained_unrevoked` é preservado, para que o
  diagnóstico não transforme "não consegui revogar" em "contive".

### 3. Reset confirmado é a condição disponível, não uma garantia universal

A leitura de volta zerada de `device_status` prova que o dispositivo aceitou o reset
VirtIO. Ela não prova, sozinha, que escritas DMA emitidas antes do reset terminaram em
toda plataforma — o VirtIO não define drenagem, e o PCI tampouco. O ADR registra
explicitamente que:

- `reset_confirmed` é tratado como a condição **disponível** para devolver memória, e é o
  que o código já fazia de forma implícita;
- a condição agora está nomeada em um único lugar, e não espalhada por `defer` ausentes;
- a garantia é a mesma de antes, não uma garantia nova, e não é alegada como tal.

### 4. O registrador `Command` é escrito com os 16 bits baixos, e só ele

O DWORD em 0x04 carrega `Command` (baixos) e `Status` (altos). Os bits de `Status` são
*read/write-1-to-clear*. A escrita grava `Command` desejado e **zero** na metade alta:
escrever 1 ali apagaria um erro registrado (paridade, *target abort*) que o kernel nunca
leu. A leitura de volta exige que o bit alvo tenha atingido o estado pedido **e que todos os
demais bits do `Command` tenham sido preservados** — `Memory Space` incluído, porque é ele
que mantém o MMIO respondendo e o caminho de reset disponível.

A verificação de preservação é **relativa** (`before` contra `after`), e não uma máscara do
que o driver considera implementado. A justificativa é que todo bit do `Command` é RW ou RO
(PCI 3.0 §6.2.2) e **nenhum é RW1C ou se limpa na leitura**: bits RO, fixos em zero ou presos
em um por uma implementação qualquer continuam iguais e passam. Recusa-se apenas o que não
pode acontecer — o dispositivo alterar outro bit do `Command` como efeito colateral da
escrita. `Status` nunca entra na comparação: `before`/`after` são truncados para `u16`.

### 5. Idempotência e ausência de espera

`contain` tenta a revogação **no máximo uma vez** por instância, preserva o primeiro motivo
e devolve o mesmo resultado nas chamadas seguintes. Não há laço, relógio nem alocação: a
estrutura é consultada em caminhos de erro, e um caminho de erro não pode bloquear o
kernel. Uma revogação que falhou não é repetida — não há retry neste incremento.

## Consequências

- Todo caminho de falha posterior à entrega da fila passa a ter estado nomeado e motivo
  registrado, inclusive a falha de configuração depois de `DRIVER_OK`.
- `releaseVirtqueueMemory` e o desmapeamento do BAR ficam atrás de uma única pergunta,
  `virtqueueMemoryMayBeReturned()`, que combina a posse do transporte (`QueueMemory`) com o
  estado de contenção do dispositivo. As duas condições são independentes de propósito.
- Nenhuma linha de log é adicionada no caminho de sucesso: `tests/integration/boot-qemu.sh`
  continua exigindo exatamente uma linha `DRIVER_OK` e nenhum `status=0xf` avulso.
- **Fora de escopo, por decisão:** recuperação online, repetição de reset, reutilização de
  fila em quarentena, restauração do *bus master* e qualquer promessa de quiescência.
  Um dispositivo contido permanece contido até a reinicialização.

## Ciclo de vida do estado de contenção

O estado de contenção é **por instância e por rodada**. Um ciclo anterior não pode autorizar
nada no seguinte: `beginNewLifecycle` exige três provas externas — a fila deixou de pertencer
ao dispositivo, não sobrou alocação ou mapeamento de DMA, e nenhum driver ativo aponta para a
instância — mais o fechamento interno do ciclo (reset confirmado, e ausência de quarentena).
Só então o estado é apagado, e a rodada nova começa com `reset_confirmed` falso.

Se qualquer prova faltar, o estado é **preservado** e a inicialização para. A recusa nunca é
silenciosa e nunca libera memória.

Limites explícitos deste incremento, que continuam valendo:

- **dispositivo único:** existe uma instância global de contenção; não há enumeração de
  múltiplos dispositivos virtuais nem contenção independente por função PCI;
- **sem recuperação online:** um dispositivo contido não é reiniciado, nem com reset
  confirmado. `DeviceQuarantined` é recusa permanente até a reinicialização do sistema;
- **sem repetição de revogação:** uma revogação que falhou não é tentada de novo.

## Alternativas descartadas

- **Ligar/desligar `Bus Master` como prova de quiescência.** Descartada: não existe
  semântica de drenagem no barramento, e tratá-la como prova liberaria memória ainda
  alcançável pelo dispositivo.
- **Desligar `Memory Space` junto com `Bus Master`.** Descartada: o MMIO deixaria de
  responder e o kernel perderia o único caminho para tentar um reset.
- **Colocar o estado de contenção em `pci.zig`.** Descartada: acoplaria a VVDI ao módulo de
  arquitetura e quebraria a independência de compilação descrita no ADR-0021.
- **Recuperação automática após timeout.** Descartada nesta sessão por decisão explícita do
  proprietário do projeto.
