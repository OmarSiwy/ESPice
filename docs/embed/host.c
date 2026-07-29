/* A minimal ESPice host: simulate an RC low-pass from netlist text, run
 * every analysis, and print |v(out)| of the AC result.
 * `zig build c-example` compiles and runs this file against libespice.a. */
#include <espice.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const char deck[] =
    "RC low-pass\n"
    "V1 in 0 DC 0 AC 1\n"
    "R1 in out 1k\n"
    "C1 out 0 159n\n"
    ".ac dec 1 10 100k\n"
    ".end\n";

/* Prints the problem's last error and returns 1. */
static int fail(espice_problem *p, const char *what) {
    char msg[128] = "";
    size_t needed = 0;
    if (p) espice_error_message(p, msg, sizeof msg, &needed);
    fprintf(stderr, "%s failed: %s\n", what, msg);
    return 1;
}

int main(void) {
    espice_create_options opt;
    espice_default_options(&opt);
    opt.source_kind = ESPICE_BYTES;
    opt.source = (espice_bytes){deck, strlen(deck)};
    opt.origin = (espice_bytes){"rc.sp", 5}; /* relative includes resolve here */

    espice_problem *p = NULL;
    char diagnostic[128];
    if (espice_create(&opt, &p, diagnostic, sizeof diagnostic) != ESPICE_OK) {
        fprintf(stderr, "espice_create: %s\n", diagnostic);
        return 1;
    }
    if (espice_run_all(p) != ESPICE_OK) return fail(p, "espice_run_all");

    /* Find the AC query the deck asked for. */
    uint32_t count = 0, ac = ESPICE_NO_QUERY;
    espice_query_count(p, &count);
    for (uint32_t id = 0; id < count; id++) {
        espice_query_info info;
        espice_get_query_info(p, id, &info);
        if (info.kind == ESPICE_AC && info.requested) ac = id;
    }
    if (ac == ESPICE_NO_QUERY) return fail(p, "finding the .ac query");

    espice_result_info r;
    if (espice_get_result_info(p, ac, &r) != ESPICE_OK) return fail(p, "espice_get_result_info");

    /* Column 0 is frequency; find v(out). */
    uint32_t out = 0;
    for (uint32_t v = 0; v < r.variable_count; v++) {
        char name[64];
        size_t needed = 0;
        espice_copy_result_name(p, ac, v, name, sizeof name, &needed);
        if (strcmp(name, "v(out)") == 0) out = v;
    }

    /* Zero-copy view: point-major, complex values as (re, im) pairs. */
    const double *data = NULL;
    size_t len = 0;
    if (espice_result_view(p, ac, &data, &len) != ESPICE_OK) return fail(p, "espice_result_view");
    size_t stride = (size_t)r.variable_count * (r.is_complex ? 2 : 1);
    for (uint64_t i = 0; i < r.point_count; i++) {
        const double *row = data + i * stride;
        double re = row[2 * out], im = row[2 * out + 1];
        printf("%10.0f Hz  |v(out)| = %.4f\n", row[0], sqrt(re * re + im * im));
    }

    espice_destroy(p);
    return 0;
}
