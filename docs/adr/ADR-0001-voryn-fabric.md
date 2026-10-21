# ADR-0001 — Voryn Fabric

| Campo | Valor |
|-------|-------|
| **Estado** | RASCUNHO (DRAFT) — aceito como direção de trabalho, não como arquitetura congelada |
| **Data** | 2026-10-21 |
| **Autoria** | Engenharia VorynOS |
| **Substitui** | — |
| **Substituído por** | — |

## 1. Contexto

O VorynOS precisa de uma arquitetura de sistema que atenda a usuários
domésticos, gamers, desenvolvedores, profissionais, criadores de conteúdo,
usuários avançados e aplicações com inteligência artificial, sem depender de
kernel externo em execução nativa.

Restrições estruturantes:

- O kernel deve conter **mecanismos privilegiados mínimos**; políticas
  complexas pertencem a serviços isolados.
- A segurança deve ser construída por capacidades, com menor privilégio e
  revogação.
- Drivers complexos não podem derrubar o sistema; o objetivo é isolamento de
  falhas.
- O desempenho precisa ser medido, não prometido.

## 2. Direcionadores

- **D1** Reduzir a superfície privilegiada do kernel.
- **D2** Permitir isolamento de falhas em drivers e serviços.
- **D3** Controlar a comunicação entre processos de forma explícita e
  auditável.
- **D4** Manter o caminho crítico (syscall, troca de contexto, IPC) previsível
  e de baixo custo.
- **D5** Evitar abstrações prematuras e dependências desnecessárias.

## 3. Opções consideradas

### Opção A — Monólito modular

Um único kernel com subsistemas internos bem separados, tudo em modo kernel.

- Prós: simplicidade, caminho rápido, fácil de depurar.
- Contras: uma falha de driver derruba o sistema; a superfície privilegiada é
  grande; políticas infiltram o kernel.

### Opção B — Microkernel com serviços em user mode

Tudo que não é mecanismo mínimo vira um processo de usuário.

- Prós: isolamento máximo, superfície privilegiada mínima.
- Contras: custo de IPC em todo caminho crítico, complexidade de
  inicialização e de recuperação, risco de overhead desproporcional para
  um sistema que ainda não tem IPC definido.

### Opção C — Voryn Fabric (híbrido modular)

**Escolhida.** Mecanismos mínimos no kernel; políticas e drivers
complexos em processos isolados, comunicando-se por canais tipados com
transferência de capacidades; escrita em Zig, com C23 e Assembly apenas onde
houver justificativa técnica.

## 4. Decisão

Adotar o **Voryn Fabric**: um modelo híbrido modular com nove componentes.

| Sigla | Nome | Escopo | Onde executa |
|-------|------|--------|--------------|
| VNB | Voryn Native Boot | Loader UEFI, fronteira firmware/kernel | Firmware |
| VNK | Voryn Nucleus Kernel | Mecanismos privilegiados mínimos | Kernel |
| VNH | Voryn Hardware Nexus | Descoberta e interface de hardware | Kernel (dados) / serviço (política) |
| VNM | Voryn Nexus Memory | Memória física, virtual, alocadores, proteções | Kernel |
| VNT | Voryn Task Fabric | Tarefas, escalonamento, afinidade | Kernel |
| VNX | Voryn Exchange | Comunicação entre processos | Kernel (mecanismo) / serviços (política) |
| VNC | Voryn Capability Fabric | Capacidades, revogação, auditoria | Kernel |
| VND | Voryn Device Fabric | Drivers, isolamento de falhas | Kernel (registro) / user mode (driver) |
| VSN | Voryn Service Node | Ciclo de vida, supervisão, recuperação | User mode |

### 4.1 Fronteiras de confiança

1. **Firmware → VNB → VNK**: única fronteira com código de terceiros em
   execução privilegiada. O contrato é uma estrutura versionada, validada
   nos dois lados, com verificação de magic, versão e coerência.
2. **VNK → serviços**: o kernel entrega capacidades, nunca ponteiros
   globais nem acesso irrestrito.
3. **Driver → VNK**: um driver em processo isolado recebe capacidades
   específicas de dispositivo; exceções existem apenas para o caminho de
   bootstrap (VNH mínimo).
4. **Aplicação → VNX**: mensagens tipadas, com esquema versionado, limites
   de recurso e transferência explícita de capacidades.

### 4.2 Onde a política NÃO entra

- Escalonamento: VNT implementa o mecanismo (filas, contexto, prioridade);
  a política (latência interativa, perfis de jogo) fica em VSN.
- Memória: VNM implementa alocadores e proteções; VSN decide quotas.
- Armazenamento: VFSX implementa semântica de arquivos; VSN decide cache,
  quotas e políticas de retenção.

## 5. Justificativa

A Opção C é escolhida porque satisfaz D1 e D2 sem pagar o custo de D4 que a
Opção B impõe no estágio atual: o sistema ainda não possui IPC definido, e
colocar todo o sistema em user mode antes de existir um canal de comunicação
eficiente criaria um beco sem saída de desempenho.

O risco da Opção C é Known: a fronteira entre "mecanismo" e "política" pode
ser mal desenhada e concentrada no kernel. Mitigação: cada regra que entrar
no kernel precisa de uma justificativa registrada, e o critério de revisão é
"esta regra é necessária para manter a segurança ou a corretude do mecanismo,
ou poderia viver em um serviço com a mesma garantia?".

## 6. Custos e riscos

| Risco | Impacto | Mitigação |
|-------|---------|-----------|
| Superfície privilegiada excessiva | Alto | Revisão por ADR; regra no kernel exige justificativa |
| IPC com custo alto | Médio | Medir latência de VNX antes de decidir políticas de escalonamento |
| Isolamento de driver incompleto | Alto | Exceções de bootstrap documentadas e auditáveis |
| Complexidade de inicialização | Médio | VSN com dependências explícitas e reinício supervisionado |
| "Voryn Fabric" como nome sem conteúdo | Alto | Cada componente precisa de implementação e critério de aceite |

## 7. Consequências

- O repositório passa a organizar-se por componente, e não por camada
  horizontal.
- Toda fronteira nova precisa de um contrato versionado.
- O kernel não cresce por conveniência: cresce por justificativa.
- O desempenho de IPC e de troca de contexto precisa ser medido antes de
  qualquer afirmação sobre adequação a jogos.

## 8. Estado de validação

Nenhum dos componentes além de VNB e do núcleo inicial de VNK está
implementado. Este documento é **RASCUNHO**: a arquitetura será reavaliada
quando VNM, VNX e VNC existirem, porque a forma final depende de decisões
que ainda não foram tomadas (formato de mensagem, modelo de capacidade,
granularidade de page table).

## 9. Perguntas em aberto

1. O canal de VNX será orientado a mensagem (fila por par) ou baseado em
   registro compartilhado com notificação? Impacto direto na latência de
   comunicação entre serviços.
2. As capacidades do VNC serão derivadas do processo (tipo Rust) ou referências
   a tabelas paginadas (tipo Capsicum)? Impacto direto no custo de uma syscall.
3. O VND roda drivers em user mode desde o primeiro driver, ou apenas a
   partir de um subconjunto mínimo? Impacto direto no marco F7.
