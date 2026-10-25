# F10 — Instalação, recuperação e produção (VorynOS) — PROPOSED

Estado **PROPOSED**

## Componentes considerados
- Instalação UEFI (`uefi/vnb/installer.zig` estagio)
- Recuperação de partições e volumes VNV
- Hardening de kernel (permissions expandidas, capabilities)
- Benchmarks de latência/throughput (F6 gráficos)
- Dual-mode e hotfix para outros arqataficos

## Critérios pendentes / bloqueios ambientais
- `zig build qemu-test` requer `OVMF` (ambiente), não regressão do código
- Fluxo de instalação completo não executado
- Drivers físicos de rede/block não homologados em hardware

## Prioridade
Alta — fixa.

## Próxima decisão (se autorizada)
Executar `OVMF` + `zig build qemu-test`, ou especificar `f10-full` (instalação+recuperação+hardening com report).
