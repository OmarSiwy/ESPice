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
/* espice_query_info.dependency of a query with no prerequisite. */
#define ESPICE_NO_QUERY UINT32_MAX
/* espice_copy_result_name's variable selecting the plot title. */
#define ESPICE_PLOT_TITLE UINT32_MAX

typedef struct espice_problem espice_problem;
typedef uint32_t espice_status;
/* espice_status. INVALID_ARGUMENT also covers malformed analysis text:
 * no analysis card, bad query options, or an unsupported directive edit
 * (espice_error_message names which), a NULL problem, a max_parallel of 0
 * or above 65535 where one is required, a query advanced before it is ready
 * or listed twice, and a set_params name that is not live. INVALID_QUERY is
 * an id outside 0..query_count. RESULT_UNAVAILABLE is a query that has not
 * completed. FAILED is a numerical, I/O or output failure.
 * INVALID_HANDLE is a problem that espice_destroy already released, or a
 * value espice_create never returned; the call does nothing else.
 * OUT_OF_MEMORY also covers create with 4095 problems already live
 * (diagnostic "TooManyProblems"). */
enum {
    ESPICE_OK = 0, ESPICE_INVALID_ARGUMENT = 1, ESPICE_BUFFER_TOO_SMALL = 2,
    ESPICE_OUT_OF_MEMORY = 3, ESPICE_INVALID_QUERY = 4,
    ESPICE_RESULT_UNAVAILABLE = 5, ESPICE_FAILED = 6, ESPICE_ABI_MISMATCH = 7,
    ESPICE_INVALID_HANDLE = 8
};
/* espice_create_options.source_kind: source holds a path (origin unused),
 * or netlist text named by origin. */
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
/* Query status (espice_query_info.status, espice_advance_event.status).
 * ESPICE_CANCELLED is reserved: no C call cancels a query (destroy cancels
 * paused workers, after which nothing reads their status), so it is never
 * reported today. */
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
    /* Receives .hdl display-task text ($strobe, $display, ...) instead of
     * stdout: each accepted point's lines, from the thread running its
     * query, so with max_parallel > 1 calls can overlap. text is not
     * NUL-terminated. It must not call back into the same handle. NULL
     * prints on stdout. Callers built before these fields pass a
     * struct_size that ends at live_param_count. */
    void (*display)(const char *text, size_t len, void *user);
    void *display_user;
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
/* max_parallel 0 inherits the Problem's limit. preview ADVANCE previews
 * espice_advance(query); READY previews espice_advance_ready(ready_ids). */
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
 * way unless its bits happen to equal a live handle's. No call keeps a
 * pointer the caller passed once it returns, except the display callback and
 * display_user. The only pointer the library hands out is
 * espice_result_view's, valid until destroy. Destroy cancels and joins any
 * paused workers.
 *
 * Buffers must be valid for their capacity; NULL is allowed only at capacity 0.
 * On OK or BUFFER_TOO_SMALL, copy APIs set required; short buffers receive no
 * partial copies. String required counts include the trailing NUL. A sizing call to
 * append_directives does not append anything. Query IDs survive appends.
 */
uint32_t espice_abi_version(void);
/* Zeroes *options and sets abi_version, struct_size and max_parallel=1.
 * NULL is a no-op. */
void espice_default_options(espice_create_options *options);
/* Reads and prepares the netlist and queues its analyses; nothing runs yet.
 * On failure, *out is NULL; diagnostic holds the error name, NUL-terminated
 * when capacity > 0 and truncated if necessary. ABI_MISMATCH for an
 * abi_version other than ESPICE_ABI_VERSION or a struct_size that ends
 * before zig_path. INVALID_ARGUMENT for an empty source, an unknown enum
 * value, explicit_gpu above 1, or max_parallel 0 or above 65535. A
 * successful create consumes its source immediately. */
espice_status espice_create(const espice_create_options *options,
    espice_problem **out, char *diagnostic, size_t diagnostic_capacity);
/* OK, or INVALID_HANDLE for a handle already destroyed (it changes nothing).
 * NULL is a no-op returning OK. */
espice_status espice_destroy(espice_problem *problem);
espice_status espice_query_count(espice_problem *, uint32_t *out);
/* failure_code is the espice_status of the query's failure, or OK. */
espice_status espice_get_query_info(espice_problem *, uint32_t id, espice_query_info *out);
espice_status espice_ready_queries(espice_problem *, espice_scope,
    uint32_t *ids, size_t capacity, size_t *required);
/* Runs one quantum of id, or of its first unfinished prerequisite, then
 * writes whatever completed to the output. In binary or ASCII raw or print
 * format the plots reach the file in one replacement when the last query
 * ends, as with espice_run_all; destroying the problem before then leaves
 * the file as it was. A terminal id returns its status
 * without running anything. The first call also runs the deck's .model OPT
 * optimization and MOSRA stress run, if any.
 * OK means the operation returned an event. Inspect its numerical status and
 * output_error separately; a failed query still produces a valid event.
 * output_error is an espice_status; INVALID_QUERY or RESULT_UNAVAILABLE there
 * means the library's query bookkeeping broke (a bug), reported, not aborted. */
espice_status espice_advance(espice_problem *, uint32_t id, espice_advance_event *out);
/* Advances each of ids by one quantum, at most max_parallel at a time, one
 * event per id in ids order, then writes results as espice_advance does.
 * Every id must be ready and distinct, else INVALID_ARGUMENT and nothing
 * runs. max_parallel 0 is INVALID_ARGUMENT here (unlike
 * espice_print_options). *required is count; events needs that many. */
espice_status espice_advance_ready(espice_problem *, const uint32_t *ids, size_t count,
    uint32_t max_parallel, espice_advance_event *events, size_t capacity, size_t *required);
/* Runs every query to the end and writes its result. Returns the first
 * query failure's status, else FAILED when writing the output failed
 * (espice_error_message names the error). After a failure the .save and
 * .stim files are not written. A second call runs nothing twice. */
espice_status espice_run_all(espice_problem *);
/* Appends the analysis cards in directives and writes each one's id to ids.
 * A card identical to an existing query gets the old id. All-or-nothing: on
 * any failure, the DAG and ids are unchanged. */
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
 * until espice_destroy and read-only. On any failure, an invalid handle
 * included, *data is NULL and *len 0. */
espice_status espice_result_view(espice_problem *, uint32_t id,
    const double **data, size_t *len);
/* variable == ESPICE_PLOT_TITLE selects the plot title; otherwise the name
 * of column variable, INVALID_ARGUMENT past variable_count. */
espice_status espice_copy_result_name(espice_problem *, uint32_t id, uint32_t variable,
    char *buffer, size_t capacity, size_t *required);
/* Pure preview. NULL options selects all/run_all/Unicode and the Problem
 * concurrency limit, as does max_parallel 0. */
espice_status espice_print(espice_problem *, const espice_print_options *,
    char *buffer, size_t capacity, size_t *required);
/* The last failing operation's error name, or an empty string; success
 * leaves it unchanged, and a failure of this call itself does not replace
 * it. An output error from advance also updates this diagnostic. A call
 * rejected for its handle records nothing. */
espice_status espice_error_message(espice_problem *, char *, size_t, size_t *required);
/* A query's persistent numerical error name, or an empty string. */
espice_status espice_query_error_message(espice_problem *, uint32_t id,
    char *, size_t, size_t *required);

/* Points: one deck as a template, run at many rows of its live_params
 * values. A point is a .step-like sweep point appended to the problem's
 * DAG, so espice_run_all (or espice_advance_ready) runs it, and its query
 * ids work with every call above. A point's measures and reason depend
 * only on the deck and its values, never on count, order, max_parallel or
 * the other points.
 *
 * Energy per transition is a .meas over a supply current, e.g.
 *   .meas tran e_rise integ par('-v(vdd)*i(vdd)') from=1n to=2n
 * and leakage the operating point's supply current,
 *   .meas op leak find i(vdd)
 * which reads the point's .op, else the operating point its transient
 * starts from. */

/* Why a point produced no value, or not all of them
 * (espice_copy_point_measures). The first nonzero reason wins. */
typedef enum {
    ESPICE_REASON_OK = 0,
    /* OpDidNotConverge, HbDidNotConverge, PzDidNotConverge, ... */
    ESPICE_REASON_NO_CONVERGENCE = 1,
    ESPICE_REASON_TIMESTEP_TOO_SMALL = 2,
    /* SingularMatrix, FloatingNode */
    ESPICE_REASON_SINGULAR_MATRIX = 3,
    /* A measure names a vector, or an analysis, the point lacks. */
    ESPICE_REASON_MEASURE_NOT_FOUND = 4,
    /* A measure's event never happened; its value is NaN. */
    ESPICE_REASON_MEASURE_UNRESOLVED = 5,
    /* espice_points_options.abort_after passed with a measure unresolved. */
    ESPICE_REASON_ABORTED = 6,
    /* No model bin holds the point's geometry. */
    ESPICE_REASON_MODEL_BIN_NOT_FOUND = 7,
    /* The values change the topology (a node collapses, a device appears)
     * or flip a top-level .if. */
    ESPICE_REASON_TOPOLOGY_CHANGED = 8,
    /* A non-finite value, or one a device rejects (NonFiniteParameter). */
    ESPICE_REASON_INVALID_PARAMETER = 9,
    /* A device refused the point (DeviceRefused). */
    ESPICE_REASON_DEVICE_REFUSED = 10,
    /* Any other failure; espice_query_error_message names it. */
    ESPICE_REASON_OTHER = 255
} espice_reason;

/* NULL options select all zeros. struct_size must cover every field;
 * fields appended later are read only when it covers them. */
typedef struct {
    uint32_t struct_size;
    uint32_t measures_only; /* 1: record no waveforms */
    uint32_t early_stop;    /* 1: end a point once its measures resolve */
    uint32_t warm_start;    /* 0: cold; 1: from the template's nominal OP */
    double abort_after;     /* t past which an unresolved measure aborts; 0 = off */
} espice_points_options;

/* Appends count points: values is [count][live_param_count] row-major, in
 * espice_create_options.live_params order. Each point runs every analysis
 * of the deck, as a .step point would; *first_id receives point 0's first
 * query id. Points are consecutive in request order: point k's analyses
 * follow point k-1's (an implicit operating point may sit between ids).
 * A point the template cannot hold (TOPOLOGY_CHANGED,
 * MODEL_BIN_NOT_FOUND, INVALID_PARAMETER) is appended already failed with
 * that reason. All-or-nothing. INVALID_ARGUMENT for count 0, a problem
 * created without live_params ("NoLiveParameters"), a deck whose analyses
 * already sweep (.step, .data, .alter, Monte Carlo: "SweptTemplate"),
 * an options flag above 1, or a negative or non-finite abort_after;
 * ABI_MISMATCH for a struct_size short of this struct. The first call
 * also runs the deck's .model OPT optimization and MOSRA stress run. */
espice_status espice_append_points(espice_problem *, const double *values,
    size_t count, const espice_points_options *options, uint32_t *first_id);
/* Copies the .meas results names (case-insensitive) of count points
 * starting at first_id into out, [count][measure_count] row-major, and
 * each point's espice_reason into reasons[count]. A point is a run of
 * consecutive requested queries on one sweep row: a point appended above,
 * a point of a swept deck, or every query of an unswept deck. A measure
 * reads the point's first analysis of its kind. A failed point reads NaN
 * throughout; otherwise NaN marks a measure with no value, and the reason
 * names the first such. INVALID_ARGUMENT for a name no .meas card has
 * ("UnknownMeasure"); INVALID_QUERY for a first_id that is not a requested
 * query or fewer than count points after it; RESULT_UNAVAILABLE while a
 * query of those points is unfinished. Nothing is written on failure. */
espice_status espice_copy_point_measures(espice_problem *, uint32_t first_id,
    size_t count, const espice_bytes *names, size_t measure_count,
    double *out, uint32_t *reasons);
/* The number of points the executor runs together on this problem's
 * backend: 1 today. Advisory: it changes speed, never results. */
espice_status espice_lane_width(espice_problem *, uint32_t *out);

#ifdef __cplusplus
}
#endif
#endif
