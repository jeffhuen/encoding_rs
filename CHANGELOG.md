# Changelog

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
