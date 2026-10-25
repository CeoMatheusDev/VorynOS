# F5 — Formato VEX (executável nativo) integrado ao carregador

## Estado

**IMPLEMENTADO — TESTADO LOCALMENTE (host + boot QEMU).** Este incremento
entrega o container VEX (`formats/vex.zig`), o primeiro formato de
executável nativo do VorynOS além do ELF puro, e o integra ao carregador
sem alterar o materializador nem a ABI.

## Implementação

- `formats/vex.zig`: cabeçalho de manifest de 64 bytes (magic `"VEX1"`,
  versão, geometria, CRC32 do payload) envolvendo uma imagem ELF64; o
  manifest opcional declara capacidades (`kind` espelhando os kinds do
  kernel: canal, processo, display, entrada; `rights` bitmask). API:
  `wrap`, `packedSize`, `validate`, `unwrap` (devolve `error.NotVex` para
  ELF puro), `manifestList`.
- `kernel/elf_loader.zig`: `planFromRamFs` chama `vex.unwrap`; para um
  VEX, valida magic/versão/geometria/CRC/manifest, move o payload para o
  início do buffer e planeja o ELF interno. O erro `vex.Error` entra no
  conjunto de erros do carregador.
- `kernel/main.zig`: o ELF da toolchain (SDK) é empacotado em
  `/apps/toolchain.vex` com o manifest display+input (os mesmos direitos
  que o kernel concede ao processo); o processo da toolchain passa a ser
  carregado do `.vex`.
- `build.zig`: módulo `voryn_vex` para o kernel e para a raiz de testes do
  host, e suíte `vex-tests`.
- `docs/specs/vex.md`: especificação normativa do formato.

## Validação

Executado com Zig `0.17.0`:

- `zig build test`: **passa** (`vex-tests` 7/7; `fs-loader-tests` inclui o
  teste de planFromRamFs com um VEX do RamFS e a recusa de payload
  corrompido).
- `zig build`: **passa**.
- `zig build qemu-test` / `bash tests/integration/boot-qemu.sh`: **passa**,
  com os marcadores:

```text
[VNK] fs: /apps/toolchain.vex installed (7176 bytes)
[VNK] vex: manifest declares display(0xc) and input(0x14)
[VNK] toolchain: /apps/toolchain.vex entry=0x17fbb44 base=0x17fa000 end=0x17fe000, 3 segments
[VNK] vex: unwrapped and planned from the VEX image
[VNK] toolchain: /apps/toolchain.vex ran from the toolchain
```

A entrada planejada (0x17fbb44) é a mesma do ELF puro anterior, provando
que o desembrulho não altera o plano de carga; o arquivo `.vex` também
sobrevive à persistência/recuperação VNV.

## Limitações (escopo futuro)

1. o manifest é validado e reportado, mas **não é imposto** contra a
   concessão de capacidades do kernel (a verificação do conjunto
   declarado é trabalho futuro);
2. `entry_hint` e `flags` do cabeçalho são reservados (a entrada do ELF
   vence);
3. VLIB (bibliotecas nativas) continua ausente;
4. o VEX não é o formato do bootloader: `VORYNK.ELF` segue ELF puro.
