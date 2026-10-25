# F4 — Codec VNV para RamFS

## Estado

**IMPLEMENTADO — NÃO TESTADO EM HARDWARE.** Esta entrega implementa o codec
bytes-in/bytes-out; ela ainda não conecta um dispositivo de bloco ao kernel.

## Implementação

- `kernel/fs/vnv.zig` define uma imagem fixa e versionada em little-endian.
- O cabeçalho registra magic, versão, geometria, sequência, tamanho e CRC32.
- Inodes, diretórios, bitmap e dados são serializados campo a campo.
- `decode` trabalha em um `ramfs.State` temporário e só publica o estado após
  todas as validações.
- `kernel/fs/ramfs.zig` expõe o registro de diretório necessário ao codec.
- `kernel/host_root.zig` inclui o codec na suíte de testes do host.

## Validação

Executado com Zig `0.17.0`:

- `zig test kernel/fs/vnv.zig`: **54/54 testes**, incluindo os testes do
  módulo RamFS importado pelo codec.
- `zig build test`: **passou**.
- `zig build`: **passou**.
- `zig build qemu-test`: **passou**, sem regressão no boot, filesystem,
  aplicações ELF ou composição gráfica.

## Limitações

Esta etapa não reivindica persistência real. Ainda faltam:

1. interface de dispositivo de blocos;
2. leitura/escrita de uma imagem VNV durante o boot;
3. política de commit atômico e journal;
4. recuperação após falha de energia;
5. integração de montagem VNV no VFSX.

O codec não deve ser usado como prova de suporte a hardware ou durabilidade.
