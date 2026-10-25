# F4 — Persistência em dispositivo de blocos e recuperação (volumes VNV)

## Estado

**IMPLEMENTADO — TESTADO LOCALMENTE.** Este incremento conecta o codec VNV
(ADR-0016) a uma camada de dispositivos de blocos e prova o ciclo completo
— commit, wipe e recuperação — no host e no boot QEMU.

## Implementação

- `kernel/storage/block.zig`: interface `block.Device` (leitura/escrita de
  setores com contexto opaco, tamanho de setor e contagem), com os helpers
  `readBytes`/`writeBytes` que atravessam fronteiras de setor validando
  limites em aritmética de 64 bits.
- `kernel/storage/ramdisk.zig`: backend em RAM que implementa a interface
  sobre um buffer contíguo, sem alocação e com validação de
  `lba + count <= sector_count` em toda operação.
- `kernel/fs/vnv_volume.zig`: `commit` serializa um `ramfs.State` em uma
  imagem VNV e a grava a partir do LBA zero; `recover` lê, valida (magic,
  versão, geometria, CRC32) e substitui o estado no lugar. O scratch de
  decodificação é fornecido pelo chamador: `ramfs.State` tem ~1 MiB.
- `kernel/fs/ramfs.zig`: `defaultState()` expõe o estado vivo do volume
  raiz; `kernel/fs/fs.zig`: `stateFor(volume_id)` e `wipeVolume(volume_id)`.
- `kernel/main.zig`: autoteste `verifyFsPersistence` — commit do volume
  raiz, wipe, recuperação e verificação dos arquivos recuperados.
- `kernel/host_root.zig`: os módulos novos entram na suíte de testes do
  host.

## Validação

Executado com Zig `0.17.0`:

- `zig build test`: **passa** (bloco, ramdisk, volume, codec, RamFS, VPK).
- `zig build`: **passa**.
- `zig build qemu-test` / `bash tests/integration/boot-qemu.sh`: **passa**,
  com os marcadores:

```text
[VNK] fs: persistence device ready, 2067 sectors of 512 bytes
[VNK] fs: vnv committed sequence=1 image=1058240 bytes over 2067 sectors
[VNK] fs: volume wiped, /apps/hello.txt no longer resolvable
[VNK] fs: vnv recovered sequence=1 from the block device
[VNK] fs: persistence round trip ok (hello.txt + 4 files, 247 blocks free)
[VNK] vpk: /apps/sample.vpk validated and unpacked (2 entries, 182 bytes)
[VNK] vpk: pack/persist/recover/unpack round trip ok
```

## Defeito encontrado e corrigido

Em modo Debug, o compilador Zig 0.17 implementa a atribuição de uma struct
grande (~1 MiB, `ramfs.State`) como uma cópia **através de um temporário na
pilha** (`sub $0x102650, %rsp` + `rep movsb` no assembly gerado). A pilha
de boot do kernel tem 16 KiB: o overflow corrompia o BSS silenciosamente e
travava o boot. O `decode` agora commita o estado campo a campo com
`@memcpy` (cópia direta, sem spill de pilha). Em ReleaseSafe a otimização
eliminava o spill, o que escondia o defeito; a correção vale para os dois
modos.

## Limitações (escopo futuro)

1. driver físico (virtio-blk, ATA PIO) e montagem automática no boot;
2. journal e troca atômica de duas imagens contra falha de energia;
3. o ramdisk não sobrevive a um reset: a persistência real depende do
   driver de disco do F7.
