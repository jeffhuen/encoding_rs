# Batch Processing Guide

This guide covers the batch API for encoding and decoding multiple items in a single NIF call.

## When to Use Batch Operations

Batch operations are useful when you need to process many separate strings or binaries:

- Decoding/encoding rows from a database
- Processing lists of filenames or paths
- Converting multiple user inputs
- Data migration tasks

For streaming a single large file, use `EncodingRs.Decoder` instead (see the [Streaming Guide](streaming.md)).

## The Problem

Each NIF call has overhead: scheduler context switching, argument marshalling, and result conversion. When processing many small items, this overhead can dominate:

```elixir
# Inefficient: 1000 NIF calls
items
|> Enum.map(fn {data, encoding} ->
  EncodingRs.decode(data, encoding)
end)
```

## The Solution

Batch operations process all items in a single NIF call, amortizing the dispatch overhead:

```elixir
# Efficient: 1 NIF call
EncodingRs.decode_batch(items)
```

## Usage

### Decoding Multiple Binaries

```elixir
items = [
  {<<72, 101, 108, 108, 111>>, "windows-1252"},
  {<<0x82, 0xA0>>, "shift_jis"},
  {<<0xC4, 0xE3, 0xBA, 0xC3>>, "gbk"}
]

results = EncodingRs.decode_batch(items)
# => [{:ok, "Hello"}, {:ok, "あ"}, {:ok, "你好"}]
```

Use `decode_batch_with_details/2` when callers need to know whether malformed
bytes were replaced or a BOM selected a different encoding. Successful results
are `{:ok, string, actual_encoding, had_errors}`.

### Encoding Multiple Strings

```elixir
items = [
  {"Hello", "windows-1252"},
  {"あ", "shift_jis"},
  {"你好", "gbk"}
]

results = EncodingRs.encode_batch(items)
# => [{:ok, <<72, 101, 108, 108, 111>>}, {:ok, <<130, 160>>}, {:ok, <<196, 227, 186, 195>>}]
```

### Handling Errors

Results are returned in the same order as input. Check each result individually:

```elixir
items = [
  {"Hello", "windows-1252"},
  {"Test", "invalid-encoding"},
  {"World", "utf-8"}
]

results = EncodingRs.encode_batch(items)
# => [{:ok, "Hello"}, {:error, :unknown_encoding}, {:ok, "World"}]

# Process results
Enum.zip(items, results)
|> Enum.each(fn {{input, encoding}, result} ->
  case result do
    {:ok, encoded} ->
      IO.puts("Encoded #{inspect(input)} to #{encoding}")
    {:error, reason} ->
      IO.puts("Failed to encode #{inspect(input)}: #{reason}")
  end
end)
```

Possible error reasons:

- `:unknown_encoding` — the encoding label is not recognized
- `:input_too_large` — the item exceeds the selected `max_input_size` (default 100MB)

Oversized items are rejected individually — other items in the same batch are still processed normally.

### Mixed Encodings

Batch operations support different encodings per item:

```elixir
# Database rows with encoding metadata
rows = [
  %{content: <<...>>, encoding: "shift_jis", id: 1},
  %{content: <<...>>, encoding: "gbk", id: 2},
  %{content: <<...>>, encoding: "windows-1252", id: 3}
]

items = Enum.map(rows, &{&1.content, &1.encoding})
results = EncodingRs.decode_batch(items)

# Combine results back with original data
Enum.zip(rows, results)
|> Enum.map(fn {row, {:ok, decoded}} ->
  Map.put(row, :content_utf8, decoded)
end)
```

## Dirty Scheduler Behavior

Batch operations sum the bytes of the valid items and apply the same threshold
as one-shot operations. The default is 64KB:

```elixir
# Force this batch onto a dirty CPU scheduler
EncodingRs.decode_batch(items, dirty_threshold: 0)

# Keep batches up to 256KB on a normal scheduler
EncodingRs.decode_batch(items, dirty_threshold: 256 * 1024)
```

Small batches avoid an unnecessary dirty-scheduler handoff. Large batches use
a dirty CPU scheduler so they do not block normal BEAM schedulers. Either route
still processes the batch in one NIF call.

Items rejected by `max_input_size` are not included in the total because they
never reach the NIF.

## Known Limitations

### No Batch Streaming

The batch API is for one-shot processing of complete binaries only. It does not support stateful streaming decoding where characters may be split across chunk boundaries.

For streaming use cases, use `EncodingRs.Decoder` which maintains state between chunks. However, each decoder handles a single stream - there is currently no way to batch process chunks from multiple streams in a single NIF call.

If you need to process multiple streams concurrently, create separate `EncodingRs.Decoder` instances for each stream.

## Performance Tips

1. **Batch similar-sized items** - Helps with memory allocation efficiency

2. **Reasonable batch sizes** - Batches of 100-10,000 items work well. Extremely large batches (100K+) may cause memory pressure.

3. **Mind the input size limit** - Individual items exceeding the 100MB default are rejected with `{:error, :input_too_large}`. For trusted larger items, pass `max_input_size: :infinity` to `decode_batch/2` or `encode_batch/2`.

4. **Consider chunking very large lists**:
   ```elixir
   large_list
   |> Enum.chunk_every(1000)
   |> Enum.flat_map(&EncodingRs.decode_batch/1)
   ```

5. **Parallel batches** - For very large workloads, split across processes:
   ```elixir
   items
   |> Enum.chunk_every(1000)
   |> Task.async_stream(&EncodingRs.decode_batch/1, max_concurrency: 4)
   |> Enum.flat_map(fn {:ok, results} -> results end)
   ```

## Comparison: Batch vs Streaming vs One-Shot

| Scenario | Best Approach |
|----------|---------------|
| Single small binary | `EncodingRs.decode/2` |
| Single large file | `EncodingRs.Decoder.stream/3` |
| Many separate items | `EncodingRs.decode_batch/1` |
| Network stream | `EncodingRs.Decoder` |
| Database rows | `EncodingRs.decode_batch/1` |
