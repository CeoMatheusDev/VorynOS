# Phase 10 — Installation, Update, Recovery, Hardening, Benchmarks, Other Architectures

**State:** CORREÇÕES APLICADAS (local) — `scheduler.zig` defensivo corrigido (pânico `stack corruption` removido quando canário não inicializado por `task.s`); `loader.zig` aritmética protegida; `model.zig` indexação corrigida; `tensor.zig` overflow protegido; `verify-integration.sh` corrigido; `docs/reports/f10/audit-corrections.md` criado. Nenhuma rede completa inventada.

## Evidência da implementação (2026-10-25)

### Endurecimento (Hardening) — IMPLANTADO
- `kernel/task/scheduler.zig`: campo `stack_canary: u64 = 0`, inicializado em `spawn()` via `cpu.readTimestamp() ^ @as(u64, task.id)` (linha 289)
- `docs/reports/f10/phase10.md`: especificação documentada

### Benchmarks — CRIADO
- `tools/benchmarks/syscall_bench.zig`: loop, função, memcpy (100000 iterações, `cycles()`)
- Compilado: `/tmp/voryn-phase2b-cache/zig-out/bin/syscall_bench` (ReleaseFast, x86_64-freestanding-none)

### Recuperação — CRIADO
- `tools/scripts/recovery_mode.zig` (antes `recovery-mode.sh`): lança o QEMU no host com o ramdisk de recuperação. Desde 2026-10-30 o arquivo tem a extensão certa, **compila** e entra no build como `recovery-mode`; ele é uma ferramenta de host e **não** é recuperação do sistema no alvo

### Limitações verificadas
- Stack canary não integrado ao `voryn_task_switch` (assembly `task.s`) — requer atualização do contexto de contexto de assembly
- Benchmark não executado em hardware — apenas compilado; TCG limita resultados
- Scripts de atualização simplificados ainda não implementados

## Objetivo

Esta fase estabelece os mecanismos de instalação, atualização, recuperação do sistema, endurecimento de segurança e benchmarks de desempenho. Também contempla a portabilidade para outras arquiteturas (ainda que o foco inicial seja x86_64).

## O que será implementado

### 1. Instalação e Imagem de Boot
- Gerador de imagem EFI (`vorynos.img`) já existe via `build.zig`
- Scripts de pós-instalação para configuração inicial
- Suporte a diferentes modos de boot (UEFI, BIOS Legacy - futuro)

### 2. Atualização de Sistema
- Mecanismo de `voryn-update` que baixa e aplica patches
- Verificação de integridade (hash SHA-256) de componentes do kernel
- Rollback em caso de falha na atualização

### 3. Recuperação de Sistema
- Ramdisk de recuperação (baseado no RamFS/F4 já implementado)
- Modo de manutenção com acesso ao shell básico
- Ferramentas de diagnóstico: `voryn-diag`, verificação de checksums de página de tabela

### 4. Endurecimento de Segurança (Hardening)
- **Stack canary**: geração de valores aleatórios para proteção contra buffer overflow
- **ASLR (Address Space Layout Randomization)**: já parcialmente implementado via endereços de tabela de página aleatórios em `paging.zig`
- **W^X enforcement**: o kernel já recusa boot sem NX bit (EFER.NXE), verificado em QEMU
- **Capability bounds**: limitar capacidades concedidas por processo (ADR-0001)
- **Kernel write protection**: impedir writes acidentais em páginas de código

### 5. Benchmarks de Desempenho
- Suite de benchmarks minimalista para medir:
  - Latência de syscalls (número de ciclos por chamada)
  - Throughput de memória: memcpy, memset rates
  - Latência de context switch entre tasks
  - Throughput de DMA window mapping
- Resultados base-line a serem comparados em Debug vs ReleaseFast vs ReleaseSafe

### 6. Outras Arquiteturas (Planejado)
- Anotações de portabilidade para ARM64 (mesmo que não seja o foco inicial)
- Mapeamento de diferenças de ABI entre x86_64 e arquiteturas suportadas

## Evidência Numérica (planejada)

Após implementação, pretendo rodar:

```bash
# Syscall latency benchmark
zig build bench --name syscall-latency

# Memory throughput
zig build bench --name mem-throughput

# Context switch latency
zig build bench --name ctx-switch
```

Metas iniciais (a serem medida depois):
- Syscall latency: < 50 ciclos em ReleaseFast
- Memcpy throughput: > 500 MB/s
- Context switch: < 2 µs

## Arquivos Relacionados
- `docs/reports/f10/phase10.md` — este relatório
- `tools/benchmarks/` — suíte de benchmarks (a ser criado)
- `tools/installer/` — scripts de instalação (a ser criado)
- `tools/hardening/` — configurações de segurança (a ser criado)

## Próximos Passos
1. Criar suíte de benchmarks básica
2. Implementar stack canary generation
3. Aprimorar ASLR na alocação de páginas
4. Escrever scripts de atualização simplificados
5. Testar em QEMU com diferentes configurações

## Limitações
- Benchmarks em ambiente TCG (QEMU) são mais lentos que hardware nativo
- Hardking features dependem de suporte de hardware (MMU, features do processador)
- Outras arquiteturas permanecem como anotações até que houver interesse/recurso para porting