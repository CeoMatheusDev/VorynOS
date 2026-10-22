//************************************************************************//
//  ADR-0007.md                                                          //
//************************************************************************//
//                         This file is part of:                          //
//                               VorynOS                                  //
//              https://github.com/CeoMatheusDev/VorynOS                  //
//************************************************************************//
// Copyright (C) 2026 VorynOS contributors.                               //
//                                                                        //
// SPDX-License-Identifier: GPL-3.0-only                                  //
//**************************************************************************

# ADR-0007 — A chamada que bloqueia à espera de uma mensagem

| Campo | Valor |
|-------|-------|
| **Estado** | ACEITO |
| **Data** | 2026-10-22 |
| **Escopo** | A comunicação entre processos e o escalonador |

## 1. Contexto

A entrega de uma mensagem entre dois processos existia desde o incremento
anterior, e ela funcionava. O que **não** existia era a **espera**: a
chamada que toma uma mensagem devolvia o erro de fila vazia, e o programa
de usuário repetia a chamada até a mensagem chegar.

A repetição funciona, e ela tem três custos:

1. **A tarefa acordada ocupa o processador.** O laço de repetição é uma
   espera ocupada: a tarefa chama, recebe o erro, chama de novo, e o
   escalonador a escolhe de novo no próximo tique. O núcleo não tem
   trabalho útil para fazer enquanto isso, e o atraso da entrega é o do
   tique do temporizador, e não o do trabalho que a outra tarefa tinha
   para fazer.
2. **A latência medida não é a da entrega.** O que o canal media era o
   intervalo entre a mensagem sair e a verificação seguinte, e não o
   intervalo entre a mensagem sair e a mensagem chegar.
3. **O programa de usuário precisa conhecer o protocolo da espera.** O
   laço de repetição é uma convenção, e ela é diferente para cada forma de
   espera.

O item pendente do marco F3 era, portanto, a **espera de verdade**: a
tarefa que espera **não** é executada, e o escalonador escolhe outra.

## 2. A decisão

### 2.1 A chamada que bloqueia é uma chamada nova

A chamada que toma uma mensagem **não muda de significado**. A nova
chamada, de número 8, é a que bloqueia, e ela recebe o contrato novo
`syscall_abi = 3`.

A razão de não mudar o significado da chamada antiga é a regra do
próprio contrato: um programa compilado contra a versão anterior tem de
continuar funcionando, e o significado de uma chamada publicada é
identidade dele.

### 2.2 A tarefa que espera não é executada

A tarefa que espera é marcada como bloqueada, e o escalonador não a
escolhe. A tarefa **não** fica em um laço, e o processador executa outra
tarefa.

O escalonador ganhou um cuidado: a tarefa que sai do processador é
marcada como pronta **apenas quando ela estava rodando**. Uma tarefa
bloqueada que sai do processador continua bloqueada, e ela só é escolhida
de novo quando a mensagem chega. Sem esse cuidado, a tarefa bloqueada
seria reescalonada no tique seguinte, e a espera seria um laço ocupado
com um caminho mais comprido.

### 2.3 A entrega escreve o resultado no contexto salvo da tarefa

A mensagem que chega a uma tarefa que espera **não fica na fila**. A
entrega escreve o tipo e o valor **direto no contexto salvo da tarefa**,
nos campos que a chamada devolveu, e acorda a tarefa.

A tarefa continua **depois** da chamada, com o resultado nos mesmos
registradores que uma chamada que tivesse respondido de imediato. O
programa de usuário não sabe que houve uma espera: ele chamou, e o
resultado está onde o contrato diz que ele estaria.

O canal não conhece o escalonador. A espera é um par de ponteiros para as
duas palavras do resultado, mais o endereço da tarefa e a rotina que a
acorda, e o escalonador é quem entrega a rotina. O canal escreve
apenas nos dois ponteiros.

### 2.4 O quadro da chamada tem o formato do quadro da interrupção

A tarefa bloqueada sai do núcleo pelo **mesmo caminho** pelo qual uma
tarefa preemptada sai: a entrada da chamada entrega o controle ao
escalonador, e a troca de contexto monta o quadro do processo que entra.

Para que o mesmo switch sirva aos dois casos, o quadro da chamada de
sistema tem de ter **exatamente** o formato do quadro do stub da
interrupção: os quinze registradores, o vetor, a palavra do código de
erro, e o quadro de retorno do processador. A entrada da chamada passou a
montar as duas palavras do vetor e do código de erro, e a voltar para o
modo de usuário ela pula as duas palavras, como o stub faz.

**O que essa unificação impede:** a entrada da chamada e o stub da
interrupção leriam o quadro com deslocamentos diferentes, e o quadro
salvo de uma tarefa bloqueada seria lido no lugar errado — o endereço de
retorno trocado com as flags, por exemplo.

### 2.5 A entrega é direta, e a latência é a da entrega

O caminho único de uma mensagem que sai é o que marca o momento da saída.
A entrega marca o momento da chegada, e a latência é a diferença entre os
dois.

O resultado é uma medição de verdade: o tempo entre a mensagem sair e a
tarefa que a esperava receber. A medição é lida no relógio do processador,
e o valor reportado é de cerca de duzentos mil ciclos, o que é da ordem
de dezenas de microssegundos.

### 2.6 A espera sem outra tarefa é um erro

A chamada que bloqueia devolve o erro 9 quando não há outra tarefa para
executar. Uma espera que seria a única tarefa do sistema seria um laço
ocupado, e o núcleo tem de dizer isso em vez de esperar para sempre.

## 3. O que foi descartado

### 3.1 A espera por rotação

A tarefa que espera poderia continuar na fila de prontidão, e o
escalonador a escolheria de novo, e ela verificaria de novo a fila. É a
implementação simples, e é a que o programa de usuário já fazia na mão.

Ela foi descartada porque a tarefa acordada ocupa o processador, e
porque a latência da entrega continua sendo a do tique do temporizador.

### 3.2 A chamada que bloqueia com o mesmo número da que não bloqueia

A chamada que toma uma mensagem poderia ter ganhado um argumento que
dissesse se ela bloqueia, e o contrato não mudaria de número.

Foi descartado porque o argumento teria de ter um valor padrão para os
programas antigos, e a chamada teria dois comportamentos com o mesmo
número. O contrato do projeto é explícito: o número é a identidade da
chamada.

### 3.3 O laço de espera no núcleo

A espera poderia ser feita com um laço de `hlt` dentro do núcleo, e a
tarefa seria acordada por um tique. Isso não é uma espera: a tarefa
continua ocupando a pilha do núcleo, e o núcleo não pode fazer nada
enquanto isso.

## 4. A consequência para o escalonador

O escalonador ganhou três estados com significado: pronta, bloqueada e
terminada. A tarefa bloqueada não é escolhida, e a rotina que a acorda a
devolve ao estado de pronta.

A troca de contexto ganhou um caminho novo, e o caminho antigo — a
troca pelo temporizador — continua igual. Os dois caminos terminam no
mesmo switch, e por isso o switch lê o mesmo formato de quadro.

## 5. A consequência para o contrato

O contrato da chamada de sistema passou para a versão 3, com a chamada 8.
As chamadas 1 a 7 **não mudaram** de número nem de significado.

A chamada 8 tem duas propriedades que a contrato precisa declarar:

1. o resultado da chamada chega **depois**, no contexto salvo da tarefa,
   e a tarefa continua depois da chamada;
2. a chamada pode devolver o erro 9, e o erro 9 é o único que diz que a
   espera **não** foi possível.

## 6. A verificação

O teste de boot automatizado verifica, além do que já era verificado:

- que as duas tarefas de usuário **bloquearam** e foram acordadas pela
  mensagem, e não por um laço de repetição: o programa de usuário mode
  **não** tem mais laço de repetição, e a resposta do outro processo
  chegou;
- que a entrega foi **direta**, com o contador de entregas a uma tarefa
  que esperava;
- que a latência relatada é a **da entrega**, e não a do tique do
  temporizador;
- que o número de tarefas prontas e o de tarefas bloqueadas são
  relatados, com uma verificação por padrão, porque os números variam de
  uma execução para a outra.

O teste roda em `zig build qemu-test`, e o conjunto completo roda em
`zig build check`.

## 7. O estado

| Item | Estado |
|------|--------|
| Espera de verdade, sem ocupar o processador | IMPLEMENTADO — TESTADO LOCALMENTE |
| Entrega direta ao contexto da tarefa | IMPLEMENTADO — TESTADO LOCALMENTE |
| Quadro da chamada com o formato do quadro da interrupção | IMPLEMENTADO — TESTADO LOCALMENTE |
| Latência da entrega medida | IMPLEMENTADO — TESTADO LOCALMENTE |
| Espera com prazo | PROPOSTO |
| Várias esperas por tarefa | PROPOSTO |
| Transferência de capacidades do VNC | PROPOSTO |
