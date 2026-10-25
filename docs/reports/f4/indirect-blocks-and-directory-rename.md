# F4 — Blocos indiretos e rename de diretórios

## Estado

**IMPLEMENTADO — TESTADO LOCALMENTE (host + boot QEMU).** Este incremento
fecha os dois itens restantes do marco F4 no RamFS: arquivos além dos 12
blocos diretos (via tabela indireta única) e rename/movimento de
diretórios com preservação da subárvore e recusa de ciclos.

## Implementação

- `kernel/fs/ramfs.zig`:
  - constantes `indirect_per_block = 512` e `max_blocks = 524`; o tamanho
    máximo de arquivo passa a ser `max_blocks * block_size` (~2 MiB, ainda
    limitado pelo volume de 1 MiB na prática);
  - `indirectTableFor`/`indirectTableMutFor` (leitura/escrita da tabela no
    bloco de dados) e `blockAddressFor` (endereço de um bloco direto ou
    indireto com validação de ponteiro);
  - `ensureBlocksFor` transacional: aloca a tabela e as entradas indiretas,
    e o rollback libera entradas novas mesmo quando a tabela pré-existia;
  - `writeFileFor` (substituição), `writeFileAtFor`, `readFileAtFor`,
    `truncateFor` (libera a tabela quando o arquivo encolhe para os blocos
    diretos), `releaseBlocksFor` e `releaseInodeFor` com suporte indireto;
  - `audit()` valida a tabela indireta: bloco referenciado uma vez,
    entradas usadas válidas, entradas além do tamanho zeradas e ponteiro
    duplo rejeitado;
  - `renameFileFor` aceita diretórios: move a subárvore inteira (a entrada
    de diretório pai é a única que muda) e recusa ciclos percorrendo a
    cadeia de pais do destino com limite de profundidade; o inode raiz não
    pode ser movido.
- `kernel/fs/vnv.zig`: `validate` aceita `i_indirect` para arquivos
  grandes, confere a tabela no bitmap (bloco + entradas) e continua
  rejeitando o ponteiro duplo.
- `kernel/main.zig`: o boot instala `/apps/large.bin` (100 KiB, 25 blocos
  via indireto) e, após a recuperação VNV, confere o conteúdo no início,
  na fronteira indireta e no fim, além de verificar o rename de diretórios
  end-to-end com recusa de ciclo.
- `kernel/fs/fs.zig`: testes de pressão de blocos ajustados ao novo limite.

## Validação

Executado com Zig `0.17.0`:

- `zig build test`: **passa** (156 testes em `fs-loader-tests`).
- `zig build`: **passa**.
- `zig build qemu-test` / `bash tests/integration/boot-qemu.sh`: **passa**,
  com os marcadores:

```text
[VNK] fs: /apps/large.bin installed (102400 bytes, indirect blocks)
[VNK] fs: large file round trip ok (indirect blocks)
[VNK] fs: directory rename round trip ok
[VNK] fs: persistence round trip ok (hello.txt + 5 files, 221 blocks free)
```

## Limitações (escopo futuro)

1. tabela indireta dupla (arquivos > 524 blocos) não implementada;
2. o limite prático do arquivo é o volume de 1 MiB;
3. driver físico e montagem automática no boot continuam no F7.
