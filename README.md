# EncodingRs

High-performance character encoding/decoding for Elixir, powered by Rust's [encoding_rs](https://crates.io/crates/encoding_rs) library.

## Why This Fork?

This is a fork of [excoding](https://github.com/elixir-ecto/excoding) that replaces the underlying Rust `encoding` crate with `encoding_rs` - the same battle-tested encoding library used by Firefox.

### Key Improvements

| Feature | Original excoding | EncodingRs |
|---------|-------------------|------------|
| **Rust backend** | `encoding` crate (unmaintained since 2018) | `encoding_rs` (actively maintained, used by Firefox) |
| **Performance** | Good | ~2-3x faster for large files |
| **Streaming** | Not supported | `EncodingRs.Decoder` for chunked data |
| **BOM detection** | Not supported | `detect_bom/1`, `detect_and_strip_bom/1` |
| **Precompiled** | No | Yes, for 10 platforms |

### Why encoding_rs?

- **Battle-tested**: Powers Firefox's character encoding - billions of page loads
- **WHATWG compliant**: Implements the [Encoding Standard](https://encoding.spec.whatwg.org/) used by all browsers
- **Performance**: SIMD-optimized, faster than most encoding libraries
- **Maintained**: Active development by Mozilla engineers

## Supported Encodings

- **Unicode**: UTF-8, UTF-16LE, UTF-16BE
- **Legacy Western**: Windows-1252, ISO-8859-1 through ISO-8859-16
- **Asian**: Shift_JIS, EUC-JP, ISO-2022-JP, EUC-KR, GBK, GB18030, Big5
- **Other**: Windows code pages (874, 1250-1258), KOI8-R/U, and more

See the full list at [encoding.spec.whatwg.org](https://encoding.spec.whatwg.org/#names-and-labels).

## Installation

```elixir
def deps do
  [
    {:encoding_rs, "~> 0.2"}
  ]
end
```

The module is still named `EncodingRs` for API compatibility with the original package.

Precompiled binaries are available for common platforms. If a precompiled binary isn't available for your platform, you'll need Rust installed (use [rustup](https://rustup.rs/)).

## Usage

### One-Shot Encoding/Decoding

For complete binaries where all data is available at once:

```elixir
# Decode from Shift_JIS to UTF-8
{:ok, string} = EncodingRs.decode(binary, "shift_jis")
string = EncodingRs.decode!(binary, "shift_jis")

# Encode from UTF-8 to Windows-1252
{:ok, binary} = EncodingRs.encode(string, "windows-1252")
binary = EncodingRs.encode!(string, "windows-1252")

# Check if encoding is supported
EncodingRs.encoding_exists?("utf-8")  # true

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
{:ok, decoder} = EncodingRs.Decoder.new("shift_jis")
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

## Dirty Schedulers

Operations on binaries larger than 64KB automatically use dirty CPU schedulers to avoid blocking the BEAM.

## Migrating from excoding

If you're switching from the original `excoding` package:

1. Update your dependency:
   ```elixir
   # Before
   {:excoding, "~> 0.1"}

   # After
   {:encoding_rs, "~> 0.2"}
   ```

2. That's it! The module name is still `EncodingRs`, so your code works unchanged.

## Acknowledgments

- [excoding](https://github.com/elixir-ecto/excoding) - The original project by Kevin Seidel
- [encoding_rs](https://github.com/nickel-rs/encoding_rs) - Mozilla's Rust encoding library

## License

MIT License - see LICENSE file for details.
