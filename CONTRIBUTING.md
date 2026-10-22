# Contribuindo com o VorynOS

Obrigado pelo interesse em contribuir. O VorynOS é um projeto open source em fase inicial, com foco em implementação original, verificável e eficiente.

## Antes de começar

1. Verifique issues e discussões existentes para evitar trabalho duplicado.
2. Descreva o problema e o resultado esperado antes de alterações arquitetônicas extensas.
3. Mantenha cada contribuição pequena e focada.
4. Não introduza dependências de runtime sem justificar custo, licença, segurança e manutenção.

## Regras de código

- Priorize Zig (versão-alvo 0.17.0); utilize C23 e Assembly somente quando justificado.
- Verifique APIs na toolchain real. Não presuma compatibilidade entre versões Zig.
- Trate erros explicitamente, valide limites e evite comportamento indefinido.
- Documente invariantes, contratos ABI e decisões relevantes.
- Inclua testes e instruções para reproduzi-los quando possível.
- Não afirme sucesso de compilação ou execução sem evidências.

## Licença, autoria e proveniência

- Ao contribuir com código original para áreas cobertas pela licença principal, você concorda em disponibilizá-lo sob **GPL-3.0-only**, salvo acordo explícito em contrário.
- Adicione `SPDX-License-Identifier: GPL-3.0-only` a novos arquivos de código próprios quando aplicável.
- Preserve avisos de copyright e licenças de terceiros.
- Envie apenas conteúdo que você tem direito de licenciar.
- Informe dependências externas, suas licenças e a origem de trechos incorporados.
- Se usar IA para auxiliar a contribuição, revise o resultado, verifique a origem de conteúdo incorporado e assuma responsabilidade técnica pelo código enviado.
- Não presuma que uma contribuição transfere direitos autorais ao mantenedor; **não há CLA de cessão automática** estabelecido aqui.

## Pull requests

Inclua:
- Objetivo e justificativa.
- Arquivos e interfaces afetados.
- Comandos de build/teste realmente executados e resultados.
- Limitações, riscos e eventuais incompatibilidades.

Alterações de kernel, MMU, interrupções, boot, ABI, drivers, parsers e segurança exigem revisão humana antes de integração.

## Conduta e segurança

Mantenha discussões técnicas respeitosas. Para vulnerabilidades, siga [SECURITY.md](SECURITY.md) em vez de abrir uma issue pública com detalhes exploráveis.

## Marca

Forks e redistribuições são permitidos nos termos da licença aplicável. Não apresente versões modificadas como lançamentos oficiais do VorynOS nem implique endosso inexistente.
