# ADR-0020 — Virtqueue dividida nativa: descritores, anéis e ativação do dispositivo

- **Estado:** IMPLEMENTADO — TESTADO LOCALMENTE (host) e TESTADO NO CI (QEMU/OVMF, run `40478940990`)
- **Data:** 2026-10-27
- **Escopo:** `kernel/drivers/virtio/virtqueue.zig`,
  `kernel/drivers/virtio/pci_transport.zig`, `kernel/drivers/virtio/transport.zig`,
  `kernel/drivers/virtio/root.zig`, `kernel/main.zig`, `build.zig`,
  `tools/fatimg.zig`, `tests/integration/boot-qemu.sh`
- **Especificação de referência:** VirtIO 1.2, seções 2.7.3 (barreiras de ordenação),
  2.7.4 a 2.7.9 (tabela de descritores, anéis `available` e `used`), 2.7.13
  (publicação e consumo), 3.1.1 (sequência de inicialização) e 4.1.4.3.2
  (programação da fila no transporte PCI)
- **Continua:** [ADR-0019](ADR-0019-virtio-pci-modern-transport.md) (transporte PCI moderno)
- **Relatório:** [`../reports/f7/virtio-pci-modern-pr-c.md`](../reports/f7/virtio-pci-modern-pr-c.md)

## Contexto

O PR B entregou o transporte até `FEATURES_OK` e parou ali de propósito: a interface não
tinha função que escrevesse `DRIVER_OK`, porque não havia fila para justificar o bit. Um
dispositivo anunciado com `DRIVER_OK` e sem fila é um dispositivo que aceita o pedido do
driver e nunca responde — exatamente o falso sucesso que o PR #10 registrou.

Faltavam três coisas, e elas não são independentes:

1. uma fila dividida real em memória que o dispositivo possa ler e escrever;
2. a escrita dos endereços físicos dessa fila e de `queue_enable` na configuração comum;
3. uma porta para `DRIVER_OK` que só abra depois de (1) e (2).

Também havia uma decisão de propriedade de memória pendente: a fila precisa de páginas
fisicamente contíguas abaixo de 4 GiB, e o kernel já tem esse alocador — `memory/dma.zig`.
Criar um segundo caminho de alocação para a virtqueue criaria duas fontes de verdade para
o mesmo recurso.

## Decisão

### 1. `virtqueue.zig` é um módulo sem hardware, com memória injetada

O módulo recebe `Memory`, um par `{ physical, bytes }`: o endereço físico que vai para o
dispositivo e a visão virtual da mesma faixa. Ele não aloca, não mapeia e não conhece
`paging.zig` nem `dma.zig`. O kernel conecta os dois:

```text
dma.allocate(manager, layout.total_size, dma32_limit)   -> Buffer físico contíguo
dma.mapVirtual(buffer)                                  -> MappedBuffer virtual
virtqueue.Queue(256).init(.{ .physical, .bytes }, size)  -> fila pronta
```

É a mesma cadeia de injeção de `mmio.zig` (`Mapper`) e de `transport.zig` (`Registers`),
e é o que mantém os 26 testes novos rodando no host, sem hardware.

### 2. O layout é o da especificação, com um arredondamento a menos

`Layout.compute` produz: tabela de descritores alinhada a 16, anel `available` alinhado a
2, anel `used` alinhado a 4 e total arredondado ao alinhamento dos descritores. O
alinhamento de 4096 do anel `used` é da interface **legada**; com `VIRTIO_F_VERSION_1`,
que este driver exige, a exigência é 4. Manter 4096 desperdiçaria até 4 KiB por fila sem
nenhum ganho de conformidade. Quem arredonda para página é o alocador de DMA, não o
layout.

`used_event` e `avail_event` fazem parte do bloco mesmo sem `VIRTIO_F_EVENT_IDX`: eles
são bytes reservados, e encurtar o anel por causa de uma feature não negociada
deslocaria o anel `used` de qualquer dispositivo que espere o layout completo.

### 3. O tamanho da fila é uma potência de dois, e isso é protocolo, não preferência

O índice do anel é um contador de 16 bits que avança sem voltar (2.7.7, 2.7.8), e a
posição é `indice & (size - 1)`. Um tamanho que não divida 65536 faria o contador
desalinhar do início do anel depois da volta. `Layout.negotiateSize` devolve a maior
potência de dois menor ou igual ao máximo que o dispositivo informa, e o driver escreve
exatamente esse valor em `queue_size` — o que 2.7.5 permite (o driver pode escolher um
tamanho até o máximo, e o máximo do virtio-blk do QEMU é 256).

### 4. Free list O(1) no próprio descritor, estado em dois bitsets

A free list é encadeada no campo `next` dos descritores livres, com `free_head` e
`free_count`: alocar e liberar custam um passo, e não há memória auxiliar para a lista.

Isso resolve alocação dupla, mas não resolve o erro mais caro: liberar um descritor que o
dispositivo ainda pode estar lendo. Dois bitsets por descritor separam os três estados
(livre, alocado, publicado) e transformam em erro nomeado o que seria corrupção de
memória:

| Operação recusada | Erro |
| --- | --- |
| publicar duas vezes a mesma cadeia | `DescriptorAlreadyPublished` |
| liberar descritor em voo | `DescriptorInFlight` |
| liberar duas vezes | `DescriptorNotAllocated` |
| dispositivo devolve `id` que não estava em voo | `UsedIdNotInflight` |
| dispositivo devolve `id` fora da tabela | `UsedIdInvalid` |
| dispositivo avança `used.idx` além do anel | `UsedIndexOutOfRange` |
| cadeia com ciclo ou `next` fora da tabela | `InvalidChain` |
| descritor indireto sem a feature | `InvalidDescriptor` |

O custo é dimensionado pela capacidade do **tipo**: `Queue(256)` carrega dois bitsets de
256 bits (64 bytes), e não dois de 32768 (8 KiB). É o mesmo padrão de
`dma.Window(pages)`, já usado no kernel.

`release` é deliberadamente tolerante a cadeias corrompidas: a caminhada para no primeiro
elo não alocado, então um ciclo nunca duplica um descritor na free list. Uma cadeia
quebrada ainda pode ser recuperada; só a publicação é que exige a cadeia intacta.

### 5. Ordenação de memória explícita nos dois sentidos

O dispositivo lê o anel `available` a qualquer momento depois do `idx`, e escreve o anel
`used` sem avisar o driver. O módulo usa três mecanismos, e não um só:

- **escritas voláteis** nas entradas dos anéis e nos descritores, para que o compilador
  não elimine, repita nem junte os acessos;
- **`@atomicStore(..., .release)`** em `avail.idx`, precedido das escritas das entradas:
  é a publicação de 2.7.13.1;
- **`mfence`** depois do índice, antes de quem chama tocar no registro de notificação
  (2.7.3.2). A mesma instrução já é usada por `mmio.zig`; aqui ela fecha a publicação sem
  depender de o transporte ser PCI;
- **`@atomicLoad(..., .acquire)`** em `used.idx` antes de ler as conclusões (2.7.13.2).

### 6. `DRIVER_OK` tem porta e fechadura

`transport.Device` ganhou `markQueueReady(index)` e `activate()`:

```zig
try device.markQueueReady(0);   // a fila foi programada e habilitada
try device.activate();          // escreve DRIVER_OK
```

`activate` recusa com `NoQueueConfigured` quando nenhuma fila foi registrada, e com
`NotReadyForDriverOk` quando o estado confirmado pelo dispositivo não é `FEATURES_OK`.
`finish()` devolve o mesmo `Outcome{stage, reason}` da inicialização, com a etapa nova
`driver_ok`. A escrita continua sendo validada por `status.transition` contra o valor
lido e confirmada por leitura imediata.

### 7. Programar a fila é do transporte, habilitar é uma operação com confirmação

`pci_transport.zig` ganhou `configureQueue(index, size, addresses)` e `enableQueue(index)`:

- `configureQueue` confere o índice contra `num_queues`, o tamanho contra o `queue_size`
  **lido do dispositivo**, e o alinhamento de cada endereço (16 / 2 / 4). Depois escreve
  `queue_size` e relê; só então grava os três endereços de 64 bits como dois DWORDs cada,
  na ordem de 4.1.4.3.2;
- `enableQueue` escreve 1 em `queue_enable` e **lê de volta**. Um dispositivo que aceita a
  escrita e não a mantém seria conduzido como se a fila existisse, e o primeiro pedido
  ficaria esperando uma conclusão que nunca chega;
- `queueEnabled` existe para quem precisa do estado sem escrever.

### 8. O boot termina em `DRIVER_OK` com a fila vazia

`programVirtqueue` em `kernel/main.zig` executa, nesta ordem: tamanho negociado, layout,
reserva DMA, `Queue.init` (com a faixa zerada e a free list montada), conferência de que a
fila começa vazia, programação, habilitação com leitura de volta, `markQueueReady` e
`activate`. Cada falha antes da programação devolve a memória ao alocador; depois de
`queue_enable` a memória **não** volta, porque pertence também ao dispositivo.

O estado final tem `status=0x0f` (`ACKNOWLEDGE|DRIVER|FEATURES_OK|DRIVER_OK`), fila 0 com
as três áreas, zero descritores em voo e nenhum pedido publicado. Nenhuma leitura ou
escrita de disco existe neste incremento.

### 9. O teste de boot passa a exigir a ativação, e na ordem certa

`boot-qemu.sh` exigia que nenhuma linha de `virtio-pci` trouxesse `status=0xf`. Agora ele
exige as três linhas da fila e do `DRIVER_OK` e falha se:

- o `DRIVER_OK` não aparecer;
- o `DRIVER_OK` aparecer **antes** da linha `virtqueue 0 enabled`;
- qualquer outra linha de `virtio-pci` trouxer `status=0xf`.

O critério deixou de ser "não ativar" e passou a ser "ativar só depois da fila".

### 10. A imagem de boot passou de 64 MiB para 128 MiB

O ELF do kernel em Debug mede 63,6 MB na `main` e 72,0 MB com este incremento (as seções
de depuração, 19,7 MB de dados estáticos e os vãos que o ligador deixa entre os segmentos
carregáveis). A imagem FAT de 64 MiB estava a 1% do limite, e o primeiro módulo novo
derrubou `zig build` com `StreamTooLong`.

`tools/fatimg.zig` passou a gerar 128 MiB e a usar o mesmo valor como limite de leitura
dos arquivos que embarca. A alternativa avaliada — embarcar um kernel sem informação de
depuração — foi descartada porque `zig objcopy --strip-debug` responde `unimplemented`
no toolchain 0.17.0, e a alternativa de compilar o kernel sem depuração por padrão
mudaria o artefato instalado e o objeto de todos os perfis de desempenho já registrados.
O volume continua FAT16 (32731 clusters de 4 KiB), legível pelo firmware.

### 11. A posse é por descritor, e a memória só volta com reset confirmado

Duas regras fecham a janela entre o driver e o dispositivo. As duas nasceram da auditoria
do PR #13, que reproduziu os defeitos antes da correção.

**Posse por descritor.** Marcar `inflight` apenas na cabeça da cadeia deixava os elos do
meio parecendo livres: `setBuffer` os sobrescrevia e `release` os devolvia à free list com
o dispositivo ainda lendo. `publish` passa a marcar **todos** os elos, e `pollUsed`
desmarca todos — a conclusão devolve a cadeia inteira. Além disso, `linked` registra os
descritores que são `next` de outro, e `release` recusa elo do meio
(`error.DescriptorNotChainHead`) mesmo depois da conclusão: só a cabeça representa a
cadeia, e liberar um elo deixaria a cabeça apontando para memória que outra cadeia pode
receber.

**Posse da memória.** `transport.QueueMemory` guarda `handed_over` (a memória foi entregue
no `queue_enable`) e `device_released` (o reset foi confirmado). O kernel marca
`handOver()` imediatamente depois de `enableQueue` retornar sucesso, antes de qualquer
leitura de volta, e nenhuma falha posterior libera a memória por conta própria: cada uma
passa por `abandonVirtqueue`, que reseta o dispositivo, exige a leitura em zero e só então
devolve as páginas ao alocador. Sem essa confirmação a memória fica reservada — vazar uma
fila é melhor do que o alocador entregar ao dispositivo páginas de outro dono.

**Filas prontas por índice.** `ready` é um `StaticBitSet` com um bit por fila: registrar o
mesmo índice duas vezes é recusado (`QueueAlreadyReady`) em vez de contar duas filas.

**`queue_enable` lido antes de escrito.** A especificação exige 0 depois do reset e proíbe o
driver de escrever 0; uma fila que já se apresente habilitada é recusada
(`QueueAlreadyEnabled`) em vez de habilitada às cegas. `configureQueue` faz a mesma leitura
antes de escrever o tamanho e os endereços: reprogramar uma fila ativa trocaria a memória
embaixo do dispositivo, e o driver não tem como desabilitá-la.

**A posse começa na primeira escrita.** `handOver()` é chamado antes de `configureQueue`, e
não depois do `queue_enable`. A primeira escreve endereços desta memória; a segunda habilita
a fila. Um erro em qualquer uma delas não prova que o dispositivo ficou sem acesso, e só o
reset confirmado devolve a memória. A política fica com quatro estados — dono é o driver,
dono é o dispositivo, reset não confirmado, reset confirmado — e apenas o primeiro e o
último liberam.

## Consequências

**Positivas**

- O dispositivo chega ao estado funcional: fila 0 programada, habilitada e confirmada,
  `DRIVER_OK` escrito por último. O PR seguinte (driver de bloco) tem a API de que
  precisa: `publish`, `pollUsed`, `release`, `setBuffer`, `setWritable`.
- A fila é exercitada no host contra bytes crus da especificação: os testes escrevem
  conclusões em `used` sem chamar nenhuma rotina do módulo, e conferem `avail.idx`,
  posição dos anéis e recusa de `id` inválido.
- Os erros de propriedade de descritor são nomeados; não existe caminho em que liberar
  cedo demais entregue ao dispositivo um descritor reescrito.
- `zig build test` passa com 525 testes (26 novos; `virtio-modern-tests` 65 → 91).

**Negativas e limites**

- Nenhum pedido foi publicado: `publish` e `pollUsed` estão implementados e testados,
  mas o boot usa a fila vazia. Isso é verificado no próprio boot (`free=size`, `avail=0`,
  `used=0`).
- Não há notificação nem interrupção: `notifyAddress` existe no transporte, `setNoInterrupt`
  e `notificationsSuppressed` existem na fila, mas nada chama o registro de notificação e
  nenhum MSI-X foi programado. O consumo por consulta (`pollUsed`) é o caminho previsto.
- `VIRTIO_F_INDIRECT_DESC`, `VIRTIO_F_EVENT_IDX` e `VIRTIO_F_RING_PACKED` continuam fora
  da negociação; `setIndirect` recusa por construção.
- A capacidade da fila no kernel é fixa em 256 (`Queue(256)`), e não em 32768.
- O teste de boot não pode ser executado na sessão de desenvolvimento (sem
  `qemu-system-x86_64` nem OVMF); ele passou na CI do PR (run `40478940990`), com os
  padrões novos da fila e do `DRIVER_OK` exigidos pelo `boot-qemu.sh`.

## Alternativas descartadas

- **Alinhar o anel `used` em 4096 "por segurança".** Não é exigência do transporte
  moderno e desperdiça até 4 KiB por fila; o layout legado já tem o seu próprio módulo
  (`kernel/arch/x86_64/virtio.zig`), que não foi tocado.
- **Alocar a fila dentro de `virtqueue.zig`.** Duplicaria a política de DMA (contiguidade,
  limite de 32 bits, janela virtual) e criaria um segundo dono da mesma memória.
- **Free list em array separado de índices.** Custaria até 64 KiB por fila para fazer o que
  o campo `next` de um descritor livre já faz.
- **Um bitset por descritor em vez de dois.** Não distingue "alocado" de "publicado", e é
  exatamente essa distinção que impede liberar o que está em voo.
- **Escrever `DRIVER_OK` incondicionalmente e conferir depois.** É o falso sucesso que a
  fechadura existe para impedir: o dispositivo já estaria ativo quando a conferência
  falhasse.
- **Notificar o dispositivo na inicialização.** Não há pedido; uma notificação com a fila
  vazia não prova nada e o `used` não mudaria.
- **Tampar o problema de tamanho com `strip = true` no kernel.** Perde a informação de
  depuração do artefato instalado e não resolve a causa (o ELF é grande por dados
  estáticos e vãos, não só por depuração).
