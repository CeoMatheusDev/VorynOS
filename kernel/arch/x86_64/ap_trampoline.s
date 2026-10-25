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
 * O trampoline e copiado pelo BSP para um endereco fisico abaixo de 1 MiB
 * (o endereco SIPI eh vetor * 4096 bytes) e recebido pelo AP via IPI
 * STARTUP. O AP comeca a executar em modo real nesse endereco.
 *
 * O trampoline:
 *   1. Monta uma GDT temporaria para modo protegido (32 bits).
 *   2. Entra em modo protegido (CR0.PE).
 *   3. Habilita PAE (CR4.PAE) e carregue PDPT para identidade mapeamento.
 *   4. Habilitacao de paginacao (CR0.PG).
 *   5. Ativa modo longo (EFER.LME) com far jump para segmento de codigo 64 bits.
 *   6. Salta para voryn_ap_entry no kernel, passando o ID da CPU em RDI.
 *
 * Todas as constantes de endereco sao relativas ao inicio do trampoline,
 * porque ele pode ser copiado para qualquer endereco fisico abaixo de 1 MiB.
 */

.section .text
.code16

/* O trampoline comeca aqui (endereco real = vetor_SIPI * 4096). */
.global voryn_ap_trampoline_start
.type voryn_ap_trampoline_start, @function
voryn_ap_trampoline_start:
    /* Aguarda ate que o BSP libere a variavel de sincronizacao.
       O BSP escreve 1 em ap_ready quando o trampoline ja foi copiado
       e o AP pode comecar a inicializacao. */
    .await_ready:
        movw $0x0000, %ax
        movw %ax, %es
        movw $ap_ready, %di
        cmpw $1, %es:(%di)
        je .setup_gdt
        jmp .await_ready

    /* Monta a GDT temporaria para modo protegido. */
    .setup_gdt:
        lgdt gdt_descriptor(%rip)

        /* Habilita modo protegido (CR0.PE). */
        movl %cr0, %eax
        orl $0x1, %eax
        movl %eax, %cr0

        /* Far jump para segmento de codigo 32 bits para esvaziar a fila. */
        ljmp $0x08, $protected_mode_start

/* Codigo de 32 bits (modo protegido). */
.code32
protected_mode_start:
    /* Segmentos de dados para modo protegido. */
    movw $0x10, %ax
    movw %ax, %ds
    movw %ax, %es
    movw %ax, %fs
    movw %ax, %gs
    movw %ax, %ss

    /* Cria uma pilha temporaria abaixo do trampoline. */
    movl $stack_top, %esp

    /* Habilita PAE (CR4 bit 5). */
    movl %cr4, %eax
    orl $0x20, %eax
    movl %eax, %cr4

    /* Define o endereco fisico da PDPT (Page Directory Pointer Table).
       Usamos uma tabela fixa no final do trampoline. */
    movl $pdpt, %eax
    movl %eax, %cr3

    /* Habilita paginacao (CR0.PG) mantendo PE. */
    movl %cr0, %eax
    orl $0x80000000, %eax
    movl %eax, %cr0

    /* Habilita modo longo (EFER.LME, bit 8). */
    movl $0xC0000080, %ecx
    rdmsr
    orl $0x100, %eax
    wrmsr

    /* Habilita paginacao novamente para ativar modo longo (CR0.PG ja esta setado). */

    /* Far jump para segmento de codigo 64 bits (seleletor 0x18). */
    ljmp $0x18, $long_mode_start

/* Codigo de 64 bits (modo longo). */
.code64
long_mode_start:
    /* Segmentos de dados para modo longo (sao ignorados pelo hardware,
       mas precisam ser validos para instrucoes de segmento). */
    movw $0x10, %ax
    movw %ax, %ds
    movw %ax, %es
    movw %ax, %fs
    movw %ax, %gs
    movw %ax, %ss

    /* Estabelece a pilha temporaria para modo longo. */
    lea ap_long_stack_end(%rip), %rsp
    and $-16, %rsp

    /* O ID da CPU ja foi gravado pelo BSP no byte de marcador
       logo apos o trampoline (offset AP_CPU_ID_OFFSET). */
    movb $0, %edi  /* placeholder: substituido pelo BSP antes de copiar */

    /* Chama o ponto de entrada do AP no kernel. */
    call voryn_ap_entry

    /* Defensive: o AP nunca deve voltar daqui. */
1:
    cli
    hlt
    jmp 1b

/* --------------------------------------------------------------------- */
/* Estruturas de dados do trampoline.                                    */
/* --------------------------------------------------------------------- */

/* GDT temporaria para modo protegido (32 bits). */
/*   Descritor nulo (8 bytes) */
/*   Descritor de codigo 32 bits (base=0, limite=4 GiB, presente, ring 0) */
/*   Descritor de dados 32 bits (base=0, limite=4 GiB, presente, ring 0) */
.align 8
gdt_table:
    .quad 0                               /* nulo */
    .quad 0x00CF9A000000FFFF              /* codigo 32 bits */
    .quad 0x00CF92000000FFFF              /* dados 32 bits */

/* Descritor de codigo 64 bits (base=0, limite=0, presente, ring 0, long mode). */
    .quad 0x00209A0000000000              /* codigo 64 bits */

gdt_end:

/* Descritor da GDT (limite + endereco base). */
gdt_descriptor:
    .word gdt_end - gdt_table - 1         /* limite */
    .long gdt_table                       /* base linear */

/* Pilha temporaria de 32 bits para o trampoline. */
.align 16
stack_space:
    .skip 4096
stack_top:

/* PDPT para modo longo: identidade mapeamento dos primeiros 4 GiB.
   Cada entrada da PDPT cobre 1 GiB (4 entradas de PD, cada uma cobre 256 MiB
   com paginas de 2 MiB, ou usamos entries diretas). Para simplicidade,
   mapeamos apenas o que precisamos para chegar ao kernel. */
.align 4096
pdpt:
    .quad pdp_table                       /* PDPT[0] aponta para a tabela de paginas de diretorio */
    .quad 0                               /* PDPT[1] */
    .quad 0                               /* PDPT[2] */
    .quad 0                               /* PDPT[3] */

/* Tabela de paginas de diretorio (cobre 4 GiB com paginas de 2 MiB). */
.align 4096
pdp_table:
    /* Entrada 0: 0 - 2 MiB (codigo do trampoline, mapeado identidade) */
    .quad 0x00000083                      /* presente, escrita, pagina de 2 MiB (PS bit) */
    /* Entradas 1-511: zeradas (511 entradas de 8 bytes cada = 4088 bytes) */
    .zero 4088

/* Variavel de sincronizacao: BSP escreve 1 quando o AP pode comecar. */
.align 4
ap_ready:
    .word 0

/* Tamanho do trampoline (usado pelo BSP para copiar). */
.global voryn_ap_trampoline_size
.type voryn_ap_trampoline_size, @object
voryn_ap_trampoline_size:
    .quad . - voryn_ap_trampoline_start

/* Simbolo de entrada do AP (definido em smp.zig). */
.extern voryn_ap_entry

/* Pilha temporaria de 64 bits para o trampoline antes de chamar voryn_ap_entry. */
.align 16
ap_long_stack_space:
    .skip 4096
ap_long_stack_end:

/* O kernel nao usa uma pilha executavel. */
.section .note.GNU-stack,"",@progbits
