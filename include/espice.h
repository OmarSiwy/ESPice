/* espice C API: create a Problem from a SPICE netlist, run or step its
 * analysis queries, and copy results out. Implemented in src/c_api.zig. */
#ifndef ESPICE_H
#define ESPICE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Must match espice_abi_version() and espice_create_options.abi_version. */
#define ESPICE_ABI_VERSION 1u
#define ESPICE_NO_QUERY UINT32_MAX
/* espice_copy_result_name's variable selecting the plot title. */
#define ESPICE_PLOT_TITLE UINT32_MAX

typedef struct espice_problem espice_problem;
typedef uint32_t espice_status;
/* espice_status. INVALID_ARGUMENT also covers malformed analysis text:
 * no analysis card, bad query options, or an unsupported directive edit
 * (espice_error_message names which), and a NULL problem. FAILED is a
 * numerical or I/O failure. INVALID_HANDLE is a problem that
 * espice_destroy already released, or a value espice_create never returned;
 * the call does nothing else. OUT_OF_MEMORY also covers create with 4095
 * problems already live (diagnostic "TooManyProblems"). */
enum {
    ESPICE_OK = 0, ESPICE_INVALID_ARGUMENT = 1, ESPICE_BUFFER_TOO_SMALL = 2,
    ESPICE_OUT_OF_MEMORY = 3, ESPICE_INVALID_QUERY = 4,
    ESPICE_RESULT_UNAVAILABLE = 5, ESPICE_FAILED = 6, ESPICE_ABI_MISMATCH = 7,
    ESPICE_INVALID_HANDLE = 8
};
/* espice_create_options.source_kind: a path, or netlist text named by origin. */
enum { ESPICE_FILE = 0, ESPICE_BYTES = 1 };
/* espice_create_options.dialect */
enum { ESPICE_NGSPICE = 0, ESPICE_HSPICE = 1, ESPICE_SPECTRE = 2 };
/* espice_create_options.backend */
enum { ESPICE_CPU = 0, ESPICE_AUTO = 1, ESPICE_CUDA = 2, ESPICE_HIP = 3 };
/* espice_create_options.output_format */
enum {
    ESPICE_BINARY = 0, ESPICE_ASCII = 1, ESPICE_CSV = 2, ESPICE_TOUCHSTONE = 3,
    ESPICE_PSF = 4, ESPICE_FSDB = 5, ESPICE_SST2 = 6, ESPICE_CITI = 7,
    ESPICE_PRINT = 8
};
/* Query status (espice_query_info.status, espice_advance_event.status) */
enum {
    ESPICE_PENDING = 0, ESPICE_PAUSED = 1, ESPICE_COMPLETE = 2,
    ESPICE_QUERY_FAILED = 3, ESPICE_DEPENDENCY_FAILED = 4, ESPICE_CANCELLED = 5
};
/* Query kind (espice_query_info.kind) */
enum {
    ESPICE_AC = 0, ESPICE_DC = 1, ESPICE_DCMATCH = 2, ESPICE_DISTO = 3,
    ESPICE_ENVELOPE = 4, ESPICE_FOUR = 5, ESPICE_HB = 6, ESPICE_MATEX = 7,
    ESPICE_MC = 8, ESPICE_NOISE = 9, ESPICE_OP = 10, ESPICE_PAC = 11,
    ESPICE_PNOISE = 12, ESPICE_PSS = 13, ESPICE_PXF = 14, ESPICE_PZ = 15,
    ESPICE_QPSS = 16, ESPICE_SENS = 17, ESPICE_SP = 18, ESPICE_STB = 19,
    ESPICE_TEMP = 20, ESPICE_TF = 21, ESPICE_TRAN = 22, ESPICE_TRAN_NOISE = 23,
    ESPICE_HBAC = 24, ESPICE_HBNOISE = 25, ESPICE_HBXF = 26, ESPICE_PHASENOISE = 27,
    ESPICE_LSTB = 28, ESPICE_ACXF = 29, ESPICE_DCXF = 30, ESPICE_DCINC = 31,
    ESPICE_FFT = 32, ESPICE_ACMATCH = 33, ESPICE_DCSENS = 34,
    ESPICE_HBLIN = 35
};
/* espice_progress.phase */
enum {
    ESPICE_PREPARE = 0, ESPICE_NONLINEAR = 1, ESPICE_DC_PHASE = 2,
    ESPICE_FREQUENCY = 3, ESPICE_TRANSIENT = 4, ESPICE_PERIODIC = 5,
    ESPICE_HARMONIC = 6, ESPICE_SWEEP = 7, ESPICE_POSTPROCESS = 8
};
/* espice_scope.kind: every query, one query and its prerequisites, or one
 * connected component of the DAG. */
enum { ESPICE_ALL = 0, ESPICE_QUERY = 1, ESPICE_COMPONENT = 2 };
/* espice_print_options.preview: which call's next frontier to mark. */
enum { ESPICE_PREVIEW_RUN_ALL = 0, ESPICE_PREVIEW_ADVANCE = 1, ESPICE_PREVIEW_READY = 2 };

typedef struct { const char *data; size_t len; } espice_bytes;
typedef struct {
    uint32_t abi_version, struct_size;
    uint32_t source_kind, dialect, backend, explicit_gpu;
    uint32_t output_format, max_parallel;
    espice_bytes source, origin, output_path;
    /* Runtime .hdl toolchain: the Zig compiler, and the share/espice
     * directory of evaluator sources. Empty keeps $ZIG and the paths found
     * beside the executable. Callers built before these fields pass a
     * struct_size that ends at output_path and get the defaults. */
    espice_bytes zig_path, share_path;
    /* Global .param names espice_set_params may change later, copied
     * during create. Callers built before these fields pass a struct_size
     * that ends at share_path and declare none. */
    const espice_bytes *live_params;
    size_t live_param_count;
} espice_create_options;
typedef struct { uint32_t kind, id; } espice_scope;
typedef struct {
    uint32_t phase, reserved;
    uint64_t completed, total; /* total == 0 means unknown. */
} espice_progress;
typedef struct {
    uint32_t id, kind, status, dependency;
    uint32_t component, requested, has_progress, failure_code;
    espice_progress progress;
} espice_query_info;
typedef struct {
    uint32_t requested, advanced, status, target_status;
    uint32_t has_progress, failure_code, output_error, reserved;
    espice_progress progress;
    char output_error_name[96]; /* NUL-terminated, truncated if necessary. */
} espice_advance_event;
typedef struct {
    uint32_t variable_count, is_complex;
    uint64_t point_count, value_count;
} espice_result_info;
/* max_parallel 0 inherits the Problem's limit. */
typedef struct {
    espice_scope scope;
    uint32_t preview, query, ascii, max_parallel;
    const uint32_t *ready_ids;
    size_t ready_count;
} espice_print_options;

/* All calls on one handle must be serialized, including reads and destroy.
 * Parallelism is selected within advance_ready/run_all. Different handles are
 * independent: calls on them may run concurrently from any threads. A handle
 * is a generation-checked token into one process-wide table, never an
 * address; every call checks it under a lock held for O(1) work. A destroyed
 * handle returns INVALID_HANDLE from every call, destroy included, and is
 * never handed out again; a value create never returned is rejected the same
 * way unless its bits happen to equal a live handle's. Input bytes are copied during create/append. The only borrowed
 * pointer is espice_result_view's, valid until destroy. Destroy cancels and
 * joins any paused workers.
 *
 * Buffers must be valid for their capacity; NULL is allowed only at capacity 0.
 * On OK or BUFFER_TOO_SMALL, copy APIs set required; short buffers receive no
 * partial copies. String required counts include the trailing NUL. A sizing call to
 * append_directives does not append anything. Query IDs survive appends.
 */
uint32_t espice_abi_version(void);
/* Initializes defaults, including struct_size and max_parallel=1. */
void espice_default_options(espice_create_options *options);
/* On failure, *out is NULL; diagnostic is NUL-terminated when capacity > 0
 * and may be truncated. A successful create consumes its source immediately. */
espice_status espice_create(const espice_create_options *options,
    espice_problem **out, char *diagnostic, size_t diagnostic_capacity);
/* OK, or INVALID_HANDLE for a handle already destroyed (it changes nothing).
 * NULL is a no-op returning OK. */
espice_status espice_destroy(espice_problem *problem);
espice_status espice_query_count(espice_problem *, uint32_t *out);
espice_status espice_get_query_info(espice_problem *, uint32_t id, espice_query_info *out);
espice_status espice_ready_queries(espice_problem *, espice_scope,
    uint32_t *ids, size_t capacity, size_t *required);
/* OK means the operation returned an event. Inspect its numerical status and
 * output_error separately; a failed query still produces a valid event.
 * output_error is an espice_status; INVALID_QUERY or RESULT_UNAVAILABLE there
 * means the library's query bookkeeping broke (a bug), reported, not aborted. */
espice_status espice_advance(espice_problem *, uint32_t id, espice_advance_event *out);
espice_status espice_advance_ready(espice_problem *, const uint32_t *ids, size_t count,
    uint32_t max_parallel, espice_advance_event *events, size_t capacity, size_t *required);
espice_status espice_run_all(espice_problem *);
espice_status espice_append_directives(espice_problem *, espice_bytes directives,
    uint32_t *ids, size_t capacity, size_t *required);
/* Sets names[i] (a live_params name, case-insensitive but in Spectre) to
 * values[i] for every query appended afterwards; other names keep their last
 * values, and queries appended earlier keep theirs. The deck is not parsed
 * again; a binned MOSFET whose L or W moves takes its new bin. All-or-nothing:
 * INVALID_ARGUMENT for a name not declared live or a non-finite value,
 * FAILED when no bin holds a new geometry or the values would flip a .if or
 * change the topology. */
espice_status espice_set_params(espice_problem *, const espice_bytes *names,
    const double *values, size_t count);
espice_status espice_get_result_info(espice_problem *, uint32_t id, espice_result_info *out);
/* Point-major data; complex values use adjacent real/imaginary doubles. */
espice_status espice_copy_result(espice_problem *, uint32_t id,
    double *values, size_t capacity, size_t *required);
/* Zero-copy espice_copy_result: *data points at the *len result values, valid
 * until espice_destroy and read-only. On failure *data is NULL and *len 0. */
espice_status espice_result_view(espice_problem *, uint32_t id,
    const double **data, size_t *len);
/* variable == ESPICE_PLOT_TITLE selects the plot title; otherwise a column name. */
espice_status espice_copy_result_name(espice_problem *, uint32_t id, uint32_t variable,
    char *buffer, size_t capacity, size_t *required);
/* Pure preview. NULL options selects all/run_all/Unicode and the Problem
 * concurrency limit, as does max_parallel 0. */
espice_status espice_print(espice_problem *, const espice_print_options *,
    char *buffer, size_t capacity, size_t *required);
/* The last failing operation's error name; success leaves it unchanged.
 * An output error from advance also updates this diagnostic. */
espice_status espice_error_message(espice_problem *, char *, size_t, size_t *required);
/* A query's persistent numerical error name, or an empty string. */
espice_status espice_query_error_message(espice_problem *, uint32_t id,
    char *, size_t, size_t *required);

#ifdef __cplusplus
}
#endif
#endif
