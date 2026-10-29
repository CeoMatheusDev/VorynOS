# VorynOS — estratégia operacional de engenharia

> **Guia opcional para tarefas complexas.** Leia primeiro [AGENTS.md](AGENTS.md), que contém todas as regras obrigatórias. Este arquivo orienta a investigação e a tomada de decisões; **não deve ser carregado automaticamente em toda tarefa**. Não ler `restal/` salvo para recuperação ou auditoria histórica.

## Quando usar

Consultar para novos subsistemas, mudanças de arquitetura/ABI, regressões difíceis, otimizações, segurança, concorrência, memória, IPC, armazenamento e gráficos. Correções pequenas seguem apenas `AGENTS.md` e os contratos diretamente afetados.

## 1. Reconhecimento com contexto mínimo

- Ler `git status`, implementação e testes do componente; identificar o comportamento real, sem presumir que o roadmap descreve o HEAD.
- Abrir **somente** documentos relevantes: `docs/architecture/overview.md` para arquitetura; `docs/specs/boot-handoff-spec.md` para boot; `docs/specs/syscall-abi.md` para syscalls; ADRs pertinentes; `docs/testing/testing-strategy.md` para validação.
- Consultar `docs/roadmap/phase-status.md` para estados declarados; `docs/reports/` apenas para evidência histórica. Não carregar diretórios inteiros por padrão.
- Contexto Voryn Fabric: VNB boot, VNK kernel, VNH hardware, VNM memória, VNT tarefas, VNX IPC, VNC capacidades, VND drivers, VSN serviços. **Confirmar quais existem no código.** Marcos F0–F10 não implicam conclusão por numeração.

## 2. Análise e decisão

1. Formular o problema observável e os critérios de aceite.
2. Mapear interfaces, ownership, privilégios, estados, concorrência, invariantes e modos de falha.
3. Avaliar a implementação atual e alternativas viáveis; estimar custos de memória, CPU, latência, cópias e acoplamento.
4. Para mudanças estruturais, registrar decisão e riscos em ADR quando aplicável.
5. Escolher o **menor incremento real e reversível** que permita validação.

## 3. Implementação e revisão

- Preservar contratos e compatibilidade; revisar limites, overflow, alinhamento, ciclo de vida, sincronização, permissões e limpeza em erro.
- Separar lógica pura de mecanismos dependentes de hardware quando isso simplificar testes e evitar duplicação.
- Evitar refatorações amplas, dependências e abstrações especulativas. Não implementar funcionalidades futuras sem escopo explícito.
- Criar testes positivos, negativos e de exaustão pertinentes; verificar regressões em consumidores do contrato.

## 4. Medição e auditoria

- Desempenho: baseline, hipótese, ambiente, configuração, carga, métricas (latência, throughput, memória), repetição, comparação e decisão. Diferenciar QEMU/TCG, KVM e hardware físico.
- Segurança: identificar fronteiras de confiança, entradas não confiáveis, direitos de capacidade, isolamento, W^X/NX e falhas de revogação/ownership.
- Concorrência: testar preempção, bloqueio/despertar, timeout, ordenação, starvation e comportamento em saturação quando aplicável.
- Falhas: investigar causas, não mascarar testes; registrar limitações e incertezas.

## 5. Entrega

Relatar de forma concisa:
1. **Objetivo e escopo**.
2. **Implementação e arquivos**.
3. **Validação**: comandos, resultados e ambiente; SHA testado quando disponível.
4. **Desempenho**: números medidos ou “não medido”.
5. **Limitações, riscos e próxima etapa**.

Se uma validação não puder ser executada, indicar claramente o bloqueio. Não converter proposta em funcionalidade concluída.

## Arquivo histórico

Os prompts anteriores estão preservados em `restal/internal/ai/`. Não são fontes normativas e não devem entrar no contexto de execução rotineira.
