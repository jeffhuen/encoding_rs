# EncodingRs Usage Rules

## Overview

EncodingRs is a character encoding library for converting between UTF-8 and legacy encodings (Shift_JIS, GBK, Windows-1252, etc.). It uses a Rust NIF powered by Mozilla's `encoding_rs` crate.

## When to Use Each API

### One-Shot (`encode/2`, `decode/2`)
Use for complete binaries where all data is available at once.

```elixir
{:ok, string} = EncodingRs.decode(binary, "shift_jis")
{:ok, binary} = EncodingRs.encode(string, "windows-1252")

# Includes the actual BOM-selected encoding and replacement status
{:ok, string, actual_encoding, had_errors} =
  EncodingRs.decode_with_details(binary, "shift_jis")
```

### Batch (`encode_batch/1`, `decode_batch/1`)
Use when processing many separate items for better throughput. Batch operations
apply the scheduler threshold to their combined valid input size.

```elixir
items = [{binary1, "shift_jis"}, {binary2, "gbk"}]
results = EncodingRs.decode_batch(items)
```

### Streaming (`EncodingRs.Decoder`)
Use for chunked data (file streams, network data) where multibyte characters may be split across chunks.

```elixir
File.stream!("data.txt", [], 4096)
|> EncodingRs.Decoder.stream("shift_jis")
|> Enum.join()
```

**Important:** One-shot `decode/2` on chunked data will corrupt multibyte characters split across chunk boundaries, producing replacement characters (`�`).

## Error Handling

One-shot and batch functions return tagged tuples. Pattern match on those results:

```elixir
case EncodingRs.decode(binary, encoding) do
  {:ok, string} -> process(string)
  {:error, :unknown_encoding} -> handle_error()
end
```

Use bang variants (`decode!/3`, `encode!/3`) only when errors should raise. For
non-raising incremental decoding, use `Decoder.new/2` to store options once,
then call `Decoder.decode_chunk/3`.
Use `decode_with_details/3` when malformed input or BOM overrides must not be silent.

## Encoding Labels

- Use WHATWG encoding labels: `"shift_jis"`, `"gbk"`, `"windows-1252"`, `"utf-8"`
- Labels are case-insensitive
- Use `EncodingRs.encoding_exists?/1` to validate user-provided decoding labels
- Use `EncodingRs.canonical_name/1` to normalize aliases (e.g., `"latin1"` → `"windows-1252"`)
- UTF-16LE, UTF-16BE, and `replacement` are decode-only; `encode/3` returns
  `{:error, :encoder_unavailable}` for those labels

## BOM Handling

For files that may have a Byte Order Mark:

```elixir
case EncodingRs.detect_and_strip_bom(data) do
  {:ok, encoding, data_without_bom} ->
    EncodingRs.decode(data_without_bom, encoding)
  {:error, :no_bom} ->
    EncodingRs.decode(data, default_encoding)
end
```

One-shot decoding also sniffs and removes a leading BOM automatically. Use
`decode_with_details/3` to see when the BOM selected a different encoding.

## Performance Considerations

- Operations on binaries larger than 64KB automatically use dirty schedulers; pass `dirty_threshold: bytes` to override it per operation
- Batch operations apply the threshold to their combined valid input size
- For streaming large files, use `EncodingRs.Decoder.stream/3` with reasonable chunk sizes (64KB recommended)

## Common Mistakes

1. **Using `decode/2` on streamed chunks** - Use `EncodingRs.Decoder` for chunked data
2. **Not handling `:error` tuples** - Unknown encodings return `{:error, :unknown_encoding}`
3. **Sharing decoder across processes** - Each `EncodingRs.Decoder` maintains mutable state; create one per process
4. **Forgetting `is_last: true`** - Always pass `true` for the final chunk to flush buffered bytes
5. **Encoding to UTF-16** - UTF-16 labels are decode-only; use a UTF-16 encoder when UTF-16 output is required
