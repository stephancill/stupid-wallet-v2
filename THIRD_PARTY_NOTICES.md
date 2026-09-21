# Third-Party Notices

This repository vendors or adapts a small set of upstream sources and algorithms.
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

## BIP-39 English Word List

- **Provenance:** MnemonicSwift 2.2.5, derived from the canonical BIP-39 English list at
  <https://github.com/zcash-hackworks/MnemonicSwift>.
- **License:** dual MIT / Apache-2.0; this project uses the MIT terms. Copyright Keefer
  Taylor (2018) and Electric Coin Company (2020-2021).
- **Vendored file:** `Sources/StupidWalletCore/BIP39EnglishWords.swift`.
- **Local adaptation:** vocabulary data only. Validation, PBKDF2-HMAC-SHA512, BIP-32
  derivation, and key handling are project-owned and use CryptoKit plus the existing
  vendored libsecp256k1 target. No MnemonicSwift runtime package is linked.

## blo Ethereum Identicon Algorithm

- **Provenance:** <https://github.com/bpierre/blo>
- **Pinned revision:** commit `bb15b6309bb5903601adab83d049c53a5a6852d2` (`blo` 2.0.0 source).
- **License:** MIT. Copyright (c) 2023 Pierre Bertet <https://bpier.re/>.
- **Local adaptation:** the seed, xorshift PRNG, random-call order, HSL palette, and mirrored 8x8
  image algorithm are adapted into `SafariExtension/Resources/popup.js`. The popup renders the
  resulting pixels as DOM elements rather than using upstream's SVG serializer. No runtime package
  is linked.

MIT License

Copyright (c) 2023 Pierre Bertet <https://bpier.re/>

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and
associated documentation files (the "Software"), to deal in the Software without restriction,
including without limitation the rights to use, copy, modify, merge, publish, distribute,
sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial
portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT
NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM,
DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT
OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

## ENSIP-15 Name Normalization

- **Provenance:** <https://github.com/adraffy/ENSNormalize.swift>
- **Pinned revision:** `v1.0.1` → `d848cc56f5ba8a9cb60dc26b61c96ca51509ef52`.
- **License:** MIT, Copyright (c) 2025 Andrew Raffensperger. The complete license is retained at
  `Sources/ENSNormalize/LICENSE`.
- **Copied subset:** the Swift normalization implementation and its `nf.bin` / `spec.bin` tables in
  `Sources/ENSNormalize/`. Upstream package, build scripts, string convenience extensions and test
  fixtures are not runtime dependencies. The copied normalizer has no transitive dependencies.
- **Purpose:** ENSIP-15 validation and normalization of recipient names, including Unicode and emoji.
  It does not fetch records, access keys, or sign. RPC, namehash, DNS framing, and CCIP-Read are
  project-owned Swift code using the existing native core.
- **Local adaptation:** `ENSIP15` and `NF` read byte-identical embedded tables instead of
  `Bundle.module`. `scripts/embed-ens-normalization-data.py` generates `NormalizationData.swift` from
  the copied binary tables and records their SHA-256 digests. This keeps all build targets independent
  of an additional runtime resource bundle. Swift formatting is applied; a folder-scoped formatter
  rule retains upstream's constant and normalization-function names for auditability.
- **Data provenance:** Unicode 17.0.0; upstream normalization specification hash
  `4febc8f5d285cbf80d2320fb0c1777ac25e378eb72910c34ec963d0a4e319c84`.

## System Frameworks

Apple system frameworks supply Foundation/URLSession, Security, LocalAuthentication, and SwiftUI.
