# ADR-0003 — Linguagens, toolchain e sistema de construção

| Campo | Valor |
|-------|-------|
| **Estado** | ACEITO |
| **Data** | 2026-10-21 |
| **Decidido por** | Engenharia VorynOS |

## 1. Contexto

O VorynOS é escrito do zero. As escolhas de linguagem e de construção
determinam o tamanho do kernel, a auditabilidade, a portabilidade e o custo
de manutenção.

## 2. Decisão

### 2.1 Linguagem principal: Zig 0.17.0

- Versão-alvo fixa em `0.17.0`, registrada em `build.zig.zon`
  (`minimum_zig_version`). A versão não é alterada sem autorização.
- Antes de usar qualquer API, ela é conferida na biblioteca padrão instalada
  (`$(zig env | jq -r .std_dir)`). APIs de versões anteriores não são
  reutilizadas por memória.
- O kernel e o loader são compilados sem libc, `single_threaded`, para
  `x86_64-freestanding` e `x86_64-uefi` respectivamente.

**Justificativa:** Zig permite ausência de libc, controle explícito de
layout de memória, alocação previsível e um único compilador para kernel,
loader, ferramentas e testes. A linguagem não impõe runtime, o que é
essencial para um componente privilegiado mínimo.

### 2.2 C23: uso restrito e justificado

C23 é aceito apenas quando houver justificativa técnica real:

- interfaces ABI que precisam interoperar com código de terceiros;
- componentes que devam ser compilados por outra toolchain;
- portabilidade de um algoritmo para fora do kernel.

Não se mantém a mesma implementação em Zig e em C. O kernel atual **não
contém** código C; a decisão é preventiva, não descritiva.

### 2.3 Assembly: uso restrito e justificado

Assembly é usado para controle direto de hardware e de estado de
privilegiagem. No estado atual existe exatamente um arquivo:
`kernel/arch/x86_64/entry.s`, que:

- recebe o controle do loader com o ponteiro do contrato em `RDI`;
- estabelece a pilha própria do kernel antes de tocar qualquer memória;
- respeita o alinhamento de 16 bytes exigido pela ABI SysV;
- mantém `RDI` (caller-saved) sem necessidade de preservá-lo;
- declara a pilha de boot em `.bss`, dentro da própria imagem, para que o
  kernel seja dono da sua pilha desde a primeira instrução.

Todo arquivo de assembly documenta a ABI, o alinhamento de pilha, os
registradores preservados e os efeitos colaterais.

### 2.4 Sistema de construção

`build.zig` é o único sistema de construção. Passos:

| Passo | Função |
|-------|--------|
| `zig build` | Compila loader, kernel e ferramentas e gera a imagem de disco |
| `zig build test` | Testes de unidade no host |
| `zig build qemu-test` | Teste automatizado de boot no QEMU/OVMF |
| `zig build qemu` | Boot interativo no QEMU |
| `zig build check` | Unidade + boot |
| `zig build image` | Apenas a imagem de disco |

A imagem de disco é produzida por `tools/voryn-fsimg`, ferramenta do próprio
projeto, o que elimina `mtools` e `dosfstools` da cadeia de construção.

## 3. Dependências de execução

Nenhuma. O VorynOS não depende de kernel Linux, Windows ou BSD em execução
nativa. A única dependência de terceiros em tempo de construção é o
firmware UEFI, que é o ponto de entrada do sistema por definição.

## 4. Custos

- O compilador Zig 0.17.0 ainda está em evolução e a API da biblioteca padrão
  muda entre versões; o custo é absorvido pela regra de verificação de API.
- Não haver `libc` significa reimplementar parte da biblioteca padrão dentro
  do kernel. É um custo aceito: o kernel precisa de controle total sobre
  alocação e layout, e a biblioteca padrão do host traria dependências
  desnecessárias.

## 5. Consequências

- Todo módulo novo precisa ser registrado explicitamente em `build.zig` e
  testado de forma independente quando possível.
- A suíte de unidade roda no host, sobre o mesmo código do kernel e do
  loader; é isso que permite testar a lógica de ELF64, mapa de memória e
  contrato de handoff sem emulador.
