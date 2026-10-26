# Fase 7 — Graficos e servicos de usuario (correção aplicada)
Estado: TESTADO LOCALMENTE
Problema: fila cheia descarta o mais novo, perdendo liberação e mantendo tecla pressionada (estado inconsistente).
Evidencia: `keyboard.zig` linha antiga: `if (len == capacity) { dropped += 1; return false; }` perdia o mais novo; `ps2.zig` usa `queue.push` sem tratar retorno.
Correção: `push` descarta o mais antigo quando cheia, preservando o evento mais recente; atualizados testes e comentarios.
Arquivos: `kernel/input/keyboard.zig`.
Testes: zig build PASS; zig build test PASS.
Estado final: incremento concluido. Proxima etapa recomendada: Fase 8 (rede) — aguardar aprovacao.
