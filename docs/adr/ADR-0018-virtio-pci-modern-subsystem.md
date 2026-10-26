# ADR-0018 — Subsistema VirtIO PCI moderno e fundação do transporte

- **Estado:** IMPLEMENTADO — TESTADO LOCALMENTE (host) e na CI (11/11 passos)
  - Revisão técnica final (2026-10-26): `cap_len` maior passou a ser aceito
    (norma do driver), a variante `cap64` é recusada com erro em vez de lida
    como padding, e `status.transition` não aceita mais apagar um bit já
    ligado. Ver `docs/reports/f7/virtio-pci-modern-pr-a.md`.
- **Data:** 2026-10-26
- **Escopo:** `kernel/drivers/virtio/`, `kernel/arch/x86_64/pci.zig`,
  `kernel/main.zig`, `build.zig`
- **Especificação de referência:** VirtIO 1.x (`oasis-tcs/virtio-spec`), seções
  2.2 (feature bits), 2.4 (device status), 3.1.1 (inicialização), 4.1.2
  (descoberta PCI), 4.1.4 (capabilities) e 5 (tipos de dispositivo)

## Contexto

O VorynOS tem uma camada PCI legada mínima (`kernel/arch/x86_64/pci.zig`) e um
módulo `kernel/arch/x86_64/virtio.zig` que implementa apenas o layout da fila
split *em memória*, sem tocar em dispositivo. `virtio_blk.zig` devolve
`error.NotImplemented` em toda operação, e não existe caminho para um driver
real: não há percurso de capabilities, não há validação de BAR, não há modelo
de estados nem de features.

O VirtIO moderno não é uma variação do legado: é outro contrato. O
dispositivo se descreve por capabilities vendor-specific no espaço de
configuração PCI, negocia 64 bits de features com `VIRTIO_F_VERSION_1` no bit
32 e publica o progresso no campo `device status`. Implementar isso dentro de
`virtio.zig` misturaria o layout de fila com o transporte e impediria reúso
por drivers diferentes.

## Decisão

### 1. O subsistema é um módulo próprio, e o PCI continua onde está

`kernel/drivers/virtio/` contém a interpretação do protocolo; o percurso
genérico da lista de capabilities e a validação de BAR ficam em `pci.zig`,
porque valem para qualquer driver e não só para o VirtIO. Não existe um
segundo subsistema PCI.

### 2. Os módulos do VirtIO não importam `pci.zig`

A raiz de um módulo Zig precisa estar acima de todos os arquivos que ele
importa. Com a raiz em `kernel/drivers/virtio/root.zig`, qualquer
`@import("../../arch/x86_64/pci.zig")` é recusado pelo compilador. As
alternativas seriam ligar `pci.zig` como módulo separado — o que criaria uma
**segunda instância** do `IrqSpinlock` que serializa `0xCF8`/`0xCFC`, ou seja,
dois locks para o mesmo par de portas — ou duplicar o percurso de capabilities.

A decisão é a inversão de dependência em dois pontos concretos:

- `caps.parse` recebe **bytes**; quem lê é o chamador, com `pci.Reader` ou com
  qualquer outro mecanismo (`ECAM`, no futuro);
- `caps.build` recebe um **validador de BAR** opcional
  (`fn (bar, offset, length) bool`), que o kernel liga a
  `pci.barSupportsRegion` e os testes ligam a uma plataforma simulada.

Assim o módulo é testável no host sem port I/O e sem hardware, e o kernel usa
uma única instância de `pci.zig`.

### 3. Funções puras, decisões explícitas e erros nomeados

Toda a lógica — percurso, alinhamento, tamanho de BAR, estados, features — é
pura. O que depende de hardware (portas, MMIO) fica fora do módulo testado.

Cada etapa tem um conjunto de erros próprio, declarado na assinatura
(`pci.CapabilityError`, `caps.Error`, `status.Error`, `features.Error`,
`types.Error`), e não um `!void` cujo corpo pode virar sucesso por omissão. O
PR #10 mostrou o custo dessa omissão.

### 4. O que a especificação manda ignorar é ignorado

Três regras do texto normativo mudam o comportamento do parser e estão
implementadas como tais:

- capability com `cfg_type` ou `bar` reservados é **ignorada**, não é erro;
- entre instâncias do mesmo tipo vale a **primeira utilizável**;
- `cap_len` **maior** que o necessário é aceito.

Uma instância de tipo conhecido que viola uma exigência normativa
(alinhamento, tamanho mínimo, multiplicador de notificação) é erro: seguir com
ela produziria acessos que o dispositivo não garante.

### 5. O estado é uma máquina explícita

`status.transition` recusa pular etapas, recusar retroceder, recusa que o
driver escreva `DEVICE_NEEDS_RESET`, aceita `FAILED` de qualquer estado e
aceita o reset (escrita 0) de qualquer estado. Repetir o valor atual é aceito
e não muda nada. O modelo é o da seção 2.4: o driver só acrescenta bits.

### 6. A negociação de features aceita só o que é implementado

`features.supported` contém apenas `VIRTIO_F_VERSION_1`. Pedir
`RING_PACKED`, `ACCESS_PLATFORM`, `EVENT_IDX`, descritores indiretos ou
qualquer outra feature de fila devolve erro nomeado: negociar um bit que o
driver não honra produz um dispositivo que responde de um jeito que o driver
não entende. Cada incremento acrescenta o bit que passou a ser conduzido de
verdade.

### 7. Nenhuma mensagem de sucesso sem trabalho feito

`initVirtioDevice()` registrava `virtio: device init complete block_type=block`
sem inicializar nada. Foi substituída por `identifyVirtioDevices()`, que
percorre as capabilities do dispositivo real, valida as regiões e declara
literalmente que nenhum BAR foi mapeado, nenhuma feature foi negociada e
nenhuma virtqueue foi programada. O teste de boot exige as duas linhas.

## Consequências

**Positivas**

- O próximo incremento (transporte MMIO) tem onde se apoiar: capabilities
  validadas, BARs verificáveis, máquina de estados e negociação de features
  com teste de valor.
- O percurso de capabilities passou a ser genérico e reaproveitável por
  qualquer driver PCI do VorynOS.
- O kernel não anuncia mais um dispositivo que não foi inicializado.

**Negativas e limites**

- Existe uma pequena duplicação de constante (`caps.max_bar_index` = 5) que o
  `pci.zig` também conhece; a fronteira de módulo impede o compartilhamento
  direto. É um limite documentado, não um segundo subsistema.
- O validador de BAR recebe `null` no kernel até existir a sonda de tamanho de
  BAR (que exige escrever no BAR).
- As features específicas de cada tipo de dispositivo continuam no módulo
  legado, com a divergência registrada em
  [`../reports/f7/virtio-pci-modern-pr-a.md`](../reports/f7/virtio-pci-modern-pr-a.md).
- Nada é inicializado: este ADR registra uma fundação, não um driver.

## Alternativas descartadas

- **Estender `kernel/arch/x86_64/virtio.zig`.** Misturaria layout de fila,
  transporte e driver no mesmo arquivo, impedindo reúso e teste isolado.
- **Criar um segundo módulo PCI em `drivers/virtio/`.** Duplicaria o
  percurso, a serialização das portas e a validação de BAR.
- **Ligar `pci.zig` por módulo para permitir o import direto.** Criaria duas
  instâncias do lock de configuração dentro do kernel, uma por unidade de
  compilação — um risco de corrida real, sem ganho arquitetural.
- **Aceitar as features que o dispositivo oferece e "tratar depois".** É a
  origem de falsos sucessos: o dispositivo passa a responder conforme um
  contrato que o driver não implementa.
