# VEX — Formato de executável nativo (Voryn EXecutable)

| Campo | Valor |
|-------|-------|
| **Estado** | EM VIGOR (implementado e testado: `formats/vex.zig`, integrado ao `elf_loader`) |
| **Data** | 2026-10-25 |
| **Escopo** | Container de executáveis nativos com manifest de capacidades |
| **Extensão** | `.vex` |

## 1. Princípio

Um arquivo VEX é um **cabeçalho de manifest** que envolve uma imagem ELF64.
O ELF continua sendo o formato de máquina (segmentos, realocações,
entrada); o VEX adiciona a camada de metadados — versão do container,
integridade (CRC32 do payload) e o **manifest de capacidades** declaradas
pelo executável. O carregador do kernel detecta o magic, valida tudo e
planeja o ELF interno normalmente; o materializador não muda.

O formato é explicitamente little-endian e nunca depende do layout de
structs do compilador.

## 2. Estrutura

```text
+------------------+  offset 0
| cabeçalho (64 B) |  magic, versão, geometria, CRC do payload
+------------------+  offset 64 (= payload_offset)
| payload (ELF64)  |  a imagem executável
+------------------+  manifest_offset (opcional, logo após o payload)
| manifest         |  registros {kind, rights} de 8 bytes
+------------------+
```

### 2.1 Cabeçalho (64 bytes)

| Offset | Tamanho | Campo | Valor |
|--------|--------:|-------|-------|
| 0 | 4 | `magic` | `0x3158_4556` (`"VEX1"` em little endian) |
| 4 | 2 | `version` | `1` |
| 6 | 2 | `header_size` | `64` |
| 8 | 4 | `flags` | reservado (zero) |
| 12 | 8 | `entry_hint` | reservado (zero; a entrada do ELF vence) |
| 20 | 8 | `payload_offset` | sempre `64` |
| 28 | 8 | `payload_size` | tamanho da imagem ELF |
| 36 | 8 | `manifest_offset` | `0` = sem manifest; senão, `64 + payload_size` |
| 44 | 8 | `manifest_size` | `contagem * 8` |
| 52 | 4 | `crc32` | CRC32 do payload (`[64..64+payload_size]`) |
| 56 | 8 | reservado | zero |

### 2.2 Registro do manifest (8 bytes)

| Offset | Tamanho | Campo |
|--------|--------:|-------|
| 0 | 4 | `kind` (0 = canal, 1 = processo, 2 = display, 3 = entrada) |
| 4 | 4 | `rights` (bitmask; `delegate = 4`, `write = 8`, `read = 16`) |

Limites: `max_manifest_entries = 16`; kinds fora de `0..3` são rejeitados.

## 3. Validação (`validate`)

O validador confere, nesta ordem:

1. tamanho mínimo do cabeçalho;
2. `magic`, `version` e `header_size`;
3. `payload_offset == 64` e `payload_end == 64 + payload_size`;
4. manifest opcional: `manifest_offset == payload_end`, `manifest_size % 8 == 0`,
   `contagem <= 16`, kinds conhecidos e fim exato do arquivo;
5. CRC32 do payload.

`unwrap` devolve `error.NotVex` quando o magic não confere — o chamador
trata o arquivo como ELF puro — e a fatia do payload (apontando para o
buffer do chamador) quando o VEX é válido.

## 4. Integração com o carregador

`elf_loader.planFromRamFs` lê o arquivo, chama `vex.unwrap` e, para um
VEX, move o payload para o início do buffer antes de planejar: o
materializador continua lendo os bytes a partir do offset zero.

O manifest é **imposto** no spawn do processo: `elf_loader.
readManifestFromRamFs` relê as capacidades declaradas e o kernel verifica
que cada entrada é um kind que ele concede ao processo e que os direitos
declarados são um subconjunto dos direitos concedidos. Uma declaração que
o kernel não honra é fatal. A concessão em si continua sendo decisão
explícita do kernel (tabela de capacidades), e o VEX não pode ampliá-la.

## 5. Verificação

- `zig build test`: suíte `vex-tests` (wrap/validate/unwrap, determinismo,
  corrupção, manifest) + teste do `elf_loader` que planeja um VEX do
  RamFS.
- `zig build qemu-test`: o executável da toolchain é instalado como
  `/apps/toolchain.vex` (manifest display+input), o carregador desembrulha
  e planeja a imagem, a tarefa roda e o arquivo sobrevive à
  persistência/recuperação VNV.
