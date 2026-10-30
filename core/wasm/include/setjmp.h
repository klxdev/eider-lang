/* core/wasm libc: WebAssembly (without exception handling) has no setjmp. setjmp always
   returns 0 and longjmp executes `unreachable`, so a trap under a test hook ends the module
   (core/wasm/README.md). */
#ifndef EI_WASM_SETJMP_H
#define EI_WASM_SETJMP_H
typedef int jmp_buf[1];
#define setjmp(b) ((void)(b), 0)
_Noreturn void longjmp(jmp_buf b, int v);
#endif
