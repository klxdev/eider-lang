/* core/wasm: types only. eider_rt.h embeds these in ei_mutex, ei_thread and ei_chan; the
   WebAssembly runtime (core/wasm/eider_rt.c) is single-threaded and never touches them.
   There are no pthread functions: programs that use threads are rejected (E0806). */
#ifndef EI_WASM_PTHREAD_H
#define EI_WASM_PTHREAD_H
typedef struct { int unused; } pthread_t;
typedef struct { int unused; } pthread_mutex_t;
typedef struct { int unused; } pthread_cond_t;
#endif
