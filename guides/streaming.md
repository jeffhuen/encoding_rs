# Streaming guide

Use `EncodingRs.Decoder` and `EncodingRs.Encoder` when reading or writing chunked data such as `File.stream!/3` or network sockets. Use `EncodingRs.Detector` when you need to guess the encoding of a stream before decoding it.

## Why streaming decoders and encoders matter

Multibyte encodings such as Shift_JIS, GBK, Big5, EUC-JP, and UTF-8 represent characters with two to four bytes. Raw byte chunks can split a character across two chunks:

```text
File content: "Hello世界" (Shift_JIS)
Bytes: <<72, 101, 108, 108, 111, 144, 162, 138, 69>>
                                  ^ chunk boundary

Chunk 1: <<72, 101, 108, 108, 111, 144>>
Chunk 2: <<162, 138, 69>>
```

Calling one-shot `EncodingRs.decode/2` on each chunk corrupts the split character into replacement characters (`U+FFFD`). Similarly, calling one-shot `EncodingRs.encode/2` on each chunk breaks stateful encodings like `ISO-2022-JP` by inserting redundant escape sequences at every chunk boundary, and fails if a raw byte chunk splits a UTF-8 code point.

`EncodingRs.Decoder` buffers incomplete input bytes between chunks. `EncodingRs.Encoder` buffers incomplete trailing UTF-8 bytes and maintains encoder shift state until the final flush.

## Choose raising or non-raising streams

Both `EncodingRs.Decoder` and `EncodingRs.Encoder` provide two stream styles:

- **Non-raising (`stream/3`, `stream_with_errors/3`)**: Emit `{:ok, chunk}` (or `{:ok, chunk, had_errors}`). On an unknown encoding, oversized chunk, or strict-mode error, emit `{:error, reason}` once and stop.
- **Raising (`stream!/3`, `stream_with_errors!/3`)**: Emit plain `chunk` binaries (or `{chunk, had_errors}`) and raise on errors.

## Decode a Shift_JIS file

To decode a file when exceptions are acceptable:

```elixir
defmodule CsvProcessor do
  def read_shift_jis_lines(path) do
    path
    |> File.stream!([], 64 * 1024)
    |> EncodingRs.Decoder.stream!("shift_jis")
    |> Enum.join()
    |> String.split("\n")
  end
end
```

To fail without exceptions on malformed input or oversized chunks:

```elixir
defmodule StrictReader do
  def read_strict(path, encoding) do
    path
    |> File.stream!([], 64 * 1024)
    |> EncodingRs.Decoder.stream(encoding, on_error: :error, max_input_size: 256 * 1024)
    |> Enum.reduce_while([], fn
      {:ok, chunk}, acc -> {:cont, [chunk | acc]}
      {:error, reason}, _acc -> {:halt, {:error, reason}}
    end)
    |> case do
      {:error, reason} -> {:error, reason}
      chunks -> {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}
    end
  end
end
```

## Track replacement errors while streaming

Use `stream_with_errors!/3` (or non-raising `stream_with_errors/3`) to record whether any byte sequence was replaced with `U+FFFD`:

```elixir
defmodule DataImporter do
  require Logger

  def import_with_validation(path, encoding) do
    {chunks, had_errors} =
      path
      |> File.stream!([], 64 * 1024)
      |> EncodingRs.Decoder.stream_with_errors!(encoding)
      |> Enum.reduce({[], false}, fn {chunk, errors}, {acc, had_any} ->
        {[chunk | acc], had_any or errors}
      end)

    if had_errors do
      Logger.warning("File contained malformed byte sequences")
    end

    chunks |> Enum.reverse() |> IO.iodata_to_binary()
  end
end
```

## Transcode a file between encodings

Pipe `EncodingRs.Decoder.stream!/3` into `EncodingRs.Encoder.stream!/3` to convert a file of any size with bounded memory:

```elixir
defmodule EncodingConverter do
  def convert(input_path, output_path, from_encoding, to_encoding) do
    input_path
    |> File.stream!([], 64 * 1024)
    |> EncodingRs.Decoder.stream!(from_encoding)
    |> EncodingRs.Encoder.stream!(to_encoding)
    |> Stream.into(File.stream!(output_path))
    |> Stream.run()
  end
end

EncodingConverter.convert("input.txt", "output.txt", "shift_jis", "iso-2022-jp")
```

Because `EncodingRs.Encoder` keeps shift state open across chunks, `ISO-2022-JP` output emits only one closing ASCII escape sequence at the end of the file.

## Detect a file's encoding before decoding

Feed the first few chunks into `EncodingRs.Detector.detect_stream/2`, then open a fresh file stream for decoding:

```elixir
defmodule AutoDecoder do
  def decode_file(path, tld \\ nil) do
    with {:ok, encoding} <-
           path
           |> File.stream!([], 64 * 1024)
           |> Stream.take(4)
           |> EncodingRs.Detector.detect_stream(tld: tld) do
      content =
        path
        |> File.stream!([], 64 * 1024)
        |> EncodingRs.Decoder.stream!(encoding)
        |> Enum.join()

      {:ok, encoding, content}
    end
  end
end
```

## Control BOM behavior on a streaming decoder

Pass `:bom` to `EncodingRs.Decoder.new/2` or `stream/3`:

- `bom: :sniff` (default): Switches the decoder to UTF-8, UTF-16LE, or UTF-16BE if a leading BOM is present and strips it. Call `EncodingRs.Decoder.encoding/1` after decoding the first chunk to inspect the active encoding.
- `bom: :strip`: Strips a leading BOM only if it matches the requested encoding. Never switches encodings.
- `bom: :preserve`: Decodes a leading BOM as `U+FEFF` without switching encodings.

## Manual chunk loops in a GenServer

Store options once in `new/2` and pass `is_last: true` on the final chunk:

```elixir
defmodule StreamProcessor do
  use GenServer

  def start_link(encoding), do: GenServer.start_link(__MODULE__, encoding)

  def process_chunk(pid, chunk, is_last \\ false) do
    GenServer.call(pid, {:process, chunk, is_last})
  end

  @impl true
  def init(encoding) do
    case EncodingRs.Decoder.new(encoding, max_input_size: 256 * 1024) do
      {:ok, decoder} -> {:ok, %{decoder: decoder}}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call({:process, chunk, is_last}, _from, state) do
    result = EncodingRs.Decoder.decode_chunk(state.decoder, chunk, is_last)
    {:reply, result, state}
  end
end
```

Calling `decode_chunk/3` or `encode_chunk/3` again after `is_last: true` (or after a strict-mode error) returns `{:error, :decoder_finished}` or `{:error, :encoder_finished}`.

## Choose chunk size and limits

| Chunk size | Memory | Overhead | Typical use |
|------------|--------|----------|-------------|
| 4 KB | Low | Higher NIF call count | Memory-constrained systems |
| 64 KB | Medium | Balanced | General file and network streams |
| 256 KB | Higher | Lower NIF call count | Large files on fast storage |

Streaming validates `:max_input_size` per chunk, so files larger than the 100 MB one-shot default stream cleanly with 64 KB to 256 KB chunks.
