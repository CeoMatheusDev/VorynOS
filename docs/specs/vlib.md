# VLIB — Formato de biblioteca nativa (Voryn Library)

| Campo | Valor |
|-------|-------|
| **Estado** | EM VIGOR (implementado e testado: `formats/vlib.zig`, autoteste no boot) |
| **Data** | 2026-10-30 |
| **Escopo** | Container de uma biblioteca nativa: imagem ELF64 relocável + símbolos + ABI + capabilities |
| **Extensão** | `.vlb` |
| **Irmãos** | VEX (executável), VPK (pacote), VDRV (driver) — ver `docs/standards/VN-NAMES-0001.md` §3 |

## 1. Princípio

Um VLIB é um arquivo único que carrega uma **imagem de biblioteca** — um
ELF64 relocável — junto com aquilo que o kernel precisa saber **antes** de
executar um único byte do código: como a biblioteca se chama, o que ela
exporta, para qual ABI de sistema de chamadas foi construída e quais
capabilities exige.

O formato é **explicitamente little-endian** e nunca depende do layout de
structs do compilador. O codec é puro: não faz syscalls, não aloca e não faz
I/O. O armazenamento do arquivo fica com o RamFS/VFSX; a decisão de carregar
ou não a biblioteca fica com o kernel. Este módulo diz apenas **o que o
arquivo contém e se ele está íntegro**.

### 1.1 O que este incremento é e o que ele não é

- **É** um codec de container: empacotar, gravar, recuperar do volume de
  blocos e validar byte a byte, com os símbolos consultáveis por nome.
- **Não é** um linker, um carregador de processos nem um resolvedor de
  relocações. Nada neste incremento mapeia a imagem em um espaço de
  endereço de processo, aplica relocações ou liga chamadas entre bibliotecas.
  A bandeira `relocatable` declara uma propriedade da imagem; ela não é uma
  promessa de que o kernel já saiba usá-la.

## 2. Estrutura

```text
+------------------+  offset 0
| cabeçalho (64 B) |  magic, versão, geometria, ABI, capabilities e CRCs
+------------------+  offset 64 (= symbol_table_offset)
| registros (N×24) |  deslocamento do nome, tamanho, binding, tipo e valor
| nomes            |  nomes dos símbolos, consecutivos
| nome da lib      |  os últimos `name_len` bytes da região da tabela
+------------------+  offset image_offset
| imagem           |  o ELF64 relocável, byte a byte
+------------------+  fim do arquivo
```

`image_offset = 64 + N*24 + soma(len(nomes dos símbolos)) + name_len`, e a
imagem termina **exatamente** no último byte do arquivo.

### 2.1 Cabeçalho (64 bytes)

| Offset | Tamanho | Campo | Valor |
|--------|--------:|-------|-------|
| 0 | 4 | `magic` | `0x564C_4231` (`"VLB1"` em little endian) |
| 4 | 2 | `version` | `1` |
| 6 | 2 | `header_size` | `64` |
| 8 | 2 | `symbol_count` | quantidade de símbolos (0 a 4096) |
| 10 | 2 | `name_len` | comprimento do nome da biblioteca (1 a 64) |
| 12 | 4 | `abi_version` | versão da ABI de sistema de chamadas da imagem |
| 16 | 4 | `flags` | bandeiras (bit 0 = `relocatable`) |
| 20 | 4 | `symbol_table_crc32` | CRC32 de `[64..image_offset)` |
| 24 | 8 | `required_capabilities` | máscara das capabilities exigidas |
| 32 | 8 | `symbol_table_offset` | sempre `64` |
| 40 | 8 | `image_offset` | início da imagem |
| 48 | 8 | `image_size` | tamanho da imagem |
| 56 | 4 | `image_crc32` | CRC32 de `[image_offset..len)` |

### 2.2 Registro de símbolo (24 bytes)

| Offset | Tamanho | Campo |
|--------|--------:|-------|
| 0 | 8 | `name_offset` (relativo ao início da região de nomes) |
| 8 | 2 | `name_len` (1 a 255) |
| 10 | 1 | `binding` (0 = exportado, 1 = interno) |
| 11 | 1 | `kind` (0 = função, 1 = objeto) |
| 12 | 4 | reservado (zero) |
| 16 | 8 | `value` (deslocamento do símbolo dentro da imagem) |

Os registros ficam **antes** dos nomes; a região de nomes é o espaço entre o
fim dos registros e o início do nome da biblioteca.

## 3. Validação (`validate`)

O validador verifica, nesta ordem, antes de qualquer leitura de conteúdo:

1. tamanho mínimo do cabeçalho;
2. `magic`, `version` e `header_size`;
3. `symbol_count <= 4096`, `1 <= name_len <= 64` e `symbol_table_offset == 64`;
4. `image_offset + image_size == len(bytes)` (sem bytes sobrando) e
   `image_size > 0`;
5. o início dos nomes cabe antes de `image_offset` e o nome da biblioteca
   cabe na região da tabela;
6. CRC32 da região da tabela (`[64..image_offset)`);
7. o nome da biblioteca é um identificador válido;
8. CRC32 da imagem;
9. **por último**, cada registro: `binding` e `kind` conhecidos,
   `name_len` válido, nome dentro da região de nomes, e nome válido.

A ordem não é acidental: um registro corrompido que ainda caiba nos limites
seria aceito se a checagem de limites viesse antes do CRC.

## 4. Duas somas de verificação

As duas falhas são diferentes e por isso existem dois CRCs:

- `image_crc32` cobre os **bytes de código**. É a parte perigosa: um único
  byte trocado muda o que a biblioteca faz;
- `symbol_table_crc32` cobre os registros, os nomes dos símbolos e o nome da
  biblioteca. Sem ele, um `name_offset` corrompido poderia apontar para uma
  região ainda válida e o *export errado* passaria na validação de limites.

## 5. Nomes e binding

Um nome de símbolo é um identificador técnico: 1 a 255 bytes, ASCII
imprimível (`0x21`–`0x7E`), sem `/` e sem `NUL`. A regra existe para que o
nome possa ser usado como chave e como parte de caminho sem nova validação. O
nome da biblioteca segue o mesmo alfabeto, com limite 64, e **não** carrega
diretório nem extensão (`libvoryn`, não `/lib/libvoryn.vlb`).

- `binding = exported` (0): faz parte da interface. Dois exportados com o
  mesmo nome são recusados no empacotamento (`DuplicateName`).
- `binding = hidden` (1): símbolo interno, não é oferecido a quem liga
  contra a biblioteca. Nomes internos repetidos são permitidos, e
  `findExport` **não** os devolve — a procura é a operação de quem liga
  contra a biblioteca.

## 6. Garantias e limites

- O empacotamento (`pack`) é determinístico: mesmas opções, mesmos bytes.
- O tamanho exato é calculável antes de empacotar (`packedSize`).
- Um erro durante `pack` não deixa arquivo parcial: a tabela é validada
  antes de o primeiro byte ser escrito.
- Limites: `max_symbols = 4096`, `max_name_len = 255`,
  `max_library_name_len = 64`, `symbol_record_size = 24`,
  `header_size = 64`.
- `abi_version` é a versão de `docs/specs/syscall-abi.md`. Um kernel que não
  a suporte deve recusar a biblioteca; o codec apenas a transporta.
- `required_capabilities` usa o valor de *wire* de `Capability.KindWire`
  (`kernel/security/capability.zig`): o bit `k` da máscara corresponde ao
  kind `k` (canal = 0, processo = 1, display = 2, fila de entrada = 3,
  inferência = 4).

## 7. Verificação

- `zig build test`: suíte **`vlib-tests`** (9 testes) — empacotar, validar,
  ler símbolo por índice, procurar export, recusar símbolo interno como
  export, nome de biblioteca inválido, duplicata de exportado, byte extra
  depois da imagem, CRC da imagem corrompido.
- `zig build qemu-test` (CI): o kernel empacota `/lib/libvoryn.vlb` a partir
  de `toolchain_app.bytes`, grava no RamFS, faz o commit VNV, recupera o
  volume de um dispositivo de blocos e, no autoteste de boot, compara o
  arquivo recuperado **byte a byte** com o buffer empacotado, revalida o
  contêiner, confere `abi_version`, `required_capabilities`, o tamanho da
  imagem, o valor de `voryn_main` (exportado) e a ausência de
  `internal_helper` (interno) entre os exports. Só depois remove o arquivo.

O autoteste de boot é verificado no CI; localmente ele é **BLOQUEADO**
(ver D9 em `docs/reports/audits/milestone-progress-2026-10-30.md`).

## 8. Exemplo: a biblioteca de sistema

O kernel empacota uma única biblioteca, `libvoryn`, como parte do autoteste:

| Campo | Valor |
|-------|-------|
| Nome | `libvoryn` |
| Caminho | `/lib/libvoryn.vlb` |
| `abi_version` | `13` |
| `required_capabilities` | `1 << 2` (display) |
| `flags` | `relocatable` |
| Exportados | `voryn_main = 0x1000`, `voryn_init = 0x0`, `voryn_shutdown = 0x1080` |
| Interno | `internal_helper = 0x1100` |
| Imagem | `toolchain_app.bytes` (ELF64 gerado pelo toolchain) |
