# EncodingRs

[![Hex.pm](https://img.shields.io/hexpm/v/encoding_rs.svg)](https://hex.pm/packages/encoding_rs)
[![Hex Docs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/encoding_rs)
[![CI](https://github.com/jeffhuen/encoding_rs/actions/workflows/ci.yml/badge.svg)](https://github.com/jeffhuen/encoding_rs/actions/workflows/ci.yml)
[![License](https://img.shields.io/hexpm/l/encoding_rs.svg)](https://github.com/jeffhuen/encoding_rs/blob/main/LICENSE)
[![Powered by encoding_rs](https://img.shields.io/badge/powered%20by-encoding__rs-orange.svg)](https://crates.io/crates/encoding_rs)

Character encoding conversion and detection for Elixir. Convert text between UTF-8 and legacy encodings such as Shift_JIS, GBK, Big5, EUC-KR, and Windows-1252. Decodes all 40 encodings in the WHATWG Encoding Standard (with 200+ label aliases), encodes their 37 output encodings, and detects unlabeled byte streams heuristically.

Powered by Mozilla's [encoding_rs](https://github.com/hsivonen/encoding_rs) and [chardetng](https://github.com/hsivonen/chardetng) Rust crates.

## Features

- **Fast Rust NIF**: Uses `encoding_rs` with `fast-legacy-encode` and `simdutf8`, 3x to 15x faster than pure Elixir and C iconv bindings (see [benchmarks](#benchmarks)).
- **Streaming decoding and encoding**: `EncodingRs.Decoder` and `EncodingRs.Encoder` preserve multibyte and shift state across arbitrary byte chunk boundaries.
- **Encoding detection**: `EncodingRs.detect/2` and `EncodingRs.Detector` detect UTF-8/UTF-16 BOMs and guess unlabeled legacy encodings with `chardetng`.
- **Strict and replacing error modes**: Choose WHATWG replacement (`on_error: :replace`, default) or strict failure (`on_error: :error`), or inspect replacements with `decode_with_details/3` and `encode_with_details/3`.
- **BOM control**: Configure `bom: :sniff`, `bom: :strip`, or `bom: :preserve` on decode operations and streaming decoders.
- **Batch processing**: Process lists of items in one NIF call to amortize dispatch overhead.
- **Precompiled binaries**: Ships prebuilt NIFs for 10 targets across NIF versions `2.15`, `2.16`, `2.17`, and `2.18` (Erlang/OTP 24 through 29).
- **Dirty schedulers**: Operations larger than `:dirty_threshold` (default 64 KB) automatically run on dirty CPU schedulers.

## Supported encodings

- **Japanese**: Shift_JIS, EUC-JP, ISO-2022-JP
- **Chinese**: GBK, gb18030, Big5
- **Korean**: EUC-KR
- **Unicode**: UTF-8; UTF-16LE and UTF-16BE (decode only)
- **Western European**: windows-1252, ISO-8859-1 (alias for windows-1252), ISO-8859-15, macintosh
- **Central and Eastern European**: windows-1250, ISO-8859-2, windows-1257
- **Cyrillic**: windows-1251, KOI8-R, KOI8-U, ISO-8859-5, IBM866, x-mac-cyrillic
- **Greek**: windows-1253, ISO-8859-7
- **Turkish**: windows-1254, ISO-8859-9
- **Hebrew**: windows-1255, ISO-8859-8, ISO-8859-8-I
- **Arabic**: windows-1256, ISO-8859-6
- **Vietnamese**: windows-1258
- **Thai**: windows-874
- **Baltic**: ISO-8859-4, ISO-8859-13

See the full list of names and aliases at [encoding.spec.whatwg.org](https://encoding.spec.whatwg.org/#names-and-labels), or call `EncodingRs.list_encodings/0` and `EncodingRs.list_output_encodings/0`.

UTF-16LE, UTF-16BE, and `replacement` are decode-only in the WHATWG Encoding Standard. Encoding with those labels returns `{:error, :encoder_unavailable}`. To produce UTF-16 bytes in Elixir, use Erlang's built-in `:unicode.characters_to_binary(string, :utf8, {:utf16, :little})` or `{:utf16, :big}`.

## Installation

Add `encoding_rs` to your dependencies in `mix.exs` (requires Elixir 1.16 or newer):

```elixir
def deps do
  [
    {:encoding_rs, "~> 0.5.0"}
  ]
end
```

Upgrading from an older version? Follow the [0.4 to 0.5 migration guide](guides/migrating-0.4-to-0.5.md) (or the [0.3 to 0.4 guide](guides/migrating-0.3-to-0.4.md) and [0.2 to 0.3 guide](guides/migrating-0.2-to-0.3.md) first).

Precompiled binaries download automatically on supported platforms. If no precompiled binary matches your target, install Rust via [rustup](https://rustup.rs/) and set `ENCODING_RS_BUILD=true`.

## Usage

### One-shot decoding and encoding

Use one-shot functions when the entire binary is already in memory:

```elixir
# Decode from Shift_JIS to UTF-8
{:ok, string} = EncodingRs.decode(binary, "shift_jis")
string = EncodingRs.decode!(binary, "shift_jis")

# Reject malformed bytes instead of substituting U+FFFD
{:error, :malformed_input} = EncodingRs.decode(<<0xFF>>, "utf-8", on_error: :error)

# Control BOM handling (:sniff default, :strip, or :preserve)
{:ok, "\uFEFFhi"} = EncodingRs.decode(<<0xEF, 0xBB, 0xBF, "hi">>, "utf-8", bom: :preserve)

# Observe BOM overrides and replacement errors
{:ok, string, actual_encoding, had_errors} =
  EncodingRs.decode_with_details(binary, "shift_jis")

# Encode from UTF-8 to Windows-1252
{:ok, binary} = EncodingRs.encode(string, "windows-1252")
binary = EncodingRs.encode!(string, "windows-1252")

# Observe or reject unmappable characters (default replaces with HTML references like "&#127881;")
{:ok, "&#127881;", true} = EncodingRs.encode_with_details("🎉", "windows-1252")
{:error, :unmappable_character} = EncodingRs.encode("🎉", "windows-1252", on_error: :error)

# Inspect labels and availability
EncodingRs.encoding_exists?("utf-16le") # true
EncodingRs.can_encode?("utf-16le")      # false
EncodingRs.canonical_name("latin1")     # {:ok, "windows-1252"}
EncodingRs.output_encoding("utf-16le")  # {:ok, "UTF-8"}
EncodingRs.available?()                 # true
```

### Streaming decoding and encoding

Use `EncodingRs.Decoder` and `EncodingRs.Encoder` for large files and chunked streams so multibyte sequences and shift states survive chunk boundaries:

```elixir
# Raising stream pipeline
File.stream!("data.txt", [], 64 * 1024)
|> EncodingRs.Decoder.stream!("shift_jis")
|> Enum.join()

# Non-raising stream pipeline (emits {:ok, chunk} or {:error, reason})
File.stream!("data.txt", [], 64 * 1024)
|> EncodingRs.Decoder.stream("shift_jis", on_error: :error)
|> Enum.reduce_while([], fn
  {:ok, chunk}, acc -> {:cont, [chunk | acc]}
  {:error, reason}, _acc -> {:halt, {:error, reason}}
end)

# Streaming transcode from Shift_JIS to ISO-2022-JP
File.stream!("input.txt", [], 64 * 1024)
|> EncodingRs.Decoder.stream!("shift_jis")
|> EncodingRs.Encoder.stream!("iso-2022-jp")
|> Stream.into(File.stream!("output.txt"))
|> Stream.run()
```

See the [Streaming Guide](guides/streaming.md) for manual chunk loops, BOM options, and error tracking.

### Encoding and BOM detection

Detect a leading BOM explicitly or let `EncodingRs.detect/2` combine BOM checks with `chardetng` heuristics:

```elixir
# One-shot detection (BOM first, then chardetng heuristics)
{:ok, "Shift_JIS"} = EncodingRs.detect(japanese_bytes, tld: "jp")
{:ok, "ISO-2022-JP"} = EncodingRs.detect(email_bytes, allow_iso_2022_jp: true)

# Streaming detection over the first few chunks of a large file
{:ok, encoding} =
  File.stream!("unknown.txt", [], 64 * 1024)
  |> Stream.take(4)
  |> EncodingRs.Detector.detect_stream(tld: "jp")

# Explicit BOM inspection
{:ok, "UTF-8", 3} = EncodingRs.detect_bom(<<0xEF, 0xBB, 0xBF, "hello">>)
{:ok, encoding, rest} = EncodingRs.detect_and_strip_bom(file_content)
```

### Batch processing

Process many items in one NIF call to amortize dispatch overhead:

```elixir
EncodingRs.decode_batch([
  {<<72, 101, 108, 108, 111>>, "windows-1252"},
  {<<0x82, 0xA0>>, "shift_jis"}
])
# => [{:ok, "Hello"}, {:ok, "あ"}]

EncodingRs.encode_batch_with_details([
  {"Hello", "windows-1252"},
  {"🎉", "windows-1252"}
])
# => [{:ok, "Hello", false}, {:ok, "&#127881;", true}]
```

See the [Batch Processing Guide](guides/batch.md) for options and performance notes.

## Dirty schedulers and input size limits

Operations on binaries larger than `:dirty_threshold` (default 64 KB) run on dirty CPU schedulers so long conversions do not block normal BEAM schedulers. Batch operations apply the threshold to the combined size of valid items.

To protect against memory exhaustion on untrusted inputs, every input, batch item, and stream chunk enforces `:max_input_size` (default 100 MB). Oversized inputs return `{:error, :input_too_large}` before entering the NIF. Pass options per call, stream, decoder, encoder, or detector:

```elixir
EncodingRs.decode(data, "shift_jis",
  dirty_threshold: 128 * 1024,
  max_input_size: 10 * 1024 * 1024
)

# Disable the limit only for trusted inputs bounded elsewhere
EncodingRs.decode(data, "utf-8", max_input_size: :infinity)
```

## Benchmarks

Comparison against `codepagex` (pure Elixir) and `iconv` (Erlang NIF wrapping libiconv) on Apple Silicon M1:

| Encoding | Input size | encoding_rs | codepagex | iconv |
|----------|------------|-------------|-----------|-------|
| ISO-8859-1 | 100 B | 347 ns | 487 ns (1.4x) | 2.0 us (5.6x) |
| ISO-8859-1 | 10 KB | 9.2 us | 118 us (13x) | 130 us (14x) |
| ISO-8859-1 | 1 MB | 3.0 ms | 12.6 ms (4x) | 13.1 ms (4x) |
| Shift_JIS | 10 KB | 13 us | N/A | 196 us (15x) |

Version 0.5 also enables `encoding_rs`'s `fast-legacy-encode` tables for 5.5x to 44x faster CJK encoding on Shift_JIS, EUC-JP, GBK, Big5, and EUC-KR. See the [Library Comparison Guide](guides/comparison.md) for methodology and trade-offs.

## Acknowledgments

- [excoding](https://github.com/elixir-ecto/excoding): Original project by Kevin Seidel
- [encoding_rs](https://github.com/hsivonen/encoding_rs): Mozilla's WHATWG encoding library
- [chardetng](https://github.com/hsivonen/chardetng): Mozilla's legacy encoding detector

## License

MIT License. See [LICENSE](https://github.com/jeffhuen/encoding_rs/blob/main/LICENSE) for details.
