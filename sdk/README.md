# SDK nativo VorynOS — F5.1

Estado: **implementado, aguardando compilação e validação em Zig 0.17.0 e QEMU**.

Este módulo é uma interface independente do kernel para aplicações
`x86_64-freestanding`. Baseia-se exclusivamente em
`docs/specs/syscall-abi.md` (VSC-0001, versão 9).

- `sdk/src/syscall.zig`: passagem de argumentos via RAX/RDI/RSI/RDX/R8,
  retorno em RAX e retorno secundário em RDX, números e erros da ABI.
- `sdk/src/root.zig`: operações de console, processo, IPC, capacidades
  e arquivos. Os valores retornados são os bits da ABI; use
  `syscall.errorCode(status)` para identificar erros.
- `user/hello.zig`: primeira aplicação migrada para a interface pública.

O SDK não implementa alocador, libc, POSIX, criação dinâmica de processos
nem descoberta de serviços. Nenhum novo número de syscall foi introduzido.

**Validação pendente no Fedora:**

```sh
zig version
zig build
zig build test
zig build qemu-test
```

Não publicar como versão estável antes de validar esses comandos.
