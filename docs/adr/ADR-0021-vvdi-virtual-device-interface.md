# ADR-0021 — Identidade nativa VVDI (Voryn Virtual Device Interface) e fronteira com o VirtIO 1.2

- **Estado:** IMPLEMENTADO — TESTADO LOCALMENTE (host: 544 testes Zig + 7/7 cenários de asserções de log); validação de boot QEMU/OVMF na CI do PR
- **Data:** 2026-10-27
- **Escopo:** `kernel/drivers/vvdi/*`, `kernel/main.zig`, `build.zig`,
  `tests/integration/boot-qemu.sh`, `tests/integration/log-assertions-test.sh`,
  `.github/workflows/ci.yml`, `docs/reports/f7/vvdi-debt.md`
- **Especificação de referência:** VirtIO 1.2 (`oasis-tcs/virtio-spec`) e
  [`VN-NAMES-0001`](../standards/VN-NAMES-0001.md)
- **Continua:** [ADR-0018](ADR-0018-virtio-pci-modern-subsystem.md),
  [ADR-0019](ADR-0019-virtio-pci-modern-transport.md) e
  [ADR-0020](ADR-0020-split-virtqueue.md)
- **Registro de dívida técnica associado:** [`../reports/f7/vvdi-debt.md`](../reports/f7/vvdi-debt.md)

## Contexto

Os incrementos PR A ([ADR-0018](ADR-0018-virtio-pci-modern-subsystem.md)), PR B
([ADR-0019](ADR-0019-virtio-pci-modern-transport.md)) e PR C
([ADR-0020](ADR-0020-split-virtqueue.md)) construíram do zero a fundação moderna de
dispositivos virtuais do VorynOS: descoberta de capabilities PCI, mapeamento MMIO validado,
máquina de estados de inicialização, negociação de 64 bits com `VIRTIO_F_VERSION_1`,
*split virtqueue* nativa sobre memória DMA e ativação controlada com `DRIVER_OK`.

Durante essa construção inicial, o subsistema recebeu nomes provisórios acoplados ao nome do
transporte externo e à distinção temporária contra o código legado:

- diretório `kernel/drivers/virtio/`;
- alias de importação `virtio_modern` em `kernel/main.zig`;
- alvo de testes `virtio-modern-tests` em `build.zig`;
- prefixo de diagnóstico serial `[VNK] virtio-pci:`.

Esses nomes provisórios traziam três problemas arquiteturais:

1. **Ausência de identidade própria na arquitetura VorynOS:** ao contrário de `VNB`, `VNK`,
   `VNM`, `VNX`, `VNC` e `VNV`, a camada nativa de dispositivos virtuais aparecia como mero
   qualificador (`virtio_modern` / `virtio-pci`) em vez de um subsistema próprio do sistema.
2. **Ambiguidade com os módulos legados:** `kernel/arch/x86_64/virtio.zig`,
   `virtio_blk.zig` e `virtio_net.zig` continuam na árvore com prefixo serial
   `[VNK] virtio:`, tornando fácil confundir em código, logs e scripts de teste qual camada
   emitiu cada evento.
3. **Risco de testes *fail-open* na troca de prefixo:** em `tests/integration/boot-qemu.sh`,
   checagens negativas baseadas em filtragem de prefixo (`grep -E '\[VNK\] virtio-pci:'`)
   poderiam passar silenciosamente por ausência de casamento caso o prefixo mudasse sem
   validação integral da sequência, da ordem dos nove eventos e da não vacuidade do log.

## Decisão

### 1. Estabelecer a identidade nativa VVDI

A infraestrutura nativa de dispositivos virtuais do VorynOS passa a denominar-se
oficialmente **VVDI — Voryn Virtual Device Interface**.

A reorganização aplica os seguintes identificadores de subsistema:

| Antes | Depois | Papel |
| --- | --- | --- |
| `kernel/drivers/virtio/` | `kernel/drivers/vvdi/` | Árvore do subsistema nativo de dispositivos virtuais |
| `virtio_modern` | `vvdi` | Identificador do módulo importado em `kernel/main.zig` |
| `virtio-modern-tests` | `vvdi-tests` | Executável de testes de unidade no host (`build.zig`) |
| `[VNK] virtio-pci:` | `[VNK] vvdi:` | Prefixo canônico das mensagens seriais da VVDI |

### 2. Relação arquitetural entre VVDI e VirtIO 1.2

A **VVDI** é o subsistema nativo do VorynOS responsável por descobrir, validar, mapear,
conduzir filas e expor dispositivos virtuais ao kernel com código próprio, sem incorporar
drivers ou subsistemas de Linux, BSD, Windows ou outros sistemas operacionais.

O **VirtIO 1.2** é o padrão público de interoperabilidade de hardware virtual que a VVDI
implementa neste estágio sobre barramento PCI moderno. Separar a identidade do subsistema
(`vvdi`) do protocolo implementado (`VirtIO 1.2`) permite que a VVDI evolua no futuro (novos
tipos de dispositivo, outros transportes como MMIO direto ou interfaces virtuais próprias)
sem rebatizar a fronteira interna do kernel.

### 3. Preservação estrita dos identificadores padronizados

Conforme a regra normativa de [`VN-NAMES-0001`](../standards/VN-NAMES-0001.md) §4 (*"An
identifier that represents a value of the firmware or of a specification preserves the
original spelling"*), **nenhum** identificador técnico definido pela especificação VirtIO 1.2
ou pela estrutura interna dos módulos foi renomeado artificialmente. Permanecem intactos:

- `virtqueue`, `Descriptor`, `Layout`, `Queue`;
- `queue_enable`, `queue_size`, `queue_select`, `queue_desc`, `queue_driver`, `queue_device`;
- `VIRTIO_F_VERSION_1` (`features.version_1`), bits de status (`ACKNOWLEDGE`, `DRIVER`,
  `FEATURES_OK`, `DRIVER_OK`, `DEVICE_NEEDS_RESET`, `FAILED`);
- nomes das estruturas de protocolo documentadas (`virtio_pci_cap`, `virtio_pci_cap64`,
  `virtio_pci_notify_cap`, `virtio_pci_common_cfg`);
- identificadores PCI padronizados (`0x1AF4`, faixa moderna `0x1040..0x107F`, faixa
  transicional `0x1000..0x103F`);
- nomes técnicos dos arquivos Zig dentro de `kernel/drivers/vvdi/`: `caps.zig`,
  `features.zig`, `mmio.zig`, `pci_transport.zig`, `root.zig`, `status.zig`,
  `transport.zig`, `types.zig` e `virtqueue.zig`.

### 4. Manutenção deliberada do caminho legado intocado

Os arquivos legados em `kernel/arch/x86_64/`:

- `kernel/arch/x86_64/virtio.zig`
- `kernel/arch/x86_64/virtio_blk.zig`
- `kernel/arch/x86_64/virtio_net.zig`

bem como a sonda legada `probeVirtqueueLayout()` (`[VNK] virtio: split queue layout ok`) e os
testes de regressão que garantem `error.NotImplemented` nos stubs de bloco, **não são
modificados neste PR**. Misturar a remoção do caminho legado com a migração de identidade
violaria o isolamento da mudança; a coexistência temporária fica registrada como dívida
técnica D-7 em [`../reports/f7/vvdi-debt.md`](../reports/f7/vvdi-debt.md).

### 5. Limites estritos da reorganização e ausência de mudança funcional

Este incremento **não altera o comportamento funcional do kernel**:

- nenhuma alteração na lógica de alocação, mapeamento ou posse de memória DMA;
- nenhuma alteração na implementação da *split virtqueue*, do transporte MMIO ou da máquina
  de estados;
- nenhum driver de bloco (`virtio-blk` / PR D) é introduzido aqui;
- as dívidas técnicas conhecidas (A-3, D-6 e D-7) são formalmente catalogadas em
  [`../reports/f7/vvdi-debt.md`](../reports/f7/vvdi-debt.md), sem correção funcional neste PR.

### 6. Endurecimento contra *fail-open* nos testes de boot

Para impedir que a mudança de prefixo crie falsos positivos silenciosos, `boot-qemu.sh`
passa a concentrar a validação VVDI em `verify_vvdi_log` (também invocável isoladamente via
`--verify-vvdi-log=<arquivo>`), exigindo simultaneamente:

1. log existente e não vazio;
2. rejeição explícita do prefixo obsoleto `[VNK] virtio-pci:` e de qualquer prefixo incorreto
   nas linhas da sequência moderna;
3. presença dos 9 padrões VVDI obrigatórios;
4. sequência completa dos 9 passos de inicialização;
5. ordem estritamente crescente de linhas entre todos os 9 eventos;
6. exatamente uma ocorrência válida de `DRIVER_OK`;
7. ausência de qualquer `status=0xf` (ou `0x0f`) fora dessa única linha válida.

O script `tests/integration/log-assertions-test.sh` exercita diretamente essa verificação
sobre sete cenários deterministas (log vazio, prefixo antigo, sequência incompleta, passo
ausente, ordem invertida, `status=0xf` indevido e log válido) e passa a rodar na CI do
GitHub Actions a cada execução.

## Consequências

**Positivas**

- A infraestrutura nativa de dispositivos virtuais passa a ter identidade clara (`VVDI`),
  separada tanto do código legado em `kernel/arch/x86_64/virtio*.zig` quanto do nome da
  especificação externa implementada.
- Nomenclatura técnica da especificação VirtIO 1.2 preservada sem traduções ou abstrações
  artificiais.
- As asserções de log da VVDI deixam de ter caminhos *fail-open* e contam com suíte própria
  de autoteste automatizada na CI (`7/7` cenários).

**Negativas e limites**

- As referências históricas em relatórios e ADRs anteriores (`ADR-0018`, `ADR-0019`,
  `ADR-0020`, `virtio-pci-modern-pr-{a,b,c}.md`) continuam mencionando os nomes vigentes na
  época de cada incremento como registro histórico fiel; a evolução para `vvdi` é apontada
  por referência cruzada a este ADR.
- As dívidas técnicas A-3, D-6 e D-7 permanecem abertas para tratamento dedicado e estão
  registradas em [`../reports/f7/vvdi-debt.md`](../reports/f7/vvdi-debt.md).

## Alternativas descartadas

- **Renomear tipos e constantes do protocolo (`virtqueue` → `vvdi_queue`,
  `VIRTIO_F_VERSION_1` → `VVDI_F_VERSION_1`).** Violaria `VN-NAMES-0001` §4 e dificultaria a
  auditoria linha a linha contra a especificação VirtIO 1.2.
- **Remover ou reescrever `kernel/arch/x86_64/virtio*.zig` no mesmo PR.** Misturaria mudança
  estrutural de código legado com uma migração que deve ter alteração funcional zero.
- **Corrigir A-3, D-6 ou D-7 junto com a renomeação.** Misturaria alteração comportamental de
  erro/MMIO/linker na mesma revisão que troca caminhos e prefixos de log, comprometendo a
  rastreabilidade de regressões.
