//************************************************************************//
//  ADR-0008.md                                                          //
//************************************************************************//
//                         This file is part of:                          //
//                               VorynOS                                  //
//              https://github.com/CeoMatheusDev/VorynOS                  //
//************************************************************************//
// Copyright (C) 2026 VorynOS contributors.                               //
//                                                                        //
// SPDX-License-Identifier: GPL-3.0-only                                  //
//************************************************************************//

# ADR-0008 — A exceção de um processo mata o processo, e não a máquina

| Campo | Valor |
|-------|-------|
| **Estado** | ACEITO |
| **Data** | 2026-10-22 |
| **Escopo** | O tratamento das exceções e a recuperação dos processos |

## 1. Contexto

O núcleo tratava **toda** exceção da mesma forma: imprimia o diagnóstico e
parava a máquina. O modo de usuário existia e funcionava, mas um processo
que escrevesse em um endereço não mapeado derrubava o sistema inteiro.

Isso é errado por três razões:

1. **Um defeito de um processo não é um defeito do núcleo.** O processo que
   escreve fora da sua janela tem um defeito, e o defeito é dele. A
   máquina tem outros processos, e derrubá-los por causa de um é
   transformar um erro local em um erro geral.
2. **O sistema perde a evidência do defeito.** Com a máquina parada, o
   diagnóstico é o que fica, e não há como comparar o comportamento do
   processo que falhou com o dos que continuaram.
3. **O limite do privilégio vira decorativo.** O terceiro nível de
   privilégio isola a **memória**, e não o **comportamento**: um processo
   pode, com uma instrução só, parar o sistema.

O item pendente do marco F3 era exatamente este: o **tratamento por tipo**
das exceções, com um teste de recuperação.

### 1.1 O defeito que escondia o problema

O quadro que o processador deixa quando uma exceção acontece tem **dois
formatos**, e a diferença é a presença do código de erro.

O processador empurra, nesta ordem: o código de erro (só nas exceções que
têm um), o `RIP`, o `CS`, as flags, o `RSP` e o `SS`. O stub da exceção
empurra, por cima disso: um marcador, o número do vetor e os quinze
registradores.

O resultado é que o quadro das exceções que **têm** código de erro é
**oito bytes maior** do que o das que não têm. O código de erro fica
entre o número do vetor e o `RIP`, e todos os deslocamentos depois dele mudam.

O tratador e o switch do contexto liam as posições do quadro de **uma das
duas formas**, e a escolha dependia do vetor. Um switch que leu o quadro
na forma errada lê o `SS` no lugar do `RFLAGS`, e o processador volta
para o código do usuário com um segmento de pilha que não é segmento de
pilha nenhum: o resultado é a exceção 13, a falta de segmento de pilha,
com um `SS` igual a zero.

Este defeito **já existia** antes do incremento. Ele não aparecia porque
nenhuma exceção com código de erro tinha acontecido no caminho de
recuperação: até aqui, toda exceção parava a máquina de qualquer forma.

### 1.2 A forma do quadro é um contrato, e não um detalhe

A correção estrutural não é "ler o quadro na forma certa em cada
chamada". A correção é **uma forma só**.

O stub de uma exceção **com** código de erro **normaliza** o quadro: ele
salva o código de erro em uma posição conhecida e move as cinco palavras
do retorno do processador **oito bytes para baixo**. O stub de uma
exceção **sem** código de erro já produz o quadro nessa forma.

Depois da normalização, o tratador, o switch do contexto e a volta do
processador leem **as mesmas posições**, e o formato do quadro deixa de
ser uma preocupação de cada chamada. É a mesma regra que o ADR-0007
estabeleceu para o quadro da chamada de sistema: um quadro, um switch.

## 2. A decisão

### 2.1 A exceção é classificada pelo segmento de código

A classificação é feita pelo `CS` do quadro do processador, que é a
evidência mais direta do nível de privilégio em que o erro aconteceu:

| Origem | `CS` | Tratamento |
|--------|------|------------|
| Modo de usuário | `0x1b` | O processo é morto, e o núcleo continua |
| Modo de núcleo | `0x08` | A máquina para |

A exceção no núcleo é fatal **por princípio**, e não por falta de
alternativa: o estado do núcleo é desconhecido depois de um erro, e
continuar a partir dele é pior do que parar. Um núcleo que continua com
o estado corrompido produz erros que não têm relação com a causa.

### 2.2 O processo morto não volta para o código que falhou

O processo morto não pode voltar para a instrução que levantou a
exceção: a instrução que levantou a falta de página levanta a falta de
página **de novo**, e o núcleo entra num laço de exceções.

O quadro do processador é **reescrito** no caminho de volta:

- o `RIP` aponta para o **laço da tarefa morta**, no núcleo;
- o `CS` e o `SS` são os segmentos do núcleo;
- o `RSP` é a pilha do núcleo da tarefa.

As flags **não** são tocadas. O laço espera por uma interrupção com o
`hlt`, e o temporizador é o que tira a tarefa de lá. Um laço com o `cli`
pararia a máquina inteira, porque a tarefa morta estaria esperando com as
interrupções desligadas.

O escalonador **não** escolhe a tarefa de novo, porque a tarefa foi
marcada como terminada. O próximo tique do temporizador escolhe a
primeira tarefa pronta, e a tarefa morta continua no laço, sem rodar.

### 2.3 A tarefa morta é contada

O escalonador conta as tarefas mortas, e o relatório do núcleo mostra o
número. Um número que é zero em toda execução é um número que não diz
nada; o número é a evidência de que a recuperação aconteceu.

## 3. O que foi descartado

### 3.1 Deixar o processo repetir a exceção

Descartado. A instrução que falhou falha de novo, e o console enche de
relatórios de exceção até o núcleo parar. O laço de exceções é um
sintoma, e não uma política de recuperação.

### 3.2 A recuperação dentro do processo, com um sinal

Descartado **por agora**. A entrega de um sinal ao processo, com um
tratador no espaço do usuário, é o modelo do POSIX e é o modelo certo
para um sistema que vai ter bibliotecas. Ele exige, antes: uma forma de
o processo instalar o tratador, um quadro de entrega no espaço do
usuário, e a preservação do estado da tarefa para o retorno. É o
incremento seguinte, e não este.

### 3.3 Matar a máquina e reiniciar

Descartado. O objetivo do marco é que um processo possa falhar sem
derrubar o sistema, e reiniciar a máquina não é isso.

### 3.4 A exceção com o tratamento no switch

Descartado. O switch do contexto é chamado em dois momentos: a preempção
e o bloqueio de uma tarefa. Ele não sabe de onde veio, e tornar o switch
inteligente sobre a origem do quadro mistura duas responsabilidades que
estão separadas de propósito.

## 4. A consequência para o escalonador

O escalonador ganhou uma operação, `killCurrent`, que marca a tarefa
corrente como terminada, conta a morte e **não** devolve a tarefa para a
fila das prontas.

A regra que já existia no `prepareNext` — a tarefa que sai só volta para
pronta se ela **estava** rodando — é a que torna a operação segura: uma
tarefa bloqueada e uma tarefa terminada não voltam para a fila por
acidente. O incremento **não** precisou mudar essa regra, e é por isso
que a regra existia.

## 5. A consequência para o contrato

O contrato da chamada de sistema **não muda**: nenhuma chamada nova, e
nenhuma chamada muda de número ou de significado.

O contrato da **chamada** não muda porque a morte do processo é um
evento do núcleo, e não um resultado de chamada. O processo que provocou
a exceção não recebe um código de erro: ele não recebe nada, porque ele
não continua.

A única mudança visível é a **forma do quadro**, e ela é interna ao
núcleo: os stubs, o tratador e o switch leem a mesma forma. O quadro
continua sendo o mesmo objeto — o contexto salvo da tarefa, com os
quinze registradores, o vetor e as palavras do retorno do processador.

## 6. A verificação

O teste de boot automatizado verifica, além do que já era verificado:

- que um terceiro processo, que escreve em um endereço que não está
  mapeado, **provoca** a exceção 14, com o código de erro 6, e o
  relatório mostra o `RIP` do usuário e o `CS` do usuário;
- que o processo é **morto**, e o console diz que o núcleo continua;
- que o número de tarefas mortas é **relatado**;
- que a máquina **continua**: o temporizador continua contando, a
  conversa entre os outros dois processos **completa** o ida e volta, e
  a máquina chega à marca `VORYN-KERNEL-READY`.

O teste roda em `zig build qemu-test`, e o conjunto completo roda em
`zig build check`.

## 7. O estado

| Item | Estado |
|------|--------|
| Quadro do processador com uma forma só | IMPLEMENTADO — TESTADO LOCALMENTE |
| Exceção do modo de usuário mata o processo | IMPLEMENTADO — TESTADO LOCALMENTE |
| Exceção do modo de núcleo é fatal | IMPLEMENTADO — TESTADO LOCALMENTE |
| O núcleo continua depois da morte do processo | IMPLEMENTADO — TESTADO LOCALMENTE |
| A tarefa morta não volta para o código que falhou | IMPLEMENTADO — TESTADO LOCALMENTE |
| Contagem das tarefas mortas | IMPLEMENTADO — TESTADO LOCALMENTE |
| Sinal no processo, com tratador no espaço do usuário | PROPOSTO |
| Exceção por tipo, com política diferente por vetor | PROPOSTO |
| Relatório do estado do processo no momento da morte | PROPOSTO |
