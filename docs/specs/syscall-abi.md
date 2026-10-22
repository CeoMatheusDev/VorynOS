# VSC-0001 — Contrato da chamada de sistema do VorynOS

| Campo | Valor |
|-------|-------|
| **Estado** | ACEITO |
| **Data** | 2026-10-22 |
| **Escopo** | A interface entre o modo de usuário e o núcleo |
| **Versão do contrato** | `syscall_abi = 2` |

## 1. Objetivo

Definir a interface da chamada de sistema do VorynOS: como o modo de usuário
pede uma operação ao núcleo, como o núcleo responde, e como um programa
descobre que a operação não foi feita.

O contrato é **estável**: um programa de usuário compilado contra a versão 1
continua funcionando quando o núcleo passa para a versão 2, e o núcleo
precisa **recusar** um número de chamada que não conhece, em vez de adivinhar
o seu significado.

A versão 2 acrescenta as chamadas de canal e a chamada que copia um bloco
entre dois processos. As chamadas da versão 1 **não mudam de número e não
mudam de significado**.

## 2. O mecanismo

A chamada é entregue pela instrução `syscall`, o caminho que a arquitetura
prevê para o modo de 64 bits. A instrução:

- carrega o código e a pilha do núcleo a partir de `IA32_STAR`;
- carrega o endereço de entrada a partir de `IA32_LSTAR`;
- aplica a máscara `IA32_SFMASK` às flags de quem chamou;
- deixa o endereço de retorno no registrador `RCX` e as flags de quem
  chamou no registrador `R11`.

A entrada da chamada está na pilha do núcleo da tarefa, e o quadro de
retorno de interrupção com o estado do usuário é montado na volta, com a
instrução `iretq`. O tratador **nunca** roda sobre a pilha do usuário.

## 3. O registro de chamada

```text
registrador  uso
RAX          o número da chamada, e o resultado da chamada
RDI          o primeiro argumento
RSI          o segundo argumento
RDX          o terceiro argumento
R8           o quarto argumento
RCX          o endereço de retorno (gravado pela instrução)
R11          as flags de quem chamou (gravado pela instrução)
```

`RCX` e `R11` **não são argumentos**: a instrução da chamada os escreve, e
um programa que precisa de um quarto argumento tem de usar `R8`. Um erro
clássico é usar `RCX` para o valor de uma mensagem: o valor que o núcleo
recebe é o endereço de retorno, e a mensagem chega com o valor errado.

Os argumentos que não são usados por uma chamada não têm significado. Um
programa de usuário **não pode** presumir que os registradores que a
arquitetura não salva estejam intactos depois da chamada: o tratador
preserva os que a convenção de chamada exige, e o núcleo documenta quais
são eles.

## 4. As chamadas da versão 1

| Número | Chamada | Argumentos | Resultado |
|--------|---------|-----------|-----------|
| 1 | `ping` | — | `0x42`, um valor conhecido |
| 2 | `write` | `RDI` buffer, `RSI` comprimento, `RDX` arquivo | o número de bytes escritos |
| 3 | `memcpy` | `RDI` destino, `RSI` origem, `RDX` comprimento | o número de bytes copiados |
| 4 | `exit` | `RDI` código de saída | — |

### 4.1 `ping`

A chamada não tem argumento e responde com um valor conhecido. Ela existe
para provar que a instrução, os registradores de modelo e a volta funcionam,
e é a chamada que o auto teste do núcleo usa.

### 4.2 `write`

Escreve um bloco de bytes no arquivo indicado. A versão 1 conhece apenas o
console do núcleo, o arquivo `1`; qualquer outro arquivo é recusado.

O bloco pertence ao usuário, e o núcleo **confere a faixa nas tabelas de
página** antes de ler: a página tem de estar presente, tem de ter o bit de
usuário, e o comprimento tem de estar no limite do contrato. Uma chamada
com um endereço do núcleo é recusada, e o núcleo não lê a memória.

A conferência é feita nas tabelas do **espaço de endereço do processo que
chamou**, porque as páginas do usuário mode vivem nesse espaço e em nenhum
outro.

### 4.3 `memcpy`

Copia um bloco de bytes de um endereço do usuário para outro endereço do
usuário. As duas faixas são conferidas nas tabelas de página antes da
cópia, e a cópia é feita pelo núcleo, de modo que o usuário não precisa ter
uma rotina própria para isso.

A origem tem de estar presente e ter o bit de usuário; o destino tem de
estar presente, ter o bit de usuário e ser gravável.

A cópia tolera faixas que se sobrepõem: quem escolhe os dois endereços é o
usuário, e uma cópia que recusasse a sobreposição negaria uma chamada
legítima. A cópia é feita do fim para o começo quando as faixas se
sobrepõem, e o resultado é o mesmo que a cópia de uma máquina de Turing.

### 4.4 `exit`

Ende a tarefa do usuário. O núcleo marca a tarefa como terminada e o
escalonador não a escolhe de novo; o processador deixa a tarefa na próxima
interrupção. O código de saída fica registrado na tarefa.

## 5. As chamadas da versão 2

| Número | Chamada | Argumentos | Resultado |
|--------|---------|-----------|-----------|
| 5 | `send` | `RDI` canal, `RSI` lado, `RDX` tipo, `R8` valor | zero, quando a mensagem foi posta na fila |
| 6 | `receive` | `RDI` canal, `RSI` lado | o tipo da mensagem, e o valor no `RDX` |
| 7 | `copy_to` | `RDI` processo, `RSI` destino, `RDX` origem, `R8` comprimento | o número de bytes copiados |

### 5.1 `send`

Põe uma mensagem na fila de um lado de um canal. Os argumentos são o
identificador do canal, o lado que recebe a mensagem, o tipo da mensagem e
o valor da mensagem.

O lado é um argumento, e não uma regra da chamada, porque **um canal
pertence a duas tarefas e cada lado do canal é uma tarefa**: quem manda
escolhe o lado de quem recebe, e quem recebe escolhe o mesmo lado. Com
essa regra a mensagem nunca volta para quem mandou, e dois processos
conversam pelo mesmo canal sem tomar a mensagem um do outro.

O canal tem uma fila por lado, e a fila é limitada a dezesseis mensagens.
Uma fila cheia recusa a mensagem, e a recusa é contada.

### 5.2 `receive`

Toma uma mensagem de um canal. Os argumentos são o identificador do canal e
o lado que guarda a mensagem. O resultado é o tipo da mensagem, e o valor
da mensagem volta no `RDX`.

A chamada **não bloqueia**: uma fila vazia devolve o erro 5, e o programa
repete a chamada até a mensagem chegar. O bloqueio é um incremento
separado, porque ele exige que a chamada consiga continuar depois que a
mensagem chega.

### 5.3 `copy_to`

Copia um bloco de bytes do espaço do processo que chamou para o espaço de
outro processo. Os argumentos são o identificador do processo de destino, o
endereço do destino no espaço de destino, o endereço da origem no espaço de
quem chamou, e o comprimento do bloco.

Os dois espaços não nomeam as mesmas páginas, portanto o núcleo não copia
o bloco com um único movimento: ele lê a origem com o espaço de quem
chamou ativo, guarda o bloco num buffer do núcleo, e escreve o destino com
o espaço de destino ativo. O buffer vive na imagem do núcleo, e a imagem
está mapeada em todos os espaços, e por isso o buffer é alcançável nas
duas direções da troca.

As duas faixas são conferidas nas tabelas do espaço de cada uma, e o espaço
de quem chamou é restaurado no fim, qualquer que seja o resultado da cópia.

## 6. O resultado e os erros

O resultado da chamada volta em `RAX`. Um resultado **negativo** significa
que a chamada **não foi feita**, e o valor absoluto do resultado é o código
do erro:

| Código | Erro | Significado |
|--------|------|-------------|
| 1 | chamada desconhecida | o número da chamada não existe nesta versão |
| 2 | endereço inválido | uma das faixas não pertence ao modo de usuário |
| 3 | comprimento inválido | o comprimento é zero ou maior que o limite |
| 4 | não permitida | a chamada não é permitida ao nível de privilégio de quem chamou |
| 5 | fila vazia | o lado do canal não tem mensagem |
| 6 | canal desconhecido | o identificador do canal não existe |
| 7 | fila cheia | o lado do canal não aceita mais mensagens |
| 8 | processo desconhecido | o identificador do processo não existe |

O limite de comprimento é de **64 KiB** por chamada, e ele existe para que
o núcleo não passe um tempo indeterminado dentro de uma chamada.

Um resultado que não é negativo é o número de bytes processados, e nunca é
negativo, de modo que o programa de usuário distingue os dois casos sem
conhecer os códigos de erro.

## 7. As regras do contrato

1. Um número de chamada novo **nunca** reaproveita o número de uma
   chamada existente: o número é a identidade da chamada para sempre.
2. Uma chamada nova entra no fim da lista, e o contrato incrementa a
   versão.
3. Um número de chamada desconhecido é recusado com o erro 1. O núcleo
   **não pode** adivinhar o significado de um número.
4. O usuário é o dono da memória dele: toda faixa que o núcleo toca por
   causa de uma chamada é conferida nas tabelas de página antes.
5. O tratador roda na pilha do núcleo da tarefa, e não na pilha do usuário.
6. A chamada nunca altera o estado de privilégio de quem chamou além da
   ida e da volta, e a volta devolve os flags de quem chamou.
7. Os argumentos de uma chamada que passa de três usam `R8`, e nunca `RCX`
   nem `R11`, porque a instrução da chamada escreve os dois.
8. Uma chamada que confere uma faixa confere a faixa **no espaço de
   endereço de quem chamou**, e não no espaço do núcleo.

## 8. O que a versão 2 não tem

- **Transferência de capacidades.** A chamada não carrega capacidades, e
  a pergunta aberta do ADR-0001 sobre o modelo de capacidade continua
  aberta.
- **Arquivos.** A chamada `write` conhece apenas o console.
- **Estrutura de mensagem.** Não há formato de mensagem definido, e a
  mensagem do canal carrega um tipo e um valor.
- **Chamada que bloqueia.** A chamada que toma uma mensagem não bloqueia.
- **Vários processos por chamada.** A chamada `copy_to` conhece o
  processo de destino pelo identificador, e não por um nome de arquivo
  nem por um caminho.
