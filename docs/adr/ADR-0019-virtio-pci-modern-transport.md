# ADR-0019 — Transporte VirtIO PCI moderno: MMIO injetado, BAR validado e negociação real

- **Estado:** IMPLEMENTADO — TESTADO LOCALMENTE (host); validação de QEMU na CI do PR #12
- **Data:** 2026-10-26
- **Escopo:** `kernel/drivers/virtio/{mmio,transport,pci_transport}.zig`,
  `kernel/arch/x86_64/pci.zig`, `kernel/main.zig`, `build.zig`,
  `tests/integration/boot-qemu.sh`
- **Especificação de referência:** VirtIO 1.x, seções 2.4, 3.1.1, 4.1.2, 4.1.4.3,
  4.1.4.4 e 4.1.5
- **Continua:** [ADR-0018](ADR-0018-virtio-pci-modern-subsystem.md) (fundação)
- **Continua em:** [ADR-0020](ADR-0020-split-virtqueue.md) (virtqueue e `DRIVER_OK`)
- **Nota:** a afirmação abaixo de que "não existe função que escreva `DRIVER_OK`" descreve
  este incremento; o ADR-0020 acrescenta `markQueueReady`/`activate`, com a fechadura que
  exige uma fila programada antes do bit 2.
- **Relatório:** [`../reports/f7/virtio-pci-modern-pr-b.md`](../reports/f7/virtio-pci-modern-pr-b.md)

## Contexto

O PR A entregou o que é puro: tipos, identificadores, máquina de estados, negociação de
features e interpretação das capabilities. Ficaram de fora, por decisão, o acesso à
memória do dispositivo, o mapeamento de BAR e a conversa real com o hardware. O
validador de BAR de `caps.build` recebia `null` no kernel.

O PR B precisa fechar essa distância sem repetir duas coisas que o projeto já tem:
não pode existir um segundo gerenciador de paginação (o kernel já tem
`paging.mapDevicePage` com `cache_disabled | no_execute`) e não pode existir uma
segunda cópia da lógica de configuração comum só para o hardware. Além disso, um
erro de ordenação aqui não aparece como falha de compilação: aparece como um
dispositivo anunciado como pronto que nunca respondeu.

## Decisão

### 1. MMIO é um módulo com validação própria, sobre um mapeador injetado

`mmio.zig` separa `Region` (faixa mapeada e validada), `Window` (faixa virtual
reservada) e `Bus` (acesso cru). O mapeamento físico é uma dependência:

```zig
pub const Mapper = struct {
    map: *const fn (virtual: u64, physical: u64) bool,
    unmap: *const fn (virtual: u64) void,
};
```

O kernel liga as duas funções a `paging.mapDevicePage` e `paging.unmapKernelPage`; os
testes ligam a uma plataforma simulada. `mmio.zig` **não** escreve em `CR3`, não cria
tabelas e não conhece `paging.zig`: o subsistema não pode depender de
`arch/x86_64/` sem criar uma segunda instância de módulo (a mesma restrição que
motivou a injeção de dependência do PR A).

### 2. A ordem das validações é parte do contrato

Uma faixa desmapeada responde `NotMapped` antes de comparar limites; um deslocamento
que começa fora da faixa responde `OutOfRange` antes da aritmética; transbordos são
detectados com `std.math.add`/`mul`, nunca com soma em `u64` que dá a volta. A
permissão de escrita é verificada depois do estado do mapeamento, para que a faixa
desmapeada não mude o erro conforme as permissões que tinha.

### 3. A janela é reservada com as tabelas, o BAR é mapeado na descoberta

A faixa virtual de 16 MiB em `0x6000_0000` é reservada em `buildPageTables`, antes dos
espaços de processo, porque `createAddressSpace` copia a tabela de nível 2. O BAR só é
mapeado quando o dispositivo é descoberto e as tabelas já estão ativas — nunca antes,
e nunca por um caminho que não seja `mapDevicePage`.

### 4. Nenhuma `struct` sobreposta ao MMIO

Confirmar o layout de uma `struct` Zig contra um bloco de registradores exige garantir
`packed`/`align`, ordem e volatilidade por campo. Em vez disso, cada registrador é
lido e escrito com o offset e a largura da especificação, e toda leitura passa pela
validação de faixa de `Region`. O custo é uma tabela de constantes; o benefício é que
um offset errado é um teste que falha, não uma struct que "quase" casa.

### 5. `Registers` é o contrato entre a sequência e o barramento

`transport.zig` conduz a 3.1.1 contra `Registers` — dez funções pequenas que o
transporte PCI implementa sobre MMIO e os testes implementam sobre memória. A sequência
não conhece offset, BAR, capability nem porta de I/O; o layout não conhece a ordem da
sequência.

### 6. O estado vem do dispositivo, e `DRIVER_OK` não existe

Toda escrita de status é validada por `status.transition` contra o valor **lido** e
confirmada por leitura imediata. `Device.status` é o último valor lido; não há cópia
local que possa divergir. Não existe função que escreva `DRIVER_OK`: a interface
termina em `FEATURES_OK`, e o teste prova pelo histórico de escritas do dispositivo
simulado que o bit 2 nunca foi tocado. A API de ativação entra junto com a programação
das virtqueues, que é o que a justifica.

### 7. O tamanho do BAR é medido, o BAR é validado antes do mapeamento

`pci.probeBarSizes` mascara o registrador do BAR sob o lock de configuração, lê de
volta, restaura o valor e calcula `~mask + 1`. O corpo (`probeBarSizesWith`) é o
mesmo no kernel e no teste, que o executa sobre uma imagem em memória; BAR de 64 bits mascara as duas metades.
`pci.barSupportsRegion` confere tipo, alinhamento, potência de dois e se a região cabe.
Uma capability que não caiba no BAR é recusada antes de qualquer acesso, e uma região
que o kernel não saiba mapear não derruba o dispositivo: `caps.build` a ignora e tenta
outra instância.

### 8. O alvo é explícito, e o legado não é conduzido

`bringUpVirtioDevices` só inicializa o primeiro `virtio-blk` com identificador moderno
(`0x1042`). Dispositivo transicional, outro tipo de dispositivo ou um segundo bloco
são registrados e ignorados. Não existe "primeiro vendor 0x1AF4 que aparecer":
escolher por vendor escolheria, num host real, o dispositivo errado.

### 9. O teste de boot exige o estado final, e falha no estado proibido

Além dos marcadores de cada etapa, `boot-qemu.sh` falha se qualquer linha de
`virtio-pci` trouxer `status=0xf` (DRIVER_OK). A ausência de `DRIVER_OK` deixa de ser
uma promessa do relatório e passa a ser uma condição do teste de integração.

## Consequências

**Positivas**

- O kernel conversa com o dispositivo de verdade: lê `device_feature`, publica
  `driver_feature`, lê o status e confirma `FEATURES_OK` no hardware emulado.
- A validação de MMIO, a sequência de inicialização e o layout da configuração comum
  rodam no host, sem hardware e sem port I/O — 36 testes novos no subsistema,
  mais a sonda de tamanho de BAR em `arch-tests`, exercitada sobre uma imagem de
  configuração em memória.
- O PR C tem a API de que precisa: `queueMaxSize`, `queueNotifyOffset`,
  `notifyAddress`, `queueAddresses` e `readDeviceConfig`.
- Um dispositivo malformado (capability fora do BAR, BAR de I/O, tamanho desconhecido,
  status que não confirma) produz erro nomeado com etapa, em vez de falso sucesso.

**Negativas e limites**

- O mapa de páginas da janela é estático (4096 páginas). É suficiente para os BARs do
  boot e evita um caminho de alocação dinâmica; um dispositivo com BAR maior que
  16 MiB não é mapeável por este incremento.
- Uma função por varredura e um BAR por dispositivo (ver o relatório, "Limitações").
- `probeBarSizes` escreve no espaço de configuração do dispositivo alvo. É o
  procedimento da especificação PCI e os valores são restaurados, mas é uma escrita em
  hardware durante o boot — documentada e restrita ao dispositivo já escolhido.
- Sem IOMMU, sem MSI-X, sem virtqueue: nada disso é anunciado como pronto.

## Alternativas descartadas

- **Reimplementar o mapeamento dentro de `mmio.zig`.** Criaria um segundo gerenciador
  de paginação, com atributos possivelmente diferentes dos de `paging.zig` — e o
  requisito de MMIO sem cache deixaria de ter uma única fonte.
- **Passar `paging.zig` como import para o subsistema.** Duplicaria `IrqSpinlock` e as
  tabelas por unidade de compilação, como já registrado no ADR-0018.
- **Declarar `extern struct` com `packed` sobre o BAR.** Layout e volatilidade
  dependeriam de detalhes do compilador para um contrato que já está escrito em
  offsets na especificação.
- **Mapear cada capability como uma faixa separada.** Um BAR pode ser mapeado uma vez
  e visto por partes; mapear cada capability repetiria páginas e criaria quatro fontes
  de verdade para o mesmo recurso.
- **Generalizar o `Bus` para "qualquer transporte".** O transporte MMIO direto
  (4.2) tem outro layout e entra quando existir um dispositivo que o use; uma
  abstração sobre dois casos não escritos seria uma aposta.
- **Escrever `DRIVER_OK` "para ver funcionar".** Exatamente o falso sucesso que o
  PR #10 registrou e o PR B precisa não repetir.
