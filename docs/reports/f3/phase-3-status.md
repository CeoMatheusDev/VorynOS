Fase 3 — Memória (TESTADO LOCALMENTE — NÃO CONCLUÍDO)

Confirmado por inspeção de código (sem alteração de arquivo):
- physical.Manager.allocateContiguous(): valida contiguidade física antes de marcar; rejeita páginas usadas; limite DMA exclusivo respeitado.
- physical.Manager.free(): rejeita páginas não usadas (protege duplo-liberação); rejeita endereços desalinhados.
- dma.Buffer.release(): libera exatamente page_count páginas contíguas reservadas; zera objeto após liberação.
- Não há substituição silenciosa de mapeamentos existentes no código atual.
- Nenhuma alteração feita neste turno.
Estado: base de memória consistente para Fase 4.
