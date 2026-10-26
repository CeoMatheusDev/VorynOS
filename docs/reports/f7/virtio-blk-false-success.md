# Relatório F7 — falso sucesso nos stubs do Virtio Block

| Campo | Valor |
|-------|-------|
| **Data** | 2026-10-26 |
| **Base inspecionada** | `11575a06eeb580c1f168cbe5870548e660dafc9b` (`main`, igual a `origin/main` no início da sessão) |
| **Estado** | TESTADO LOCALMENTE (host) e TESTADO NO CI (boot QEMU/OVMF) |
| **Escopo** | `kernel/arch/x86_64/virtio_blk.zig` |
| **Toolchain** | Zig 0.17.0 |

## Problema original

`kernel/arch/x86_64/virtio_blk.zig` continha dois corpos vazios publicados
como operações de bloco:

```zig
pub fn blk_read() !void {
    // Stub: logs and returns; device not yet programmed.
}

pub fn blk_write() !void {
    // Stub: logs and returns; device not yet programmed.
}
```

O achado já estava registrado em
[`../audits/bootloader-2026-10-26.md`](../audits/bootloader-2026-10-26.md)
como P1 ("risco de falso sucesso"), sem tratamento naquele incremento.

## Causa do falso sucesso

Em Zig, uma função cujo tipo de retorno é `!void` e cujo corpo termina sem
`return` devolve o payload — isto é, **sucesso**. Um stub vazio, portanto,
não é neutro: ele publica uma leitura ou uma escrita concluída sem que
nenhum dispositivo tenha sido acessado. Verificado no compilador alvo, e não
por inspeção:

```text
// corpo vazio, conjunto de erros explícito
pub fn blk_read() BlkError!void {}

test "vazio" {
    try blk_read();          // -> OK, All 1 tests passed
}
```

A consequência não é teórica: qualquer chamador futuro — a camada de bloco,
um volume VNV, um teste de persistência — receberia `void` e concluiria que
os setores foram transferidos. O estado persistido seria silêncio.

## Alterações realizadas

Somente `kernel/arch/x86_64/virtio_blk.zig` foi alterado no código.

1. **Erro explícito.** `blk_read` e `blk_write` devolvem
   `error.NotImplemented` de forma incondicional.
2. **Conjunto de erros declarado.** `pub const BlkError =
   error{NotImplemented};`, no mesmo padrão de `virtio.QueueError` e
   `block.Error`, de modo que o contrato de erro faça parte da assinatura
   em vez de ser inferido do corpo. Nenhuma assinatura recebe parâmetros
   novos: não há chamador no repositório (a única referência é
   `_ = @import("virtio_blk.zig")` no bloco `test` de
   `kernel/arch/x86_64/root.zig`), e a semântica de `try`/`catch` não muda.
3. **Documentação do módulo.** Cabeçalho `//!` declarando que o Virtio Block
   não é um driver funcional, que as assinaturas não recebem LBA, buffer nem
   contagem de setores e que a integração com `block.Device` e a persistência
   física ficam para um incremento posterior.
4. **Comentários enganosos removidos.** Os stubs citavam `serial`, `sector`
   e `buf` — parâmetros que não existem na assinatura.

Nenhuma interface funcional foi inventada. Redesenhar a API seria declarar
um contrato que não foi decidido; este incremento apenas impede que o
contrato atual minta.

## Testes adicionados

Quatro testes em `virtio_blk.zig`, executados por `zig build test` através
do binário `arch-tests` (o módulo entra na compilação pelo bloco `test` de
`kernel/arch/x86_64/root.zig`):

| Teste | O que prova |
|---|---|
| `virtio-blk read returns an explicit error instead of success` | `blk_read()` devolve `error.NotImplemented` |
| `virtio-blk write returns an explicit error instead of success` | `blk_write()` devolve `error.NotImplemented` |
| `the block operations never succeed and ignore the presence of hardware` | chamadas repetidas devolvem sempre o mesmo erro documentado, sem estado oculto; nenhum ramo consulta um dispositivo |
| `the declared error set is the whole contract of the operations` | `BlkError` é o conjunto inferido das duas funções e tem exatamente um erro, `NotImplemented` |

Nenhum teste depende de hardware: o módulo não abre portas de I/O nem mapeia
barras, e roda no host.

### Prova de que os testes falham se o stub voltar

Com os dois corpos vazios restaurados, `zig build test` falha:

```text
error: 'virtio_blk.test.virtio-blk read returns an explicit error instead of success' failed:
       expected error.NotImplemented, found void
error: 'virtio_blk.test.virtio-blk write returns an explicit error instead of success' failed:
       expected error.NotImplemented, found void
error: 'virtio_blk.test.the block operations never succeed and ignore the presence of hardware' failed:
Build Summary: 33/35 steps succeeded (1 failed); 60/63 tests passed (3 failed)
```

O quarto teste (contrato do conjunto de erros) continua passando nesse
cenário, o que é esperado: ele verifica tipos, e o tipo não muda com o corpo
vazio. Os três testes de comportamento são os que capturam a regressão.

## Validação executada

O sandbox não tem Zig no `PATH` e `ziglang.org` não é alcançável. O
compilador oficial 0.17.0 foi obtido do wheel PyPI `ziglang==0.17.0`
(`zig version` → `0.17.0`), a mesma versão que a CI instala. QEMU e OVMF não
estão instalados e não são instaláveis no ambiente.

| Comando | Resultado real |
|---|---|
| `zig version` | `0.17.0` |
| `zig build test` | **PASS** (exit 0) — `arch-tests` foi de 59 para 63 testes; soma dos 17 binários de teste: 416 → 420 |
| `zig build` | **PASS** (exit 0) — `voryn-boot.efi`, `voryn-kernel` e `vorynos.img` (64 MiB) gerados |
| `zig build qemu-test` | **BLOQUEADO no sandbox** — `qemu-boot-test`: firmware OVMF não encontrado, script sai com código 2; `qemu-system-x86_64` ausente. **PASS na CI** (ver abaixo) |
| `zig build check` | **BLOQUEADO no sandbox** — falha transitiva em `qemu-test` (44/47 passos). **PASS na CI** (ver abaixo) |
| `git diff --check` | **PASS** — sem erro de whitespace |

O teste de boot não é afetado por esta mudança: `virtio_blk.zig` não é
importado por `kernel/main.zig` nem por nenhum outro arquivo fora do bloco
`test` de `kernel/arch/x86_64/root.zig`, portanto o módulo não é ligado à
imagem do kernel. Ainda assim o boot foi revalidado na CI, abaixo.

## Evidência da CI

Run [`40361111218`](https://github.com/CeoMatheusDev/VorynOS/actions/runs/40361111218),
job `121706477468`, commit `55d9fe3`, concluído em 3m10s com
`conclusion: success`. Os quatorze passos terminaram em `success`, entre
eles `Testes de unidade` (`zig build test`), `Construir` (`zig build`),
`Teste de boot no QEMU` (`zig build qemu-test`), `Verificação agregada`
(`zig build check`) e `Verificar os artefatos`.

O texto bruto do log fica em armazenamento externo fora do alcance do
sandbox de desenvolvimento, portanto este relatório registra a conclusão
estruturada de cada passo obtida pela API, e não cita linhas de marcador
que não foram lidas.

## Divergência de documentação corrigida

`docs/roadmap/phase-status.md` afirmava, na linha F7, que a Fase 3 havia
entregado "interfaces `read`/`write` e `transmit`/`receive`". No código
atual:

- `virtio_blk.zig` expõe `blk_read()`/`blk_write()` **sem** LBA, buffer ou
  contagem de setores;
- `virtio_net.zig` expõe apenas `net_transmit()`, sem `receive`.

A frase histórica foi mantida e a divergência foi registrada no mesmo
campo, sem reconciliação inventada, conforme `AGENTS.md`. Também foram
atualizados `docs/architecture/overview.md` (limitação conhecida 11) e
`docs/testing/testing-strategy.md` (casos L1 do módulo).

## Fora do escopo deste incremento

Achados da mesma classe, registrados e **não** alterados aqui para manter o
incremento verificável e mínimo:

1. `kernel/arch/x86_64/virtio_net.zig:25` — `net_transmit() !void` tem corpo
   vazio e devolve sucesso pelo mesmo motivo. É o defeito idêntico no módulo
   de rede, não no de bloco.
2. `kernel/main.zig:1134` — `initVirtioDevice()` imprime
   `[VNK] virtio: device init complete block_type=block` sem escrever em
   nenhum registro MMIO nem executar o handshake de status que o próprio
   comentário descreve. O marcador não é exigido por
   `tests/integration/boot-qemu.sh`, mas publica um estado que não
   aconteceu.

## Pendências

- Implementar o driver virtio-blk real (detecção, handshake, features,
  virtqueue programada, submit e colheita de usados) — proposta em
  [`../../adr/ADR-F04-block-driver-proposta.md`](../../adr/ADR-F04-block-driver-proposta.md).
- Redesenhar as assinaturas para receber LBA, buffer e contagem, e integrá-las
  a `block.Device` (ADR-0017) como substituto do ramdisk.
- Validar persistência física em disco; hoje o backend verificado é o
  ramdisk em memória.
- Tratar os dois achados da mesma classe registrados acima
  (`net_transmit()` e o marcador `device init complete`).

Validação de `zig build qemu-test` e `zig build check` na CI: **feita** no
run `40361111218`.
