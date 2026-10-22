# ADR-0004 — Armadilhas de ABI x86_64 encontradas na bring-up do VNK

| Campo | Valor |
|-------|-------|
| **Estado** | ACEITO — as armadilhas estão registradas e o código as evita |
| **Data** | 2026-10-21 |
| **Decidido por** | Engenharia VorynOS |
| **Contexto** | Marco F2, bring-up do núcleo |

## 1. Contexto

A instalação das estruturas de segmento, de interrupção e de paginação do
kernel encontrou uma série de erros que não produzem falha de compilação e
que o emulador reporta de forma pouco óbvia. Todos foram diagnosticados com o
registro de exceções do QEMU (`-d int`), que mostra o vetor, o código de
erro e o estado do processador no momento da falha.

Este documento registra as armadilhas, para que elas não voltem a aparecer
e para que a leitura do código do kernel seja mais rápida.

## 2. As armadilhas

### 2.1 A entrada da tabela de segmentos tem oito bytes

A estrutura da entrada é composta por dois quad words, não por um par de
quad words. Com entradas de dezesseis bytes, o deslocamento de cada
descritor era o dobro do esperado e **todos** os seletores apontavam para o
descritor errado.

```zig
const Entry = extern struct {
    low: u32 = 0,   // limite e base baixa
    high: u32 = 0,  // byte de acesso, flags e base alta
};
```

### 2.2 O seletor codifica o deslocamento em bytes

O seletor não é um índice: os bits de zero a doze são o **descolamento em
bytes** do descritor na tabela, o bit três é o indicador de tabela e os bits
quatro e cinco são o nível de privilégio. O indicador de tabela fica **dentro**
do campo de deslocamento, portanto o seletor não pode ser descrito por uma
estrutura empacotada e é montado por uma função.

```zig
pub fn makeSelector(byte_offset: u13, table_indicator: u1, rpl: u2) u16 {
    return @as(u16, byte_offset) | (@as(u16, table_indicator) << 3) | (@as(u16, rpl) << 4);
}
```

### 2.3 O descritor da segmentação de tarefa precisa do bit de presença

Para descritores de sistema, o byte de tipo carrega o bit de presença na
posição mais alta. Um segmento de tarefa de 64 bits presente e disponível tem
o tipo `0x89`, e não `0x09`. Com `0x09` o processador recusa a instrução
`ltr` com uma falha de segmento de pilha (#SS) cujo código de erro é o
próprio seletor do segmento.

### 2.4 A porta da tabela de interrupções tem um byte de índice de pilha

O formato da porta de interrupção é:

```text
0-1   deslocamento do tratador, parte baixa
2-3   seletor do segmento de código
4     índice da tabela de pilha de interrupção nos três bits baixos
5     tipo da porta, nível de privilégio e bit de presença
6-7   deslocamento do tratador, parte média
8-11  deslocamento do tratador, parte alta
12-15 reservado
```

Omitir o byte do índice desloca o tipo da porta e o processador entrega a
exceção para um endereço inválido, o que resulta em uma sequência de falhas
de página que não tem relação com a causa original.

### 2.5 A tabela de segmentos precede a tabela de interrupções

As portas da tabela de interrupções carregam um seletor de segmento de
código. Se a tabela de interrupções for instalada enquanto a tabela de
segmentos do firmware ainda estiver ativa, o seletor pode não existir na
tabela do firmware (o OVMF usa `0x38` para o código e `0x30` para os dados) e
a entrega da exceção falha com uma falha de proteção geral.

A ordem correta é: **tabela de segmentos, depois tabela de interrupções**.
O kernel também precisa do segmento de tarefa para o índice de pilha da
porta, o que exige que ele seja carregado depois da tabela de interrupções,
para que uma falha seja relatada pelo tratador do próprio kernel.

### 2.6 A instrução `ltr` opera com dezesseis bits

O montador integrado do Zig promove o operando de registro para a forma de
trinta e dois bits, que é uma codificação diferente da instrução. A forma de
dezesseis bits só é alcançável pela forma de memória:

```asm
    movw %di, voryn_tss_selector(%rip)
    ltrw voryn_tss_selector(%rip)
```

O mesmo vale para a tabela de segmentos e para a de interrupções: `lgdt` e
`lidt` não têm forma de registro, o operando é sempre a memória.

### 2.7 O retorno distante exige um seletor estendido com zeros

O retorno distante lê o seletor de um quad word completo e recusa um seletor
cujos bits superiores não sejam zero. Os bits superiores do registrador de
argumento não são definidos pela ABI, portanto o seletor tem de ser
estendido explicitamente.

A troca distante foi preferida ao retorno distante: ela não toca a pilha e
elimina uma classe de problemas de alinhamento do quadro removido.

### 2.8 A montagem embutida do Zig 0.17 tem regras próprias

- O operando de entrada tem de ser um **identificador**, não uma expressão:
  um endereço ou uma conversão precisa estar numa variável local.
- A seção de operandos tem sempre **três** seções: saídas, entradas e
  registradores alterados. Uma seção de entradas vazia continua sendo uma
  seção.
- As instruções sem forma de registro precisam ficar em assembly.

## 3. Decisão

Cada armadilha tem uma forma no código que a evita:

| Armadilha | Forma no código |
|-----------|------------------|
| Entrada de oito bytes | `kernel/arch/x86_64/segment.zig` |
| Seletor por deslocamento | `makeSelector` |
| Bit de presença do segmento de tarefa | `task_type = 0x89` |
| Byte do índice de pilha | `kernel/arch/x86_64/interrupt.zig` |
| Ordem das instalações | `kernel/main.zig` |
| Seletor de dezesseis bits | `kernel/arch/x86_64/segment.s` |
| Seletor estendido com zeros | `movzwq` antes do salto distante |
| Regras da montagem embutida | acessos em assembly |

## 4. Consequências

- A bring-up do núcleo não pode ser feita apenas com o compilador: o
  registro de exceções do QEMU foi a ferramenta que transformou um
  sintoma (a máquina parada) em uma causa (o vetor e o código de erro).
- O teste automatizado verifica a instalação de cada estrutura pelo valor
  lido de volta do processador (`sgdt`, `sidt`) e pelo efeito observável
  (a contagem de interrupções do temporizador).
- As estruturas do processador têm um teste de integração, porque dependem
  do estado do processador e não podem ser exercitadas no host.
