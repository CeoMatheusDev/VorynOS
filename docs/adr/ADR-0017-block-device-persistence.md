# ADR-0017 — Persistência em dispositivo de blocos via volumes VNV

- **Estado:** IMPLEMENTADO — TESTADO LOCALMENTE (host + boot QEMU)
- **Data:** 2026-10-25
- **Escopo:** camada de blocos, ramdisk, commit/recuperação de volume VNV

## Contexto

O ADR-0016 entregou o codec VNV (imagem bytes-in/bytes-out), mas a imagem
não era persistência: não havia dispositivo de blocos nem montagem no boot.
O VFSX (ADR-M0.3) roteava arquivos para o RamFS, e o RamFS vivia na imagem
do kernel, desaparecendo a cada desligamento.

Este incremento fecha a lacuna com a menor camada possível:

1. uma **interface de dispositivo de blocos** (`kernel/storage/block.zig`)
   independente do hardware;
2. um **backend em RAM** (`kernel/storage/ramdisk.zig`) que implementa a
   interface sem um driver físico;
3. uma **camada de volume** (`kernel/fs/vnv_volume.zig`) que serializa um
   `ramfs.State` em uma imagem VNV e a grava no dispositivo, e que relê,
   valida e restaura o estado.

## Decisão

### 1. A interface de bloco é mínima e sem alocação

`block.Device` expõe duas funções (`read`/`write`), o tamanho do setor e a
quantidade de setores, com um contexto opaco do backend. Os helpers
`readBytes`/`writeBytes` traduzem intervalos de bytes em operações de setor
com validação de limites em aritmética de 64 bits. A transferência pode
cobrir parte de um setor; o ramdisk copia direto e um driver de disco real
fará read-modify-write.

### 2. O ramdisk é o backend verificado; o driver físico é substituto direto

`ramdisk.RamDisk` serve a interface sobre um buffer contíguo do kernel. O
ciclo completo — commit, wipe e recuperação — é verificado no host e no
boot QEMU. Um driver virtio-blk ou ATA PIO implementa as mesmas duas
funções e substitui o ramdisk sem alterar o volume, o VFSX ou o RamFS.

### 3. O volume VNV é commitado e recuperado no lugar

`vnv_volume.commit(device, state, sequence, staging)` serializa o estado
vivo e o grava a partir do LBA zero. `vnv_volume.recover(device, state,
staging, scratch)` lê a imagem, valida magic, versão, geometria e CRC32, e
só então substitui o estado — uma imagem corrompida nunca altera o destino.

O `scratch` é fornecido pelo chamador porque `ramfs.State` tem ~1 MiB: um
local desse tamanho estouraria a pilha de boot de 16 KiB.

### 4. O boot prova o ciclo completo

O autoteste `verifyFsPersistence` roda depois do probe de ciclo de vida
(todos os descritores fechados): commit do volume raiz no ramdisk, wipe,
recuperação e re-verificação de `/apps/hello.txt` e dos quatro arquivos
instalados. O pacote VPK (F5) gravado no RamFS sobrevive ao ciclo e é
desempacotado depois da recuperação.

## Consequências

### Segurança

- A camada de bloco valida todo pedido antes de tocar a memória do backend.
- O decodificador valida a estrutura completa antes de publicar o estado.
- Nenhum driver físico novo entrou no kernel; o ramdisk é um buffer do
  kernel, e o device address space não é exposto a processos.

### Limitações (escopo futuro, não erros)

- O commit é atômico no formato (imagem completa montada antes da escrita),
  mas **não há journal nem troca atômica de duas imagens** contra falha de
  energia no meio da escrita.
- Não há montagem automática no boot a partir de um disco: o autoteste
  monta o dispositivo em RAM por construção.
- O driver físico (virtio-blk/ATA) e o dispositivo real continuam no F7.

## Critério de aceite

- `zig build test`: passa (bloco, ramdisk, volume e codec no host).
- `zig build qemu-test`: passa, com os marcadores de persistência e VPK.
- O checksum da composição F6.28 (`0xd6baff86f4575725` era a baseline da
  cena kernel) permanece estável para a captura do F6.28/F6.29.
