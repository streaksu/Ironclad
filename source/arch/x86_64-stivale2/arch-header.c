# header.S: Stivale2 header.
# Copyright (C) 2021 streaksu
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

.section ".stivale2hdr", "aw", @progbits
.globl stivale2hdr
stivale2hdr:
    .quad 0                              # Alternative entrypoint, 0 is none.
    .quad stack_top                      # Stack to be loaded for the kernel.
    .quad (1 << 1) | (1 << 2) | (1 << 4) # Flags to request offset mem + PMRs.
    .quad framebuffer_tag                # Start of tags.

.section .data

framebuffer_tag:
    .quad 0x3ecc1bc43d0f7971 # Identifier of the tag.
    .quad terminal_tag       # Next in line.
    .word 0                  # Prefered width, 0 for default.
    .word 0                  # Ditto.
    .word 0                  # Ditto.

terminal_tag:
    .quad 0xa85d499b1823be72 # Identifier of the tag.
    .quad smp_tag            # Next in line.
    .quad 0                  # Flags.

smp_tag:
    .quad 0x1ab015085f3273df # Identifier of the tag.
    .quad 0                  # Next one in line, 0 is none.
    .quad 0                  # Flags, we dont need anything in particular.

.section .bss
.align 16

stack:
    .space 32768
stack_top:
