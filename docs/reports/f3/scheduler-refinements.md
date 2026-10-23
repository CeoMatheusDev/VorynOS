# Relatório de Desenvolvimento F3 — Refinamentos no Scheduler

## Objetivo

Implementar refinamentos no scheduler do kernel VorynOS, adicionando suporte a quantum de tempo (time-slicing) além do suporte a prioridade já existente. Este incremento melhora a preemptividade do scheduler, garantindo que tarefas de alta prioridade não detenham o processador indefinidamente e que todos os tarefas recebam tempo de execução justo.

## Implementação

### Arquivos modificados

- `kernel/task/scheduler.zig`

### Mudanças realizadas

#### 1. Novos campos na struct `Task` (linhas 91-100)

Dois novos campos foram adicionados à estrutura de tarefa:

- **`priority: u8 = 0`** — Prioridade da tarefa. Valores maiores significam maior prioridade. O scheduler escolhe a tarefa pronta com a maior prioridade.

- **`quantum: u16 = 0`** — Quantum de tempo em ticks do timer do scheduler. Quando o quantum expira (atinge 0), a tarefa é preemptively retornada à fila de tarefas prontas e o scheduler escolhe a próxima tarefa. Um quantum de zero significa que a tarefa não está sujeita a time-slicing.

#### 2. Função `prepareNext` — Lógica de quantum (linhas 278-290)

Adicionado o tratamento do quantum no handler do timer:

- A cada tick do timer, o quantum da tarefa atual é decrementado
- Quando o quantum atinge 0, a tarefa é retornada ao estado `.ready`
- O scheduler então escolhe a próxima tarefa para executar
- Tarefas com `quantum = 0` são imunes a time-slicing e continuam executando até bloquearem ou serem substituídas por prioridade maior

#### 3. Função `findNextReady` — Escolha por prioridade (linhas 453-473)

Refatorado para selecionar explicitamente a tarefa com maior prioridade:

- Antes: retornava a primeira tarefa pronta encontrada na iteração
- Agora: varre todas as tarefas prontas e escolhe a de maior prioridade; empates são resolvidos pela primeira tarefa encounterada

#### 4. Função `allocate` — Quantum inicial (linhas 494-496)

Tarefas recém-criadas recebem um quantum padrão de **16 ticks**, ativando o time-slicing por padrão. Isso garante que, mesmo sem configuração explícita, o sistema tem preemptividade cooperativa. Tarefas podem desativar o time-slicing definindo `quantum = 0`.

## Comportamento

### Antes desta mudança

O scheduler já escolhia a tarefa de maior prioridade (adicionada na etapa anterior), mas, se duas tarefas tivessem a mesma prioridade ou se uma tarefa de alta prioridade nunca bloqueasse, ela poderia executar indefinidamente, bloqueando outras tarefas de mesma prioridade.

### Depois desta mudança

- O scheduler ainda prioriza tarefas de maior prioridade
- Além disso, o quantum garante que nenhuma tarefa detenha o processador indefinidamente
- O quantum de 16 ticks (a 100 Hz do timer = 0,16 segundos) fornece um equilíbrio entre responsividade e estabilidade
- Tarefas críticas podem definir `quantum = 0` para execução contínua sem interrupções de time-slicing

## Validação

- `zig build check` — ✅ Compila sem erros
- `zig build qemu-test` — ✅ Todos os testes de boot passam
- O kernel boot completo funciona com as tarefas usuais (syscalls, IPC, capacidades, user mode)

## Próximos passos

As próximas refinamentos planejados para F3 incluem:

1. **Wait on several channels** — Permitir que uma tarefa aguarde múltiplas canais/sides simultaneamente
2. **Mais processos** — Estender o número de processos além das 3 atuais
3. **Dynamic heap with VNM** — Implementar alocador dinâmico usando o subsistema de memória Voryn Nexus

## Critérios de aceite verificáveis

1. O código compila com `zig build check`
2. O kernel inicia no QEMU com `zig build qemu-test`
3. Tarefas com mesma prioridade ainda são escolhidas em ordem round-robin
4. Tarefas de maior prioridade ainda são escolhidas antes de tarefas de menor prioridade
5. Tarefas podem definir `quantum = 0` para desativar o time-slicing
6. O custo de contexto permanece baixo (sem alocação em caminho crítico)