# Fase F11 — Estabilidade do Kernel, Escalonamento e Inicialização

## Estado
**TESTADO LOCALMENTE** em 2026-10-26 com Zig 0.17.0: `zig build test`, `zig build` e `zig build qemu-test` passaram. O teste QEMU chegou a `VORYN-KERNEL-READY` e terminou com `qemu-boot-test: all checks passed`.

## Defeitos identificados (evidência real)
- O canário colocado em `kernel_rsp - 8` ficava no topo da pilha e era sobrescrito pelo frame de syscall/interrupção.
- O teste QEMU também não expunha o erro de inicialização do emulador quando a saída serial estava vazia; execuções concorrentes podiam disputar a imagem.
- A calibração do timer APIC usava `hlt()` em um polling longo, cedendo a CPU repetidamente durante a inicialização.
## Causas-raiz demonstradas
- O frame da syscall é construído a partir do topo da stack do kernel, portanto o topo não pode servir como canário.
- O canário agora fica no limite inferior do buffer de stack e é inicializado tanto para a tarefa inicial quanto para tarefas de kernel e de usuário.
- O polling do timer APIC agora usa `pause()` e mantém o limite de tentativas sem suspender a CPU. Se a contagem não avançar, o caminho de fallback de 10 MHz permanece explícito.
- Nenhuma fonte de entropia criptográfica é usada; o canário usa `readTimestamp() ^ id`, documentado conforme modelo de ameaça (detecção de overflow, não proteção criptográfica).

## Arquivos alterados
- `kernel/task/scheduler.zig`: inicialização e verificação do canário no limite inferior da stack.
- `kernel/main.zig`: stacks usadas pelos handlers de kernel ampliadas para 256 KiB.
- `kernel/arch/x86_64/timer.zig`: polling limitado da calibração APIC sem `hlt()`.
- `tests/integration/boot-qemu.sh`: imagem de disco isolada por execução, stderr de QEMU visível quando não há saída serial e falha de inicialização reportada diretamente.
- `docs/roadmap/phase-status.md` e este relatório: estado atualizado com a validação real.

## Correções implementadas
1. Posicionamento do canário fora da área usada pelos frames de syscall/interrupção, incluindo a tarefa inicial e as tarefas de usuário.
2. Aumento das stacks de kernel para 256 KiB para comportar os caminhos de interrupção e syscall exercitados no boot.
3. Polling da calibração APIC limitado sem `hlt()`, evitando suspensões repetidas durante o boot.
4. O fluxo do escalonador e a política EEVDF foram preservados.

## Testes executados
- `zig version`: 0.17.0 ✅
- `zig build test`: PASS ✅
- `zig build`: PASS; imagem `vorynos.img` de 64 MiB ✅
- `zig build qemu-test`: PASS; `VORYN-KERNEL-READY` e `qemu-boot-test: all checks passed` confirmados ✅
- O QEMU registrou fallback da calibração APIC para 10 MHz; esse fallback não impediu a conclusão do teste.
- Nenhum arquivo vazio criado.

## Limitações
- O teste QEMU valida o boot no ambiente local, não em hardware físico.
- Benchmark e testes de múltiplas CPUs ainda pendentes.
- Nenhum `git push`, tag ou release executado.

## Próxima etapa
Validar calibração APIC e inicialização SMP em hardware ou em uma configuração QEMU com múltiplas CPUs; o boot automatizado monoprocessador está validado localmente.

## Licença
GPL-3.0-only.
