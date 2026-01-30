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
- `:input_too_large` — the item exceeds `EncodingRs.max_input_size/0` (default 100MB)

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

Batch operations **always** use dirty CPU schedulers, regardless of input size or item count.

### Rationale

Batch operations are typically used for throughput-focused workloads where:

1. **Total work is significant** - Even if individual items are small, processing many items adds up
2. **Predictability matters** - Consistent dirty scheduler usage avoids variable latency
3. **Simplicity** - No threshold logic to tune or understand

### Trade-offs

| Aspect | Batch (always dirty) | Single-item (threshold-based) |
|--------|---------------------|------------------------------|
| Small workloads | Slight overhead from dirty scheduler | Uses normal scheduler |
| Large workloads | Optimal | Optimal |
| Latency | Consistent | Variable based on size |
| Complexity | Simple | Requires threshold tuning |

### When This Matters

For most use cases, always using dirty schedulers is the right choice. The overhead is minimal and the behavior is predictable.

If you have a latency-sensitive application processing very small batches (< 10 items, each < 1KB), you may see slightly better latency using individual `decode/2` or `encode/2` calls, which respect the configured dirty threshold.

## Known Limitations

### No Batch Streaming

The batch API is for one-shot processing of complete binaries only. It does not support stateful streaming decoding where characters may be split across chunk boundaries.

For streaming use cases, use `EncodingRs.Decoder` which maintains state between chunks. However, each decoder handles a single stream - there is currently no way to batch process chunks from multiple streams in a single NIF call.

If you need to process multiple streams concurrently, create separate `EncodingRs.Decoder` instances for each stream.

## Future Options

The following options may be added in future versions based on user feedback:

- **Batch streaming** - Process chunks from multiple decoders in a single NIF call
- **Threshold-based routing** - Check total bytes and route to normal/dirty scheduler
- **Item count threshold** - Use dirty scheduler only above N items
- **Explicit scheduler choice** - `decode_batch/2` with options like `[scheduler: :normal]`

If you have a use case that would benefit from these options, please [open an issue](https://github.com/jeffhuen/encoding_rs/issues).

## Performance Tips

1. **Batch similar-sized items** - Helps with memory allocation efficiency

2. **Reasonable batch sizes** - Batches of 100-10,000 items work well. Extremely large batches (100K+) may cause memory pressure.

3. **Mind the input size limit** - Individual items exceeding `EncodingRs.max_input_size/0` (default 100MB) are rejected with `{:error, :input_too_large}`. For very large items, use the streaming decoder or increase the limit via `config :encoding_rs, max_input_size: :infinity`.

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
| Single large file | `EncodingRs.Decoder.stream/2` |
| Many separate items | `EncodingRs.decode_batch/1` |
| Network stream | `EncodingRs.Decoder` |
| Database rows | `EncodingRs.decode_batch/1` |
