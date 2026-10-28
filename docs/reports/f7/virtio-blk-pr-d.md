# PR D — VirtIO Block nativo sobre VVDI

**Estado nesta revisão:** O PR #15 permanece Draft; não houve merge. O run de CI [40580172526](https://github.com/CeoMatheusDev/VorynOS/actions/runs/40580172526) passou em `186e14c1f02ca455d784aea6908e401edb51c5e1`, incluindo `zig build check`, o boot regressivo e o teste real de armazenamento em dois boots. Esse resultado comprova o HEAD anterior, não as correções desta auditoria. Esta revisão reteve o BAR quando o reset falha, tornou não fatal a falha de leitura do LBA 0 antes da assinatura opt-in, serializou os dois testes QEMU no grafo de build e restaurou a execução explícita dos quatro testes da API de bloco que deixaram de ser coletados quando ela virou um módulo nomeado; para qualquer HEAD posterior, a evidência aplicável é somente a CI associada àquele SHA. O harness só retorna sucesso depois de Boot 1 (write/FLUSH/read/byte-compare) e Boot 2 (mesmo disco, read/byte-compare, sem escrita) passarem. QEMU/OVMF não estão instalados localmente.

## Driver e integração

`kernel/drivers/vvdi/block.zig` usa o transporte PCI e a split virtqueue VVDI existentes. O boot detecta dispositivos VirtIO Block modernos no PCI bus 0, seleciona um dispositivo (o último BDF quando há mais de um; em QEMU o disco de dados do teste é anexado após o disco de boot), lê a capacidade com `config_generation` estável e registra o backend na API `kernel/storage/block.zig`.

O driver suporta `VIRTIO_BLK_T_IN`, `VIRTIO_BLK_T_OUT` e `VIRTIO_BLK_T_FLUSH`. A feature FLUSH (bit 9) é opcional durante a negociação, mas o teste de persistência exige que o dispositivo a ofereça e falha se a operação FLUSH falhar. O tamanho do setor exposto é 512 bytes; `VIRTIO_BLK_F_BLK_SIZE` não é negociado. Leituras e escritas parciais preservam o restante do setor via read-modify-write.

## DMA, conclusão e contenção

A fila e o scratch da requisição compartilham uma alocação física contígua, abaixo de 4 GiB, mapeada pela janela DMA existente. `Driver.init` valida alinhamento, extensão do buffer, consistência da memória virtual com a memória da fila, overflow e limite DMA. A cadeia de dados segue as direções VirtIO: em `IN`, o dispositivo grava dados/status; em `OUT`, grava apenas status. A publicação usa as barreiras da fila; a notificação MMIO valida índice, multiplicador e limite da região.

Uma operação só retorna sucesso depois que a used ring devolve o head publicado, com comprimento esperado e status VirtIO válido. IOERR/UNSUPP são erros, não sucessos. Espera limitada a um número finito de polls; timeout, notificação falha ou conclusão inválida envenena o driver. A fila, os descritores e o scratch não são reutilizados nem liberados sem confirmação de que o dispositivo parou de acessá-los. A instância envenenada recusa novos pedidos. Não há recuperação online/reset após esse tipo de falha.

## Teste de I/O e persistência

`tests/integration/virtio-block-persistence.sh` cria um disco descartável de dados separado da imagem de boot, escreve uma assinatura de opt-in na LBA 0, e executa dois boots QEMU/OVMF. A imagem de boot e o disco de dados são anexados como dois dispositivos distintos. O driver seleciona o último dispositivo moderno em BDF order, e o kernel só escreve após uma leitura da assinatura exata no dispositivo selecionado; a assinatura nunca é destino de escrita.

- **Boot 1:** o kernel espera setor zerado em LBA 64, grava o padrão determinístico de 512 bytes, confirma o retorno da requisição, exige e aguarda FLUSH, lê novamente e compara cada byte. O script exige marcadores separados para dispositivo, fila/DRIVER_OK, escrita concluída, FLUSH, leitura e comparação.
- **Boot 2:** o script mantém o mesmo arquivo, verifica o mesmo inode e não o trunca nem recria. O kernel lê LBA 64, compara com o padrão e só então emite `storage persistence confirmed boot=2`. O script reprova se Boot 2 publicar escrita ou FLUSH, ou se qualquer marcador estiver ausente.
- Cada execução QEMU é limitada por `timeout`; depois que o kernel emite `storage-test complete boot=1/2` (só após as asserções daquele estágio), o HMP `quit` pede encerramento controlado sem esperar a sequência de boot gráfico/scheduler não relacionada.

O teste está incluído como `zig build qemu-storage-test` e como dependência de `zig build check`. Após correções descobertas pela CI, o run [40580172526](https://github.com/CeoMatheusDev/VorynOS/actions/runs/40580172526), no SHA `186e14c1f02ca455d784aea6908e401edb51c5e1`, passou integralmente: instalação de OVMF, unidade, construção, boot QEMU, verificação agregada e artefatos. A verificação agregada inclui `qemu-storage-test`; seu código de saída zero comprova que o script observou os marcadores obrigatórios de Boot 1 e Boot 2, a mesma imagem de dados e ausência de escrita em Boot 2. Isso comprova persistência para aquele SHA e em QEMU, não em hardware físico; qualquer commit posterior precisa de CI própria.

## Verificações locais atuais

- `zig build test --cache-dir /tmp/vorynos-final-cache --summary all`: **554/554**. O HEAD anterior `186e14c1f02ca455d784aea6908e401edb51c5e1` reportava 550 porque quatro testes da API `kernel/storage/block.zig` não eram coletados após a migração para módulo nomeado. Esta auditoria adicionou `block-api-tests` explícito; o total corrigido é 544 testes existentes + 10 novos de VVDI, sem perder os quatro testes da API de bloco. A validação de CI precisa corresponder ao SHA final antes de qualquer merge.
- `zig build`: passou.
- `zig fmt --check` nos arquivos Zig modificados: passou.
- `git diff --check`: passou.
- `bash tests/integration/log-assertions-test.sh`: **7/7**.
- `bash -n tests/integration/virtio-block-persistence.sh`: passou.
- `zig build check`: não completou localmente, pois `qemu-system-x86_64` e o par OVMF CODE/VARS não estão instalados. A CI do SHA anterior não substitui o run exigido para o novo HEAD.
- Harness de persistência com QEMU simulado: **6/6** cenários; sucesso e rejeição de marcador de escrita ausente, comparação ausente, dados divergentes, substituição do arquivo e saída prematura no Boot 2. Isso testa as asserções/control-flow do script, não VirtIO real.
- Grafo de build com wrappers de comandos: confirmou que `boot-qemu.sh` termina antes de `virtio-block-persistence.sh`; não é uma execução QEMU real.

Os testes de host cobrem cabeçalho, layout DMA, cadeia de descritores, permissões de direção, limites, status, conclusão inválida e propriedade de descritores. Eles não substituem o teste QEMU real.

## Limitações e riscos

- Somente um dispositivo é registrado no backend padrão; se vários dispositivos modernos forem encontrados, seleciona-se o último por BDF. É uma política de integração inicial, não enumeração completa de armazenamento.
- I/O síncrono por polling e uma requisição em voo por fila; sem MSI-X/interrupt-driven I/O.
- Setor de 512 bytes; sem `VIRTIO_BLK_F_BLK_SIZE`, múltiplas filas, DISCARD/WRITE_ZEROES, sistema de arquivos sobre o disco ou montagem automática.
- Timeout coloca a instância em contenção e mantém a memória DMA; não há reset/recovery da fila. Se o reset durante a falha de configuração não for confirmado, a correção desta auditoria também mantém mapeado o BAR MMIO; a memória e a janela ficam retidas até reinicialização, sem recuperação online.
- O run CI `40580172526` comprovou Boot 1/Boot 2 no SHA `186e14c1f02ca455d784aea6908e401edb51c5e1`; ele não valida commits posteriores nem hardware físico.
- Os arquivos legados `kernel/arch/x86_64/virtio*.zig` permanecem sem alterações.
