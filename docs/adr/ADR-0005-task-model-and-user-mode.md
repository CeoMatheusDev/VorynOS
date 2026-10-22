# ADR-0005 — Modelo de tarefa, troca de contexto e modo de usuário

| Campo | Valor |
|-------|-------|
| **Estado** | ACEITO — o escalonador e o modo de usuário estão implementados e verificados |
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

**O modo de usuário está implementado e verificado.** O programa da tarefa de
usuário executa no terceiro nível de privilégio, escreve na sua própria
página de dados, chama o núcleo pela instrução `syscall` e recebe a resposta
de volta no mesmo registrador.

Existe e foi verificado:

- as tabelas de página com o bit de usuário e as páginas do núcleo sem ele;
- a tarefa de usuário, com o seu próprio programa, a sua página de dados e a
  sua pilha;
- a pilha do núcleo de cada tarefa, onde os tratadores de interrupção e de
  chamada rodam;
- o segmento de tarefa, com o layout do modo de 64 bits, apontando para a
  pilha do núcleo da tarefa em execução;
- a chamada de sistema pela instrução `syscall`, com o tratador em Zig.

A entrega da exceção que vem do usuário **foi corrigida**: a causa era o
layout do segmento de tarefa, descrita na seção 3.3.

O diagnóstico da porta de interrupção continua registrado, porque ele
delimita o problema, mas **a conclusão dele estava errada**: a falha não era
uma verificação de privilégio, e sim uma falha de pilha, com o vetor 12. O
registro abaixo é o que a investigação encontrou na época:

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
6. Durante a entrega, o emulador levanta uma **exceção com código de erro
   zero**, antes de o tratador receber o controle: o traço das exceções
   mostra a mesma exceção e, em seguida, uma falha dupla, porque a entrega
   da própria falha também falha.
7. A leitura do traço identificou a exceção como a **falha de proteção
   geral**, com o código de erro zero, e a conclusão foi que se tratava de
   uma verificação de privilégio.

**A correção do ponto 7 é o que resolveu o defeito:** a exceção é a
**falha de pilha**, o vetor 12, e ela não vem da porta: vem do segmento de
tarefa, cujo layout estava errado. A porta de interrupção entregava a
chamada corretamente, e o que falhava era a pilha que o processador usava
para entregar a exceção que vinha do usuário.

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

### 3.3 A causa do defeito: o segmento de tarefa

A migração para a instrução `syscall` **não** resolveu o defeito por si só: a
primeira execução do caminho novo reproduziu a mesma falha, e o traço das
exceções apontou o defeito real.

O sintoma, no traço do emulador, é o vetor **12** — a exceção de **falha de
pilha**, com código de erro zero —, e não a falha de proteção geral que o
diagnóstico anterior supunha. A falha de pilha é levantada na entrega de
uma interrupção vinda do terceiro nível de privilégio, e é seguida de falha
dupla, porque a entrega da própria falha também falha.

A causa está no **segmento de tarefa**, e é um defeito de layout:

- O segmento de tarefa do modo de 64 bits **não é** o do modo protegido. A
  estrutura do modo de 64 bits não tem o campo do seletor do segmento de
  pilha, e os campos do segmento de tarefa começam em outros deslocamentos:
  a pilha de ring 3 (`RSP0`) está no **deslocamento 4**, e não no 8; a
  tabela de pilhas de interrupção (`IST`) começa no **deslocamento 36**; a
  estrutura tem **104 bytes**, e o limite do segmento é 103.
- O núcleo usava o layout do modo protegido: a pilha de ring 3 estava no
  deslocamento 8 e a tabela de pilhas de interrupção no 40. O processador
  lia, no deslocamento 4, o campo reservado e a metade baixa do ponteiro
  de pilha: o valor lido não era um endereço de pilha, e o quadro da
  interrupção era escrito num endereço inválido.
- A estrutura do núcleo era declarada como `extern struct`, e o compilador
  insere **alinhamento implícito**: o primeiro `u64` de uma `extern struct`
  fica no deslocamento 8, mesmo depois de um `u32` no deslocamento 0. A
  estrutura precisa ser `packed`, e o compilador acrescenta oito bytes de
  preenchimento no fim, de modo que o tamanho relevante é uma constante da
  arquitetura, e não `@sizeOf`.

**A correção** foi reescrever a estrutura com os deslocamentos da
arquitetura, com a verificação em tempo de compilação dos deslocamentos e do
tamanho, e com o limite do segmento no último byte válido.

**Consequência:** a entrega de interrupções ao terceiro nível de
privilégio passou a funcionar, e o traço do emulador **não registra nenhuma
exceção** durante toda a execução: nem falta de pilha, nem falha dupla, nem
falha de página.

### 3.4 O caminho da chamada de sistema

A chamada usa a instrução `syscall`, e o núcleo tem quatro decisões
próprias desse caminho:

1. **A instrução é o caminho do usuário para o núcleo, e nada mais.** O
   processador carrega os segmentos do núcleo e o nível de privilégio do
   núcleo **antes** de o ponto de entrada executar, e portanto o ponto de
   entrada não consegue distinguir o nível de privilégio de quem chamou. A
   volta é sempre um `iretq`, e o núcleo chama o próprio tratador com uma
   chamada comum, e não com a instrução.
2. **Cada tarefa tem duas pilhas.** A pilha do usuário é a que a tarefa usa,
   e a pilha do núcleo é a que recebe os quadros das interrupções e das
   chamadas. O tratador da chamada **nunca** roda sobre a pilha do usuário,
   e o usuário não pode reescrever o quadro do tratador. O segmento de
   tarefa aponta para a pilha do núcleo da tarefa que está em execução.
3. **O registro `IA32_STAR` tem um layout só, e o núcleo o programa para
   ele.** A arquitetura define a operação da instrução assim: o seletor do
   código do núcleo vem do campo da metade baixa, `IA32_STAR[47:32]`, e o
   seletor da pilha do núcleo vem do valor oito bytes acima dele, porque a
   pilha do núcleo é *"SS just above CS"*. A tabela do núcleo tem o segmento
   de dados oito bytes depois do segmento de código, e portanto o seletor do
   código serve para os dois: o campo da metade baixa recebe o seletor do
   código do núcleo, e a pilha do núcleo que o processador carrega é a do
   seletor do código mais oito. O campo da metade alta pertence à instrução
   de retorno, que o núcleo não usa, porque a volta da chamada é um retorno
   de interrupção.
4. **A máscara de flags tem de limpar a interrupção.** O ponto de entrada
   monta o quadro da chamada na pilha do núcleo, e uma interrupção que
   chegasse no meio dessa sequência escreveria o próprio quadro por cima do
   quadro da chamada. A máscara limpa a interrupção, a armadilha, a direção
   e as flags da aritmética.

   A máscara **não** tira a interrupção de quem chamou: o processador salva
   as flags no registrador `R11` **antes** de aplicar a máscara, e a volta
   restaura o valor de `R11`. A medição confirma: com a máscara `0x7fd`, o
   tratador leu `0x202` em `R11`, com a interrupção ligada, e a tarefa do
   usuário mode voltou preemptível, e o escalonador preemptivo continuou a
   escolhê-la ✓.

### 3.5 Correções que a investigação produziu

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
- **O seletor de segmento tem o nível de privilégio nos dois campos mais
  baixos.** A função que monta o seletor colocava o indicador de tabela no
  campo 3 e o nível de privilégio no campo 4, e o seletor do usuário saía
  `0x38` e `0x30`: um índice fora da tabela, e com o nível de privilégio do
  núcleo. A correção põe o indicador de tabela no campo 2 e o nível de
  privilégio nos campos 0 e 1, e o seletor do usuário passa a ser `0x1b` e
  `0x23` ✓. O defeito era silencioso: os seletores hardcoded do escalonador
  estavam certos, e só o registro da chamada de sistema usava os valores
  errados.
- **O quadro do retorno de interrupção é montado na ordem inversa.** O
  processador desempilha o endereço de retorno, o seletor do código, as
  flags, o ponteiro de pilha e o seletor da pilha, e portanto o valor do
  endereço de retorno é o que fica no endereço mais baixo do quadro. O
  quadro da chamada de sistema era montado na ordem oposta, e o retorno
  carregava o valor errado para o endereço de retorno ✗.
- **O número da chamada não pode ser destruído antes de ser salvo.** O
  ponto de entrada usava o primeiro registrador para ler o ponteiro de
  pilha do usuário, e o número da chamada, que é o primeiro registrador do
  usuário, deixava de existir: o tratador recebia o ponteiro de pilha no
  lugar do número ✗. A medição mostrava o número `0x404000`, que é o topo
  da pilha do usuário.

## 4. Custos e riscos

| Risco | Impacto | Tratamento |
|-------|---------|------------|
| Pilha de usuário compartilhada com o tratador | Resolvido | Cada tarefa tem uma pilha do núcleo, e o tratador da chamada roda nela |
| A política circular pode gerar inanição com tarefas bloqueadas | Médio | O bloqueio ainda não existe; quando existir, a política precisa de classes de prioridade |
| A porta de interrupção não entrega a chamada de sistema do usuário | Resolvido | O caminho da porta é abandonado, e a chamada usa a instrução `syscall` |
| O segmento de tarefa com o layout errado | Alto | O layout é verificado em tempo de compilação, e o limite do segmento é o último byte da estrutura |

### 4.1 Plano de migração para a instrução de chamada de sistema

1. Escrever os registradores de modelo `IA32_STAR`, `IA32_LSTAR` e
   `IA32_SFMASK`, com o seletor do código do núcleo em `IA32_STAR`. **Feito.**
2. Escrever a entrada da chamada de sistema em assembly: a instrução
   `syscall` não troca a pilha, e a entrada tem de salvar o ponteiro de
   pilha do usuário antes de saltar para a pilha do núcleo, que o segmento
   de tarefa aponta. **Feito.**
3. Gravar no contexto da tarefa o estado do usuário que a volta precisa:
   o endereço de retorno, as marcas e o ponteiro de pilha, e os registradores
   que a convenção de chamada preserva. **Feito:** o quadro da volta é
   montado na pilha do núcleo, com o quadro de retorno de interrupção.
4. Devolver ao usuário com `iretq`, montando o quadro com o estado do
   usuário. **Feito:** a ordem dos empilhamentos é a inversa da ordem em que
   o processador desempilha, e o quadro de retorno de interrupção fica no
   topo da pilha.
5. Tratar a preempção dentro da chamada de sistema: a tarefa suspensa
   dentro do tratador tem de voltar ao tratador, e não ao usuário.
   **Feito por construção:** o quadro da chamada fica na pilha do núcleo da
   tarefa, e a troca de contexto salva o quadro da interrupção por cima
   dele, de modo que a retomada devolve a tarefa ao tratador.

## 5. Consequências

- O modelo de contexto completo é a base para o modo de usuário, para os
  processos e para as threads: todos compartilham a mesma mecânica.
- A medição do custo da troca de contexto é a referência para as decisões de
  desempenho do marco F10.
- Cada tarefa tem duas pilhas, e a pilha do núcleo é a que o segmento de
  tarefa aponta. O modo de usuário deixou de rodar o tratador sobre a pilha
  que o usuário controla.
- O layout do segmento de tarefa é verificado em tempo de compilação,
  porque um erro de deslocamento produz uma falha de pilha cujo diagnóstico
  é indireto, e o defeito que este registro descreve consumiu um incremento
  inteiro.

## 6. A ordem da inicialização

O canal de mensagens do VNX não entregava nada, e o defeito não estava no
canal: estava na **ordem** da inicialização do núcleo.

A sequência de inicialização habilita as interrupções do temporizador, e o
escalonador começa a escolher as tarefas nesse instante. A tarefa do
usuário mode roda no seu primeiro turno, e ela envia a primeira mensagem
nesse turno. A inicialização dos canais vinha **depois** do temporizador, e
ela reiniciava as filas, e portanto apagava a mensagem que a tarefa tinha
mandado.

A medição que fechou o diagnóstico mostra os contadores das duas filas do
mesmo canal, lidos na mesma execução: no instante da mensagem, a fila do
núcleo contava uma mensagem enviada, e na verificação seguinte, um instante
depois, as duas filas contavam zero. O canal era o mesmo, e a única coisa
que passou entre as duas leituras foi a inicialização.

**A regra que o defeito ensina:** tudo o que as tarefas podem usar tem de
existir **antes** do temporizador, porque o temporizador é o que começa a
executar as tarefas. A inicialização que vem depois do temporizador é uma
inicialização tardia, e ela corre com as tarefas em execução.

**Consequência:** a inicialização dos canais do VNX vem antes do
temporizador, e a entrega da mensagem passou a funcionar: a mensagem que a
tarefa do usuário mode envia chega ao núcleo, o núcleo responde, e a
resposta chega de volta à tarefa.

## 7. A tolerância da sobreposição na cópia

A chamada de cópia copia um bloco de memória entre duas faixas que o
usuário mode escolhe. A primeira implementação usava a instrução de cópia,
que **exige** que as duas faixas não se sobreponham, e a exigência levanta
um pânico no núcleo, e o pânico do núcleo para a máquina.

O defeito é uma negação de serviço: uma tarefa do usuário mode derrubava o
sistema com dois argumentos, e nenhum isolamento impede isso, porque a
faixa da origem e a do destino são ambas válidas.

A medição confirma: com a cópia sem a tolerância, o programa do usuário
mode levanta o pânico `@memcpy arguments alias` e o núcleo para ✓. Com a
tolerância, a mesma cópia com as faixas sobrepostas devolve o número de
bytes, e o programa do usuário mode continua ✓.

**A regra:** uma chamada que trabalha com faixas escolhidas por quem chama
tem de tolerar a sobreposição, ou tem de recusar a chamada com um erro
próprio. Levantar um pânico no núcleo não é uma das duas.
