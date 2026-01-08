# Annex F — discipline resolution methods

Source: docs/annex-f-resolution.html. Every HTML section id is listed literally. Discipline resolution traverses an elaborated signal hierarchy, while FastVAF emits a single flattened analog device; source-level declarations are tested and traversal cases are explicit diagnostics.

Boundary disclosure: `conflicting_declarations.va` is a well-formed exact snapshot of
FastVAF's missing conflict diagnostic. Out-of-context dotted declarations stop at a
parser token, while traversal/default/alternate algorithm sources stop at unsupported
module instances; none claim to execute the hierarchy-resolution algorithm.

| HTML id | Algorithm/rule | Fixtures / disposition |
|---|---|---|
| `sF-1` | Clause 7.4 resolution semantics may use either conforming algorithm | `continuous_discipline.va`, `discrete_discipline.va` |
| `sF-2` | post-order child-to-parent and top-down parent-to-child signal traversal | `hierarchy_resolution_unsupported.va` |
| `sF-2-1` | default: elaborate; apply in-context then out-of-context declarations; depth-first domain selection; default_discipline/single/resolution-connect/unknown decision; insert converters | `in_context_declaration.va`, `out_of_context_unsupported.va`, `conflicting_declarations.va` (well-formed conflicting declarations snapshot the missing diagnostic), `default_algorithm_unsupported.va` |
| `sF-2-2` | expanded analog: same first pass, then top-down reclassification before insertion | `alternate_algorithm_unsupported.va`; selection is a simulator option rather than VA syntax |
