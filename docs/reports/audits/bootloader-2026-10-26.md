# Reauditoria P0 — carregador ELF64 e transição UEFI

**Data:** 2026-10-26

**Base inspecionada:** `99b35ab51ab74f39bb1abb1832f091c8b4db2eaa` (`main`, igual a `origin/main` no início da sessão)

**Branch de trabalho:** `arena/9f3de243-vorynos`

**Estado deste incremento:** implementado no código, **não validado** — o ambiente não contém Zig nem QEMU.

Este relatório complementa [`bootloader-2026-10-25.md`](bootloader-2026-10-25.md). A tabela daquele relatório é histórica: no checkout atual, `loader.zig` já chama `AllocatePages()` com endereço exato. A revisão abaixo distingue esse estado observado das correções novas, que ainda não passaram pelo compilador ou pelos testes.

## Achados e classificação

| Prioridade / classificação | Arquivo e evidência | Impacto | Tratamento neste incremento |
|---|---|---|---|
| P0 — funcionalidade implementada | `boot/uefi/vnb/loader.zig:82-100`: valida `file_size <= memory_size`, pula segmentos vazios, exige alinhamento de página e chama `allocatePages(.{ .address = requested }, .loader_data, pages)` antes de copiar. | A alocação exata reserva as páginas antes de `@memcpy`; a checagem do endereço retornado evita publicar um destino diferente. | Confirmado por inspeção estática. Continua pendente validar execução em UEFI/QEMU. |
| P0 — defeito confirmado | `shared/elf64.zig` anterior: `collectRelocations()` aceitava `R_X86_64_RELATIVE` sem conferir índice de símbolo ou se os oito bytes de destino pertenciam a segmento gravável; `loader.zig:126` aplicava a escrita após somar o bias. | Um ELF malformado poderia direcionar a escrita da relocação para código, lacuna ou região fora dos segmentos carregados, corrompendo memória antes da transferência ao kernel. | Adicionada validação do símbolo zero e do destino integral dentro de `PT_LOAD` com `PF_W`; adicionados testes negativos para código, lacuna, overflow e relocação baseada em símbolo. A suíte host foi tentada na CI e falhou; sem os logs brutos não é possível confirmar se estes casos chegaram a executar. |
| P0 — validação insuficiente confirmada | `shared/elf64.zig` anterior: a entrada era aceita em qualquer segmento carregável, sem exigir conteúdo executável; não verificava congruência `p_vaddr % p_align == p_offset % p_align` nem rejeitava segmento W+X. | Endereço de entrada e permissões poderiam contradizer o contrato do carregador; imagens com alinhamento ELF inválido eram aceitas pelo parser. | Parser agora exige entrada em bytes de arquivo de segmento executável, congruência de alinhamento, rejeita W+X e exige `p_vaddr == p_paddr` para `ET_EXEC`, já que este carregador copia para `p_paddr` mas usa os endereços virtuais para entrada/relocações. Testes negativos novos para entrada não executável e W+X; a suíte host falhou na CI antes de se obter evidência de que estes casos executaram. |
| P1 — defeito confirmado | `boot/uefi/main.zig` anterior: após `ExitBootServices()` retornar `EFI_INVALID_PARAMETER`, a tentativa seguinte imprimia também pela console UEFI (`Console.printLine`). | Após falha, o firmware pode ter desativado parcialmente serviços; a chamada do protocolo de texto não é garantida. A condição também permitia nove chamadas, embora a constante fosse oito. | Ao primeiro `InvalidParameter`, a console de firmware é desanexada; diagnósticos seguintes ficam no serial. O limite agora corresponde a oito tentativas. **Não validado em firmware.** |
| P1 — funcionalidade implementada | `boot/uefi/vnb/memory.zig:87`: produto `info.len * info.descriptor_size` usa `std.math.mul`; `loader.zig` verifica somas de endereços e relocações com `std.math.add`. | Mitiga overflow em tamanhos do mapa e segmentos/relocações antes dos acessos. | Preservado; confirmação estática. |
| P1 — defeito confirmado, pendente | `boot/uefi/vnb/loader.zig:91-100`: se uma alocação posterior, cópia ou relocação falhar, páginas anteriormente reservadas não são explicitamente liberadas. | Vazamento de páginas no retorno de erro ao firmware e ausência de rollback transacional do carregamento. | Não alterado: requer confirmar a API `FreePages` e exercitar a limpeza com Zig 0.17.0/UEFI antes de mexer no caminho de falha. |
| Potencial / limitação arquitetural | `shared/handoff.zig` define `identity_mapped_limit = 4 GiB`; `main.zig` e o loader assumem acesso direto aos endereços físicos abaixo desse limite no ambiente de firmware. | A premissa de mapeamento precisa estar vinculada à plataforma/firmware efetivamente suportada; o mapa físico, por si só, não prova que cada endereço está mapeado na tabela de páginas ativa. | ABI preservada. Não declarar portabilidade física nem remover a premissa sem validação de firmware e desenho de uma transição de paginação própria. |

## Estado de outros subsistemas observado na auditoria inicial

A documentação e a estrutura foram comparadas com o código existente; estes itens são pendências/limitações conhecidas, não alegações de defeito novo neste incremento:

- **Memória:** bitmap físico limitado a 4 GiB e heap fixo de 256 KiB, conforme roadmap; expansão dinâmica não implementada.
- **Processos:** `paging.max_process_spaces` é 8 no código, sem expansão dinâmica; capabilities genéricas de dispositivo, espera em múltiplos canais e notificações/sinais permanecem propostas.
- **Armazenamento:** VNV/VFSX e persistência foram descritos para backend RAM; montagem persistente automática e driver físico ainda pendentes.
- **SDK/runtime:** SDK freestanding e wrappers presentes; VLIB permanece ausente.
- **Gráficos:** apresentação/composição demonstrativa foi descrita como testada localmente; serviço completo, superfícies compartilhadas, foco e desktop permanecem pendentes.
- **Drivers/rede:** `virtio_blk.zig` mantém `blk_read()`/`blk_write()` vazias que retornam sucesso (`kernel/arch/x86_64/virtio_blk.zig:23-34`), embora marcadas como stubs; qualquer integração futura deve trocar esse comportamento por erro explícito até haver I/O real. `virtio_net.zig` confirma não implementar TX/RX; não há driver funcional nem rede completa declarada. Classificação: implementação parcial/risco de falso sucesso, prioridade P1; não alterado neste incremento.
- **Hardware:** nenhuma afirmação de suporte físico é feita; validação real requer máquina de referência.

## Arquivos deste incremento

- `shared/elf64.zig`: validação de alinhamento, W^X, endereço fixo, ponto de entrada e relocação; novos testes ELF negativos.
- `boot/uefi/main.zig`: evita console UEFI durante recuperação de `ExitBootServices` e limita o total de tentativas.
- `.github/workflows/ci.yml`: adiciona timeout/retries à instalação de OVMF/QEMU, executa `zig build check` e publica uma síntese dos logs quando um comando falha.
- `docs/testing/testing-strategy.md`: lista os novos casos ELF negativos no conjunto host.
- `docs/adr/ADR-0013-elf-materialization-and-nx.md` e `docs/roadmap/phase-status.md`: corrigem a capacidade de processos documentada (8 espaços de endereço no código atual, ainda fixa).
- Este relatório: registro dos achados, estado, correções e bloqueios de validação.

Não houve alteração da ABI VNB→VNK nem dos números/formatos de syscalls. Não foi feita medição de desempenho: a correção é de segurança/robustez e o ambiente não permite compilar ou executar o sistema.

## Validação executada nesta sessão

O repositório iniciou limpo. `git status` indicou a branch `arena/9f3de243-vorynos`; `main` e `origin/main` apontavam para o commit listado acima. A versão do compilador não pôde ser confirmada porque `zig` não está instalado/disponível no `PATH`; `qemu-system-x86_64` também está ausente.

| Comando | Resultado real |
|---|---|
| `zig version` | Bloqueado: `zig: command not found` (exit 127) |
| `zig build` | Bloqueado: `zig: command not found` (exit 127) |
| `zig build test` | Bloqueado: `zig: command not found` (exit 127) |
| `zig build qemu-test` | Bloqueado: `zig: command not found` (exit 127); QEMU ausente |
| `zig build check` | Bloqueado: `zig: command not found` (exit 127) |
| `git diff --check` | PASS — sem erros de whitespace no diff revisado |

**Não se afirma que o incremento compila ou passa testes.** O ambiente local não tem Zig/QEMU; a CI confirmou instalação de Zig 0.17.0, OVMF e QEMU e confirmou a versão do Zig, mas os dois runs observados falharam em `zig build test`. Os outros comandos foram ignorados pelo `set -e` do workflow; nenhum resultado de compilação ou boot deve ser inferido.

## Evidência posterior da CI

- Run `40347639388` (commit `b8d524f`): instalação de Zig, OVMF/QEMU, verificação de versão e diagnóstico do firmware concluíram com sucesso; `zig build test` falhou (exit 1); `zig build`, `zig build qemu-test` e `zig build check` não foram executados. A anotação do check run contém somente o exit code, sem a saída do compilador/test runner.
- Run `40352274138` (commit `6dcc9b4`): Zig, OVMF/QEMU, versão e diagnóstico também concluíram; `zig build test` falhou novamente; os passos seguintes foram ignorados. A execução agregada ainda não começou.
- A obtenção dos logs completos pelo agente falhou porque a API redireciona para o host externo de armazenamento de logs, fora do acesso de rede disponível nesta sessão. A causa da falha permanece **não identificada**; nenhuma correção ao kernel foi inventada.
- O workflow foi atualizado em `6dcc9b4` com limites/retries para apt, timeout de job e a execução explícita de `zig build check`. O próximo incremento acrescenta a saída final do comando como anotação de erro para permitir diagnosticar falhas sem acesso ao arquivo bruto do runner.

Pendências registradas: [issue #8 — validar mapeamento identidade](https://github.com/CeoMatheusDev/VorynOS/issues/8) e [issue #9 — rollback de páginas](https://github.com/CeoMatheusDev/VorynOS/issues/9). O PR #6 deve permanecer em draft e não ser mesclado até a causa da falha ser identificada, corrigida e os comandos obrigatórios passarem.
