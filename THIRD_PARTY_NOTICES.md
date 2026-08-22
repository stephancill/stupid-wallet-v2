# Third-Party Notices

This repository vendors a small set of upstream sources for cryptographic primitives.
Each is pinned to an exact revision so builds are reproducible and auditable.

## libsecp256k1 (C)

- **Provenance:** <https://github.com/bitcoin-core/secp256k1>
- **Pinned revision:** `v0.5.1` → commit `642c885b6102725e25623738529895a95addc4f4`
- **License:** MIT — see `third-party/libsecp256k1/COPYING`.
- **Vendored tree:** `third-party/libsecp256k1/` (full source checkout at the pinned tag).
- **Local adaptation:**
  - Built as a SwiftPM C target (`CSecp256k1`). SwiftPM cannot run the upstream
    autotools/configure step, so the three build translation units are `#include`d
    through thin shims in `Sources/CSecp256k1/`:
    - `shim_secp256k1.c` → `third-party/libsecp256k1/src/secp256k1.c`
    - `shim_precomputed_ecmult.c` → `src/precomputed_ecmult.c`
    - `shim_precomputed_ecmult_gen.c` → `src/precomputed_ecmult_gen.c`
  - Build flags: `ENABLE_MODULE_RECOVERY`, `ENABLE_MODULE_ECDH`.
  - `Sources/CSecp256k1/include/` holds a copy of the public headers for the Swift
    module; the compilation itself uses the sources in `third-party/`.
- **Semantics note:** only the core secp256k1 API surface plus the recovery and ECDH
  modules are compiled; nothing else from the upstream tree is built or linked.

## Deprecation / no-other-dependencies policy

No other runtime dependency is vendored or imported. Apple system frameworks supply
Foundation/URLSession, Security, LocalAuthentication, and SwiftUI.