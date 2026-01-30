# Changelog

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
- [encoding_rs](https://github.com/nickel-rs/encoding_rs) - Mozilla's Rust encoding library
