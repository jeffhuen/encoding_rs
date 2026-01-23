# Streaming Guide

This guide covers how to use `EncodingRs.Decoder` for processing large files and streaming data in multibyte encodings like Shift_JIS, GBK, Big5, and EUC-JP.

## The Problem

When processing files in chunks, multibyte characters can be split across chunk boundaries:

```
File content: "Hello世界" (in Shift_JIS)
Bytes: <<72, 101, 108, 108, 111, 144, 162, 138, 69>>
                                   ↑
                            Chunk boundary here

Chunk 1: <<72, 101, 108, 108, 111, 144>>  → "Hello" + incomplete byte
Chunk 2: <<162, 138, 69>>                  → incomplete byte + "界"
```

Using one-shot `EncodingRs.decode/2` on each chunk independently produces corrupted output with replacement characters (`�`).

## The Solution

`EncodingRs.Decoder` maintains state between chunks, buffering incomplete byte sequences until they can be completed.

## Real-World Examples

### Processing a Large CSV File

```elixir
defmodule CsvProcessor do
  def process_shift_jis_csv(path) do
    path
    |> File.stream!([], 64 * 1024)  # 64KB chunks
    |> EncodingRs.Decoder.stream("shift_jis")
    |> Enum.join()
    |> String.split("\n")
    |> Enum.map(&String.split(&1, ","))
  end
end
```

### Streaming HTTP Response

```elixir
defmodule HttpClient do
  def fetch_and_decode(url, encoding) do
    # Using Req or similar HTTP client with streaming
    Req.get!(url, into: fn {:data, chunk}, acc ->
      {:cont, [chunk | acc]}
    end).body
    |> Enum.reverse()
    |> EncodingRs.Decoder.stream(encoding)
    |> Enum.join()
  end
end
```

### Processing with Error Tracking

```elixir
defmodule DataImporter do
  require Logger

  def import_with_validation(path, encoding) do
    {content, had_errors} =
      path
      |> File.stream!([], 8192)
      |> EncodingRs.Decoder.stream_with_errors(encoding)
      |> Enum.reduce({"", false}, fn {chunk, errors}, {acc, had_any} ->
        if errors do
          Logger.warning("Invalid bytes detected in chunk")
        end
        {acc <> chunk, had_any or errors}
      end)

    if had_errors do
      Logger.warning("File contained invalid byte sequences")
    end

    content
  end
end
```

### GenServer for Continuous Stream Processing

```elixir
defmodule StreamProcessor do
  use GenServer

  def start_link(encoding) do
    GenServer.start_link(__MODULE__, encoding)
  end

  def process_chunk(pid, chunk, is_last \\ false) do
    GenServer.call(pid, {:process, chunk, is_last})
  end

  @impl true
  def init(encoding) do
    {:ok, decoder} = EncodingRs.Decoder.new(encoding)
    {:ok, %{decoder: decoder, buffer: ""}}
  end

  @impl true
  def handle_call({:process, chunk, is_last}, _from, state) do
    {:ok, output, had_errors} =
      EncodingRs.Decoder.decode_chunk(state.decoder, chunk, is_last)

    {:reply, {:ok, output, had_errors}, state}
  end
end

# Usage
{:ok, pid} = StreamProcessor.start_link("gbk")
{:ok, out1, _} = StreamProcessor.process_chunk(pid, chunk1)
{:ok, out2, _} = StreamProcessor.process_chunk(pid, chunk2)
{:ok, out3, _} = StreamProcessor.process_chunk(pid, chunk3, true)
```

### Converting File Encoding

```elixir
defmodule EncodingConverter do
  @doc """
  Convert a file from one encoding to another.
  """
  def convert(input_path, output_path, from_encoding, to_encoding) do
    input_path
    |> File.stream!([], 64 * 1024)
    |> EncodingRs.Decoder.stream(from_encoding)
    |> Stream.map(fn chunk ->
      {:ok, encoded} = EncodingRs.encode(chunk, to_encoding)
      encoded
    end)
    |> Stream.into(File.stream!(output_path))
    |> Stream.run()
  end
end

# Convert Shift_JIS to UTF-8
EncodingConverter.convert("input.txt", "output.txt", "shift_jis", "utf-8")
```

## Choosing Chunk Size

The chunk size affects memory usage and performance:

| Chunk Size | Memory | Performance | Use Case |
|------------|--------|-------------|----------|
| 4KB | Low | More overhead | Memory-constrained |
| 64KB | Medium | Good balance | General purpose |
| 256KB+ | Higher | Less overhead | Large files, fast storage |

```elixir
# Memory-constrained environment
File.stream!(path, [], 4096)

# General purpose (recommended)
File.stream!(path, [], 64 * 1024)

# High-throughput processing
File.stream!(path, [], 256 * 1024)
```

## When to Use Streaming vs One-Shot

| Scenario | Approach |
|----------|----------|
| Small files (<1MB) | `EncodingRs.decode/2` |
| Large files | `EncodingRs.Decoder.stream/2` |
| Network streams | `EncodingRs.Decoder` |
| Unknown size | `EncodingRs.Decoder.stream/2` |
| Memory-constrained | `EncodingRs.Decoder.stream/2` |

## Common Encodings

| Region | Common Encodings |
|--------|------------------|
| Japanese | `shift_jis`, `euc-jp`, `iso-2022-jp` |
| Chinese (Simplified) | `gbk`, `gb18030` |
| Chinese (Traditional) | `big5` |
| Korean | `euc-kr` |
| Western European | `windows-1252`, `iso-8859-1` |
| Cyrillic | `windows-1251`, `koi8-r` |

## Tips

1. **Always flush**: Pass `is_last: true` for the final chunk to flush any buffered bytes.

2. **Don't share decoders**: Each decoder maintains mutable state. Don't share across processes.

3. **Check for errors**: Use `stream_with_errors/2` if you need to know about invalid byte sequences.

4. **BOM detection**: For files with BOMs, detect and strip first:
   ```elixir
   content = File.read!(path)
   {encoding, data} = case EncodingRs.detect_and_strip_bom(content) do
     {:ok, enc, rest} -> {enc, rest}
     {:error, :no_bom} -> {"utf-8", content}  # default
   end
   {:ok, decoded} = EncodingRs.decode(data, encoding)
   ```
