# Auditoria do relatório "Milestone Progress" — 2026-10-30

| Campo | Valor |
|-------|-------|
| **Objeto** | Tabela *Milestone Progress* (F0–F10) de `README.md` |
| **Base auditada** | `a418ad334bb9912e3c0460eced5949174a747bcd` (`main`, HEAD do checkout) |
| **Ambiente** | Linux x86_64, Zig 0.17.0 instalado na sessão, sem QEMU/OVMF |
| **Método** | Leitura de código e testes + `zig build test` + `zig build` + conferência das execuções de CI citadas via API do GitHub |
| **Veredito** | Relatório **majoritariamente honesto e verificável**; um item superestimado (F9) e três divergências de documentação a corrigir |
| **Estado das correções** | D1–D8 **aplicadas em 2026-10-30** (ver seção 8); **D9 permanece aberto**; D10–D11 são documentais |

---

## 1. Resumo

A tabela do `README.md` não é um texto de marketing descolado do código: ela
descreve de forma correta o estado do repositório em 9 dos 11 marcos. As
alegações centrais — boot nativo UEFI, kernel com interrupções/paginação,
escalonador, syscalls, IPC, RamFS/VNV, carregamento ELF nativo e **persistência
VirtIO Block em QEMU** — encontram lastro direto no código e na CI.

O que **não** se sustenta é o rótulo `✅ Scoped complete` do **F9 (AI)**: o
subsistema de IA existe como biblioteca testada no host e não é importado pelo
kernel, não tem syscall, não tem aplicação e não aparece no boot. O "Native CPU
inference" do relatório é, hoje, uma rotina de inferência em Zig com 3 testes de
host — não uma capacidade do sistema operacional em execução.

Além disso, a própria documentação interna do repositório (`docs/roadmap/`) é
**menos confiável que o relatório**: em F8 e F10 o roadmap afirma `CONCLUÍDO`
para coisas que não existem no código.

---

## 2. O que foi realmente executado

| Comando | Resultado |
|---------|-----------|
| `zig build test --summary all` | **596 testes, 19 grupos, todos aprovados** (0 falhas) |
| `zig build` | **13/13 passos**, gera `zig-out/bin/vorynos.img` (128 MiB, FAT) |
| `zig build qemu-test`, `qemu-storage-test`, `qemu-interactive-test` | **não executados** — o ambiente não tem `qemu-system-x86_64` nem OVMF |
| CI run `40989806725` @ `a418ad33` | **sucesso**, 11 passos verdes, incluindo "Verificação agregada" (unit + boot + dois boots de storage) |

Distribuição dos 596 testes (grupos com peso relevante):
`fs-loader-tests` 154, `vvdi-tests` 148, `arch-tests` 91, `shared-tests` 55,
`kernel-tests` 22, `user-composition-tests` 22, `security-tests` 18,
`damage-tests` 15, `keyboard-motion-tests` 13, demais 15 grupos ≤ 9.

Execuções de CI citadas no roadmap foram conferidas e **existem, passaram e
correspondem ao SHA citado**:

| Run | SHA | Conclusão |
|-----|-----|-----------|
| `40580172526` | `186e14c1` | success |
| `40478940990` | `f550190a` | success |
| `40361111218` | `55d9fe3f` | success |

Dimensão do código: **246 arquivos rastreados**, 104 arquivos `.zig`,
**42.179 linhas** de Zig, 24 ADRs, 100 documentos `.md`, `kernel/main.zig` com
4.738 linhas, subsistema VVDI com 7.854 linhas, `kernel/fs/` com 5.101 linhas.
Isso é consistente com um kernel real em desenvolvimento, não com um esqueleto.

---

## 3. Comparação fase por fase

Legenda: **✔ confirmado** · **≈ confirmado com ressalva** · **✘ não confirmado**

| Fase | Relatório | Verificação independente | Veredito |
|:---:|---|---|:---:|
| **F0** | ✅ Complete | `build.zig` funcional, 596 testes, AGENTS/STRATEGY/ADRs/convenções presentes e coerentes | ✔ |
| **F1** | ✅ Complete | `boot/uefi/vnb/` (console, framebuffer, memory map, loader) + `shared/elf64.zig`, `shared/handoff.zig`; boot test exige `[VNB] kernel placed` e `[VNK] handoff ok` | ✔ |
| **F2** | 🟢 Tested | `segment.zig`, `interrupt.zig`, `paging.zig` (NX exigido), `memory/physical.zig` bitmap 4 GiB, heap com boundary tags; 117 asserções no boot test cobrem GDT/IDT/TSS/CR3/NX | ✔ |
| **F3** | 🟡 Active | Escalonador preemptivo, EEVDF, SMP com APs (`smp.zig`, `ap_trampoline.s`), `syscall` com 12 chamadas implementadas, IPC com capacidades e timeout; "expansion pending" é justo | ✔ |
| **F4** | 🟡 Active | RamFS 2.227 linhas, VFSX, VNV + `vnv_volume` com commit/recovery; **persistência VirtIO Block real**: `block_dev.installDefault(virtio_block_driver.device())` alimenta a sonda de dois boots | ✔ |
| **F5** | 🟡 Active | `elf_loader` (planner) + `elf_materializer`, W^X, VEX/VPK com spec e testes, app nativo no boot; SDK tem 19 wrappers em 2 arquivos e **VLIB não existia** na base auditada (fechado depois, ver §8) | ✔ |
| **F6** | 🟡 Active | Rasterizador, compositor, damage tracking, PS/2, 6 syscalls de vídeo/entrada, screenshot P6 comparado no boot test; **desktop.zig existe e é apresentado** (nome engana: é cena com 2 janelas, não shell) | ≈ |
| **F7** | 🟡 Active | VVDI moderno completo (caps, BAR, transporte, virtqueue, block com DMA/FLUSH/envenenamento, containment/ADR-0022); **não há driver de rede**: `virtio_net.zig` devolve `NotImplemented` | ✔ |
| **F8** | 🟡 Active | `formats/vex.zig` e ABI de syscall nativas são reais; **não existe nada de PE/Win32** e `elf_compat.zig` (30 linhas, só `e_machine`) não é importado por ninguém | ✔ |
| **F9** | ✅ Scoped complete | `kernel/ai/{tensor,model,security}.zig` existem e têm `infer()` real, mas **o kernel nunca os importa**; só o alvo de testes `ai-tests` (3 testes); zero syscall, zero marcador de boot, zero app | ✘ |
| **F10** | 🟡 Partial | Sem instalador, sem update; "recovery" é script de host mal nomeado (ver D6); hardening inicial (canário, NX, W^X) presente | ✔ |

---

## 4. Divergências e correções necessárias

### D1 — Alta · F9 declarado "Scoped complete" sem integração
`kernel/ai/` é uma biblioteca host-only: `build.zig:334` a referencia apenas como
alvo de teste (`ai-tests`, 3 testes), e nenhum arquivo do kernel a importa
(`grep` por `infer|tensor` em `kernel/main.zig`: 0 ocorrências; 0 marcadores
`[VNK] ai` no boot test). O texto "Native CPU inference" sugere capacidade do SO.
**Correção:** rebaixar para `🟡 Biblioteca de inferência (host-only)` ou declarar
explicitamente "implementado como biblioteca; não exposto ao runtime".

### D2 — Alta · Roadmap F8 afirma PE/Win32 "CONCLUÍDO" (falso)
`docs/roadmap/phase-status.md:382` lista
`F8 | ELF, Linux ABI, PE, Win32, external formats | CONCLUÍDO`. Busca por
`win32|PE32|dos_header` em todo o `.zig`: **zero resultados**; `formats/` contém
apenas `vex.zig` e `vpk.zig`. O relatório (F8 = Active, "broader support
pending") é o texto correto — o roadmap precisa ser corrigido, não o README.

### D3 — Média-Alta · Contrato de syscalls defasado em relação ao código
`docs/specs/syscall-abi.md` declara `syscall_abi = 12`, encerra a tabela na
chamada 21 e diz que "12 está reservado". O código tem **`fs_truncate = 22`** e
**`input_wait = 23`** implementados e usados pelo app nativo, e o roadmap fala em
"ABI v13". Pelo `AGENTS.md`, mudança de ABI exige especificação e testes — a
especificação está para trás. **Correção:** subir a spec para v13 com 22 e 23
documentados e testes de contrato correspondentes.

### D4 — Média · Contagens de teste obsoletas
O README afirma "554 Zig tests"; o real é **596**. O roadmap acumula 525 → 544 →
550 → 554. **Correção:** substituir números por referência ao último run de CI ou
atualizar para 596.

### D5 — Média · Roadmap F10 "CONCLUÍDO (local)" contra o relatório "Partial"
`docs/roadmap/phase-status.md:379` e `docs/reports/f10/*` usam "concluído" para
itens que o próprio relatório chama de pendentes (instalação, update). Pior:
`docs/reports/f10/phase8-net.md` encerra com "incremento concluido" sobre um
**stub documentado** de rede — exatamente o vocabulário que o `AGENTS.md`
proíbe ("código escrito não equivale a código validado").

### D6 — Média · "Recovery mode" não é recovery do sistema
`tools/scripts/recovery-mode.sh` é, na verdade, **código-fonte Zig com extensão
`.sh`** (cabeçalho `recovery-mode.zig`), não é compilado, não está no grafo do
`build.zig` e apenas **lança QEMU no host** com ramdisk. É citado como evidência
de F10. **Correção:** renomear para `.zig`, integrar ou remover; e não listar como
mecanismo de recuperação do SO.

### D7 — Média · Higiene do repositório
- `syscall_bench` é um **binário ELF rastreado na raiz** (contém caminhos do
  desenvolvedor, ex. `/home/matheus/...`), embora exista o fonte em
  `tools/benchmarks/syscall_bench.zig`.
- `restal/` (6 arquivos) e `internal/ai/archive/` (4 arquivos) são arquivos de
  prompt/instrução de IA rastreados, o que **contradiz o `AGENTS.md`**
  ("Não há outros prompts ou guias de agentes ativos no repositório").
- `tests/integration/f4_physblk_vnv_integration.zig` é **teste morto**: não está
  em nenhum alvo do `build.zig` e o comentário `//!` contém `\n` literal quebrado.

### D8 — Baixa · F6 "desktop pending" vs. `desktop.zig` existente
Existem `desktop.zig` (228 linhas), `window_manager.zig`, `window_renderer.zig` e
`session.zig`, e o kernel apresenta um desktop gerenciado no boot. O relatório
está correto no sentido de "não há shell/taskbar/launcher", mas o nome dos
arquivos induz o leitor ao erro. **Correção:** "desktop de cena presente;
shell/taskbar/launcher pendentes".

### D9 — Baixa · Verificação interativa fora da CI
`tests/integration/interactive-qemu.sh` (26 KB) **não** integra `zig build check`
nem a CI; só o boot test cobre marcadores de teclado e screenshot. Os rótulos
"TESTED LOCALLY" do roadmap para F6.22–F6.29 estão, portanto, corretos — mas
nenhum teste de entrada PS/2 roda automaticamente.

### D10 — Baixa · Evidência não reprodutível localmente
O roadmap cita commits (`1b5a909`, `d1c3ca0`, `f8929be`, `591bde4`, `7167434`,
`3418766`) que **não existem neste clone** (histórico reduzido a um commit,
`a418ad3`). Só as execuções de CI puderam ser verificadas. O relatório também
**omite SMP**, embora `smp.zig`, `ap_trampoline.s` e `initAps()` estejam
integrados em `voryn_kmain()`.

### D11 — Informativo · Ausência total de rede
Não há Ethernet, ARP, IPv4, TCP ou UDP no repositório; `virtio_net.zig` devolve
`error.NotImplemented`. O relatório diz "wider hardware support pending", o que é
verdade, mas "sem driver de rede algum" é a informação que o leitor precisa.

---

## 5. Onde o relatório é mais conservador que a documentação interna

| Item | Relatório | Documentação do repo | Código |
|---|---|---|---|
| F8 (PE/Win32) | 🟡 Active | `CONCLUÍDO` | inexistente |
| F10 | 🟡 Partial | `CONCLUÍDO (local)` | sem instalador/update |
| Nº de testes | 554 | 525–554 | **596** |
| F6 desktop | "pending" | "shell pendente" | desktop de cena existe |

Nos quatro casos o README é o texto mais próximo da realidade. Recomenda-se
alinhar o roadmap **ao** README, e não o contrário.

---

## 6. Prioridades sugeridas

1. **Corrigir F9** no README (rebaixar o rótulo) — é a única afirmação
   significativamente acima do código.
2. **Corrigir F8 e F10 no roadmap** (`CONCLUÍDO` → estado real), incluindo
   `phase8-net.md`.
3. **Atualizar `docs/specs/syscall-abi.md` para v13** com `fs_truncate` (22) e
   `input_wait` (23).
4. **Higiene:** remover `syscall_bench` binário, decidir o destino de `restal/` e
   `internal/ai/archive/`, remover ou integrar o teste morto de F4.
5. **Trocar números fixos de teste** por referência ao run de CI.
6. Se F9 for para o produto: expor a inferência (syscall + app de exemplo +
   marcador no boot test), como foi feito com F4/F5/F6.

---

## 7. Limitações desta auditoria

- **QEMU/OVMF ausentes** neste ambiente: `qemu-test`, `qemu-storage-test` e
  `qemu-interactive-test` **não foram reexecutados**. A confiança nos itens de
  boot e de persistência vem de (a) leitura do código que os implementa e
  (b) execução de CI verde no SHA auditado, com os passos nomeados.
- Os **logs** dos jobs não puderam ser baixados (hospedados em domínio fora do
  acesso desta sessão); a verificação para no nível de conclusão por passo.
- Análise estática e de build; nenhuma validação em hardware físico foi feita
  (o próprio relatório também não a alega).

---

## 8. Correções aplicadas (2026-10-30)

| Item | Ação | Evidência |
|---|---|---|
| **D1** — F9 superestimado | A inferência virou **capacidade do sistema**: imagem embutida em comptime, autoteste fatal no boot, chamada 24 `ai_infer`, capability de kind 4 com o direito `execute`, prova positiva em ring 3 e prova negativa no processo sem a capability | `kernel/ai/embedded.zig`, `shared/ai.zig`, `kernel/arch/x86_64/syscall.zig`, `user/hello.zig`, `user/client.zig`; 9 asserções novas no boot test; `docs/reports/f9/f9-inference-call.md` e ADR-0023 |
| **D1** (rótulo) | README: `✅ Scoped complete` → `🟢 Tested (host)`, com o escopo explícito (um modelo, sem GPU) | `README.md`, tabela de marcos |
| **D2** — F8 "PE/Win32 CONCLUÍDO" | As duas linhas de F8 no roadmap passaram a `PARCIAL`, com a frase "não existe uma linha de PE, de Win32 nem de ABI Linux no repositório" | `docs/roadmap/phase-status.md` |
| **D3** — contrato v12 vs código | `docs/specs/syscall-abi.md` subiu para **v13**: chamadas 22, 23 e 24 documentadas, direito `execute` (32), erro 26 e a tabela de kinds | `docs/specs/syscall-abi.md` (seções 5.11–5.13) |
| **D4** — contagem de testes | Roadmap e README passaram a citar **612** testes (a contagem real após este incremento), em vez de 554 | `zig build test --summary all` |
| **D5** — F10 "CONCLUÍDO (local)" | Linha reescrita como `PARCIAL`, nomeando o que existe (NX, W^X, canário, benchmark, ferramenta de host) e o que não existe (instalador, atualização, recuperação no alvo) | `docs/roadmap/phase-status.md` |
| **D5** — `phase8-net.md` | "incremento concluido" → **stub documentado, não funcional**; a rede não conta como progresso | `docs/reports/f10/phase8-net.md` |
| **D6** — `recovery-mode.sh` | Renomeado para `tools/scripts/recovery_mode.zig`, **corrigido** (API do Zig 0.17) e integrado ao build como `recovery-mode` | `zig build` instala `zig-out/bin/recovery-mode` |
| **D7** — binário rastreado | `syscall_bench` removido do índice e ignorado no `.gitignore`; o fonte em `tools/benchmarks/` permanece | `.gitignore`, `git status` |
| **D7** — teste morto de F4 | `tests/integration/f4_physblk_vnv_integration.zig` (fora do build, com imports impossíveis) foi **movido** para `kernel/host_root.zig`, onde roda de verdade | `fs-loader-tests` 154 → **158** |
| **D7** — dois defeitos em `phys_blk.zig` | O teste da unidade não compilava (`initialized` sem campos e `init` com argumento a mais) e `flush` **não era publicado** no `block.Device`; ambos corrigidos, com dois testes novos | `phys_blk.zig`: 3/3 testes |
| **D7** — arquivos de prompt rastreados | `AGENTS.md` passou a declarar `restal/` e `internal/ai/archive/` como **históricos e não normativos**, em vez de negar a existência deles | `AGENTS.md` |
| **D8** — "desktop pending" | README e roadmap distinguem **desktop de cena presente** de **shell ausente** (barra, lançador, cursor, foco) | `README.md`, F6 no roadmap |
| **D9** — teste interativo fora da CI | **Não corrigido**: `interactive-qemu.sh` continua fora de `zig build check`; exige QEMU com captura de tela e não foi possível validá-lo nesta sessão. Registrado como pendência | — |
| **F5 — VLIB ausente** (pós-auditoria, 2026-10-30) | O contêiner de biblioteca nativa foi implementado como **codec puro**: `formats/vlib.zig` com spec em `docs/specs/vlib.md`, suíte `vlib-tests` (9 testes) e autoteste de boot que empacota `/lib/libvoryn.vlb`, persiste por VNV, recupera o volume, compara byte a byte e revalida os símbolos. **Não** há linker, relocação nem carga de biblioteca em processo — e isso está dito na spec | `formats/vlib.zig`, `docs/specs/vlib.md`, `kernel/main.zig`; `zig build test` 621/621, `zig build` 15/15 |
| **Contagem (revisada)** | Com o VLIB, a contagem real passou de 612 para **621** testes; o README e o roadmap citam o número novo | `zig build test --summary all` |
| **F6 — testes fora do runner** (pós-auditoria, 2026-10-30) | No mesmo dia da auditoria apareceu o mesmo defeito de D7 em outro lugar: **29 testes de oito arquivos gráficos nunca rodavam**. O binário `desktop-tests` (raiz `kernel/graphics/desktop.zig`) passou a coletá-los; a suíte foi de 621 para **670** provas | `build.zig`, `kernel/graphics/desktop.zig`; `zig build test --summary all` |
| **F6 — "sem foco entre clientes"** (pós-auditoria, 2026-10-30) | A frase era **falsa**: `session.zig` entrega o teclado só à janela em foco, o clique muda o foco e o renderizador colore a janela focada. README e roadmap corrigidos; F6.31 acrescentou a barra da shell e `window_manager.focusNext` | `README.md`, `docs/roadmap/phase-status.md`, `docs/reports/f6/shell-taskbar.md` |
| **D10/D11** | Permanecem documentais: histórico git reduzido neste clone; ausência total de rede agora está explícita na linha de F8/F7 do README | `README.md` |

**Validação deste bloco:** ao fim do incremento de F9, `zig build test` →
612 testes, 0 falhas; `zig build` → 15/15 passos, gerando `vorynos.img` e
`recovery-mode`. Depois do incremento de VLIB a mesma suíte passou a
**621 testes** (as 9 provas de `vlib-tests`), mantendo 15/15 passos de build;
com o incremento F6.31 a mesma suíte chegou a **670 provas** e o build a 43/43
passos de teste.
QEMU/OVMF ausentes, portanto as asserções de boot **não** foram executadas
aqui: o estado de F9 segue **TESTADO LOCALMENTE (host)** e o autoteste de
VLIB **IMPLEMENTADO — NÃO TESTADO** no boot.
