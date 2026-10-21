# ADR-0002 — Cadeia de boot, contrato de handoff e ABI UEFI

| Campo | Valor |
|-------|-------|
| **Estado** | ACEITO — implementado e validado no QEMU/OVMF |
| **Data** | 2026-10-21 |
| **Decidido por** | Engenharia VorynOS |
| **Substitui** | — |

## 1. Contexto

O VorynOS precisa de um caminho de boot reproduzível, verificável e
independente do firmware. O loader recebe controle de um firmware UEFI x86_64
e precisa entregar ao kernel uma imagem válida, um mapa de memória fiel e um
contrato verificável, sem usar serviços de boot depois de
`ExitBootServices`.

## 2. Decisão

1. **VNB é uma aplicação UEFI própria**, escrita em Zig, alvo
   `x86_64-uefi`, sem libc, single-threaded.
2. **O kernel é uma imagem ELF64 relocável** (`ET_DYN`, PIE), carregada do
   volume de boot e posicionada pelo loader em uma região de RAM escolhida em
   tempo de execução.
3. **O contrato entre loader e kernel é uma estrutura versionada**,
   `shared/handoff.zig`, preenchida em memória de runtime services (que
   sobrevive a `ExitBootServices`) e verificada nos dois lados.
4. **O console serial (COM1) é o canal de diagnóstico primário**, escrito
   diretamente pela UART 16550. O console do firmware é secundário e é
   desacoplado antes de `ExitBootServices`.
5. **A imagem de teste é construída pelo próprio projeto** (`tools/fatimg.zig`),
   um volume FAT16 escrito do zero, sem depender de ferramentas externas de
   disco.

## 3. Contrato de handoff

Resumido; a especificação normativa está em
[`docs/specs/boot-handoff-spec.md`](../specs/boot-handoff-spec.md).

| Campo | Valor |
|-------|-------|
| `magic` | `0x564F5259_4E424F54` ("VORYNBOT") |
| `version` | 1 |
| `header_size` | `@sizeOf(BootHandoff)` |
| `flags` | framebuffer presente, kernel vindo de disco, mapa final, mapa de identidade, RSDP |
| `memory_map_address` | endereço físico do array de descritores normalizados |
| `memory_map_entries` | número de descritores válidos |
| `memory_map_stride` | `@sizeOf(MemoryDescriptor)`, 40 bytes |
| `kernel_base` / `kernel_end` / `kernel_entry` | endereços físicos da imagem |
| `framebuffer` | base, tamanho, resolução, pitch, formato e máscaras de canal |

O kernel valida magic, versão, tamanho do cabeçalho e coerência do mapa de
memória antes de qualquer uso. Um handoff inválido interrompe o boot com
mensagem explícita, sem tentar usar a estrutura.

## 4. Descobertas de ABI no firmware (evidência experimental)

A ABI da UEFI medida no OVMF usado pelos testes diverge da descrição
esquemática da especificação em três pontos. Cada ponto foi confirmado
experimentalmente no próprio firmware, não por suposição.

### 4.1 Cabeçalho `EFI_REVISION` ausente em alguns protocolos

O `EFI_FILE_PROTOCOL` do firmware **tem** o cabeçalho `EFI_REVISION`
(`0x00010000` nos primeiros oito bytes), enquanto o
`EFI_GRAPHICS_OUTPUT_PROTOCOL` e o `EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL` do
**mesmo** firmware **não têm**: os primeiros oito bytes são o ponteiro da
primeira função.

Evidência: uma aplicação de teste chamou o membro no deslocamento 8 e o
membro no deslocamento 16. O deslocamento 8 imprimiu a mensagem esperada; o
deslocamento 16 não imprimiu nada (chamou `TestString`, que não escreve).

**Consequência:** o loader não assume nenhuma das variantes. `Protocol` em
`boot/uefi/vnb/protocols.zig` detecta a variante em tempo de execução
(comparando os primeiros oito bytes com `0x00010000`) e mantém **dois**
ponteiros: o *corpo* do protocolo, usado para ler os membros, e o ponteiro
`*this*`, que é o endereço que o firmware espera receber como primeiro
argumento de cada callback. Passar o corpo como `this` faria o firmware ler
os membros em deslocamentos errados.

### 4.2 Tamanho do descritor de memória

O firmware reporta `DescriptorSize = 48` no `GetMemoryMap`, e não os 40 bytes
do `EFI_MEMORY_DESCRIPTOR` da especificação. A estrutura observada é:

```text
+0   Type (u32) + reservado (u32)
+8   PhysicalStart (u64)
+16  VirtualStart (u64)
+24  NumberOfPages (u64)
+32  Attribute (u64)
+40  palavra adicional, sempre zero nos descritores observados
```

**Consequência:** o loader nunca assume o tamanho do descritor. Ele lê os
campos por deslocamento fixo, que é idêntico nas duas variantes, e ignora o
que o firmware acrescentar no final. O tamanho relatado pelo firmware é
sempre respeitado.

### 4.3 `SizeOfInfo` no modo gráfico

`EFI_GRAPHICS_OUTPUT_PROTOCOL_MODE_INFORMATION` contém, entre o ponteiro
`Info` e `FrameBufferBase`, um campo `SizeOfInfo` (36 bytes nesta máquina).
Sem ele, o `FrameBufferBase` é lido do valor errado.

**Consequência:** a estrutura de modo do VorynOS declara `size_of_info`.

## 5. Justificativa das decisões

- **Imagem relocável em vez de endereço fixo**: com endereço fixo, o kernel
  é carregado onde o linker o colocou. Na máquina de teste, esse endereço
  (16 MiB) cai em memória de boot services, e a carga falha de forma
  correta mas inutilizável. Com imagem relocável, o loader escolhe uma
  região de RAM convencional, alinhada a 2 MiB quando possível, acima de
  1 MiB (a área baixa da PC guarda estruturas do firmware).
- **Contrato versionado em vez de passagem de ponteiros soltos**: permite
  evoluir o contrato, detecta carregamento incorreto e é verificável por
  testes de unidade no host.
- **Serial como canal primário**: é o único canal que sobrevive à fronteira
  firmware/kernel e que funciona em automação sem interação humana.
- **Volume FAT16 próprio**: remove `mtools`/`dosfstools` da cadeia de
  construção e do teste, e serve de base para o futuro VFSX.

## 6. Custos e riscos

| Custo | Motivo | Aceito porque |
|-------|--------|---------------|
| Detecção de layout em tempo de execução | Firmwares divergem | Alternativa é quebrar em hardware real |
| Suporte a realocação no loader | Complexidade do loader | Necessário para robustacross machines |
| Tabela FAT16 própria (~350 linhas) | Manutenção | Remove dependência externa e valida o formato |
| Nomes 8.3 no volume de teste | Limite do FAT | O volume de teste não é produto final |

## 7. Alternativas rejeitadas

- **Kernel com endereço fixo e link address baixo**: rejeitado, quebra em
  máquinas cuja RAM não cobre o endereço escolhido pelo linker.
- **Loader em C com GNU-EFI**: rejeitado, adiciona dependência de biblioteca
  externa a um componente que deve ser mínimo e auditável.
- **Depender do console do firmware para diagnóstico**: rejeitado, o console
  do firmware não sobrevive a `ExitBootServices` e não é automatizável.
- **Usar `mtools` para construir a imagem**: rejeitado, dependência externa
  na cadeia de teste.

## 8. Consequências futuras

- O formato do kernel evoluirá para **VEX**, formato nativo do projeto; o
  loader atual já possui a estrutura necessária (segmentos, realocações
  relativas, manifesto de capacidades) para ser reutilizado.
- O contrato de handoff será estendido com ACPI (RSDP), tabela de
  interrupções do firmware e informações de SMP no marco F2.
