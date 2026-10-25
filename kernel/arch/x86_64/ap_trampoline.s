/**************************************************************************/
/*  ap_trampoline.s                                                       */
/**************************************************************************/
/*                         This file is part of:                          */
/*                               VorynOS                                  */
/*              https://github.com/CeoMatheusDev/VorynOS                  */
/**************************************************************************/
/* Copyright (C) 2026 VorynOS contributors.                               */
/*                                                                        */
/* SPDX-License-Identifier: GPL-3.0-only                                  */
/**************************************************************************/

/*
 * Trampoline de inicializacao de AP (Application Processor).
 *
 * O BSP copia este bloco para uma pagina fisica abaixo de 1 MiB e envia
 * uma IPI STARTUP (SIPI) para cada AP. O AP comeca a executar em modo real
 * no endereco `vetor * 4096`, que e o inicio deste bloco.
 *
 * O bloco e independente da posicao: todos os enderecos internos sao
 * diferencas entre rotulos do proprio bloco, e os enderecos absolutos que
 * o hardware precisa (base da GDT, alvo do salto distante, CR3 e pilha)
 * sao preenchidos pelo BSP na copia antes da SIPI.
 *
 * Sequencia:
 *   1. modo real: DS = ES = SS = CS, calcula a base de execucao;
 *   2. espera o BSP terminar de preencher a copia (palavra `ready`);
 *   3. carrega a GDT temporaria e liga o modo protegido (CR0.PE);
 *   4. modo protegido (32 bits): carrega o CR3 do kernel, liga PAE e
 *      EFER.LME, liga a paginacao e salta para o modo longo;
 *   5. modo longo (64 bits): carrega a pilha do AP, habilita FPU/SSE,
 *      passa o numero logico da CPU em RDI e chama `voryn_ap_entry`.
 *
 * O AP nunca retorna: o laco final e uma salvaguarda.
 *
 * ABI no modo longo:
 *   RDI - numero logico da CPU (inteiro de 32 bits, zero estendido).
 *   RSP - topo da pilha de kernel do AP, alinhado a 16 bytes.
 *
 * Registradores: o codigo de modo real e de modo protegido usa EAX, EBX,
 * ECX, ESI e EDX como temporarios; nenhum valor do BSP e preservado,
 * porque o AP comeca com o estado do processador que a SIPI define.
 */

.section .text

/* --------------------------------------------------------------------- */
/* Modo real (16 bits).                                                   */
/* --------------------------------------------------------------------- */

.code16
.global voryn_ap_trampoline_start
.type voryn_ap_trampoline_start, @function
voryn_ap_trampoline_start:
.Lstart:
.Lbase:
    cli

    /* A SIPI define CS = vetor << 8 e IP = 0. Os demais segmentos sao
       carregados com o mesmo valor, de modo que todo acesso a dados use
       um deslocamento relativo ao inicio do bloco. */
    movw %cs, %ax
    movw %ax, %ds
    movw %ax, %es
    movw %ax, %ss
    movw $(stack_top - .Lstart), %sp

    /* ESI = base linear da copia (CS << 4). O valor sobrevive a troca de
       modo e e usado pelo codigo de 32 bits para acessar os campos. */
    xorl %esi, %esi
    movw %cs, %si
    shll $4, %esi

    /* Espera o BSP preencher a copia. A escrita de `ready` e a ultima,
       depois de todos os outros campos; o x86 mantem a ordem das
       escritas, portanto ver 1 garante que o resto esta pronto. */
.Lwait_ready:
    movw $(ready - .Lstart), %bx
    cmpw $1, (%bx)
    je .Lgdt
    pause
    jmp .Lwait_ready

.Lgdt:
    /* Carrega a GDT temporaria. O prefixo 0x66 seleciona o formato de
       32 bits do operando (limite de 16 bits e base de 32 bits). */
    movw $(gdt_descriptor - .Lstart), %bx
    .byte 0x66
    lgdt (%bx)

    /* Liga o modo protegido. */
    movl %cr0, %eax
    orl $1, %eax
    movl %eax, %cr0

    /* Salto distante para o codigo de 32 bits, pelo ponteiro preenchido
       pelo BSP. O prefixo 0x66 seleciona o ponteiro de 4 bytes de offset
       e 2 bytes de seletor. */
    movw $(far32 - .Lstart), %bx
    .byte 0x66
    ljmp *(%bx)

/* --------------------------------------------------------------------- */
/* Modo protegido (32 bits).                                              */
/* --------------------------------------------------------------------- */

.code32
.global voryn_ap_trampoline_protected_mode
voryn_ap_trampoline_protected_mode:
protected_mode_start:
    movw $0x10, %ax
    movw %ax, %ds
    movw %ax, %es
    movw %ax, %fs
    movw %ax, %gs
    movw %ax, %ss

    /* EBX = base linear da copia. */
    movl %esi, %ebx

    /* Habilita PAE (CR4.PAE), requisito do modo longo. */
    movl %cr4, %eax
    orl $0x20, %eax
    movl %eax, %cr4

    /* Carrega as tabelas de paginas do kernel, preenchidas pelo BSP. */
    movl (cr3_value - .Lstart)(%ebx), %eax
    movl %eax, %cr3

    /* Liga EFER.LME. */
    movl $0xC0000080, %ecx
    rdmsr
    orl $0x100, %eax
    wrmsr

    /* Liga a paginacao. Com PAE e LME ja ligados, o processador entra no
       modo longo; o salto distante abaixo carrega um seletor de 64 bits. */
    movl %cr0, %eax
    orl $0x80000000, %eax
    movl %eax, %cr0

    /* Preenche o ponteiro do salto para o modo longo com o endereco
       linear de `long_mode_start` e salta. */
    leal (long_mode_start - .Lstart)(%ebx), %eax
    movl %eax, (far64 - .Lstart)(%ebx)
    movw $0x18, (far64 - .Lstart + 4)(%ebx)
    ljmp *(far64 - .Lstart)(%ebx)

/* --------------------------------------------------------------------- */
/* Modo longo (64 bits).                                                  */
/* --------------------------------------------------------------------- */

.code64
long_mode_start:
    movw $0x10, %ax
    movw %ax, %ds
    movw %ax, %es
    movw %ax, %fs
    movw %ax, %gs
    movw %ax, %ss

    /* Habilita a FPU e as extensoes SSE para o codigo do kernel. O estado
       de reset do AP nao garante CR0.EM = 0 nem CR4.OSFXSR. */
    movq %cr0, %rax
    andq $~((1 << 2) | (1 << 3)), %rax
    orq $(1 << 1), %rax
    movq %rax, %cr0
    movq %cr4, %rax
    orq $((1 << 9) | (1 << 10)), %rax
    movq %rax, %cr4

    /* A base do bloco e obtida por RIP; os campos abaixo sao acessados
       por deslocamento constante a partir dela. */
    leaq .Lbase(%rip), %rbx

    /* Pilha de kernel do AP, preenchida pelo BSP. */
    movq (stack_top_value - .Lbase)(%rbx), %rsp
    andq $-16, %rsp

    /* Numero logico da CPU, preenchido pelo BSP. */
    movl (cpu_id_value - .Lbase)(%rbx), %edi

    call *(entry_value - .Lbase)(%rbx)

    /* O ponto de entrada nao retorna; o laco e uma salvaguarda. */
.Lhalt:
    cli
    hlt
    jmp .Lhalt

/* --------------------------------------------------------------------- */
/* Dados do trampoline.                                                   */
/* --------------------------------------------------------------------- */

/* GDT temporaria. Os descritores de codigo e dados de 32 bits usam base
   zero e limite de 4 GiB; o de 64 bits usa o bit L e limite zero. */
.align 8
.global voryn_ap_trampoline_gdt_table
voryn_ap_trampoline_gdt_table:
gdt_table:
    .quad 0x0000000000000000
    .quad 0x00CF9A000000FFFF
    .quad 0x00CF92000000FFFF
    .quad 0x00209A0000000000
gdt_end:

/* Pseudo-descritor da GDT: limite de 16 bits e base de 32 bits. A base e
   preenchida pelo BSP. */
.align 8
.global voryn_ap_trampoline_gdt_descriptor
voryn_ap_trampoline_gdt_descriptor:
gdt_descriptor:
    .word gdt_end - gdt_table - 1
    .long 0

/* Ponteiro do salto distante para o codigo de 32 bits. O BSP preenche o
   offset; o seletor e fixo. */
.align 4
.global voryn_ap_trampoline_far32
voryn_ap_trampoline_far32:
far32:
    .long 0
    .word 0x08

/* Ponteiro do salto distante para o codigo de 64 bits. O offset e
   preenchido pelo proprio trampoline em modo protegido. */
.align 4
far64:
    .long 0
    .word 0x18

/* CR3 do kernel (endereco fisico da PML4), preenchido pelo BSP. */
.align 4
.global voryn_ap_trampoline_cr3
voryn_ap_trampoline_cr3:
cr3_value:
    .long 0

/* Topo da pilha de kernel do AP, preenchido pelo BSP. */
.align 8
.global voryn_ap_trampoline_stack
voryn_ap_trampoline_stack:
stack_top_value:
    .quad 0

/* Numero logico da CPU, preenchido pelo BSP. */
.align 4
.global voryn_ap_trampoline_cpu_id
voryn_ap_trampoline_cpu_id:
cpu_id_value:
    .long 0

/* Endereco do ponto de entrada do AP no kernel, preenchido pelo BSP. */
.align 8
.global voryn_ap_trampoline_entry
voryn_ap_trampoline_entry:
entry_value:
    .quad 0

/* Palavra de sincronizacao: o BSP escreve 1 por ultimo. */
.align 4
.global voryn_ap_trampoline_ready
voryn_ap_trampoline_ready:
ready:
    .word 0

/* Pilha minima usada apenas ate a carga da pilha do kernel. */
.align 16
stack_space:
    .skip 64
stack_top:

/* Tamanho do bloco, sem contar a propria palavra de tamanho. */
.global voryn_ap_trampoline_end
.type voryn_ap_trampoline_end, @object
voryn_ap_trampoline_end:

.global voryn_ap_trampoline_size
.type voryn_ap_trampoline_size, @object
voryn_ap_trampoline_size:
    .quad voryn_ap_trampoline_end - .Lstart

/* O kernel nao usa uma pilha executavel. */
.section .note.GNU-stack,"",@progbits
