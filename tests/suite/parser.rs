//! Parser and tokenizer tests.
#[path = "../common/mod.rs"]
mod common;
use common::parse_netlist_str;
use bigospice_parser::{SaveSpec, SpiceParser, StepKind};

#[test]
fn parser_basic_netlist_parses() {
    let netlist = "\
* Basic test
V1 1 0 DC 5
R1 1 0 1k
.OP
.END
";
    let result = parse_netlist_str(netlist);
    assert!(result.is_ok(), "basic netlist should parse: {:?}", result.err());
}

#[test]
fn parser_if_true_branch_includes_element() {
    let netlist = "\
* IF true branch
.PARAM USE_R1=1
V1 1 0 DC 5
.IF (USE_R1)
R1 1 0 1k
.ELSE
R1 1 0 999
.ENDIF
.OP
.END
";
    let (circuit, _, _) = SpiceParser::parse(netlist).unwrap();
    let r1 = circuit.find_device("r1").expect("R1 should be present");
    let res = r1.params.get("resistance").unwrap_or(0.0);
    assert!((res - 1e3).abs() < 1e-9, "R1 from true branch should be 1k, got {res}");
}

#[test]
fn parser_if_false_branch_taken() {
    let netlist = "\
* IF false branch
.PARAM USE_R1=0
V1 1 0 DC 5
.IF (USE_R1)
R1 1 0 1k
.ELSE
R1 1 0 4k
.ENDIF
.OP
.END
";
    let (circuit, _, _) = SpiceParser::parse(netlist).unwrap();
    let r1 = circuit.find_device("r1").expect("R1 from else branch");
    let res = r1.params.get("resistance").unwrap_or(0.0);
    assert!((res - 4e3).abs() < 1e-9, "R1 from else branch should be 4k, got {res}");
}

#[test]
fn parser_step_list_directive_values() {
    let s = StepKind::List(vec![1.0, 2.5, 4.0]);
    if let StepKind::List(v) = s {
        assert_eq!(v, vec![1.0, 2.5, 4.0]);
    }
}

#[test]
fn parser_func_definition() {
    let netlist = "\
* FUNC test
.FUNC sqr(x) = x*x
.PARAM W = sqr(3)
V1 1 0 DC 1
R1 1 0 1k
.OP
.END
";
    let _ = SpiceParser::parse(netlist).unwrap();
}

#[test]
fn parser_brace_expression_in_resistor_value() {
    let netlist = "\
* Brace value
V1 1 0 DC 5
R1 1 0 {2*500}
.OP
.END
";
    let (circuit, _, _) = SpiceParser::parse(netlist).unwrap();
    let r1 = circuit.find_device("r1").expect("R1");
    let res = r1.params.get("resistance").unwrap_or(0.0);
    assert!((res - 1e3).abs() < 1e-9, "expected R1=1k from brace expr, got {res}");
}

#[test]
fn parser_print_branch_current() {
    let netlist = "\
* PRINT branch current
V1 1 0 DC 5
R1 1 0 1k
.TRAN 1n 100n
.PRINT TRAN I(V1) V(1)
.END
";
    let (_, analyses, _) = SpiceParser::parse(netlist).unwrap();
    assert_eq!(analyses.len(), 1);
}

#[test]
fn save_spec_variants() {
    let _ = SaveSpec::All;
    let _ = SaveSpec::AllVoltages;
    let _ = SaveSpec::AllCurrents;
    let _ = SaveSpec::NodeVoltage("out".into());
    let _ = SaveSpec::BranchCurrent("v1".into());
    let _ = SaveSpec::NodeVoltageDiff("a".into(), "b".into());
}

#[test]
fn parser_continuation_line_robust() {
    let netlist = "\
* Continuation test
V1 1 0
+ DC
+ 5
R1 1 0
+ 1k
.OP
.END
";
    let (circuit, _, _) = SpiceParser::parse(netlist).unwrap();
    let v1 = circuit.find_device("v1").expect("V1");
    assert!((v1.params.get("dc").unwrap_or(0.0) - 5.0).abs() < 1e-9);
    let r1 = circuit.find_device("r1").expect("R1");
    assert!((r1.params.get("resistance").unwrap_or(0.0) - 1e3).abs() < 1e-9);
}

#[test]
fn parser_continuation_with_intermediate_comment() {
    let netlist = "\
* Continuation with comment
V1 1 0 DC 5
R1 1 0
* a comment in the middle
+ 1k
.OP
.END
";
    let (circuit, _, _) = SpiceParser::parse(netlist).unwrap();
    let r1 = circuit.find_device("r1").expect("R1");
    assert!((r1.params.get("resistance").unwrap_or(0.0) - 1e3).abs() < 1e-9);
}

#[test]
fn connect_directive_merges_nets() {
    let netlist = "\
* .CONNECT test
V1 a 0 DC 1
R1 a 0 1k
R2 b 0 2k
.CONNECT a b
.OP
.END
";
    let (circuit, _, _) = SpiceParser::parse(netlist).unwrap();
    assert!(circuit.find_node("b").is_none(), "node 'b' should be removed after .CONNECT");
    let r2 = circuit.find_device("r2").expect("R2 device");
    let node_a_id = circuit.find_node("a").expect("node 'a'");
    assert!(
        r2.terminals.iter().any(|t| t.node == node_a_id),
        "R2 terminal should reference node 'a' after .CONNECT"
    );
}

#[test]
fn connect_directive_unknown_net_ignored() {
    let netlist = "\
* Unknown net
V1 a 0 DC 1
.CONNECT a nonexistent_net
.OP
.END
";
    let result = SpiceParser::parse(netlist);
    assert!(result.is_ok(), "unknown .CONNECT net should not be an error");
}

#[test]
fn extract_directive_parsed() {
    let netlist = "\
* .EXTRACT parse test
V1 out 0 DC 3.3
R1 out 0 1k
.TRAN 1n 10n
.EXTRACT TRAN vmax=ymax(v(out)) vmin=ymin(v(out))
.END
";
    let (_, _, _, specs) = SpiceParser::parse_netlist(netlist).unwrap();
    assert_eq!(specs.len(), 2, "expected 2 extract specs");
    assert_eq!(specs[0].analysis, "tran");
    assert_eq!(specs[0].label, "vmax");
    assert_eq!(specs[0].expr, "ymax(v(out))");
}

#[test]
fn extract_directive_ac_type() {
    let netlist = "\
* .EXTRACT AC variant
V1 in 0 AC 1
R1 in out 1k
C1 out 0 1n
.AC DEC 10 1k 1G
.EXTRACT AC gain_db=ymax(vdb(out))
.END
";
    let (_, _, _, specs) = SpiceParser::parse_netlist(netlist).unwrap();
    assert_eq!(specs.len(), 1);
    assert_eq!(specs[0].analysis, "ac");
}
