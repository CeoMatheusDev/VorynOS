# ADR-0016 — Codec persistente VNV para volumes RamFS

- **Estado:** IMPLEMENTADO — NÃO TESTADO EM HARDWARE
- **Data:** 2026-10-24
- **Escopo:** codec host/kernel-puro; sem driver de bloco e sem alteração da ABI

## Decisão

O VorynOS serializa uma instância `ramfs.State` em uma imagem VNV fixa,
versionada e little-endian. O codec fica em `kernel/fs/vnv.zig` e não depende
do layout binário de structs Zig.

A imagem contém cabeçalho explícito, bitmap, metadados dos 32 inodes, 64
entradas de diretório e os 256 blocos de 4 KiB. O payload é protegido por
CRC32. O decodificador valida geometria, enums, referências de blocos,
bitmap, nomes e referências de diretório antes de substituir o destino.
Falhas nunca alteram o estado de destino.

## Consequências

- O round-trip é determinístico e testado no host.
- O formato pode receber um backend de bloco posteriormente sem alterar as
  syscalls existentes.
- A imagem ainda não é persistência do sistema: não há dispositivo de bloco,
  journal, commit atômico contra falha de energia ou montagem no boot.
- A geometria atual continua limitada a 1 MiB, 32 inodes, 64 entradas e 48 KiB
  por arquivo.

## Critério de aceite desta etapa

`zig test kernel/fs/vnv.zig`, `zig build test`, `zig build` e `zig build qemu-test`
passam. A integração com um dispositivo físico fica para a próxima etapa F4.
