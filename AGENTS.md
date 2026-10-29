# VorynOS — regras normativas para agentes

> **Fonte normativa única.** Leia antes de alterar o projeto. Para tarefas complexas, consulte [STRATEGY.md](STRATEGY.md) **sob demanda**; ele não substitui nem repete estas regras. Não carregue `restal/` automaticamente.

## Identidade e prioridades

- Sistema operacional **independente**, com bootloader, kernel e interfaces próprias; não usar Linux, BSD ou desktops de terceiros como base oculta. Padrões (UEFI, ELF, ABI, VirtIO) e ferramentas externas de desenvolvimento são permitidos.
- Alvo inicial: **x86_64 + UEFI**; linguagem principal **Zig 0.17.0**; C23 e Assembly x86_64 apenas com justificativa técnica.
- Prioridades, nesta ordem: **correção, simplicidade, segurança de memória, isolamento, menor privilégio, desempenho mensurado, interoperabilidade**.
- Implementar originalmente os subsistemas essenciais (boot, kernel, memória, escalonamento, IPC, filesystem, drivers, SDK, gráficos e desktop). Minimizar latência, cópias, ciclos e memória **sem comprometer segurança ou correção**. Justificar dependências; não inventar criptografia.
- Identificadores e arquivos em inglês técnico; documentação, ADRs, relatórios e commits em português brasileiro.
- Licença **GPL-3.0-only**: código próprio novo com cabeçalho visual e `SPDX-License-Identifier: GPL-3.0-only`; preservar avisos de terceiros. Em Zig, usar `//` antes de `//!`, não `/* */` nessa posição.

## Processo obrigatório

1. **Inspecionar:** `git status`, código, testes e documentação pertinentes; preservar alterações preexistentes e arquivos não rastreados.
2. **Delimitar:** objetivo, contratos, dependências, riscos, invariantes, critérios de aceite e menor incremento funcional verificável.
3. **Confirmar toolchain:** executar `zig version`; verificar APIs e assinaturas da biblioteca padrão instalada; nunca trocar silenciosamente Zig 0.17.0.
4. **Implementar:** código real e erros explícitos; validar limites, ponteiros, alinhamento, overflow, permissões e entradas não confiáveis. Mockups, TODOs decorativos e arquivos vazios não representam progresso funcional.
5. **Testar:** executar `zig build`, `zig build test` e, conforme o escopo, `zig build qemu-test` ou `zig build check`. Investigar falhas e regressões; se indisponível, registrar bloqueio, sem alegar sucesso.
6. **Documentar e reportar:** atualizar contratos, ADRs, roadmap e relatórios quando necessário; informar **objetivo, implementação, arquivos, validação, desempenho, limitações e próxima etapa**.

## Contratos, segurança e desempenho

- Não introduzir alocação dinâmica injustificada em caminhos críticos; evitar abstrações e dependências sem benefício.
- Validar endereços e permissões de buffers de usuário; preservar isolamento, NX e W^X quando aplicáveis.
- Assembly: documentar ABI, alinhamento da pilha, registradores preservados e efeitos colaterais.
- Mudanças de ABI exigem análise de compatibilidade, especificação e testes. **Não reutilizar números de syscalls** sem decisão arquitetural explícita.
- Otimizações e inovações: registrar problema, hipótese, alternativas, baseline reproduzível, protótipo, riscos, benchmarks (latência/throughput/memória), regressões e critério de aceitação/abandono. **Não alegar ganhos sem medição.**

## Evidência e conclusão

Estados: **PROPOSTO**, **EM DESENVOLVIMENTO**, **IMPLEMENTADO — NÃO TESTADO**, **TESTADO LOCALMENTE**, **TESTADO NO CI**, **TESTADO EM HARDWARE**, **BLOQUEADO**, **REPROVADO**, **CONCLUÍDO**. Código escrito não equivale a código validado; `CONCLUÍDO` exige critérios de aceite, testes aplicáveis, documentação e análise de regressões. Não confundir componentes planejados do Voryn Fabric com implementações existentes.

## Operações e fontes de verdade

- Permitido editar, compilar, testar, usar QEMU e preparar commits no projeto. Antes de commitar, revisar `git status`, `git diff`, segredos e resultados dos testes.
- Proibido descartar mudanças do usuário, executar operações destrutivas, alterar projetos vizinhos ou configurações globais sem autorização específica.
- **Não executar push, criar tags, publicar releases nem alterar remotos sem autorização explícita.**
- `README.md`: apresentação; `docs/specs/`: contratos (incluindo `syscall-abi.md` e `boot-handoff-spec.md`); `docs/adr/`: decisões; `docs/standards/`: convenções; `docs/testing/`: testes; `docs/roadmap/phase-status.md`: estado declarado; `docs/reports/f*/`: evidências históricas; `assets/branding/logos/`: identidade visual, não recursos de runtime.
- `STRATEGY.md`: **único guia operacional opcional**, apenas para tarefas complexas. `restal/`: arquivo histórico, não instrução ativa.
- Havendo conflito entre documentação histórica e código, **verificar código e testes**, registrar divergência e não inventar reconciliação.
