"""Checks that the fixture gate rejects false agreement and incomplete output."""
from pathlib import Path
import struct
import tempfile
import unittest

from check_fixtures import compare, read_raw
from sky130_corpus import extracted


class FixtureGateTests(unittest.TestCase):
    def test_extraction_preserves_source_and_binds_observed_port_order(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "strongarm").mkdir()
            source = root / "strongarm/strongarm_pex.spice"
            text = "* test extraction\n.subckt strongarm_flat CLK GND VINP VINN OUTN OUTP VDD\nC0 OUTP GND 1f\n.ends\n"
            source.write_text(text)
            records = extracted(root, root / "out", root / "models.sp", ["tt"])
            self.assertEqual(source.read_text(), text)
            self.assertEqual(records[0]["quality_issues"], [])
            self.assertEqual(records[0]["explicit_capacitors"], 1)
            deck = (root / "out/sky130_extracted/strongarm_pex_spice_tt_op/circuit.sp").read_text()
            self.assertIn("Xdut clk 0 vinp vinn outn outp vdd strongarm_flat", deck)
            source.write_text(".subckt strongarm_flat VINP VINN VSS\n.ends\n")
            broken = extracted(root, root / "out", root / "models.sp", ["tt"])
            self.assertIn("missing design ports", broken[0]["quality_issues"][0])
            self.assertNotEqual(records[0]["sha256"], broken[0]["sha256"])

    def test_complex_multi_plot_and_bad_payloads(self):
        header = (b"Title: test\nPlotname: AC Analysis\nFlags: complex\n"
                  b"No. Variables: 2\nNo. Points: 1\nVariables:\n"
                  b"0 frequency frequency\n1 v(out) voltage\nBinary:\n")
        plot = header + struct.pack("=4d", 1, 0, 0.5, -0.5)
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "test.raw"
            path.write_bytes(plot + plot)
            plots = read_raw(path)
            self.assertEqual(len(plots), 2)
            self.assertEqual(plots[0][1]["v(out)"], [0.5 - 0.5j])
            for bad in (plot[:-1], header + struct.pack("=4d", 1, 0, float("nan"), 0),
                        plot.replace(b"AC Analysis", b"Periodic Noise (PSS not converged)"), b""):
                path.write_bytes(bad)
                with self.assertRaises(ValueError):
                    read_raw(path)

    def test_op_checks_first_signal_and_tiny_currents(self):
        reference = [("Operating Point", {"v(out)": [1.0], "i(v1)": [1e-9]})]
        compare(reference, reference, 1e-3)
        for bad in ({"v(out)": [0.0], "i(v1)": [1e-9]},
                    {"v(out)": [1.0], "i(v1)": [0.0]}, {"v(out)": [1.0]}):
            with self.assertRaises(ValueError):
                compare([("Operating Point", bad)], reference, 1e-3)

    def test_complex_phase_and_truncated_interval_fail(self):
        ref = [("AC Analysis", {"frequency": [1, 2], "v(out)": [1j, 1j]})]
        compare(ref, ref, 1e-3)
        for bad in ({"frequency": [1, 2], "v(out)": [-1j, -1j]},
                    {"frequency": [1, 1.9], "v(out)": [1j, 1j]}):
            with self.assertRaises(ValueError):
                compare([("AC Analysis", bad)], ref, 1e-3)


if __name__ == "__main__":
    unittest.main()
