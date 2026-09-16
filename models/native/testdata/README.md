# Native line reference histories

`ltra1_ngspice_44_2.bin` contains 498 independently accepted timepoints from
ngspice 44.2 running the checked-in LTRA1 fixture. Each row contains five
little-endian binary64 values: time, near voltage, far voltage, near current,
and far current. The JSON sidecar records source and data hashes, the exact
command and the model parameters. The source deck and all expected values
are unchanged.

The native test feeds that history through `precompute`, `eval` and
`updateState`. It checks both branch residuals against the device's declared
1e-12 A current tolerance. This isolates convolution arithmetic from the host
solver's choice of accepted points. It does not certify the host's complete
waveform, AC behavior or arbitrary history lengths. The original replay's
largest residual was 4.31e-16 A; full simulator LTRA1 agreement remains open.

Reproduce the reference from the repository root using ngspice 44.2:

```sh
ngspice -n -b -r reference.raw tests/fixtures/tran/bench_tline_ltra1_1_line.sp
python3 - <<'PY'
import hashlib
import json
import re
import struct
from pathlib import Path

fixture = Path('models/native/testdata/ltra1_ngspice_44_2.bin')
metadata = json.loads(fixture.with_suffix('.json').read_text())
source = Path(metadata['source']).read_bytes()
assert hashlib.sha256(source).hexdigest() == metadata['source_sha256']
header, payload = Path('reference.raw').read_bytes().split(b'Binary:\n', 1)
assert b'Flags: real' in header
n = int(re.search(rb'No. Variables:\s*(\d+)', header).group(1))
rows = int(re.search(rb'No. Points:\s*(\d+)', header).group(1))
names = [line.split()[1].decode()
         for line in header.split(b'Variables:\n', 1)[1].splitlines()
         if line.split()]
# ngspice writes native-endian doubles. The checked-in data are always little-endian.
values = struct.unpack('=' + str(n * rows) + 'd', payload)
selected = [values[row * n + names.index(column)]
            for row in range(rows) for column in metadata['columns']]
encoded = struct.pack('<' + str(len(selected)) + 'd', *selected)
assert rows == metadata['rows']
assert hashlib.sha256(encoded).hexdigest() == metadata['fixture_sha256']
assert encoded == fixture.read_bytes()
PY
zig build test-native-lines
```

The raw-file hash records the original run, including its date header. The
selected-data hash is the reproducible numeric check; different ngspice
builds or platforms may choose different accepted points and must be
investigated rather than silently replacing this oracle.

Fixture layout decisions: the data are five values per accepted point; all
five are consumed together; rows are read sequentially once; the binary is
immutable for the test lifetime; its fixed size is 498 × 40 bytes; no vector
kernel is involved because timesteps are sequential. Runtime model history
storage remains the existing SoA layout.
