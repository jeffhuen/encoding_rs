# Batch processing guide

Use the batch API when you need to encode or decode many separate items in one NIF call.

## When to use batch operations

Batch operations amortize NIF dispatch overhead across many small items:

- Database rows with per-row encoding metadata
- Lists of filenames, headers, or form values
- Bulk data migrations

For a single large file or chunked network stream, use `EncodingRs.Decoder` or `EncodingRs.Encoder` instead (see the [Streaming Guide](streaming.md)).

## Usage

### Decode multiple binaries

```elixir
items = [
  {<<72, 101, 108, 108, 111>>, "windows-1252"},
  {<<0x82, 0xA0>>, "shift_jis"},
  {<<0xC4, 0xE3, 0xBA, 0xC3>>, "gbk"}
]

EncodingRs.decode_batch(items)
# => [{:ok, "Hello"}, {:ok, "あ"}, {:ok, "你好"}]
```

Use `EncodingRs.decode_batch_with_details/2` when you need the BOM-selected encoding and replacement flag for each item:

```elixir
EncodingRs.decode_batch_with_details([
  {<<0xFF, 0xFE, 0x48, 0x00>>, "windows-1252"},
  {<<0xFF>>, "utf-8"}
])
# => [{:ok, "H", "UTF-16LE", false}, {:ok, "\uFFFD", "UTF-8", true}]
```

### Encode multiple strings

```elixir
items = [
  {"Hello", "windows-1252"},
  {"あ", "shift_jis"},
  {"你好", "gbk"}
]

EncodingRs.encode_batch(items)
# => [{:ok, "Hello"}, {:ok, <<130, 160>>}, {:ok, <<196, 227, 186, 195>>}]
```

Use `EncodingRs.encode_batch_with_details/2` to observe unmappable-character HTML numeric character reference replacements:

```elixir
EncodingRs.encode_batch_with_details([
  {"Hello", "windows-1252"},
  {"🎉", "windows-1252"}
])
# => [{:ok, "Hello", false}, {:ok, "&#127881;", true}]
```

### Strict mode and BOM options

Batch decode accepts `:bom` (`:sniff`, `:strip`, `:preserve`) and `:on_error` (`:replace`, `:error`). Batch encode accepts `:on_error` (`:replace`, `:error`):

```elixir
EncodingRs.decode_batch([{"ok", "utf-8"}, {<<0xFF>>, "utf-8"}], on_error: :error)
# => [{:ok, "ok"}, {:error, :malformed_input}]

EncodingRs.encode_batch([{"ok", "windows-1252"}, {"🎉", "windows-1252"}], on_error: :error)
# => [{:ok, "ok"}, {:error, :unmappable_character}]
```

### Handle per-item errors

Results stay in input order. An error on one item does not stop valid items in the same batch:

- `:unknown_encoding`: The encoding label is not recognized.
- `:encoder_unavailable`: Encode was requested for a decode-only label (`"utf-16le"`, `"utf-16be"`, `"replacement"`).
- `:invalid_utf8`: Encode received a binary that is not valid UTF-8.
- `:unmappable_character`: Encode failed in strict mode (`on_error: :error`).
- `:malformed_input`: Decode failed in strict mode (`on_error: :error`).
- `:input_too_large`: The item exceeded `:max_input_size` (default 100 MB).
- `:allocation_failed`: Native output buffer allocation failed.

## Dirty scheduler routing

Batch calls sum the byte sizes of valid items and compare that total to `:dirty_threshold` (default 64 KB):

```elixir
# Force a batch onto a dirty CPU scheduler
EncodingRs.decode_batch(items, dirty_threshold: 0)

# Keep batches up to 256 KB on a normal scheduler
EncodingRs.decode_batch(items, dirty_threshold: 256 * 1024)
```

Oversized items are excluded before computing the total and never cross the NIF boundary. When all items fit within `:max_input_size`, the batch takes a fast path without building index maps.

## Performance tips

1. **Chunk very large lists**: Batches of 100 to 10,000 items balance dispatch savings against peak memory.
   ```elixir
   large_list
   |> Enum.chunk_every(1000)
   |> Enum.flat_map(&EncodingRs.decode_batch/1)
   ```
2. **Parallelize large workloads across processes**:
   ```elixir
   items
   |> Enum.chunk_every(1000)
   |> Task.async_stream(&EncodingRs.decode_batch/1, max_concurrency: System.schedulers_online())
   |> Enum.flat_map(fn {:ok, results} -> results end)
   ```
3. **One-shot only**: Batch operations decode or encode complete items. For chunked streams with split characters, use `EncodingRs.Decoder` or `EncodingRs.Encoder`.
