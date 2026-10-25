# VPK — Formato de pacote de aplicação (Voryn Application Package)

| Campo | Valor |
|-------|-------|
| **Estado** | EM VIGOR (implementado e testado: `formats/vpk.zig`, autoteste no boot) |
| **Data** | 2026-10-25 |
| **Escopo** | Container de arquivos para distribuição de aplicações nativas |
| **Extensão** | `.vpk` |

## 1. Princípio

Um VPK é um arquivo único que embala um executável e seus recursos com
nomes, tipos e integridade por entrada. O formato é **explicitamente
little-endian** e nunca depende do layout de structs do compilador. O codec
é puro: não faz syscalls, não aloca e não faz I/O; o armazenamento do
arquivo fica com o VFSX/RamFS.

## 2. Estrutura

```text
+------------------+  offset 0
| cabeçalho (64 B) |  magic, versão, contagem, geometria, CRC do corpo
+------------------+  offset 64 (= table_offset)
| registros (N×32) |  nome, tipo, offset, tamanho e CRC de cada entrada
| nomes            |  nomes das entradas, consecutivos
+------------------+  payload_offset = table_offset + table_size
| payload          |  bytes dos arquivos, consecutivos
+------------------+
```

### 2.1 Cabeçalho (64 bytes)

| Offset | Tamanho | Campo | Valor |
|--------|--------:|-------|-------|
| 0 | 4 | `magic` | `0x5650_4B31` (`"VPK1"` em little endian) |
| 4 | 2 | `version` | `1` |
| 6 | 2 | `header_size` | `64` |
| 8 | 4 | `entry_count` | quantidade de entradas |
| 12 | 8 | `table_offset` | sempre `64` |
| 20 | 8 | `table_size` | `entry_count * 32 + nomes` |
| 28 | 8 | `payload_offset` | `table_offset + table_size` |
| 36 | 8 | `payload_size` | soma dos tamanhos dos arquivos |
| 44 | 8 | `total_size` | `payload_offset + payload_size` |
| 52 | 4 | `checksum` | CRC32 do corpo (`[64..total_size]`) |
| 56 | 8 | reservado | zero |

### 2.2 Registro de entrada (32 bytes)

| Offset | Tamanho | Campo |
|--------|--------:|-------|
| 0 | 8 | `name_offset` (relativo ao início da tabela) |
| 8 | 2 | `name_len` (1 a 255) |
| 10 | 1 | `kind` (0 = executável, 1 = dado, 2 = configuração) |
| 11 | 1 | reservado (zero) |
| 12 | 8 | `offset` (relativo ao início do payload) |
| 20 | 8 | `size` |
| 28 | 4 | `crc32` do conteúdo da entrada |

## 3. Validação (`validate`)

O validador verifica, nesta ordem, antes de qualquer leitura de conteúdo:

1. tamanho mínimo do cabeçalho;
2. `magic`, `version` e `header_size`;
3. `entry_count <= 4096`;
4. `table_offset == 64` e `payload_offset == table_offset + table_size`;
5. `total_size == payload_offset + payload_size` e `total_size == len(bytes)`;
6. CRC32 do corpo;
7. para cada entrada: `kind` conhecido, byte reservado zero, nome dentro da
   região de nomes com comprimento válido e sem `\0` nem `/`, nomes
   únicos, e `offset + size <= payload_size`.

## 4. Integridade por entrada

Além do CRC do corpo, cada entrada carrega o CRC32 dos seus próprios bytes.
`readEntry`/`readEntryByName` conferem esse CRC antes de devolver o
conteúdo: um byte corrompido no payload de um arquivo é detectado mesmo
quando o CRC do corpo foi refeito.

## 5. Garantias e limites

- O empacotamento (`pack`) é determinístico: mesmos arquivos, mesmos bytes.
- O tamanho exato é calculável antes de empacotar (`packedSize`).
- Limites: `max_name_len = 255`, `max_entries = 4096`, nomes sem `/` nem
  `\0`, sem duplicatas.
- O VPK não é um executável: a entrada `kind = executable` referencia um
  arquivo VEX (ver `docs/standards/VN-NAMES-0001.md`), que o carregador
  nativo materializa.

## 6. Verificação

- `zig build test`: suíte `vpk-tests` (empacotar, validar, ler, corromper,
  nomes inválidos, duplicatas, geometria).
- `zig build qemu-test`: o kernel empacota `/apps/sample.vpk`, grava no
  RamFS, recupera o volume de um dispositivo de blocos (VNV) e desempacota
  o pacote byte a byte no autoteste de boot.
