# Estratégia de teste do VorynOS

| Campo | Valor |
|-------|-------|
| **Estado** | ACEITO |
| **Data** | 2026-10-21 |

## 1. Princípio

Nenhuma funcionalidade é declarada funcionando sem um comando executado que
demonstre o comportamento. A estratégia separa o que pode ser testado sem
hardware do que exige emulação ou máquina real, e mantém a separação entre
**implementado** e **validado** visível em `docs/roadmap/phase-status.md`.

## 2. Camadas

| Camada | Onde | O que cobre | Comando |
|--------|------|-------------|---------|
| L1 — Unidade | Host | Lógica pura: ELF64, mapa de memória, contrato de handoff, formatos | `zig build test` |
| L2 — Integração de boot | QEMU + OVMF | Cadeia completa firmware → loader → kernel | `zig build qemu-test` |
| L3 — Comportamento no QEMU | QEMU + OVMF | Comportamento observável (exceções, temporizador, alocadores) | script dedicado, a criar por marco |
| L4 — Hardware | PC real | Boot em hardware, drivers físicos, desempenho | a criar quando existir hardware-alvo |
| L5 — Desempenho | Host e QEMU | Métricas de boot, latência, memória | a criar com F10 |

## 3. L1 — Testes de unidade

Os módulos de `shared/` são compilados para o host e testados com
`std.testing`. São módulos sem alocação e sem dependência de sistema, o que
permite testar a lógica que roda dentro do kernel e do loader:

- `shared/elf64.zig`: cabeçalho malformado, segmento fora do arquivo, entry
  point inválido, segmento sem RAM por trás, número excessivo de segmentos.
- `shared/memmap.zig`: busca de região, faixa utilizável, overflow de
  endereço, resumo do mapa, região de carga com alinhamento e limite
  inferior.
- `shared/handoff.zig`: magic, versão, tamanho do cabeçalho, coerência do
  mapa de memória.

Regra: todo módulo de `shared/` nasce com testes, porque é a camada que o
kernel vai depender para não repetir erro de firmware.

## 4. L2 — Teste de boot no QEMU

`scripts/qemu-boot-test.sh` executa a imagem de disco no QEMU com OVMF,
captura o console serial e verifica marcadores de progresso:

```text
ok: found '[VNB] VorynOS'
ok: found '[VNB] kernel placed'
ok: found '[VNK] Voryn Nucleus Kernel'
ok: found '[VNK] handoff ok'
ok: found 'VORYN-KERNEL-READY'
qemu-boot-test: all checks passed
```

O teste também falha se o console contiver a marca `FATAL`, o que detecta
falhas que não param o boot mas indicam estado incorreto.

Características:

- Determinístico: a imagem é construída pelo próprio projeto, sem
  dependência de estado externo.
- Sem rede e sem interação: o emulador é encerrado por tempo.
- O console serial é o canal verificado, porque é o único que existe dos dois
  lados da fronteira firmware/kernel.

## 5. L3 — Comportamento no QEMU

A ser criado no F2, junto das exceções e do temporizador. Exemplo de
critério: o kernel provoca uma `#DE` e imprime o vetor, o código de erro e o
RIP, e o teste verifica a presença do código de erro e que o kernel continua
executando depois da exceção.

## 6. L4 — Hardware

Requer máquina física com UEFI e hardware de referência. Enquanto isso não
existir, toda afirmação sobre hardware real é marcada como não verificada.
O emulador não substitui o hardware: diferenças de firmware, de tabela de
página, de temporizador e de console são previsíveis.

## 7. Evidências

Toda execução de teste relevante é registrada com:

1. comando exato;
2. saída real;
3. ambiente (versão do Zig, QEMU, OVMF, máquina);
4. data.

O relatório de incremento em `AGENTS.md` §4.8 segue esse formato. Resultados
nunca são inventados nem arredondados para "corretos".

## 8. Limitações do conjunto atual

- Não há teste de fuzzing ainda. O leitor ELF64 é o alvo prioritário,
  porque processa entrada não confiável do firmware.
- Não há teste de concorrência: ainda não há código concorrente.
- Não há medição de desempenho: o conjunto mede correção, não velocidade.
  A primeira medição (tempo de boot) entra no F2.
