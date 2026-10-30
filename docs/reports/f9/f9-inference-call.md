# F9 — A inferência como chamada de sistema

| Campo | Valor |
|-------|-------|
| **Data** | 2026-10-30 |
| **Base** | `arena/14acbfc7-vorynos`, sobre `a418ad33` (`main`) |
| **Estado** | **TESTADO NO CI** — `zig build test`, `zig build` e `zig build qemu-test` verdes no run 41013843472, SHA `2348a56`, com as asserções de boot desta chamada exigidas pelo teste |
| **Contrato** | `docs/specs/syscall-abi.md` v13, chamada 24 |
| **Decisão** | [`ADR-0023`](../../adr/ADR-0023-ai-inference-capability.md) |

## 1. Problema

O F9 entregou `kernel/ai/{tensor,model,security}.zig` — formato binário de
modelo com CRC32 sobre os pesos, limites verificados, produto denso com ReLU e
uma rotina de inferência — e o código **não era alcançável pelo sistema
operacional**: nenhum arquivo do kernel o importava, não havia chamada, não
havia capability e não havia marcador no boot. O rótulo "Scoped complete —
native CPU inference" do README descrevia uma capacidade que não existia para
um programa.

## 2. Implementação

| Arquivo | Mudança |
|---|---|
| `kernel/ai/embedded.zig` | **novo**. Imagem do modelo construída em comptime (cabeçalho, pesos, bias e CRC32), com a geometria e os valores do contrato |
| `kernel/ai/root.zig` | **novo**. Raiz do módulo: agrega `tensor`, `model`, `security` e `embedded`, para que nenhum arquivo fique fora do binário de testes |
| `shared/ai.zig` | **novo**. Contrato público: número 24, kind 4, direito `execute` (32), geometria, entrada de amostra, saída esperada e checksum FNV-1a |
| `kernel/security/capability.zig` | kind `.ai` (wire 4) e direito `execute`; `allowedRights`, `kindName`, `kindFromWire`/`kindToWire` e o teste dos cinco kinds |
| `kernel/arch/x86_64/syscall.zig` | chamada 24, erro 26 `ai_failure`, dispatch e `aiInfer()` com capability antes dos tamanhos e dos endereços, validação do modelo e leitura de volta |
| `kernel/main.zig` | `verifyAiSelfTest()` antes do timer, capability criada e concedida ao processo que compõe, linha de relatório |
| `sdk/src/{root,syscall}.zig` | `aiInfer()`, número 24, erro 26, `CapabilityKind.ai` e `Right.execute` |
| `user/hello.zig` | prova de ring 3: tamanho errado recusado (erro 3), chamada válida (12 bytes), conferência bit a bit e checksum no serial |
| `user/client.zig` | prova negativa: processo sem a capability recusado com o erro 10, e o trabalho normal continua depois |
| `build.zig` | módulo `voryn_ai` no SDK e nos testes de host; `kernel/ai/root.zig` como raiz de `ai-tests` |
| `tests/integration/boot-qemu.sh` | nove asserções novas, incluindo os dois códigos de erro e o checksum |

### 2.1 Ordem das verificações

`ai_infer` verifica, nesta ordem: privilégio → **capability** → tamanhos →
faixas de usuário → inferência → escrita → **leitura de volta**. A capability
vem antes de qualquer tamanho ou endereço, como em `present`: um processo sem
autorização não aprende a geometria do motor e o buffer dele nunca é lido.

### 2.2 Por que a imagem é validada em toda chamada

`model.validate` recalcula o CRC32 dos 48 bytes de pesos. O custo é
desprezível e evita a classe de defeito em que uma única leitura corrompida
produz números plausíveis pelo resto do boot. A decodificação de cabeçalho já
é feita com limites e aritmética verificada em `kernel/ai/security.zig`.

## 3. Validação

| Comando | Ambiente | Resultado |
|---|---|---|
| `zig build test --summary all` | Zig 0.17.0, host x86_64 | **612 testes, 0 falhas** (`ai-tests` 3 → 10, `shared-tests` 55 → 59, `sdk-tests` 4 → 5, `fs-loader-tests` 154 → 158) |
| `zig build` | idem | 15/15 passos; `voryn-kernel` (66,8 MB Debug), `vorynos.img` (128 MiB) e `recovery-mode` |
| `zig build qemu-test` / `check` | pass | run [41013843472](https://github.com/CeoMatheusDev/VorynOS/actions/runs/41013843472), passo *Teste de boot no QEMU* `success` no SHA `2348a56` |
| Inspeção do binário | `strings zig-out/bin/voryn-kernel` | marcadores `[VNK] ai: model validated`, `inference ok`, `ran the model` presentes no kernel |

Testes do módulo, executados isoladamente:

```text
zig test kernel/ai/root.zig          10/10
zig test shared/root.zig             59/59
zig test sdk/src/root.zig             5/5
zig test kernel/security/capability.zig 17/17
```

O resultado numérico é exato por construção (potências de dois e inteiros
pequenos), e o teste `the embedded image produces the exact output of the
contract` compara o checksum com `0x30f2bf7325eecf35`. O teste
`a corrupted image is refused before the inference` altera um byte dos pesos e
exige `ChecksumMismatch`.

## 4. Asserções de boot adicionadas

```text
[VNK] ai: model validated id=0 input=4 hidden=4 output=3 image=124 bytes weights=48 bytes crc ok
[VNK] ai: inference ok output_x1000=2125,5250,4000 checksum=0x30f2bf7325eecf35 model=0
[VNK] capabilities: the inference engine belongs to the process N
ai infer wrong size refused
[VNK] syscall 24 from user ai_infer result 0xfffffffffffffffd   (erro 3)
[VNK] ai: process N ran the model output=0x... inputs=0x... checksum=0x30f2bf7325eecf35
[VNK] syscall 24 from user ai_infer result 0xc                   (12 bytes)
ai infer ok checksum=0x30f2bf7325eecf35
[VNK] syscall 24 from user ai_infer result 0xfffffffffffffff6   (erro 10, cliente)
ai infer denied without the capability
```

## 5. Desempenho

**Não medido.** A inferência é uma multiplicação de matriz 3x4 com 4 somas e
4 comparações de ReLU, mais um CRC32 de 48 bytes; não há benchmark, e este
relatório não alega número algum. Medir a chamada exigiria o `syscall_bench`
no ambiente de boot, que não está disponível nesta sessão.

## 6. Limitações

- A geometria é fixa (4 → 3). Um modelo diferente exige nova versão do
  contrato; o campo `model_id` existe e é verificado, para que a evolução não
  precise reutilizar o número da chamada.
- Sem GPU, sem pesos quantizados, sem lote e sem conclusão assíncrona.
- A inferência roda dentro da chamada, na pilha do kernel. Um modelo maior
  teria de virar serviço com tarefa própria — outra decisão.
- A capability é concedida **sem** o direito de delegação; não há segundo
  consumidor hoje.
- **Sem validação em QEMU nesta sessão.** A confiança vem da compilação, dos
  testes de host e da revisão do caminho; o `qemu-test` na CI é o que
  confirma as nove asserções novas, e deve ser lido antes de promover o
  estado para TESTADO NO CI.

## 7. Próximo incremento

1. Rodar `zig build check` na CI e registrar o SHA verde neste relatório.
2. Medir a latência da chamada 24 com o `syscall_bench` no boot.
3. Se houver segundo consumidor, conceder a capability com `delegate` e
   testar a cadeia de delegação e a revogação, como foi feito com o display.
