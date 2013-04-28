#include <asm.h>

# Start the CPU: switch to 32-bit protected mode, jump into C.
# The BIOS loads this code from the first sector of the hard disk into
# memory at physical address 0x7c00 and starts executing in real mode
# with %cs=0 %ip=7c00.

#以下定义段选择子，即段描述符表中的相对偏移地址
#除去最后3byte的结果为索引index
.set PROT_MODE_CSEG,        0x8                     # kernel code segment selector
.set PROT_MODE_DSEG,        0x10                    # kernel data segment selector
.set CR0_PE_ON,             0x1                     # protected mode enable flag
.set SMAP,                  0x534d4150

# start address should be 0:7c00, in real mode, the beginning address of the running bootloader
.globl start
start:
.code16                                             # 十六位汇编模式 Assemble for 16-bit mode
    cli                                             # 首先关闭中断Disable interrupts
    cld
# 清除方向标志，在字符串的比较，赋值，读取等一系
#列和rep连用的操作中，di或si是可以自动增减的而不需要人来加减它的值，cld即告诉程序si，di向前移动（
#值增加），std指令为设置方向，告诉程序si，di向后移动    String operations increment

    # Set up the important data segment registers (DS, ES, SS).
    xorw %ax, %ax                                   # 把所有ax,es,ss都置为0  Segment number zero
    movw %ax, %ds                                   # -> Data Segment
    movw %ax, %es                                   # -> Extra Segment
    movw %ax, %ss                                   # -> Stack Segment

    # Enable A20:
    #  For backwards compatibility with the earliest PCs, physical
    #  address line 20 is tied low, so that addresses higher than
    #  1MB wrap around to zero by default. This code undoes this.
    #  打开A20模式，A20模式具体看指导说明，主要就是在计算机发展过程有，有一个20号地址线的开关问题，
    #  影响到能使用的地址范围，开启后才能完全使用内存
seta20.1:
    #inb 表示从一个端口读入一个字节到一个寄存器
    #outb 表示输出一个字节到一个端口
    inb $0x64, %al                                  # 判断0x64寄存器，该寄存器决定输入缓冲是否为空
                                                    # Wait for not busy(8042 input buffer empty).
    #testb 表示将一个字节与一个寄存器内容进行and操作
    testb $0x2, %al
    #jnz 表示如果zf寄存器(即上次testb的结果是否为0)为0就跳转到指定地址
    jnz seta20.1                                    # 输入缓冲不为空，跳转到seta20.1，继续等待

    movb $0xd1, %al                                 # 向端口0x64输出0xd1，表示要向8042控制器写入数据
                                                    #0xd1 -> port 0x64
    outb %al, $0x64                                 # 0xd1 means: write data to 8042's P2 port

seta20.2:
    inb $0x64, %al                                  # 再次等待输入缓冲为空,同seta20.1
                                                    # Wait for not busy(8042 input buffer empty).
    testb $0x2, %al
    jnz seta20.2

    movb $0xdf, %al                                 # 向0x60端口输出0xdf,表示把A20位置为1
                                                    # 0xdf -> port 0x60
    outb %al, $0x60                                 # 0xdf = 11011111, means set P2's A20 bit(the 1 bit) to 1

probe_memory:
    movl $0, 0x8000
    xorl %ebx, %ebx
    movw $0x8004, %di
start_probe:
    movl $0xE820, %eax
    movl $20, %ecx
    movl $SMAP, %edx
    int $0x15
    jnc cont
    movw $12345, 0x8000
    jmp finish_probe
cont:
    addw $20, %di
    incl 0x8000
    cmpl $0, %ebx
    jnz start_probe
finish_probe:

    # Switch from real to protected mode, using a bootstrap GDT
    # and segment translation that makes virtual addresses
    # identical to physical addresses, so that the
    # effective memory map does not change during the switch.
    lgdt gdtdesc                                #加载段描述符,段描述符具体定义看文档,涉及到分段存储
                                                #的概念，在存储器管理一章有定义

    # 控制寄存器（CR0～CR3）用于控制和确定处理器的操作模式以及当前执行任务的特性，CR0中
    # 含有控制处理器操作模式和状态的系统控制标志；CR1保留不用；CR2含有导致页错误的线性地址；CR3中含有页
    # 目录表物理内存基地址，因此该寄存器也被称为页目录基地址寄存器PDBR（Page-Directory Base address
    # Register）。
    # 具体百度百科介绍很详细
    movl %cr0, %eax

    #CR0中保护控制位
    #（1）PE：CR0的位0是启用保护（Protection Enable）标志。当设置该位时即开启了保护模式；当复位时即进
    #入实地址模式。这个标志仅开启段级保护，而并没有启用分页机制。若要启用分页机制，那么PE和PG标志都要
    #置位。
    orl $CR0_PE_ON, %eax                            #这一小段的主要目的是读出cr0的状态，然后将PE位置
    #为1表示进入保护模式

    movl %eax, %cr0                                 #将PE位为1的结果写入cr0寄存器

    # Jump to next instruction, but in 32-bit code segment.
    # Switches processor into 32-bit mode.
    ljmp $PROT_MODE_CSEG, $protcseg                 #分段模式下的跳转？？？

.code32                                             # Assemble for 32-bit mode
protcseg:
    # Set up the protected-mode data segment registers
    # 设置保护模式下的寄存器
    movw $PROT_MODE_DSEG, %ax                       # Our data segment selector
    movw %ax, %ds                                   # -> DS: Data Segment
    movw %ax, %es                                   # -> ES: Extra Segment
    movw %ax, %fs                                   # -> FS
    movw %ax, %gs                                   # -> GS
    movw %ax, %ss                                   # -> SS: Stack Segment

    # Set up the stack pointer and call into C. The stack region is from 0--start(0x7c00)
    # 为了实现call调用，需要堆栈的支持，所以需要设置ebp和esp寄存器
    # call和ret的操作可以参考http://blog.csdn.net/zrhhust/article/details/1904849
    movl $0x0, %ebp                                 # 设置堆栈栈底为0
    movl $start, %esp                               # 设置栈顶为0x7c00
    call bootmain                                   # 跳转到bootmain.c中的bootmain函数中

    # If bootmain returns (it shouldn't), loop.
spin:
    jmp spin

.data
# Bootstrap GDT
.p2align 2                                          # force 4 byte alignment
gdt:
    SEG_NULLASM                                     # null seg
    SEG_ASM(STA_X|STA_R, 0x0, 0xffffffff)           # code seg for bootloader and kernel
    SEG_ASM(STA_W, 0x0, 0xffffffff)                 # data seg for bootloader and kernel

gdtdesc:
    .word 0x17                                      # sizeof(gdt) - 1
    .long gdt                                       # address gdt
