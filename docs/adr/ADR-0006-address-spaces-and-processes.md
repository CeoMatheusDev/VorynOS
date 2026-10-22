# ADR-0006 — Espaços de endereço por processo e o quadro do processador

| Campo | Valor |
|-------|-------|
| **Estado** | ACEITO |
| **Data** | 2026-10-22 |
| **Escopo** | O modelo de memória do VorynOS e a troca de contexto |

## 1. Contexto

O ADR-0005 fechou o marco do modo de usuário com um defeito no desenho do
segmento de tarefa, e o marco F3 ficou com dois itens pendentes: os
**processos** e a **entrega de uma mensagem entre dois processos**.

Enquanto os processos não existiam, o núcleo tinha uma única hierarquia de
tabelas de página, e a tarefa do modo de usuário vivia nela. A auditoria
deste incremento encontrou três defeitos que vinham desse desenho, e que
eram a causa de todos os sintomas observados:

1. **A troca de contexto não guardava os registradores que a arquitetura
   não salva entre chamadas.** O contexto tinha apenas `rbx`, `rbp`,
   `r12` a `r15`, o ponteiro de pilha, as flags, o endereço de instrução e
   os seletores de segmento. O resultado de uma chamada de sistema vive em
   `rax`, e os argumentos da chamada seguinte vivem em `rdi`, `rsi` e `rdx`.
   Uma tarefa que era interrompida no meio de uma chamada voltava com o
   resultado de outra tarefa, e o sintoma aparecia longe da causa: o
   programa do usuário mode escrevia valores que não eram seus, o laço de
   recepção de uma mensagem saía com o registrador `rax` de outra tarefa, e
   o núcleo entrava emespera de uma resposta que nunca chegava.

2. **O quadro do processador da volta era montado sobre a pilha do código
   interrompido.** Para uma tarefa do núcleo, essa pilha é a pilha do
   próprio código, e o quadro ficava logo acima dela, em um endereço que o
   código ia usar em seguida. Para uma tarefa do modo de usuário, a pilha do
   código é uma página que o **usuário** possui, e o quadro do processador
   — que decide o nível de privilégio da volta — ficava em uma página que o
   usuário pode reescrever. Era uma escalada de privilégio dentro do
   próprio mecanismo de retorno.

3. **A janela do modo de usuário tinha endereço fixo, e a imagem do núcleo
   é mapeada por identidade.** A janela ficava em `0x400000`, e a imagem do
   núcleo é carregada em `0x200000` e cresce com o núcleo. A página do
   programa do usuário substituía a página do segmento de dados do próprio
   núcleo. O defeito só apareceu quando a imagem passou de dois megabytes,
   e a falha foi um **processo de página** dentro do núcleo.

## 2. A decisão

### 2.1 O contexto guarda todos os registradores

O contexto passa a ter os quinze registradores de uso geral, o vetor da
interrupção, o ponteiro de pilha, as flags, o endereço de instrução e os
dois seletores de segmento. A rotina de troca lê o quadro do stub da
interrupção e grava o estado inteiro, e monta o quadro do processo que
entra com o mesmo formato do quadro do stub.

O formato do quadro é o mesmo por uma razão prática: uma tarefa
interrompida **dentro** de um tratador de interrupção tem de voltar
para o meio do tratador, e o tratador assume o formato do stub.

### 2.2 Cada tarefa tem duas pilhas

A pilha do código da tarefa e a pilha do núcleo da tarefa são memórias
diferentes. O quadro do processador é montado na pilha do núcleo da tarefa
que entra, e a pilha do código é restaurada pelo próprio quadro.

A pilha do núcleo vive na imagem do núcleo, e a imagem é mapeada em
**todos** os espaços de endereço, inclusive nos dos processos. Por isso o
quadro pode ser montado e lido em qualquer espaço.

### 2.3 O quadro da volta salta a pilha do kernel

O quadro do processo que entra é montado na pilha do kernel do processo, e
o `iretq` da volta carrega o ponteiro de pilha do código a partir do
quadro. O TSS `rsp0` aponta para a pilha do kernel da tarefa corrente, e é
dela que o processador parte quando a interrupção vem do modo de usuário.

### 2.4 Cada processo tem um espaço de endereço próprio

O espaço de um processo é uma **cópia** das tabelas do núcleo: a raiz, o
terceiro nível e o segundo nível são copiados, e a janela do modo de
usuário recebe uma cadeia privada. A cópia é o que mantém a imagem do
núcleo e o quadro de vídeo mapeados dentro do espaço do processo, e é
necessária porque o núcleo roda no espaço do processo que interrompeu.

O escalonador troca o espaço junto com o contexto da tarefa. A troca
acontece no mesmo ponto da troca do contexto, e o valor é o endereço da
tabela raiz do processo que entra.

A consequência é a **isolamento**: dois processos que usam o mesmo
endereço virtual para os seus dados não veem as mesmas páginas, e uma
cópia entre os dois é uma cópia de verdade.

### 2.5 A janela do modo de usuário não tem endereço fixo

A janela fica **abaixo** da imagem do núcleo, e o seu endereço é entregue
à tarefa no registrador `rbx` quando a tarefa começa. A janela é descrita
no módulo compartilhado, porque o programa do modo de usuário é escrito em
assembly e os dois lados precisam concordar com o desenho byte a byte.

A janela do processo vive em um único bloco de dois megabytes, e a cadeia
privada do espaço usa uma tabela do primeiro nível só dela.

### 2.6 A cópia entre processos passa pela pilha do kernel

O núcleo não copia o bloco de um processo para o outro com um único
movimento, porque os dois espaços não nomeam as mesmas páginas. A leitura
da origem acontece com o espaço de quem chamou ativo, o bloco fica num
buffer que vive na imagem do núcleo, e a escrita do destino acontece com o
espaço de destino ativo. O buffer é alcançável nas duas direções porque a
imagem está mapeada em todos os espaços.

### 2.7 O canal tem os lados como argumento

A chamada que manda e a que recebe uma mensagem recebem o **lado** do
canal como argumento. Um canal pertence a duas tarefas, e cada lado do
canal é uma tarefa: quem manda escolhe o lado de quem recebe.

A regra anterior — o remetente escreve na fila do núcleo e o receptor lê
da fila do usuário — só funciona com um único par de tarefas, e ela
impedia que dois processos conversassem pelo mesmo canal sem tomar a
mensagem um do outro.

## 3. O que foi descartado

### 3.1 A janela com endereço fixo

Um endereço fixo é mais simples para o programa de usuário, e foi o que
a primeira versão usou. A imagem do núcleo é mapeada por identidade e
cresce, e a janela fixa acabou dentro da imagem. A alternativa seria
reservar uma região fixa da imagem para a janela, e isso acopla o
endereço do usuário mode ao tamanho do núcleo.

### 3.2 As páginas intermediárias para a cópia entre processos

A primeira versão do desenho de outro ramo do repositório usava páginas
intermediárias: o núcleo mapeava a página física do processo em uma
janela privada e lia por ela. A solução funciona, e evita a troca do
espaço de endereço no meio de uma chamada.

Ela foi descartada porque exige uma janela física que o processo não
possui, uma segunda hierarquia de tabelas para as páginas intermediárias, e
uma sincronização entre a janela e o espaço do processo. A troca do espaço
dentro de uma chamada é mais simples, e o custo é de uma troca de tabela
por cópia, e não por byte.

### 3.3 O quadro montado sobre a pilha do código

A primeira versão montava o quadro do processo que entra sobre a pilha do
código interrompido, e o resultado funcionava. Funcionava por acidente: o
endereço estava livre no momento em que o quadro era montado, e o
processador não conferia nada. Um usuário que escrevesse no endereço do
quadro controlaria o nível de privilégio da volta.

## 4. A consequência para o contrato das chamadas

A instrução `syscall` escreve `rcx` com o endereço de retorno e `r11` com
as flags de quem chamou. O quarto argumento de uma chamada **tem de viajar
no `r8`**.

O programa do usuário mode usava o `rcx` para o valor da mensagem, e o
núcleo recebia o endereço de retorno no lugar do valor. O sintoma foi um
processo que esperava uma resposta que nunca tinha o valor certo.

## 5. A consequência para o diagnóstico

O relatório de uma exceção passou a relatar o **endereço que causou a
falta** (o registrador `CR2`), e não apenas o quadro do processador. Sem
ele, um defeito de mapeamento aparece como um endereço de instrução que
não faz sentido, e a investigação depende de um depurador externo.

O `CR2` é lido no momento da exceção, e a página que causou a falta é
mapeada com o bit de usuário, e por isso o endereço é a origem real do
defeito.

## 6. A verificação

O teste de boot automatizado verifica, nesta ordem:

- os dois processos existem, cada um com o seu espaço de endereço;
- cada processo escreve o seu marcador no **mesmo** endereço virtual, e os
  marcadores são diferentes, o que prova o isolamento;
- a mensagem sai de um processo e chega ao outro, e a resposta volta pelo
  mesmo canal;
- a cópia entre os dois processos escreve no espaço do destino, e o
  espaço de quem chamou **não** muda, o que prova que a cópia é uma cópia
  e não um compartilhamento de página;
- a cópia com faixas sobrepostas move o bloco no sentido certo.

O teste de boot roda em `zig build qemu-test`, e o conjunto completo
(`zig build check`) roda os testes de unidade e o teste de boot.

## 7. O estado

| Item | Estado |
|------|--------|
| Espaços de endereço por processo | IMPLEMENTADO — TESTADO LOCALMENTE |
| Troca do espaço com a tarefa | IMPLEMENTADO — TESTADO LOCALMENTE |
| Isolamento entre dois processos | IMPLEMENTADO — TESTADO LOCALMENTE |
| Cópia entre dois processos | IMPLEMENTADO — TESTADO LOCALMENTE |
| Entrega de mensagem entre dois processos | IMPLEMENTADO — TESTADO LOCALMENTE |
| Transferência de capacidades do VNC | PROPOSTO |
| Chamada que bloqueia à espera de uma mensagem | PROPOSTO |
| Medição da latência da entrega com o relógio do processador | IMPLEMENTADO — TESTADO LOCALMENTE |
