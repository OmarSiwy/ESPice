#ifndef ESPICE_H
#define ESPICE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define ESPICE_ABI_VERSION 1u
#define ESPICE_NO_QUERY UINT32_MAX

typedef struct espice_problem espice_problem;
typedef uint32_t espice_status;
enum {
    ESPICE_OK = 0, ESPICE_INVALID_ARGUMENT = 1, ESPICE_BUFFER_TOO_SMALL = 2,
    ESPICE_OUT_OF_MEMORY = 3, ESPICE_INVALID_QUERY = 4,
    ESPICE_RESULT_UNAVAILABLE = 5, ESPICE_FAILED = 6, ESPICE_ABI_MISMATCH = 7
};
enum { ESPICE_FILE = 0, ESPICE_BYTES = 1 };
enum { ESPICE_NGSPICE = 0, ESPICE_HSPICE = 1, ESPICE_SPECTRE = 2 };
enum { ESPICE_CPU = 0, ESPICE_AUTO = 1, ESPICE_CUDA = 2, ESPICE_HIP = 3 };
enum {
    ESPICE_BINARY = 0, ESPICE_ASCII = 1, ESPICE_CSV = 2, ESPICE_TOUCHSTONE = 3,
    ESPICE_PSF = 4, ESPICE_FSDB = 5, ESPICE_SST2 = 6, ESPICE_CITI = 7,
    ESPICE_PRINT = 8
};
enum {
    ESPICE_PENDING = 0, ESPICE_PAUSED = 1, ESPICE_COMPLETE = 2,
    ESPICE_QUERY_FAILED = 3, ESPICE_DEPENDENCY_FAILED = 4, ESPICE_CANCELLED = 5
};
enum {
    ESPICE_AC = 0, ESPICE_DC = 1, ESPICE_DCMATCH = 2, ESPICE_DISTO = 3,
    ESPICE_ENVELOPE = 4, ESPICE_FOUR = 5, ESPICE_HB = 6, ESPICE_MATEX = 7,
    ESPICE_MC = 8, ESPICE_NOISE = 9, ESPICE_OP = 10, ESPICE_PAC = 11,
    ESPICE_PNOISE = 12, ESPICE_PSS = 13, ESPICE_PXF = 14, ESPICE_PZ = 15,
    ESPICE_QPSS = 16, ESPICE_SENS = 17, ESPICE_SP = 18, ESPICE_STB = 19,
    ESPICE_TEMP = 20, ESPICE_TF = 21, ESPICE_TRAN = 22, ESPICE_TRAN_NOISE = 23
};
enum {
    ESPICE_PREPARE = 0, ESPICE_NONLINEAR = 1, ESPICE_DC_PHASE = 2,
    ESPICE_FREQUENCY = 3, ESPICE_TRANSIENT = 4, ESPICE_PERIODIC = 5,
    ESPICE_HARMONIC = 6, ESPICE_SWEEP = 7, ESPICE_POSTPROCESS = 8
};
enum { ESPICE_ALL = 0, ESPICE_QUERY = 1, ESPICE_COMPONENT = 2 };
enum { ESPICE_PREVIEW_RUN_ALL = 0, ESPICE_PREVIEW_ADVANCE = 1, ESPICE_PREVIEW_READY = 2 };

typedef struct { const char *data; size_t len; } espice_bytes;
typedef struct {
    uint32_t abi_version, struct_size;
    uint32_t source_kind, dialect, backend, explicit_gpu;
    uint32_t output_format, max_parallel;
    espice_bytes source, origin, output_path;
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
typedef struct {
    espice_scope scope;
    uint32_t preview, query, ascii, max_parallel;
    const uint32_t *ready_ids;
    size_t ready_count;
} espice_print_options;

/* All calls on one handle must be serialized, including reads and destroy.
 * Parallelism is selected within advance_ready/run_all. Different handles are
 * independent. Input bytes are copied during create/append. No borrowed result
 * pointers escape. Destroy cancels and joins any paused workers.
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
void espice_destroy(espice_problem *problem);
espice_status espice_query_count(espice_problem *, uint32_t *out);
espice_status espice_get_query_info(espice_problem *, uint32_t id, espice_query_info *out);
espice_status espice_ready_queries(espice_problem *, espice_scope,
    uint32_t *ids, size_t capacity, size_t *required);
/* OK means the operation returned an event. Inspect its numerical status and
 * output_error separately; a failed query still produces a valid event. */
espice_status espice_advance(espice_problem *, uint32_t id, espice_advance_event *out);
espice_status espice_advance_ready(espice_problem *, const uint32_t *ids, size_t count,
    uint32_t max_parallel, espice_advance_event *events, size_t capacity, size_t *required);
espice_status espice_run_all(espice_problem *);
espice_status espice_append_directives(espice_problem *, espice_bytes directives,
    uint32_t *ids, size_t capacity, size_t *required);
espice_status espice_get_result_info(espice_problem *, uint32_t id, espice_result_info *out);
/* Point-major data; complex values use adjacent real/imaginary doubles. */
espice_status espice_copy_result(espice_problem *, uint32_t id,
    double *values, size_t capacity, size_t *required);
/* variable == ESPICE_NO_QUERY selects the plot title; otherwise a column name. */
espice_status espice_copy_result_name(espice_problem *, uint32_t id, uint32_t variable,
    char *buffer, size_t capacity, size_t *required);
/* Pure preview. NULL options selects all/run_all/Unicode and the Problem concurrency limit. */
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
