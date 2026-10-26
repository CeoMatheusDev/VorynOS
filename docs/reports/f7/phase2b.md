# Phase 2b — Contiguous Virtqueue + DMA Virtual Window

**State:** IMPLEMENTED — locally compiled and tested; **NÃO VALIDADO**: hardware real x86_64 com NIC.

## Objetivo

Implementar o wire layout de split-virtqueue visível para o dispositivo (`DeviceQueue`) e uma janela DMA virtual monotônica (`KernelWindow`), mantendo os drivers VirtIO e a transport network fora do escopo. Esta fase completa a base para filas device-visible sem tocar no modelo de dispositivo real.

## O que foi implementado

### `kernel/arch/x86_64/virtio.zig`

- `QueueLayout` com offsets e tamanhos verificados (`splitQueueLayout`).
- `splitQueueLayout(size)`: calcula `descriptor_offset=0`, `available_offset=16*size`, `used_offset=4096`, `total_size` alinhado a 4096.
- `DeviceQueue.init(memory, layout)`: válida o layout, alinhamento 4096, zeroiza a memória.
- `deviceAddresses(layout, physical_base)`: devolve endereços de descriptor/available/used.
- `DeviceQueue.setDescriptor/publish/takeUsed`: acesso atômico aos índices e escrita de descritores.
- Novos testes: layout contíguo, escala, inicialização de heads, exposição do wire, recusa de layouts inválidos e cheio.

### `kernel/arch/x86_64/paging.zig`

- `level1_count` aumentado de 32 para 64 (64 MiB de tabela L1).
- `mapKernelDataPage(virtual, physical)`: mapping com `Flags.no_execute` para buffers DMA.
- `reserveKernelRange(virtual, length)`: reserva tabelas de nível 1 antes da criação dos espaços de endereço de processo.
- `unmapKernelPage(virtual)`: remove a PTE e invoca `invlpg`; anota que shootdown multi-CPU não está disponível.
- `translate`/`translateIn`: tradução em espaço kernel e processo.
- Quatro novos testes: reserva de range, rejeição de ranges inválidos, dessan mapping, e compartilhamento com espaço de processo.

### `kernel/memory/dma.zig`

- `virtual_window_base = 0x4000_0000`, `virtual_window_size = 64 MiB`, `virtual_window_pages`.
- `Window(pages)`: alocador monotônico com bitmap e `std.atomic.Value` lock.
- `map(buffer)`: traduz physical → virtual através do mapper; falha rollback em erro.
- `unmap(mapped)`: limpa PTE e bitmap; **não recicla** endereço virtual (sem shootdown).
- `KernelWindow = Window(virtual_window_pages)`: instância global.
- `initWindow(mapper)`: instala o mapper e reseta a window.
- `mapVirtual` / `unmapVirtual` camadas superiores.
- Testes com `MockMapper`: mapeamento, dessan mapping, rollback, recusa de buffers inválidos, exaustão e monotonicidade (endereço livre não reutilizado).

### `kernel/main.zig`

- `installDma()`: chama `dma.initWindow` com `mapDmaPage`/`unmapDmaPage`.
- `probeDmaWindow()`: aloca página física, mapeia pela DMA window, escreve `0xA5`/`0x5A` nos extremos, traduz e verifica; emite `[VNK] dma: window map probe ok phys=0x... virt=0x...`.
- `probeVirtqueueLayout()`: usa `virtio.splitQueueLayout` e `DeviceQueue.init` com `virtqueue_storage` estático; emite `[VNK] virtio: split queue layout ok desc=... avail=... used=... size=...`.
- `virtqueue_storage: [8192]u8 align(4096)`: buffer estático para o probe.

## Comandos de validação

```bash
# Formatação
zig fmt kernel/arch/x86_64/virtio.zig kernel/arch/x86_64/paging.zig kernel/memory/dma.zig kernel/main.zig kernel/arch/x86_64/root.zig

# Testes host (400/400 passed)
zig build test --cache-dir /tmp/voryn-phase2b-cache --summary all

# Compilação do kernel
zig build --cache-dir /tmp/voryn-phase2b-cache

# Teste QEMU (boot markers verificados)
zig build qemu-test --cache-dir /tmp/voryn-phase2b-cache
```

## Limitações

- **Dispositivo-visible:** `DeviceQueue` é um layout de wire em memória contígua; não programa um dispositivo real nem acessa BARs PCI.
- **DMA virtual:** janela monotônica — `unmap` não recicla endereços virtuais porque não há shootdown de TLB multi-CPU.
- **Sem driver de NIC:** `virtio-net`/`virtio-blk` permanecem stubs compilados mas sem init/RX/TX.
- **PCI limitado:** enumeração função 0 apenas, match `1af4:1001`, BAR0 somente; sem command register, bus-master, MSI.
- **Sem IOAPIC/MSI-X:** routing de dispositivo ausente.
- **`physical.Manager`:** sem sincronização; alocação DMA deve ser serializada pelo chamador.
- **Sem IOMMU/DMA isolation:** endereços físicos programados diretamente no dispositivo.

## Próximas etapas (não nesta fase)

- Implementar `virtio-net`/`virtio-blk` init/RX/TX reais.
- Habilitar ECAM completo, capabilities, MSI-X, BARs.
- Rotear interrupções via IOAPIC/MSI-X.
- Cross-CPU TLB shootdown.
- Janela DMA reciclavel após shootdown.

## Evidência numérica

- `zig build test`: 400/400 tests passed (incluindo 22 kernel-tests, 50 arch-tests).
- `zig build qemu-test`: todos os checks passados; marcadores `[VNK] dma: window map probe ok` e `[VNK] virtio: split queue layout ok` presentes no log de boot.
- `zig build`: kernel image links com sucesso.