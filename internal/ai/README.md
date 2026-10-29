# IA — entrada mínima para agentes

**Fonte normativa única:** [AGENTS.md](../../AGENTS.md). Leia-o antes de qualquer alteração. Este diretório não mantém cópias das regras.

## Leitura sob demanda

1. Leia `AGENTS.md` e inspecione `git status`, código e testes afetados.
2. Consulte **apenas** as fontes necessárias: `docs/specs/` (contratos), `docs/adr/` (decisões), `docs/standards/` (convenções), `docs/testing/` (validação) e `docs/roadmap/phase-status.md` (estado declarado, sujeito a verificação).
3. Confirme `zig version` (alvo: 0.17.0); implemente o menor incremento real com tratamento de erros e testes negativos.
4. Execute `zig build`, `zig build test` e testes QEMU aplicáveis; não invente resultados nem confunda proposta, implementação e validação.
5. Reporte: **objetivo, implementação, arquivos, validação, desempenho medido, limitações e próxima etapa**.
6. Preserve mudanças existentes; não publique ou altere remotamente sem autorização específica.

## Arquivo histórico

Os prompts redundantes foram preservados integralmente em `restal/internal/ai/`:
- [engineering-prompt.md](../../restal/internal/ai/engineering-prompt.md)
- [start-development.md](../../restal/internal/ai/start-development.md)

**Não carregar `restal/` automaticamente no contexto de agentes.** Consulte o arquivo apenas para auditoria ou recuperação. O conteúdo arquivado não é uma segunda fonte normativa.
