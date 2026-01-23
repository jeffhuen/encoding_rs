# EncodingRs Usage Rules

## Overview

EncodingRs is a character encoding library for converting between UTF-8 and legacy encodings (Shift_JIS, GBK, Windows-1252, etc.). It uses a Rust NIF powered by Mozilla's `encoding_rs` crate.

## When to Use Each API

### One-Shot (`encode/2`, `decode/2`)
Use for complete binaries where all data is available at once.

```elixir
{:ok, string} = EncodingRs.decode(binary, "shift_jis")
{:ok, binary} = EncodingRs.encode(string, "windows-1252")
```

### Batch (`encode_batch/1`, `decode_batch/1`)
Use when processing many separate items for better throughput. Batch operations always use dirty schedulers.

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

All functions return tagged tuples. Always pattern match on results:

```elixir
case EncodingRs.decode(binary, encoding) do
  {:ok, string} -> process(string)
  {:error, :unknown_encoding} -> handle_error()
end
```

Use bang variants (`decode!/2`, `encode!/2`) only when you're certain the encoding is valid.

## Encoding Labels

- Use WHATWG encoding labels: `"shift_jis"`, `"gbk"`, `"windows-1252"`, `"utf-8"`
- Labels are case-insensitive
- Use `EncodingRs.encoding_exists?/1` to validate user-provided encodings
- Use `EncodingRs.canonical_name/1` to normalize aliases (e.g., `"latin1"` → `"windows-1252"`)

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

## Performance Considerations

- Operations on binaries larger than 64KB automatically use dirty schedulers (configurable via `config :encoding_rs, dirty_threshold: bytes`)
- Batch operations always use dirty schedulers regardless of size
- For streaming large files, use `EncodingRs.Decoder.stream/2` with reasonable chunk sizes (64KB recommended)

## Common Mistakes

1. **Using `decode/2` on streamed chunks** - Use `EncodingRs.Decoder` for chunked data
2. **Not handling `:error` tuples** - Unknown encodings return `{:error, :unknown_encoding}`
3. **Sharing decoder across processes** - Each `EncodingRs.Decoder` maintains mutable state; create one per process
4. **Forgetting `is_last: true`** - Always pass `true` for the final chunk to flush buffered bytes
