#!/usr/bin/env bash
#
# regex/mayhem/build.sh — build rust-lang/regex's cargo-fuzz targets as sanitized libFuzzer
# binaries, replicating OSS-Fuzz's Rust path (base-builder-rust `compile` + `cargo fuzz build -O`).
#
# regex is the Rust regular-expression crate. Its UPSTREAM fuzz/ crate (regex-fuzz, libfuzzer-sys
# 0.4 + arbitrary 1.3, path deps on regex/regex-automata/regex-lite/regex-syntax) is a clean, modern
# cargo-fuzz crate maintained by the project — it builds directly under the image nightly, so we
# build it AS-IS and DO NOT touch it (the integration stays purely additive; everything we add lives
# under mayhem/). It ships eight fuzzers (the upstream OSS-Fuzz set):
#   fuzz_regex_match, fuzz_regex_lite_match, ast_roundtrip, ast_fuzz_match, ast_fuzz_regex,
#   ast_fuzz_match_bytes, fuzz_regex_automata_deserialize_dense_dfa,
#   fuzz_regex_automata_deserialize_sparse_dfa
# The old fork shipped only fuzz_regex_match; we expose all eight, each at /mayhem/<target>.
#
# cargo-fuzz drives the build:
#   - it provides its own libFuzzer runtime (the produced binary IS a libFuzzer target — Mayhem runs
#     it directly via `libfuzzer: true`, and it also runs once on a single input file as a reproducer);
#   - ASan is enabled the Rust way, through RUSTFLAGS `-Zsanitizer=address` (NOT clang's
#     $SANITIZER_FLAGS / CFLAGS — those don't apply to rustc), which is what OSS-Fuzz's `compile`
#     sets for FUZZING_LANGUAGE=rust. nightly is required for `-Zsanitizer`.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer (kept for parity even though
# the Rust build doesn't invoke clang directly; cargo's cc-built deps might).
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SRC:=/mayhem}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${RUST_DEBUG_FLAGS:=-C debuginfo=2 -C llvm-args=--dwarf-version=3}"
export MAYHEM_JOBS
export RUST_DEBUG_FLAGS
# cargo-fuzz has no --jobs flag; cargo reads parallelism from CARGO_BUILD_JOBS.
export CARGO_BUILD_JOBS="$MAYHEM_JOBS"

cd "$SRC"

# Build upstream's own cargo-fuzz crate. Discover every target from its fuzz_targets/ dir so the set
# stays in lock-step with upstream (a new upstream fuzzer is picked up automatically on sync).
FUZZ_DIR="fuzz"
FUZZ_TARGETS=()
for f in "$FUZZ_DIR"/fuzz_targets/*.rs; do
  FUZZ_TARGETS+=("$(basename "${f%.*}")")
done
[ "${#FUZZ_TARGETS[@]}" -gt 0 ] || { echo "ERROR: no fuzz targets under $FUZZ_DIR/fuzz_targets/" >&2; exit 1; }
TRIPLE="x86_64-unknown-linux-gnu"

# Replicate OSS-Fuzz `compile` RUSTFLAGS for a libFuzzer+ASan Rust build. cargo-fuzz sets the ASan
# flag itself by default, but we set it explicitly so the behavior is pinned and visible. `--cfg
# fuzzing` matches what libfuzzer-sys expects; force-frame-pointers aids ASan stack traces.
# Thread $RUST_DEBUG_FLAGS for DWARF < 4 symbols (required by Mayhem's diff coverage).
export RUSTFLAGS="${RUSTFLAGS:-} --cfg fuzzing -Zsanitizer=address -Cdebuginfo=2 -Cdwarf-version=3 -Cforce-frame-pointers -Csplit-debuginfo=off $RUST_DEBUG_FLAGS"

echo "=== cargo fuzz build (image-default nightly toolchain, ASan via RUSTFLAGS) ==="
echo "RUSTFLAGS=$RUSTFLAGS"
echo "targets: ${FUZZ_TARGETS[*]}"

# `-O` (release w/ opt) + `--debug-assertions` mirrors OSS-Fuzz's Rust build (catches overflow/debug
# asserts during fuzzing). Use the image's DEFAULT toolchain (the Dockerfile pins it to the required
# nightly); a `+toolchain` override would make rustup try to install a different channel into the
# read-only shared /opt/rust. Build per-target so a single bad target doesn't mask the others.
for t in "${FUZZ_TARGETS[@]}"; do
  echo "--- building fuzz target: $t ---"
  cargo fuzz build --fuzz-dir "$FUZZ_DIR" -O --debug-assertions "$t"
  bin="$SRC/$FUZZ_DIR/target/$TRIPLE/release/$t"
  if [ ! -x "$bin" ]; then
    echo "ERROR: expected fuzz binary not found at $bin" >&2
    exit 1
  fi
  cp "$bin" "/mayhem/$t"
  echo "built /mayhem/$t"
done

echo "build.sh complete:"
ls -la "/mayhem/${FUZZ_TARGETS[@]}" 2>&1 || true
