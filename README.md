# EncodingRs

Character encoding and decoding for Elixir. Convert text between UTF-8 and legacy encodings like Shift_JIS, GBK, Big5, EUC-KR, Windows-1252, and 200+ others.

Powered by Rust's [encoding_rs](https://crates.io/crates/encoding_rs) - the same encoding library used by Firefox.

## Use Cases

- **Processing Japanese text files** - Shift_JIS, EUC-JP, ISO-2022-JP
- **Processing Chinese text files** - GBK, GB18030, Big5, HZ
- **Processing Korean text files** - EUC-KR
- **Importing legacy data** - Windows-1252, ISO-8859-1, legacy code pages
- **Web scraping non-UTF-8 sites** - decode HTML in any encoding
- **Converting file encodings** - batch convert legacy files to UTF-8
- **Reading CSV/text with mixed encodings** - detect and decode automatically

## Supported Encodings

**Japanese**: Shift_JIS, EUC-JP, ISO-2022-JP

**Chinese**: GBK, GB18030, Big5, HZ

**Korean**: EUC-KR

**Unicode**: UTF-8, UTF-16LE, UTF-16BE

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

## Features

- **High performance** - SIMD-optimized Rust NIF, 2-3x faster than pure Elixir alternatives
- **Batch processing** - encode/decode multiple items in a single NIF call for throughput
- **Streaming decoder** - handle large files and chunked data without corrupting multibyte characters
- **BOM detection** - automatically detect UTF-8, UTF-16LE, UTF-16BE from byte order marks
- **WHATWG compliant** - implements the [Encoding Standard](https://encoding.spec.whatwg.org/) used by browsers
- **Precompiled binaries** - no Rust toolchain required for common platforms
- **Dirty schedulers** - configurable threshold for offloading large operations (default 64KB)

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

The BEAM VM has a limited number of normal schedulers, and long-running NIFs can block them, causing latency for other processes. Operations on binaries larger than the configured threshold automatically use dirty CPU schedulers, keeping the normal schedulers available for other work.

The default threshold is 64KB. You can configure it in your `config.exs`:

```elixir
# Using multiplication for readability
config :encoding_rs, dirty_threshold: 128 * 1024

# Or using Elixir's underscore notation
config :encoding_rs, dirty_threshold: 131_072
```

**Increasing the threshold** reduces context switching overhead, which benefits batch processing and throughput-focused workloads. However, larger operations will block normal schedulers longer, potentially causing latency for other processes.

**Decreasing the threshold** keeps normal schedulers more available, which benefits latency-sensitive and high-concurrency applications. However, more frequent context switching adds overhead that may reduce throughput.

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
