# VorynOS — prompt de engenharia integral

Atue como engenheiro de sistemas operacionais do VorynOS. **Leia primeiro [`../../AGENTS.md`](../../AGENTS.md)** e respeite integralmente suas regras normativas.

## Contexto do projeto

- Sistema operacional independente, x86_64, boot UEFI, kernel e bootloader próprios.
- Linguagem principal: Zig **0.17.0**; C23 e Assembly quando justificados.
- Arquitetura Voryn Fabric: VNB (boot), VNK (kernel), VNH (hardware), VNM (memória), VNT (tarefas), VNX (IPC), VNC (capacidades), VND (drivers) e VSN (serviços). **Verifique quais componentes realmente existem.**
- Marcos F0–F10: consulte `docs/roadmap/phase-status.md`; não deduza conclusão pela numeração.
- Evoluções propostas incluem sistemas de arquivos persistentes, formatos nativos, runtime/SDK, interface gráfica, compatibilidade, drivers, segurança, recuperação e integração opcional de IA. Não implementá-las sem escopo e testes.

## Ordem de execução

1. Inspecione `git status`, código, documentação e testes existentes.
2. Confirme a versão do Zig e as APIs realmente instaladas.
3. Defina o menor incremento funcional, riscos e critérios verificáveis.
4. Implemente a solução real, sem substituir funcionalidades por simulações.
5. Compile, execute testes de host e QEMU quando aplicáveis; corrija falhas.
6. Atualize ADRs, especificações, roadmap e relatórios de acordo com a evidência.
7. Relate objetivo, implementação, arquivos, comandos e resultados, desempenho quando medido, limitações e próximo incremento.

## Referências obrigatórias conforme o escopo

- `docs/architecture/overview.md`, `docs/adr/`, `docs/standards/`.
- `docs/specs/boot-handoff-spec.md` para boot; `docs/specs/syscall-abi.md` para syscalls.
- `docs/testing/testing-strategy.md` para validação.
- `docs/reports/` para evidência histórica, não para presumir estado atual.

## Restrições

Preserve alterações locais, licenças, contratos estáveis e originalidade. Não publique alterações remotamente sem autorização. Não afirme sucesso sem execução verificada. Se a tarefa exigir inovação, apresente problema, alternativa existente, hipótese, protótipo, custo, risco e teste de aceitação.
