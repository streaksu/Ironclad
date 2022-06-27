/*
 * arch-bootstrap.ld: Bootstrap code of the port.
 * Copyright (C) 2021 streaksu
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 */

.section .bss
.align 16
// Stack for the bootstrap.
stack_bottom:
    .space 32768
stack_top:

.section .text
.global entrypoint_main
entrypoint_main:
    // x0: DTB pointer.

    // Clear BSS, the symbols are declared in the linker file.
    ldr x5, =bss_start
    ldr x6, =bss_end
1:
    str	xzr, [x5], #8
    cmp	x5, x6
    b.lo 1b

    // Disable interrupts.
    msr daifset, #0xf

    // Load the vector table.
    ldr x1, =execution_vectors
    msr vbar_el1, x1

    // Load the stack.
    msr spsel, #0
    ldr x1, =stack_top
    mov sp, x1

    // Jump to the kernel.
    b kernel_main

// Vector table, values in x0 match with arch-interrupts.ads
.balign 0x800
execution_vectors:
    // Current EL with SP0 handlers.
    .balign 0x80; mov x0, #0; b common_handler; // Synchronous.
    .balign 0x80; mov x0, #1; b common_handler; // IRQ.
    .balign 0x80; mov x0, #2; b common_handler; // FIQ.
    .balign 0x80; mov x0, #3; b common_handler; // SError.

    // Current EL with SPx handlers.
    .balign 0x80; mov x0, #4; b common_handler; // Synchronous.
    .balign 0x80; mov x0, #5; b common_handler; // IRQ.
    .balign 0x80; mov x0, #6; b common_handler; // FIQ.
    .balign 0x80; mov x0, #7; b common_handler; // SError.

    // Lower EL using AArch64.
    .balign 0x80; mov x0, #8;  b common_handler; // Synchronous.
    .balign 0x80; mov x0, #9;  b common_handler; // IRQ.
    .balign 0x80; mov x0, #10; b common_handler; // FIQ.
    .balign 0x80; mov x0, #11; b common_handler; // SError.

    // Lower EL using AArch32.
    .balign 0x80; mov x0, #12; b common_handler; // Synchronous.
    .balign 0x80; mov x0, #13; b common_handler; // IRQ.
    .balign 0x80; mov x0, #14; b common_handler; // FIQ.
    .balign 0x80; mov x0, #15; b common_handler; // SError.

common_handler:
    // Load the kernel stack back.
    ldr x1, =stack_top
    mov sp, x1

    // Load some values and jump to our handler
    mrs x1, esr_el1  // syndrome
    mrs x2, elr_el1  // ip
    mrs x3, spsr_el1 // state
    mrs x4, far_el1  // fault address
    b exception_handler
