/* core/wasm: the host interface of a WebAssembly module, shared by libc.c and eider_rt.c.
   Contract: core/wasm/README.md. Not a header for generated code. */
#ifndef EI_WASM_HOST_H
#define EI_WASM_HOST_H
#include <stddef.h>
#include <stdint.h>

#if defined(__wasm__)
#define EI_WASM_IMPORT(name) __attribute__((import_module("env"), import_name(name)))
#define EI_WASM_EXPORT(name) __attribute__((export_name(name)))
/* Linear memory size in 64 KiB pages, and growth by n pages (SIZE_MAX on failure). */
#define ei_wasm_pages() __builtin_wasm_memory_size(0)
#define ei_wasm_grow(n) __builtin_wasm_memory_grow(0, (n))
#define ei_wasm_trap() __builtin_trap()
#elif defined(EI_WASM_SYNTAX_CHECK)
/* Lets a host C compiler check this code (-fsyntax-only); it does not link. */
#define EI_WASM_IMPORT(name)
#define EI_WASM_EXPORT(name)
size_t ei_wasm_pages(void);
size_t ei_wasm_grow(size_t n);
_Noreturn void ei_wasm_trap(void);
#else
#error "core/wasm: build with clang --target=wasm32 (or check the C with -DEI_WASM_SYNTAX_CHECK)"
#endif

#if defined(EI_WASM_CORE)
/* A module built with `eiderc build --wasm-core` (README.md "Core modules") reaches the host
   only through the C core's ABI (core/ABI.md), imported from "env" under the core's names;
   these are the ones the runtime itself calls (Eider code imports the rest). */
EI_WASM_IMPORT("ec_in_clear") void ei_host_in_clear(void);
EI_WASM_IMPORT("ec_in_push") void ei_host_in_push(int32_t b);
EI_WASM_IMPORT("ec_write_fd") int64_t ei_host_write_fd(int32_t fd);
EI_WASM_IMPORT("ec_exit") void ei_host_exit(int32_t code);
EI_WASM_IMPORT("ec_time_mono_ns") int64_t ei_host_mono_ns(void);
#else
/* Host imports (module "env"; the generated JS loader supplies both). */
/* Write bytes p[0..n) of linear memory to the host's output (stdout and stderr alike). */
EI_WASM_IMPORT("eider_write") void eider_write(const char *p, uint32_t n);
/* The host's clock in milliseconds (the loader: Date.now(), as a BigInt). */
EI_WASM_IMPORT("eider_now_ms") int64_t eider_now_ms(void);
#endif

/* Write p[0..n) to the host's stdout (fd 1) or stderr (fd 2): eider_write (which has one
   output for both), or ec_write_fd in a core module. In libc.c. */
void ei_host_write(int fd, const char *p, uint32_t n);
/* Leave the module: `unreachable`, or in a core module ec_exit(code). In libc.c. */
_Noreturn void ei_host_leave(int code);

#endif
