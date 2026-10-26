Fase 6 — DMA virtual provisório + descritor físico VirtIO (TESTADO LOCALMENTE):

Adiciona `MappedBuffer` e `mapVirtual/unmapVirtual` em `kernel/memory/dma.zig`, mapeamento identidade provisório para host, validação de ponteiro, reset explícito dos campos, e teste determinístico que valida alocação DMA -> mapeamento virtual -> endereço físico no descritor. Não envolve rede nem transmissão Ethernet.

- zig build test: aprovado
- zig build: aprovado
- zig build qemu-test: aprovado

Estado: IMPLEMENTADO — NÃO TESTADO EM HARDWARE, não declarado CONCLUÍDO.
