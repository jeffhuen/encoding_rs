# Changelog

## v0.5.0 (2026-11-26)

### Breaking changes

- Raised the minimum Elixir version to 1.16 to adopt `rustler_precompiled` 0.10.1 (which fixes GitHub release download failures caused by `:httpc`'s 10 KB `max_header_size` limit and adds NIF 2.18 support for Erlang/OTP 29). Source builds (`ENCODING_RS_BUILD=true`) now require Rust `1.88` or newer (required by `encoding_rs` `0.8.40+`).
- Changed `EncodingRs.Decoder.stream/2,3` and `EncodingRs.Decoder.stream_with_errors/2,3` to emit tagged tuples (`{:ok, chunk}`, `{:ok, chunk, had_errors}`, or `{:error, reason}`) instead of raising mid-stream. Added `EncodingRs.Decoder.stream!/2,3` and `EncodingRs.Decoder.stream_with_errors!/2,3` for raising pipelines.
- Changed non-bang encode functions (`encode/2,3`, `encode_with_details/2,3`, `encode_batch/1,2`, `encode_batch_with_details/1,2`) to return `{:error, :invalid_utf8}` for non-UTF-8 binaries instead of raising `ArgumentError`. Bang variants (`encode!/2,3`) still raise `ArgumentError`.
- Unified `EncodingRs.Decoder.new/1` and `new!/1` to return the same opaque `%EncodingRs.Decoder{}` struct as `new/2`, matching `EncodingRs.Encoder` and `EncodingRs.Detector`.
- Added the [0.4 to 0.5 migration guide](guides/migrating-0.4-to-0.5.md).

### Added

- **Streaming encoder (`EncodingRs.Encoder`)**: Added `new/1,2`, `new!/1,2`, `encode_chunk/2,3,4`, `encode_chunk!/2,3,4`, `stream/2,3`, `stream!/2,3`, `stream_with_errors/2,3`, and `stream_with_errors!/2,3`. Preserves shift state for stateful encodings like `ISO-2022-JP` and buffers UTF-8 code points split across chunk boundaries.
- **Heuristic encoding detection**: Added `EncodingRs.detect/1,2`, `EncodingRs.detect!/1,2`, and `EncodingRs.Detector` (`new/0,1`, `feed/2,3,4`, `feed!/2,3,4`, `guess/1,2`, `guess!/1,2`, `detect_stream/1,2`, `detect_stream!/1,2`) powered by Mozilla's `chardetng` crate with BOM-first detection and optional `:tld`, `:allow_utf8`, `:allow_iso_2022_jp`, and `:bom` controls.
- **Encode details and strict error modes**: Added `EncodingRs.encode_with_details/2,3` and `EncodingRs.encode_batch_with_details/1,2` returning `{:ok, binary, had_errors}`. Added `on_error: :replace | :error` to encode, decode, batch, and streaming APIs to reject unmappable characters (`{:error, :unmappable_character}`) or malformed bytes (`{:error, :malformed_input}`).
- **BOM handling control**: Added `bom: :sniff | :strip | :preserve` to one-shot decode, batch decode, and `EncodingRs.Decoder.new/2`, plus `EncodingRs.Decoder.encoding/1` to inspect the active encoding after BOM sniffing.
- **Target encoding inspection**: Added `EncodingRs.can_encode?/1`, `EncodingRs.output_encoding/1`, and `EncodingRs.list_output_encodings/0`.
- **OTP 29 precompiled binaries**: Added NIF version `2.18` alongside `2.15`, `2.16`, and `2.17` (40 precompiled release assets).

### Improved

- **Faster CJK encoding**: Enabled `encoding_rs`'s `fast-legacy-encode` Cargo feature. Release benchmarks on Apple Silicon measured 5.5x to 44x faster CJK encoding (Shift_JIS 72 to 914 MB/s, EUC-JP 72 to 1197 MB/s, GBK 33 to 1212 MB/s, Big5 29 to 1288 MB/s, EUC-KR 154 to 849 MB/s) for an additional ~120 KB gzipped NIF size.
- **Zero-copy borrowed decode path**: One-shot and batch decode now copy `Cow::Borrowed` ASCII and UTF-8 slices directly into BEAM `OwnedBinary` buffers without allocating an intermediate Rust `String`.
- **Batch fast path**: `decode_batch/2` and `encode_batch/2` skip `MapSet` and `Map` allocations when no item exceeds `:max_input_size`.
- **Dependencies**: Updated `rustler_precompiled` to `0.10.1`, `dialyxir` to `1.4.9`, `ex_doc` to `0.40.5`, and Rust `encoding_rs` from `0.8.35` to `0.8.44` (which adds `simdutf8` validation on stable Rust and fixes legacy two-byte and `ISO-2022-JP` streaming boundary bugs).

### Fixed

- Guarded `EncodingRs.Decoder.decode_chunk/3,4` against post-finish calls; calling after `is_last: true` now returns `{:error, :decoder_finished}` instead of panicking in the NIF and poisoning the mutex.
- Corrected documentation for unmappable encode characters (WHATWG HTML decimal numeric character references such as `&#127881;`), fixed the upstream `encoding_rs` repository link (`hsivonen/encoding_rs`), and documented `:unicode.characters_to_binary/3` for UTF-16 output.

## v0.4.0 (2026-08-28)

### Changed

- Removed global application configuration. The defaults remain 64KB for dirty scheduler dispatch and 100MB for input size. Pass options to each operation, stream, or decoder when different limits are needed.
- Removed the unused Logger startup declaration. EncodingRs has no application callback, supervision tree, or shared process state.
- Released the streaming decoder lock before compacting its output buffer.
- Added a [0.3 to 0.4 migration guide](guides/migrating-0.3-to-0.4.md).

## v0.3.0 (2026-08-16)

### Changed

- Added validated per-operation options while preserving existing arities and application configuration as a compatibility fallback; `Decoder.new/2` stores options once for manual chunk loops, and batches now select schedulers by their combined input size.
- Added detailed decode results and a non-raising native availability check; clarified BOM and decode-only UTF-16 behavior.
- Updated Elixir, Rust, and GitHub Actions dependencies; the minimum Elixir version is now 1.15.
- Added a [0.2 to 0.3 migration guide](guides/migrating-0.2-to-0.3.md).

### Fixed

- Kept no-option calls on the direct scheduler path and resolved stream options once per enumeration.
- Decode-only labels now return `{:error, :encoder_unavailable}` from encode operations instead of silently emitting UTF-8.
- Replaced panic-capable streaming output allocation with checked reservation and an `:allocation_failed` error.

## v0.2.4 (2026-02-16)

### Improved

- **Reduced heap allocations in NIF error paths**: Error returns from `decode`, `decode_batch`, `canonical_name`, and `detect_bom` no longer allocate heap strings — uses `String::new()` where Elixir discards the value, and `&'static str` where `encoding_rs` already provides static references
- **Replaced `write_all` with `copy_from_slice`**: Encode operations (`encode`, `encode_batch`) now use the infallible `copy_from_slice` instead of the fallible `Write` trait, since buffers are pre-allocated to the exact required size
- **Smarter streaming decoder memory management**: `shrink_to_fit()` in `decoder_decode_chunk` now only triggers when excess capacity exceeds 4KB, avoiding unnecessary `realloc` overhead on small chunks
- **Extracted `empty_binary` helper**: De-duplicated zero-length binary allocation logic across `encode` and `encode_batch` error paths with accurate documentation about `enif_alloc_binary` costs

### Removed

- Unused Rustler atom definitions (`unknown_encoding`, `encode_error`, `decode_error`, `no_bom`) and `use std::io::Write` import

## v0.2.3 (2026-01-29)

### Improved

- **Rustler 0.37 modernization**: Replaced deprecated `rustler::resource!` macro and `on_load` callback with `#[rustler::resource_impl]` for automatic resource registration — the recommended pattern since Rustler 0.34
- **Mutex poisoning safety**: `Decoder.decode_chunk/3` now returns `{:error, :lock_poisoned}` instead of raising an unhandled NIF exception if the internal mutex is poisoned (near-impossible in practice, but the code path is now safe)
- **Elixir DRY refactor**: Extracted `normalize_decode_result/1` in `Decoder` module to unify error normalization for streaming decode operations, matching the `normalize_result/1` pattern in the main module

### Added

- **Input size guardrails**: Configurable maximum input size (default 100MB) to prevent excessive memory allocation from untrusted or unexpectedly large inputs
  - `encode/2`, `decode/2`, batch operations, and `Decoder.decode_chunk/3` all validate input size
  - Oversized inputs return `{:error, :input_too_large}` (or raise `ArgumentError` for bang variants)
  - Batch operations reject oversized items individually while processing valid items normally
  - **Runtime configurable** via `Application.get_env/3` — can be set in `runtime.exs` or changed dynamically with `Application.put_env/3` without recompiling
  - Set to `:infinity` to disable the limit for trusted environments
  - Configure via `config :encoding_rs, max_input_size: 200 * 1024 * 1024`
  - `EncodingRs.max_input_size/0` returns the configured limit

### Testing

- Added input size validation tests for `encode/2`, `decode/2`, `encode!/2`, `decode!/2`, `decode_batch/1`, `encode_batch/1`, and `Decoder.decode_chunk/3`
- Slow tests (allocating 100MB+) are excluded by default; run with `mix test --include slow`

## v0.2.2 (2026-01-29)

### Fixed

- **NIF safety**: Replaced `.unwrap()` calls in `encode_batch` with proper error propagation via `NifResult`, preventing potential BEAM crashes on memory allocation failure
- **Documentation**: Removed unsupported HZ encoding from README (not in WHATWG/encoding_rs)
- **Documentation**: Clarified "200+ encodings" claim — the library supports 40 distinct WHATWG encodings with 200+ label aliases
- **Documentation**: Fixed `Decoder.stream/2` docs that incorrectly claimed 1:1 output-to-input correspondence; the stream may emit an extra element when flushing buffered bytes

### Improved

- **Rust DRY refactor**: Extracted shared `decoder_decode_chunk_impl` to eliminate duplicated logic between `decoder_decode_chunk` and `decoder_decode_chunk_dirty` NIF functions
- **Elixir DRY refactor**: Extracted `route_nif/4` helper to eliminate duplicated dirty-scheduler routing in `encode/2` and `decode/2`
- **Elixir DRY refactor**: Extracted `normalize_result/1` helper to unify error normalization across `encode/2`, `decode/2`, `encode_batch/1`, and `decode_batch/1`

### Testing

- Added stream flush test verifying extra element emission for incomplete trailing multibyte sequences
- Added stream flush test verifying no extra element when stream ends cleanly
- Added `stream_with_errors/2` flush test verifying `had_errors: true` on flushed replacement characters

## v0.2.1 (2026-01-22)

### Fixed

- Fixed precompiled binary checksums that were mismatched with release artifacts

### Documentation

- Added [Library Comparison Guide](guides/comparison.md) with benchmarks against codepagex and iconv
- Added benchmark results to README showing 3-15x performance improvement over alternatives
- Added `bench/comparison_bench.exs` benchmark suite for reproducing results

## v0.2.0 (2026-01-22)

### Added

- **Batch processing API** - Process multiple items in a single NIF call for improved throughput
  - `EncodingRs.decode_batch/1` - Decode multiple `{binary, encoding}` tuples
  - `EncodingRs.encode_batch/1` - Encode multiple `{string, encoding}` tuples
  - Always uses dirty CPU schedulers (see [Batch Processing Guide](guides/batch.md))

- **Configurable dirty threshold** - The threshold for switching to dirty schedulers is now configurable via `config.exs`:
  ```elixir
  config :encoding_rs, dirty_threshold: 128 * 1024
  ```
  Default remains 64KB. See documentation for guidance on increasing vs decreasing.

### Documentation

- Added [Batch Processing Guide](guides/batch.md) with usage examples, performance tips, and known limitations

## v0.1.0 (2026-01-22)

Initial release of `encoding_rs`, a fork of [excoding](https://github.com/elixir-ecto/excoding) with significant improvements.

### Why This Fork?

The original `excoding` package used the `encoding` Rust crate (unmaintained since 2018). This fork replaces it with `encoding_rs` - Mozilla's actively maintained encoding library used by Firefox.

### Features

- **High-performance encoding/decoding** using Rust's [encoding_rs](https://crates.io/crates/encoding_rs) library
- **Streaming decoder** (`EncodingRs.Decoder`): Stateful decoder for chunked data that properly handles multibyte characters split across chunk boundaries
  - `EncodingRs.Decoder.new/1` - Create a stateful decoder
  - `EncodingRs.Decoder.decode_chunk/3` - Decode a chunk with state preservation
  - `EncodingRs.Decoder.stream/2` - Stream transformer for use with `File.stream!/3`
- **BOM detection**: Detect encoding from Byte Order Marks
  - `detect_bom/1` - Detect BOM and return encoding name and length
  - `detect_and_strip_bom/1` - Detect and strip BOM from data
- **Dirty schedulers**: Operations on binaries >64KB use dirty CPU schedulers
- **Precompiled binaries**: Available for 10 platforms across NIF versions 2.15-2.17

### API

```elixir
# One-shot encoding/decoding
{:ok, string} = EncodingRs.decode(binary, "shift_jis")
{:ok, binary} = EncodingRs.encode(string, "windows-1252")

# Bang variants
string = EncodingRs.decode!(binary, "shift_jis")
binary = EncodingRs.encode!(string, "windows-1252")

# Streaming decoder for chunked data
File.stream!("data.txt", [], 4096)
|> EncodingRs.Decoder.stream("shift_jis")
|> Enum.join()

# BOM detection
{:ok, "UTF-8", 3} = EncodingRs.detect_bom(<<0xEF, 0xBB, 0xBF, "hello">>)

# Utilities
EncodingRs.encoding_exists?("utf-8")  # true
EncodingRs.canonical_name("latin1")   # {:ok, "windows-1252"}
EncodingRs.list_encodings()           # ["UTF-8", "Shift_JIS", ...]
```

### Supported Encodings

All encodings from the [WHATWG Encoding Standard](https://encoding.spec.whatwg.org/):
- UTF-8, UTF-16LE, UTF-16BE
- Windows code pages (874, 1250-1258)
- ISO-8859 family (1-16)
- Asian: Shift_JIS, EUC-JP, ISO-2022-JP, EUC-KR, GBK, GB18030, Big5
- And more

### Acknowledgments

- [excoding](https://github.com/elixir-ecto/excoding) - Original project by Kevin Seidel
- [encoding_rs](https://github.com/hsivonen/encoding_rs) - Mozilla's Rust encoding library
