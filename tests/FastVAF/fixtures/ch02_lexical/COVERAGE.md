# Chapter 2 coverage

Source: `docs/ch2-lexical.html`, read in full including every syntax box and table.

HTML section-ID audit: `s2-1` `s2-2` `s2-3` `s2-4` `s2-5` `s2-6` `s2-6-1` `s2-6-2` `s2-7` `s2-8` `s2-8-1` `s2-8-2` `s2-8-3` `s2-8-4` `s2-9` `s2-9-1` `s2-9-2`.

| LRM section/rule | Fixture or disposition |
|---|---|
| 2.1–2.3 free-format tokens and whitespace separators | `01_whitespace_comments.va` uses spaces, tabs, and newlines; `27_form_feed_whitespace.va` contains literal form feeds and records FastVAF's current lexer rejection |
| 2.4 `//` and `/*…*/`; `//` inside a block comment; unclosed block | `01_whitespace_comments.va`, `12_unclosed_comment.va` |
| 2.5 single/double/triple-character operators | token/operator semantics are exercised exhaustively in `ch04_expressions` |
| 2.6.1 decimal, binary, octal, hexadecimal, sizes, underscores | `04_integer_bases.va`, `35_uppercase_bases_hex.va`, `36_based_number_digit_whitespace.va`, `37_macro_based_number_tokens.va` |
| 2.6.1 x/z/? four-state digits | `05_xz_integer_rejected.va` records FastVAF's explicit two-state-codegen rejection; padding/truncation is therefore not representable in the device contract |
| 2.6.2 decimal/scientific real notation | `06_real_notation.va`, `34_real_underscores.va` |
| 2.6.2 all scale symbols T/G/M/K/k/m/u/n/p/f/a | `07_si_scale_factors.va` |
| 2.7 strings, whitespace, `\n`, `\t`, `\\`, `\"`, octal escapes | `08_string_escapes.va` |
| 2.8 simple identifiers, leading `_`, embedded `$`, case sensitivity, minimum supported length | `02_simple_identifiers.va`, `28_identifier_1024_chars.va` |
| 2.8.1 escaped identifiers terminate at whitespace | `03_escaped_identifiers.va` |
| 2.8.2 lowercase reserved keywords | declaration/control/function keywords are exercised throughout this suite; Annex B provides the complete inventory |
| 2.8.3 `$` system names, with and without arguments | `09_system_identifiers.va`; task statement forms belong to Chapter 9 |
| 2.8.4 grave-accent compiler directives | `10_compiler_directive_macro.va`; directive-specific semantics belong to Chapter 10 |
| 2.9 attribute syntax, defaults, duplicates, multiple specs, strings, nesting ban, standard attributes | `11_attributes.va`, `20_duplicate_attributes.va`, `29_attribute_default_and_multiple.va`, `30_nested_attribute_rejected.va` |
| 2.9 attribute placement on statements, operators, function calls, `?:`, connections, UDPs, and declarations | `31_analog_statement_attributes.va`, `21_operator_attribute_rejected.va`, `32_function_call_attribute.va`, and `33_conditional_attribute.va` directly pin analog/expression placements; connection/UDP-only forms remain mixed/digital grammar boundaries |
| 2.9.2 reporting meaning of desc/units/op/multiplicity | encoded as accepted metadata in `11_attributes.va`; operating-point reporting is a simulator responsibility and is not present in a static Zig dump |

Boundary and negative lexical fixtures: `13_nested_comment_rejected.va` (non-nesting), `14_real_leading_dot_current_behavior.va`, `15_real_trailing_dot_rejected.va`, `16_real_dot_exponent_rejected.va` (the explicitly invalid decimal-point forms), `17_identifier_digit_rejected.va` (identifier first character), `18_system_whitespace_rejected.va` (`$` adjacency), `19_multiline_string_rejected.va` (single-line string rule), `20_duplicate_attributes.va` (last duplicate wins), `21_operator_attribute_rejected.va` (operator placement gap), `22_unsized_based_rejected.va`, `23_signed_based_rejected.va`, `24_question_digit_rejected.va`, `25_base_sign_current_behavior.va` (based-number grammar boundaries), and `26_escaped_keyword.va` (escaped reserved spelling). Each is an independent snapshot or diagnostic for `s2-4`, `s2-6-1`, `s2-6-2`, `s2-7`, `s2-8`, `s2-8-1`, `s2-8-2`, `s2-8-3`, or `s2-9`.

## Lexical and attribute completion

- `27_form_feed_whitespace.va` contains literal form-feed bytes between tokens and records the current lexer rejection.
- `28_identifier_1024_chars.va` uses an identifier exactly 1024 characters long.
- `29_attribute_default_and_multiple.va` covers value-less attributes (default value 1), explicit values, and comma-separated specifications.
- `30_nested_attribute_rejected.va` covers the normative ban on nesting an attribute inside an attribute value.
- `31_analog_statement_attributes.va`, `32_function_call_attribute.va`, and `33_conditional_attribute.va` place attributes on analog statements, after an analog function name, and after `?`; current parser diagnostics are pinned.
- `34_real_underscores.va` covers underscores in decimal, fractional, and exponent-adjacent real notation.
- `35_uppercase_bases_hex.va` covers uppercase base letters and mixed-case hexadecimal digits.
- `36_based_number_digit_whitespace.va` covers the normative whitespace boundary between base format and digit token and records FastVAF's current rejection.
- `37_macro_based_number_tokens.va` expands separate macros for the base-format and digit tokens of a based number and records the current preprocessor/parser boundary.
- `38_string_line_continuation_rejected.va` is `bsim4va.va:3658` verbatim: a `$strobe` string ending its line with `\`. 2.7 requires a literal be "contained on a single line" and Table 2-2 lists no `\<newline>` escape, so the continuation — an IEEE 1800 5.9 SystemVerilog addition that Verilog-AMS did not inherit from IEEE 1364-2005 — is rejected as E0138. Normative, not a snapshot: it pins that FastVAF does *not* adopt the vendor extension.
