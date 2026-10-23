# VorynOS — instruções para agentes de engenharia

> **Fonte normativa única.** Este arquivo fica na raiz do repositório, ao lado de `README.md` e `LICENSE`. Leia-o antes de modificar qualquer componente. Os prompts de `internal/ai/` são auxiliares; em caso de divergência, prevalecem estas instruções e as especificações técnicas aplicáveis.

## Missão e limites

Desenvolver um sistema operacional **independente**, com kernel, bootloader e interfaces próprias. VorynOS não é uma distribuição Linux, fork de Windows/BSD ou interface executada sobre outro kernel. Ferramentas de desenvolvimento externas são permitidas. Não confunda componentes planejados na arquitetura Voryn Fabric com implementações existentes.

- Plataforma inicial: **x86_64 + UEFI**; linguagem principal **Zig 0.17.0**; C23 e Assembly x86_64 somente quando tecnicamente justificados.
- Prioridades: correção, simplicidade, segurança de memória, isolamento, menor privilégio, desempenho mensurado e interoperabilidade.
- Identificadores e nomes de arquivo: inglês técnico; documentação, relatórios, ADRs e mensagens de commit: português brasileiro.
- Licença: **GPL-3.0-only**. Código próprio novo deve ter cabeçalho visual e `SPDX-License-Identifier: GPL-3.0-only`; preservar avisos de terceiros. Em Zig, usar comentários de linha `//` antes de `//!`, nunca bloco `/* */` nessa posição.

## Fluxo obrigatório de trabalho

1. **Inspecionar:** ler `git status`, arquivos relevantes, testes e documentação; preservar alterações preexistentes e arquivos não rastreados.
2. **Delimitar:** identificar objetivo, interfaces, dependências, riscos, critérios de aceite e o menor incremento verificável.
3. **Implementar:** entregar código real e tratamento explícito de erros; validar limites, ponteiros, alinhamento, overflow, privilégios e entradas não confiáveis.
4. **Verificar toolchain:** executar `zig version`; confirmar APIs e assinaturas na biblioteca padrão da versão instalada. Não substituir silenciosamente Zig 0.17.0.
5. **Compilar e testar:** executar `zig build`, `zig build test` e, quando aplicável, `zig build qemu-test` ou `zig build check`; registrar comandos e resultados reais. Se indisponíveis, declarar bloqueio.
6. **Corrigir e repetir:** investigar falhas e regressões; não contornar testes nem inventar sucesso.
7. **Documentar:** atualizar especificações, ADRs, `docs/roadmap/phase-status.md` e relatórios quando o escopo exigir. Não declarar funcionalidades planejadas como prontas.
8. **Reportar:** objetivo, implementação, arquivos, validação, desempenho medido (quando houver), limitações e próxima etapa.

## Regras de implementação

- Nenhum mockup, TODO decorativo ou arquivo vazio deve representar progresso funcional.
- Não adicionar alocação dinâmica em caminhos críticos sem justificativa; evitar abstrações e dependências desnecessárias.
- Verificar endereços e permissões de memória de usuário antes de acessar buffers; respeitar isolamento de processos, NX e W^X quando aplicáveis.
- Em Assembly, documentar ABI, alinhamento de pilha, registradores preservados e efeitos colaterais.
- Não criar criptografia própria. Verificar licença, origem e compatibilidade de qualquer código de terceiros.
- Alterações de ABI exigem análise de compatibilidade, atualização de especificação e testes; **não reutilizar números de syscalls** sem decisão arquitetural explícita.
- Inovações exigem hipótese, protótipo, comparação, riscos, medição e critério de aceitação/abandono.

## Estados e conclusão

Estados documentados: **PROPOSTO**, **EM DESENVOLVIMENTO**, **IMPLEMENTADO — NÃO TESTADO**, **TESTADO LOCALMENTE**, **TESTADO NO CI**, **TESTADO EM HARDWARE**, **BLOQUEADO**, **REPROVADO**, **CONCLUÍDO**. Implementação não implica funcionamento verificado. Só marcar **CONCLUÍDO** quando os critérios de aceite, testes aplicáveis, documentação e análise de regressão forem atendidos.

## Segurança operacional e Git

- Pode editar, compilar, testar, usar QEMU e preparar commits dentro do projeto.
- Não executar comandos destrutivos, descartar alterações do usuário, modificar projetos vizinhos ou configurações globais sem autorização específica.
- Antes de commitar: revisar `git status`, `git diff`, segredos e resultados dos testes.
- **Não executar push, criar tags, publicar releases ou alterar repositórios remotos sem autorização explícita.**
- Não alegar compilação, teste, desempenho ou suporte a hardware sem evidência real.

## Fontes de verdade e organização

- `README.md`: apresentação e instruções públicas.
- `docs/specs/`: contratos técnicos, incluindo `syscall-abi.md` e `boot-handoff-spec.md`.
- `docs/adr/`: decisões arquiteturais; `docs/standards/`: convenções.
- `docs/roadmap/phase-status.md`: estado por marco, separado de propostas futuras.
- `docs/testing/`: estratégia de validação; `docs/reports/f*/`: relatórios históricos por fase.
- `internal/ai/`: prompts operacionais auxiliares, sem cópia concorrente deste arquivo.
- `assets/branding/logos/`: imagens de identidade visual do repositório; recursos de runtime devem ter fluxo de empacotamento próprio.

**Atenção:** em caso de conflito entre documentação histórica e código atual, verificar o código e os testes antes de alterar contratos. Documentar a divergência, sem inventar uma reconciliação.
