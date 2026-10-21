# ADR-0005 — Modelo de tarefa, troca de contexto e modo de usuário

| Campo | Valor |
|-------|-------|
| **Estado** | ACEITO — o escalonador está implementado e verificado; o modo de usuário está em desenvolvimento |
| **Data** | 2026-10-21 |
| **Decidido por** | Engenharia VorynOS |
| **Contexto** | Marco F3, execução |

## 1. Contexto

O marco F2 entregou as estruturas do processador. O marco F3 precisa de tarefas
que alternam entre si, e o primeiro objetivo verificável é o **modo de
usuário**: uma tarefa que executa no terceiro nível de privilégio, com páginas
próprias, e que volta para o núcleo por uma chamada de sistema.

## 2. Decisões

### 2.1 O contexto guarda o quadro completo do processador

Uma tarefa suspensa **dentro** de um tratador de interrupção não tem
endereço de retorno para onde voltar: o quadro da interrupção pertence ao
tratador, e não ao código interrompido. Um contexto que só guardasse os
registradores que a arquitetura não salva, e que fosse retomado com um
`ret`, leria da pilha um valor qualquer.

O contexto do VorynOS guarda, além dos registradores que a arquitetura não
salva, o ponteiro de instrução, as flags e os seletores de segmento. A troca
monta o quadro do processador sobre a pilha da tarefa que entra e termina com
um `iretq`.

**Consequência:** a troca custa alguns ciclos a mais do que um `ret`, e a
medição confirma a ordem de grandeza: **358 ciclos** no melhor caso, com uma
média de 8 mil ciclos na primeira execução, em que as caches ainda estão
frias.

### 2.2 A troca acontece no ponto de entrada da interrupção

A troca de contexto é executada pelo ponto de entrada da interrupção, e não
pelo tratador em Zig. O quadro da interrupção ainda está na pilha quando a
tarefa suspensa é retomada, e portanto o contexto pode ser reconstruído a
partir dele.

**Consequência:** o tratador devolve um valor que indica se a troca é
necessária, e o ponto de entrada decide.

### 2.3 A política é circular, e não "a primeira tarefa pronta"

A primeira versão da política devolvia sempre a primeira tarefa pronta da
lista. Com três tarefas, a segunda nunca era escolhida: o processador
alternava entre a primeira e a segunda e a terceira passava fome.

A política visita as tarefas **a partir da tarefa atual**, e volta ao
começo quando chega ao fim. É a política mais simples que não produz fome,
e é a base sobre a qual as políticas de latência do perfil gamer vão ser
construídas, com dados.

### 2.4 O segmento de tarefa aponta para a pilha da tarefa

O processador carrega o ponteiro de pilha do segmento de tarefa sempre que o
nível de privilégio muda, **nos dois sentidos**. Uma tarefa de usuário que
recebe o seu ponteiro de pilha de um outro lugar executaria sobre a pilha do
núcleo, cujas páginas não são acessíveis de usuário.

O escalonador aponta o segmento de tarefa para a pilha da tarefa que vai
executar. Para uma tarefa de usuário, é a pilha de usuário; para uma tarefa
do núcleo, é a pilha da própria tarefa.

**Consequência:** o tratador de uma exceção que vem do usuário executa sobre
a pilha de usuário. A pilha de usuário precisa ser maior do que a pilha do
núcleo usaria, e é preciso documentar esse acoplamento.

### 2.5 O bit de usuário existe em todos os níveis da hierarquia

O processador verifica o bit de usuário em **todos** os níveis da hierarquia
de tabelas. As entradas de nível superior recebem sempre o bit, e são as
entradas de página que decidem: as páginas do núcleo não o têm, e portanto
continuam inacessíveis a partir do usuário.

### 2.6 O núcleo prepara o coprocessor

O firmware deixa o coprocessor desabilitado, e uma instrução de ponto
flutuante levanta um erro de coprocessor. A rotina de cópia de memória do
compilador usa instruções de vetor, e o núcleo habilita a unidade, habilita o
estado salvo pelo processador e mascara as exceções da unidade.

**Consequência:** todo núcleo precisa dessa rotina, e a sua ausência aparece
como um erro de coprocessor dentro de uma rotina de biblioteca, o que
desvia o diagnóstico.

## 3. O modo de usuário: o que já existe e o que falta

Já existe e foi verificado:

- as tabelas de página com o bit de usuário e as páginas do núcleo sem ele;
- a porta de interrupção da chamada de sistema, com o terceiro nível de
  privilégio, e o tratador em Zig;
- a tarefa de usuário, com o seu próprio programa, a sua página de dados e a
  sua pilha;
- o segmento de tarefa com o ponteiro de pilha da tarefa de usuário.

**Falta:** a entrega da exceção que vem do usuário. O portão da chamada de
sistema é acionado pelo programa de usuário, e a exceção que o programa
provoca não chega ao tratador do núcleo: o processador levanta uma falha de
página, e o tratador não é executado. A causa está em investigação, e a
tarefa de usuário **não é agendada** até que a causa seja encontrada, porque
uma tarefa que falha interrompe a máquina.

A alternativa seria mascarar a falha de página no usuário, o que destruiria
justamente o isolamento que o modo de usuário deve oferecer.

## 4. Custos e riscos

| Risco | Impacto | Tratamento |
|-------|---------|------------|
| Pilha de usuário compartilhada com o tratador | Médio | A pilha de usuário é maior e o acoplamento está documentado |
| A política circular pode gerar inanição com tarefas bloqueadas | Médio | O bloqueio ainda não existe; quando existir, a política precisa de classes de prioridade |
| A entrega de exceções do usuário não funciona | Alto | A tarefa de usuário fica desabilitada até a causa ser encontrada |

## 5. Consequências

- O modelo de contexto completo é a base para o modo de usuário, para os
  processos e para as threads: todos compartilham a mesma mecânica.
- A medição do custo da troca de contexto é a referência para as decisões de
  desempenho do marco F10.
