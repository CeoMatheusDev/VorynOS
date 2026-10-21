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
sistema é acionado pelo programa de usuário, e a entrega levanta uma falha
de proteção geral, com o código de erro zero, e o tratador não é executado.

O diagnóstico está delimitado, e a causa está fora do núcleo:

1. A tarefa de usuário **executa** no terceiro nível de privilégio: o
   processador registra `cpl=3`, com o seletor de código `0x1b` e o de dados
   `0x23`, e o programa chega à instrução de chamada de sistema, com o
   registro de número preenchido.
2. A porta da chamada de sistema está **correta**, byte a byte. O
   descritor medido em memória é `81 07 08 00 00 ee 29 00 00 00 00 00 00
   00 00`: o deslocamento em duas partes, o seletor `0x08` do código do
   núcleo, o índice de pilha de interrupção zero, e o tipo `0xee`, presente
   e de terceiro nível de privilégio.
3. Os segmentos estão corretos: o código do usuário tem o bit de modo longo
   e o terceiro nível de privilégio, e o segmento de dados é gravável e do
   terceiro nível de privilégio.
4. As tabelas de página estão corretas: as três páginas do usuário estão
   presentes, graváveis e com o bit de usuário, e os níveis superiores da
   hierarquia também o têm.
5. A chamada de sistema **é entregue** pelo emulador: o registro de
   interrupções mostra o vetor `0x80` com a marca de interrupção de software.
6. Durante a entrega, o emulador levanta uma **falha de proteção geral com
   código de erro zero**, antes de o tratador receber o controle: o traço
   das exceções mostra a mesma falha de proteção geral e, em seguida, uma
   falha dupla, porque a entrega da própria falha também falha.
7. O código de erro zero é a assinatura de uma verificação de **privilégio**
   que falha, e não de uma falta de página. No código do emulador, a única
   verificação com código de erro zero nesse caminho é a da porta nula, e
   todas as demais condições de falha desse caminho foram verificadas uma a
   uma e não se aplicam.

O conjunto das medições é, portanto, **internamente contraditório**: o
emulador falha uma verificação de privilégio numa porta de terceiro nível,
com o processador no terceiro nível, e uma porta comprovadamente correta.

### 3.1 Consequência: a instrução de chamada de sistema

O caminho da porta de interrupção é abandonado. O núcleo passa a usar a
instrução `syscall`, com o mecanismo previsto pela arquitetura para isso em
modo de 64 bits, e a decisão tem três motivos:

1. **O caminho da porta é o único que falha.** A instrução `syscall` não
   passa pela tabela de interrupções, e portanto não depende da verificação
   que falha.
2. **A pilha do tratador passa a ser do núcleo.** Com a porta de
   interrupção, o tratador roda sobre a pilha do usuário, e o usuário
   poderia reescrever o quadro do tratador. Com `syscall`, o processador
   entrega a chamada na pilha que o segmento de tarefa aponta, e a pilha do
   usuário só é restaurada na volta.
3. **A porta de interrupção é um caminho herdado.** A recomendação da
   arquitetura para chamadas de sistema no modo de 64 bits é a instrução
   `syscall`, com os registradores de modelo `IA32_STAR`, `IA32_LSTAR` e
   `IA32_SFMASK`.

A tarefa de usuário **não é agendada** até a chamada de sistema funcione
pelo caminho novo, porque uma tarefa que falha interrompe a máquina. A
alternativa seria mascarar a falha no usuário, o que destruiria justamente
o isolamento que o modo de usuário deve oferecer.

### 3.2 Correções que a investigação produziu

- **A tabela de vetores de exceção do modo de 64 bits é diferente da de 32
  bits.** A falta de página é o vetor 14, e não o 13, e a exceção de
  segmento de pilha é o 13, e não o 11. A tabela do núcleo usava a numeração
  do modo protegido, e o diagnóstico da falta de página dizia "erro de ponto
  flutuante" ✗.
- **A cópia do programa do usuário tem de acontecer depois da troca das
  tabelas de página.** Antes da troca, a escrita usaria as tabelas do
  firmware, e o programa cairia em outra página física, que a tarefa
  executaria como se fosse o programa ✗.
- **A instrução que para o processador é privilegiada.** O programa de
  usuário esperava com `hlt`, que levanta uma falha de proteção geral no
  terceiro nível de privilégio ✗. A instrução `pause` é rejeitada pelo
  emulador pelo mesmo motivo ✗, e a espera passa a ser um laço que só
  salta para si mesmo ✓.

## 4. Custos e riscos

| Risco | Impacto | Tratamento |
|-------|---------|------------|
| Pilha de usuário compartilhada com o tratador | Médio | A pilha de usuário é maior e o acoplamento está documentado |
| A política circular pode gerar inanição com tarefas bloqueadas | Médio | O bloqueio ainda não existe; quando existir, a política precisa de classes de prioridade |
| A porta de interrupção não entrega a chamada de sistema do usuário | Alto | O caminho da porta é abandonado, e a chamada passa a usar a instrução `syscall`, que não depende da tabela de interrupções |

### 4.1 Plano de migração para a instrução de chamada de sistema

1. Escrever os registradores de modelo `IA32_STAR`, `IA32_LSTAR` e
   `IA32_SFMASK`, com o seletor do código do núcleo em `IA32_STAR`.
2. Escrever a entrada da chamada de sistema em assembly: a instrução
   `syscall` não troca a pilha, e a entrada tem de salvar o ponteiro de
   pilha do usuário antes de saltar para a pilha do núcleo, que o segmento
   de tarefa aponta.
3. Gravar no contexto da tarefa o estado do usuário que a volta precisa:
   o endereço de retorno, as marcas e o ponteiro de pilha, e os registradores
   que a convenção de chamada preserva.
4. Devolver ao usuário com `iretq`, montando o quadro com o estado do
   usuário.
5. Tratar a preempção dentro da chamada de sistema: a tarefa suspensa
   dentro do tratador tem de voltar ao tratador, e não ao usuário.

## 5. Consequências

- O modelo de contexto completo é a base para o modo de usuário, para os
  processos e para as threads: todos compartilham a mesma mecânica.
- A medição do custo da troca de contexto é a referência para as decisões de
  desempenho do marco F10.
