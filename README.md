# EncodingRs

[![Hex.pm](https://img.shields.io/hexpm/v/encoding_rs.svg)](https://hex.pm/packages/encoding_rs)
[![Hex Docs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/encoding_rs)
[![CI](https://github.com/jeffhuen/encoding_rs/actions/workflows/ci.yml/badge.svg)](https://github.com/jeffhuen/encoding_rs/actions/workflows/ci.yml)
[![License](https://img.shields.io/hexpm/l/encoding_rs.svg)](https://github.com/jeffhuen/encoding_rs/blob/main/LICENSE)
[![Powered by encoding_rs](https://img.shields.io/badge/powered%20by-encoding__rs-orange.svg)](https://crates.io/crates/encoding_rs)

Character encoding and decoding for Elixir. Convert text between UTF-8 and legacy encodings like Shift_JIS, GBK, Big5, EUC-KR, Windows-1252, and more. Decodes all 40 encodings from the WHATWG Encoding Standard (with 200+ label aliases) and encodes its output encodings.

Powered by Rust's [encoding_rs](https://crates.io/crates/encoding_rs) - the same encoding library used by Firefox.

## Use Cases

- **Processing Japanese text files** - Shift_JIS, EUC-JP, ISO-2022-JP
- **Processing Chinese text files** - GBK, GB18030, Big5
- **Processing Korean text files** - EUC-KR
- **Importing legacy data** - Windows-1252, ISO-8859-1, legacy code pages
- **Web scraping non-UTF-8 sites** - decode HTML in any encoding
- **Converting file encodings** - batch convert legacy files to UTF-8

## Supported Encodings

**Japanese**: Shift_JIS, EUC-JP, ISO-2022-JP

**Chinese**: GBK, GB18030, Big5

**Korean**: EUC-KR

**Unicode**: UTF-8; UTF-16LE and UTF-16BE (decode only)

**Western European**: Windows-1252, ISO-8859-1, ISO-8859-15, macintosh

**Central/Eastern European**: Windows-1250, ISO-8859-2, Windows-1257

**Cyrillic**: Windows-1251, KOI8-R, KOI8-U, ISO-8859-5, x-mac-cyrillic

**Greek**: Windows-1253, ISO-8859-7

**Turkish**: Windows-1254, ISO-8859-9

**Hebrew**: Windows-1255, ISO-8859-8

**Arabic**: Windows-1256, ISO-8859-6

**Vietnamese**: Windows-1258

**Thai**: Windows-874

**Baltic**: ISO-8859-4, ISO-8859-13

And more - see the full list at [encoding.spec.whatwg.org](https://encoding.spec.whatwg.org/#names-and-labels).

UTF-16LE, UTF-16BE, and `replacement` are decode-only in the WHATWG standard. Encoding with one of those labels returns `{:error, :encoder_unavailable}` instead of silently emitting UTF-8.

## Features

- **High performance** - SIMD-optimized Rust NIF, 3-15x faster than alternatives (see [benchmarks](#benchmarks))
- **Batch processing** - encode/decode multiple items in a single NIF call for throughput
- **Streaming decoder** - handle large files and chunked data without corrupting multibyte characters
- **BOM detection** - automatically detect UTF-8, UTF-16LE, UTF-16BE from byte order marks
- **WHATWG compliant** - implements the [Encoding Standard](https://encoding.spec.whatwg.org/) used by browsers
- **Precompiled binaries** - no Rust toolchain required for common platforms
- **Dirty schedulers** - per-call threshold for offloading large operations (default 64KB)

## Installation

```elixir
def deps do
  [
    {:encoding_rs, "~> 0.3.0"}
  ]
end
```

Upgrading from 0.2? See the [0.2 to 0.3 migration guide](guides/migrating-0.2-to-0.3.md).

The module is still named `EncodingRs` for API compatibility with the original package.

Precompiled binaries are available for common platforms. If a precompiled binary isn't available for your platform, you'll need Rust installed (use [rustup](https://rustup.rs/)).

## Usage

### One-Shot Encoding/Decoding

For complete binaries where all data is available at once:

```elixir
# Decode from Shift_JIS to UTF-8
{:ok, string} = EncodingRs.decode(binary, "shift_jis")
string = EncodingRs.decode!(binary, "shift_jis")

# Observe malformed input and any encoding selected by a BOM
{:ok, string, actual_encoding, had_errors} =
  EncodingRs.decode_with_details(binary, "shift_jis")

# Encode from UTF-8 to Windows-1252
{:ok, binary} = EncodingRs.encode(string, "windows-1252")
binary = EncodingRs.encode!(string, "windows-1252")

# Check if a decoding label is recognized
EncodingRs.encoding_exists?("utf-8")  # true

# Check whether the native implementation loaded
EncodingRs.available?()  # true

# Get canonical name for an alias
EncodingRs.canonical_name("latin1")  # {:ok, "windows-1252"}
```

### Streaming Decoding

For chunked data (file streams, network data), use `EncodingRs.Decoder` to properly handle multibyte characters that may be split across chunk boundaries:

```elixir
# Stream a Shift_JIS file to UTF-8
File.stream!("data.txt", [], 4096)
|> EncodingRs.Decoder.stream("shift_jis")
|> Enum.join()

# Manual chunked decoding
{:ok, decoder} =
  EncodingRs.Decoder.new("shift_jis", max_input_size: 256 * 1024)
{:ok, out1, _errors} = EncodingRs.Decoder.decode_chunk(decoder, chunk1, false)
{:ok, out2, _errors} = EncodingRs.Decoder.decode_chunk(decoder, chunk2, false)
{:ok, out3, _errors} = EncodingRs.Decoder.decode_chunk(decoder, final_chunk, true)
result = out1 <> out2 <> out3
```

**Why streaming matters**: Multibyte encodings like Shift_JIS use 2+ bytes per character. If a chunk boundary splits a character, the one-shot `decode/2` would see invalid bytes and produce replacement characters (`�`). The streaming decoder buffers incomplete sequences until the next chunk completes them.

### BOM Detection

Detect encoding from a Byte Order Mark (BOM) at the start of a file:

```elixir
# Detect BOM and get encoding
{:ok, "UTF-8", 3} = EncodingRs.detect_bom(<<0xEF, 0xBB, 0xBF, "hello">>)
{:ok, "UTF-16LE", 2} = EncodingRs.detect_bom(<<0xFF, 0xFE, ...>>)
{:ok, "UTF-16BE", 2} = EncodingRs.detect_bom(<<0xFE, 0xFF, ...>>)
{:error, :no_bom} = EncodingRs.detect_bom("no bom here")

# Detect and strip BOM in one step
{:ok, encoding, data_without_bom} = EncodingRs.detect_and_strip_bom(file_content)
{:ok, decoded} = EncodingRs.decode(data_without_bom, encoding)
```

One-shot decoding honors a leading BOM even when it differs from the requested label. Use `EncodingRs.decode_with_details/3` to observe the encoding that was actually selected.

### Batch Processing

For processing many items efficiently, use batch operations to amortize NIF dispatch overhead:

```elixir
# Decode multiple binaries in one call
items = [
  {<<72, 101, 108, 108, 111>>, "windows-1252"},
  {<<0x82, 0xA0>>, "shift_jis"}
]
results = EncodingRs.decode_batch(items)
# => [{:ok, "Hello"}, {:ok, "あ"}]

# Encode multiple strings in one call
items = [{"Hello", "windows-1252"}, {"あ", "shift_jis"}]
results = EncodingRs.encode_batch(items)
# => [{:ok, "Hello"}, {:ok, <<130, 160>>}]
```

See the [Batch Processing Guide](guides/batch.md) for more details.

## Dirty Schedulers

The BEAM VM has a limited number of normal schedulers, and long-running NIFs can block them, causing latency for other processes. Operations on binaries larger than the selected threshold automatically use dirty CPU schedulers, keeping the normal schedulers available for other work.

The default threshold is 64KB. Override it for a specific operation:

```elixir
EncodingRs.decode(data, "shift_jis", dirty_threshold: 128 * 1024)
```

Batch operations compare the threshold with the combined size of valid items.

**Increasing the threshold** reduces context switching overhead, which benefits batch processing and throughput-focused workloads. However, larger operations will block normal schedulers longer, potentially causing latency for other processes.

**Decreasing the threshold** keeps normal schedulers more available, which benefits latency-sensitive and high-concurrency applications. However, more frequent context switching adds overhead that may reduce throughput.

## Maximum Input Size

To prevent excessive memory allocation from untrusted or unexpectedly large inputs, encoding and decoding operations enforce a maximum input size. Inputs exceeding this limit return `{:error, :input_too_large}` before reaching the NIF. Batch operations reject oversized items individually — valid items in the same batch still succeed.

The default limit is **100MB**. Override it explicitly per operation:

```elixir
# Increase the limit
EncodingRs.decode(data, "utf-8", max_input_size: 500 * 1024 * 1024)

# Disable entirely (trusted inputs only)
EncodingRs.decode(data, "utf-8", max_input_size: :infinity)

# Batch and streaming APIs accept the same option
EncodingRs.decode_batch(items, max_input_size: 10 * 1024 * 1024)
EncodingRs.Decoder.stream(chunks, "shift_jis", max_input_size: 256 * 1024)
```

Existing `config :encoding_rs` values remain supported for compatibility, but
explicit options are preferred for library-safe configuration.

**Why a size limit?** A single large input can cause up to 3x memory amplification in the NIF (input buffer + output buffer + BEAM binary copy). A 500MB input could transiently allocate over 1.5GB, potentially destabilizing the BEAM node even on a dirty scheduler.

**For large files**, use the streaming decoder (`EncodingRs.Decoder.stream/3`) with bounded chunk sizes instead of loading the entire file into memory. Each chunk is validated independently.

## Benchmarks

Comparison against `codepagex` (pure Elixir) and `iconv` (Erlang NIF wrapping libiconv):

| Encoding | Input Size | encoding_rs | codepagex | iconv |
|----------|------------|-------------|-----------|-------|
| ISO-8859-1 | 100 B | 347 ns | 487 ns (1.4x) | 2.0 μs (5.6x) |
| ISO-8859-1 | 10 KB | 9.2 μs | 118 μs (13x) | 130 μs (14x) |
| ISO-8859-1 | 1 MB | 3.0 ms | 12.6 ms (4x) | 13.1 ms (4x) |
| Shift_JIS | 10 KB | 13 μs | N/A | 196 μs (15x) |

*Benchmarks on Apple Silicon M1. See [comparison guide](guides/comparison.md) for full methodology, more encodings, and when to use each library.*

## Quick Start

```elixir
# Decode a Shift_JIS file to UTF-8
{:ok, content} = File.read("japanese.txt")
{:ok, utf8_string} = EncodingRs.decode(content, "shift_jis")

# Encode a UTF-8 string to Windows-1252
{:ok, binary} = EncodingRs.encode("Hello world", "windows-1252")
```

## Acknowledgments

- [excoding](https://github.com/elixir-ecto/excoding) - The original project by Kevin Seidel
- [encoding_rs](https://github.com/nickel-rs/encoding_rs) - Mozilla's Rust encoding library

## License

MIT License - see LICENSE file for details.
