# Library Comparison

A comparison of Elixir character encoding libraries: `encoding_rs`, `codepagex`, and `iconv`.

## Feature Comparison

| Feature | encoding_rs | codepagex | iconv |
|---------|-------------|-----------|-------|
| Implementation | Rust NIF | Pure Elixir | Erlang NIF (C) |
| Encoding Support | 40 encodings, 200+ aliases (WHATWG) | ~50 | System-dependent |
| Streaming API | ✅ Yes | ❌ No | ❌ No |
| Batch Operations | ✅ Yes | ❌ No | ❌ No |
| BOM Detection | ✅ Yes | ❌ No | ❌ No |
| Precompiled Binaries | ✅ Yes | N/A | ❌ No |
| Native Dependencies | Optional (Rust) | None | Required (libiconv) |
| WHATWG Compliant | ✅ Yes | ❌ No | ❌ No |
| Dirty Scheduler Support | ✅ Yes | N/A | ❌ No |

## Benchmark Results

Run the benchmarks yourself by temporarily adding these dev dependencies to `mix.exs`:

```elixir
# In deps(), add:
{:benchee, "~> 1.0", only: :dev},
{:benchee_html, "~> 1.0", only: :dev},
{:codepagex, "~> 0.1", only: :dev},
{:iconv, "~> 1.0", only: :dev}
```

Then run:

```bash
mix deps.get
mix run bench/comparison_bench.exs
open bench/output/*.html  # View interactive HTML reports
```

### Methodology

**Library versions tested:** encoding_rs 0.2.0, codepagex 0.1.13, iconv 1.0.14

The benchmarks use encoding-specific character sets to ensure fair comparison:
- **iso-8859-1**: 60% ASCII + 40% Latin-1 supplement (accented chars)
- **shift_jis**: 40% ASCII + 30% Hiragana + 30% Katakana
- **utf-16le**: 40% ASCII + 20% Latin-1 + 20% Hiragana + 20% CJK

This ensures all characters can be encoded without replacement, exercising realistic code paths.

### Expected Performance Characteristics

- **encoding_rs**: Fastest across all input sizes due to Rust's SIMD optimizations. Uses dirty schedulers for large data to avoid blocking the BEAM.

- **codepagex**: Competitive for small inputs (~100 bytes) where NIF call overhead is significant. Slower for larger data due to pure Elixir implementation.

- **iconv**: Consistently slower than encoding_rs. C implementation adds more overhead than Rust NIF approach.

### Benchmark Results (Apple Silicon M1)

**ISO-8859-1 (Western European) - All three libraries:**

| Operation | Input Size | encoding_rs | codepagex | iconv | encoding_rs vs others |
|-----------|------------|-------------|-----------|-------|----------------------|
| Encode | 100 B | 426 ns | 531 ns | 2.2 μs | 1.2x / 5.2x faster |
| Encode | 10 KB | 20 μs | 144 μs | 152 μs | 7x faster |
| Encode | 1 MB | 5.6 ms | 15 ms | 15.6 ms | 2.7x faster |
| Decode | 100 B | 347 ns | 487 ns | 2.0 μs | 1.4x / 5.6x faster |
| Decode | 10 KB | 9.2 μs | 118 μs | 130 μs | 13-14x faster |
| Decode | 1 MB | 3.0 ms | 12.6 ms | 13.1 ms | 4.2-4.4x faster |

**Shift_JIS (Japanese) - encoding_rs vs iconv:**

| Operation | Input Size | encoding_rs | iconv | Speedup |
|-----------|------------|-------------|-------|---------|
| Encode | 100 B | 0.50 μs | 3.7 μs | 7.4x |
| Encode | 10 KB | 32 μs | 451 μs | 14x |
| Encode | 1 MB | 6.2 ms | 46 ms | 7.5x |
| Decode | 100 B | 0.35 μs | 2.3 μs | 6.5x |
| Decode | 10 KB | 13 μs | 196 μs | 15x |
| Decode | 1 MB | 3.4 ms | 21 ms | 6.3x |

**UTF-16LE - encoding_rs vs iconv:**

| Operation | Input Size | encoding_rs | iconv | Speedup |
|-----------|------------|-------------|-------|---------|
| Encode | 100 B | 0.31 μs | 1.8 μs | 5.8x |
| Encode | 10 KB | 7.7 μs | 116 μs | 15x |
| Encode | 1 MB | 2.8 ms | 11.9 ms | 4.2x |
| Decode | 100 B | 0.33 μs | 1.7 μs | 5.1x |
| Decode | 10 KB | 8.1 μs | 98 μs | 12x |
| Decode | 1 MB | 0.83 ms | 10.4 ms | 12.5x |

*Run `mix run bench/comparison_bench.exs` to generate results for your system.*

## Pros and Cons

### encoding_rs

**Pros:**
- **Fastest performance** - Rust NIF with SIMD optimizations
- **WHATWG compliant** - Same behavior as web browsers
- **Streaming support** - Handle chunked data with stateful decoder
- **Batch operations** - Process multiple items efficiently
- **BOM detection** - Automatic byte order mark handling
- **Firefox-tested** - Battle-tested in Mozilla's browser
- **Precompiled binaries** - No Rust toolchain needed for most platforms
- **Dirty scheduler aware** - Won't block the BEAM with large data

**Cons:**
- Requires precompiled binary or Rust toolchain
- Larger dependency footprint than pure Elixir
- NIF crashes can take down the BEAM VM

### codepagex

**Pros:**
- **Pure Elixir** - No native dependencies at all
- **Simple installation** - Just add to mix.exs
- **Predictable behavior** - No NIF edge cases
- **Safe** - Can't crash the BEAM VM

**Cons:**
- Significantly slower than NIF-based solutions
- Limited encoding support (~50 encodings)
- No streaming API for chunked data
- No batch operations
- Not WHATWG compliant

### iconv

**Pros:**
- **Fast** - C-based implementation
- **Wide encoding support** - Whatever system iconv supports
- **Mature** - Well-tested libiconv library

**Cons:**
- **System dependency** - Requires libiconv installed
- **No streaming API** - Can't handle chunked data
- **Platform variance** - Different behavior across systems
- **No precompiled binaries** - Must compile on install
- **No dirty scheduler support** - Can block BEAM with large data

## When to Use Each Library

### Use encoding_rs when:
- Performance is critical
- Processing large files or high throughput
- Need streaming support for chunked data
- Batch processing multiple encodings
- WHATWG compliance matters (web content)
- Processing CJK encodings (Shift_JIS, GBK, Big5, etc.)

### Use codepagex when:
- No native dependencies allowed
- Only need basic Western encodings
- Processing small amounts of data
- Deployment environment is restrictive
- BEAM stability is paramount

### Use iconv when:
- Need encodings not in WHATWG standard
- Already have libiconv as a dependency
- System-native behavior is preferred
- Legacy system compatibility

## API Comparison

### Decoding

```elixir
# encoding_rs
{:ok, utf8} = EncodingRs.decode(binary, "windows-1252")

# codepagex
utf8 = Codepagex.to_string!(binary, :iso_8859_1)

# iconv
utf8 = :iconv.convert("WINDOWS-1252", "UTF-8", binary)
```

### Encoding

```elixir
# encoding_rs
{:ok, encoded} = EncodingRs.encode(utf8, "windows-1252")

# codepagex
encoded = Codepagex.from_string!(utf8, :iso_8859_1)

# iconv
encoded = :iconv.convert("UTF-8", "WINDOWS-1252", utf8)
```

### Streaming (encoding_rs only)

```elixir
# Create decoder for chunked data
decoder = EncodingRs.Decoder.new("shift_jis")

# Process chunks (handles split multibyte characters)
{:ok, chunk1, decoder} = EncodingRs.Decoder.decode_chunk(decoder, data1)
{:ok, chunk2, decoder} = EncodingRs.Decoder.decode_chunk(decoder, data2)
{:ok, final} = EncodingRs.Decoder.finish(decoder)
```

### Batch Operations (encoding_rs only)

```elixir
# Decode multiple items in one call
items = [
  {"data1", "windows-1252"},
  {"data2", "shift_jis"},
  {"data3", "utf-16le"}
]
results = EncodingRs.decode_batch(items)
```

## Summary

| Priority | Recommended Library |
|----------|---------------------|
| Maximum performance | encoding_rs |
| No native dependencies | codepagex |
| System compatibility | iconv |
| Streaming/chunked data | encoding_rs |
| Web content processing | encoding_rs |
| Legacy system support | iconv |
