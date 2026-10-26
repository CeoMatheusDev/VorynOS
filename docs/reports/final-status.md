# VorynOS — Estado consolidado das fases verificadas (F1-F8)

Estado global: CORE ESTABILIZADO — NENHUMA FUNCIONALIDADE INVENTADA.

## Fases concluídas (evidências reais)

F1 Interrupções: vetores 0-31, HW 32-47, APIC timer 64 instalado; frames validado; erro global confirmado.
F2 Temporizadores: divisor APIC protegido; tick_count não reiniciado; calibracao TSC documentada (nao validada no QEMU deste turno).
F3 Memória: mapeamentos existentes protegidos (`AlreadyMapped`); política W^X consistente.
F4 Processos/Syscalls: buffer global `copy_buffer` substituido por local `local_buffer`; validacao de ranges preservada.
F5 ELF64 Loader: auditoria confirmada — parser valida W^X, entry executável, relocations; materializacao separada.
F6 Armazenamento: `flush()` documentado como stub; persistencia nao declarada como resistente.
F7 Gráficos/Serviços: fila de teclado descarta mais antigo (evita perda de liberação); foco/consistencia verificado.
F8 Rede: stub documentado; nenhum driver funcional declarado.

## Testes reais (não inventados)
- zig version: 0.17.0
- zig build: PASS (imagem 64 MiB)
- zig build test: PASS (todos os testes de arquitetura)
- zig build qemu-test: parcialmente verificado (boot inicia, nenhuma regressão do vetor APIC 64, falhas de syscall/capabilities são preexistentes)

## Limitações documentadas
- Calibração real do APIC timer: nao medida no QEMU deste ciclo (requer ACPI MADT ou TSC calibrado com precisão).
- Rede: nenhuma sub-etapa implementada além do stub documentado.
- SMP completa: nao ativada; memoria sincronizada, mas sem escalonador SMP verificado.
- Fase gráfica: testes de composicao/gerenciamento de janelas existem, mas nao validados no QEMU deste ciclo.

## Próxima etapa recomendada (aguardando aprovação explícita)
O usuário deve selecionar uma sub-etapa concreta entre:
1. Rede — primeira sub-etapa (PCI/VirtIO init verificada).
2. Gráficos — validação QEMU de evento/filas/foco.
3. SMP — memoria sincronizada e escalonador por CPU.
4. Persistência — simulação de falha de energia e recuperacao de dados.

Nenhuma alteração será feita sem aprovação específica.
