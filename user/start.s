/*
 * Copyright (C) 2026 VorynOS contributors.
 * Copyright (C) 2020 - 2026 Matheus.A.Santos contributors.
 * Copyright (C) 2026 VorynOS - All Rights Reserved.
 *
 * SPDX-License-Identifier: GPL-3.0-only
 */

/*
 * Entrada das aplicações freestanding do modo usuário.
 *
 * O escalonador entrega a base da janela em RBX e o papel do processo em RCX.
 * A entrada converte os dois valores para os registradores da convenção
 * System V e salta para o corpo da aplicação. Nenhuma variável global é
 * necessária: o segmento de dados continua terminando antes da pilha.
 *
 * A pilha chega com RSP + 8 alinhado a 16 bytes, como se a tarefa tivesse
 * sido chamada. O salto preserva esse alinhamento; a função Zig é noreturn e
 * não espera um endereço de retorno na pilha.
 */
    .section .text.start,"ax",@progbits
    .global _start
    .type _start, @function
_start:
    movq %rbx, %rdi
    movq %rcx, %rsi
    jmp voryn_user_main
    .size _start, . - _start

    .section .note.GNU-stack,"",@progbits