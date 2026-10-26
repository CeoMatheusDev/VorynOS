# Fase 4 — Processos / Syscalls (correção aplicada)
Estado: TESTADO LOCALMENTE
Problema: buffer global compartilhado `copy_buffer` em syscall de cópia entre processos.
Evidência: `syscall.zig` linha 1487 variavel global; usada apenas em `copyTo`.
Correção: variável local `local_buffer` dentro de `copyTo`; elimina concorrencia do buffer global.
Arquivos: `kernel/arch/x86_64/syscall.zig`.
Testes: zig build PASS; zig build test PASS.
Estado final: incremento concluído. Próxima etapa recomendada: Fase 5 (segurança do carregador ELF64) — aguardar aprovação.
