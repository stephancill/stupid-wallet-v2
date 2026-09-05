"""Opt-in subprocess crash/coordination test. All records stay in a temporary directory."""
import concurrent.futures
import json
import pathlib
import subprocess
import sys
import tempfile
import uuid

host = str(pathlib.Path(sys.argv[1]).resolve())
with tempfile.TemporaryDirectory(prefix="wallet-lifecycle-proof-") as temporary:
    def call(identifier, profile="proof-profile", crash="none"):
        return subprocess.run(
            [host, "--checkpoint", temporary, identifier, profile, crash],
            capture_output=True, text=True, timeout=20,
        )

    identifiers = [str(uuid.uuid4()) for _ in range(40)]
    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
        results = list(pool.map(call, identifiers))
    assert all(r.returncode == 0 and not r.stderr for r in results)
    assert sorted(int(r.stdout) for r in results) == list(range(1, 41))
    state = pathlib.Path(temporary) / "chrome-lifecycle-proof-v1/checkpoints.json"
    assert len(json.loads(state.read_text())) == 40
    before = str(uuid.uuid4())
    assert call(before, crash="before").returncode == -9
    assert len(json.loads(state.read_text())) == 40
    assert call(before).stdout.strip() == "41"
    after = str(uuid.uuid4())
    assert call(after, crash="after").returncode == -9
    assert len(json.loads(state.read_text())) == 42
    assert call(after).stdout.strip() == "42"
    saved = state.read_bytes()
    assert call(after, profile="other-profile").returncode != 0
    assert state.read_bytes() == saved
    state.write_text("invalid JSON")
    assert call(str(uuid.uuid4())).returncode != 0
    assert state.read_text() == "invalid JSON"
print("PASS: 40 concurrent commits; crash before/after commit; idempotent recovery; profile binding; corrupt-state refusal.")
