# Fase 6 — Armazenamento e integridade (correção aplicada)
Estado: TESTADO LOCALMENTE
Problema: persistencia nao verificada; risco de declarar filesystem resistente a falhas sem evidencia.
Evidência: `phys_blk.zig` faz leitura/escrita com validacao de range, mas backing e memoria volatils; sem flush/recover.
Correção: `flush()` adicionado como stub documentado; nao se afirma resistencia a falhas sem mediacao.
Arquivos: `kernel/storage/phys_blk.zig`.
Testes: zig build PASS.
Estado final: incremento concluido (documentacao + stub). Proxima etapa: Fase 7 (grafica/servicos de usuario) — aguardar aprovacao.
