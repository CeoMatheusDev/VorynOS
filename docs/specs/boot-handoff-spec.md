# Especificação do contrato de handoff VNB → VNK

| Campo | Valor |
|-------|-------|
| **Estado** | ACEITO — versão 1, implementada e validada |
| **Data** | 2026-10-21 |
| **Versão do contrato** | 1 |
| **Código** | `shared/handoff.zig` |

Esta especificação é normativa. O loader (VNB) e o kernel (VNK) compilam a
mesma definição, e ambos devem rejeitar um contrato incompatível.

## 1. Visão geral

O loader preenche uma estrutura `BootHandoff` em memória alocada como
`EfiRuntimeServicesData`, que sobrevive a `ExitBootServices`, e passa o
endereço físico dessa estrutura ao kernel no registrador `RDI`, conforme a
ABI System V AMD64.

O kernel **precisa** validar o contrato antes de qualquer uso. Um contrato
inválido interrompe a inicialização com mensagem explícita; o kernel não
interpreta campos desconhecidos.

## 2. Convenções

- Endianness: little endian.
- Alinhamento: 8 bytes.
- Tamanho dos descritores de memória: 40 bytes, `memory_map_stride`.
- Todos os inteiros são sem sinal, exceto onde indicado.

## 3. Estrutura `BootHandoff`

| Offset | Tamanho | Campo | Descrição |
|--------|---------|-------|-----------|
| 0 | 8 | `magic` | `0x564F5259_4E424F54` |
| 8 | 4 | `version` | 1 |
| 12 | 4 | `header_size` | `@sizeOf(BootHandoff)` |
| 16 | 8 | `flags` | ver §4 |
| 24 | 8 | `handoff_address` | endereço físico da própria estrutura |
| 32 | 8 | `memory_map_address` | endereço físico do array de descritores |
| 40 | 4 | `memory_map_entries` | número de descritores válidos |
| 44 | 4 | `memory_map_stride` | 40 |
| 48 | 96 | `framebuffer` | `FramebufferInfo` |
| 144 | 8 | `kernel_base` | primeiro endereço físico da imagem do kernel |
| 152 | 8 | `kernel_end` | endereço físico após a imagem |
| 160 | 8 | `kernel_entry` | endereço físico do ponto de entrada |
| 168 | 8 | `kernel_stack_top` | topo da pilha de boot do kernel |
| 176 | 8 | `kernel_stack_bottom` | base da pilha de boot do kernel |
| 184 | 8 | `acpi_rsdp_address` | endereço do RSDP, 0 se ausente |
| 192 | 4 | `boot_processor_id` | identificador do processador do handoff |
| 196 | 4 | `processor_count` | processadores reportados pelo firmware |
| 200 | 8 | `firmware_size` | tamanho do cabeçalho da tabela do firmware |
| 208 | 8 | `firmware_revision` | revisão do firmware |

Tamanho total: 216 bytes.

## 4. Flags

| Bit | Nome | Significado |
|-----|------|-------------|
| 0 | `flag_framebuffer` | existe framebuffer linear utilizável |
| 1 | `flag_kernel_from_disk` | imagem do kernel lida de um volume e validada |
| 2 | `flag_memory_map_final` | mapa capturado imediatamente antes de `ExitBootServices` |
| 3 | `flag_identity_mapped` | os primeiros 4 GiB estão mapeados por identidade |
| 4 | `flag_acpi_rsdp` | `acpi_rsdp_address` é válido |

Bits desconhecidos **devem** ser ignorados pelo consumidor, para permitir
extensão futura do contrato.

## 5. `FramebufferInfo`

| Offset | Tamanho | Campo |
|--------|---------|-------|
| 0 | 8 | `base` |
| 8 | 8 | `size` |
| 16 | 4 | `width` |
| 20 | 4 | `height` |
| 24 | 4 | `pitch` |
| 28 | 4 | `bits_per_pixel` |
| 32 | 4 | `pixel_format` |
| 36 | 4 | `red_mask` |
| 40 | 4 | `green_mask` |
| 44 | 4 | `blue_mask` |
| 48 | 1 | `red_shift` |
| 49 | 1 | `green_shift` |
| 50 | 1 | `blue_shift` |
| 51 | 3 | reservado, zero |

`pixel_format`: 0 = `rgb32`, 1 = `bgr32`, `0xFFFFFFFF` = desconhecido.

## 6. Descritor de memória

| Offset | Tamanho | Campo |
|--------|---------|-------|
| 0 | 4 | `memory_type` |
| 4 | 4 | reservado, zero |
| 8 | 8 | `physical_start` |
| 16 | 8 | `virtual_start` |
| 24 | 8 | `page_count` |
| 32 | 8 | `attributes` |

`memory_type` é numericamente compatível com `EFI_MEMORY_TYPE`:
0 reservado, 1 loader code, 2 loader data, 3 boot services code, 4 boot
services data, 5 runtime services code, 6 runtime services data, 7 memória
convencional, 8 inutilizável, 9 ACPI reclaim, 10 ACPI NVS, 11 MMIO, 12 PAL
code, 13 memória persistente, 14 memória não aceita.

## 7. Validação obrigatória pelo consumidor

1. `magic == 0x564F5259_4E424F54`.
2. `version` é suportada.
3. `header_size >= @sizeOf(BootHandoff)`.
4. Se `memory_map_entries != 0`: `memory_map_address != 0` e
   `memory_map_stride == 40`.

Qualquer falha interrompe a inicialização. Não há valor padrão para campo
inválido: o kernel não pode "adivinhar" um mapa de memória.

## 8. Requisitos do produtor

1. O mapa de memória é capturado **imediatamente antes** de
   `ExitBootServices`, porque qualquer alocação posterior o invalida.
2. Se `ExitBootServices` retornar `EFI_INVALID_PARAMETER`, o mapa é
   capturado de novo e a chamada é repetida. O loader repete até oito vezes.
3. A estrutura e o mapa de memória vivem em memória de runtime services, que
   sobrevive a `ExitBootServices`.
4. O endereço físico e o virtual do contrato são iguais: o loader exige que
   ambos estejam abaixo de 4 GiB, faixa que o firmware mapeia por
   identidade enquanto os boot services estão disponíveis.
5. Nenhum serviço de boot é usado depois de `ExitBootServices`. O console do
   firmware é desacoplado antes da chamada.

## 9. Compatibilidade futura

- Novos campos são acrescentados ao final, com incremento de `header_size` e
  de `version` quando o significado mudar.
- Campos nunca são removidos nem reutilizados.
- O kernel deve ignorar flags desconhecidas, mas **não** campos
  desconhecidos: um `header_size` maior é aceito, os campos além do tamanho
  conhecido são ignorados.
