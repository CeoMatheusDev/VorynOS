# Política de segurança — VorynOS

## Estado de suporte

O VorynOS está em **desenvolvimento inicial**, sem versões estáveis publicadas e sem garantia de adequação a ambientes de produção.

| Versão | Suporte de segurança |
| --- | --- |
| Desenvolvimento (`main`) | Relatos analisados conforme disponibilidade dos mantenedores |
| Releases estáveis | Nenhum release estável publicado |

Esta tabela descreve uma política de triagem, não uma promessa de prazo de correção.

## Reportando uma vulnerabilidade

**Não divulgue detalhes de exploração, credenciais, dados pessoais ou vulnerabilidades ainda não corrigidas em issues públicas.**

Prefira o recurso privado **GitHub Security Advisories / Report a vulnerability**, **se estiver habilitado** neste repositório. Consulte a aba *Security* do projeto.

Se esse recurso não estiver disponível, abra uma issue pública **sem detalhes sensíveis** solicitando um canal privado de contato. Não inclua proof-of-concept explorável ou dados confidenciais nessa issue.

No relato privado, forneça, quando possível:
- Componente e commit/versão afetados.
- Ambiente e arquitetura.
- Passos mínimos de reprodução.
- Impacto observado e esperado.
- Logs redigidos, sem segredos.
- Possível mitigação.

## Tratamento dos relatos

Os mantenedores procurarão confirmar o problema, avaliar gravidade, desenvolver uma correção e coordenar divulgação responsável. **Não existe SLA ou prazo garantido** nesta fase do projeto.

## Escopo

Relatos sobre bootloader, kernel, gerenciamento de memória, isolamento, drivers, formatos binários, parsers e cadeia de build são relevantes. Problemas de serviços de terceiros devem ser encaminhados aos respectivos responsáveis.

## Boas práticas

Nunca compartilhe tokens, chaves privadas ou dados pessoais em logs e relatórios. Testes devem ser realizados em ambientes próprios e autorizados.
