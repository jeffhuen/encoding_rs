defmodule EncodingRs.Decoder do
  @moduledoc """
  Stateful streaming decoder for converting encoded byte streams to UTF-8.

  This module provides a streaming API for decoding multibyte encodings
  (like Shift_JIS, GBK, Big5, EUC-JP, etc.) where characters may be split
  across chunk boundaries.

  ## Why Use Streaming Decoding?

  Multibyte encodings use variable-length byte sequences to represent characters.
  For example, in Shift_JIS, the character "あ" is encoded as two bytes: `<<0x82, 0xA0>>`.

  When processing data in chunks (e.g., from `File.stream!/1` or network streams),
  a character's bytes may be split across chunks:

      # Chunk 1 ends with first byte of "あ"
      chunk1 = <<..., 0x82>>
      # Chunk 2 starts with second byte of "あ"
      chunk2 = <<0xA0, ...>>

  The one-shot `EncodingRs.decode/2` treats each chunk independently, so:
  - Chunk 1's trailing `0x82` is invalid → replaced with `�`
  - Chunk 2's leading `0xA0` is invalid → replaced with `�`

  The streaming decoder maintains state between chunks, properly buffering
  incomplete sequences until completed.

  ## Usage

  ### Manual Chunked Decoding

      {:ok, decoder} = EncodingRs.Decoder.new("shift_jis")

      {:ok, output1, _} = EncodingRs.Decoder.decode_chunk(decoder, chunk1, false)
      {:ok, output2, _} = EncodingRs.Decoder.decode_chunk(decoder, chunk2, false)
      {:ok, output3, _} = EncodingRs.Decoder.decode_chunk(decoder, chunk3, true)

      result = output1 <> output2 <> output3

  ### Stream-Based Decoding

      File.stream!("data.txt", [], 4096)
      |> EncodingRs.Decoder.stream("shift_jis")
      |> Enum.join()

  ## Important Notes

  - Always pass `is_last: true` for the final chunk to flush any buffered bytes
  - The decoder resource is mutable; don't share it across concurrent processes
  - For single complete binaries, use `EncodingRs.decode/2` instead (more efficient)
  """

  alias EncodingRs.Native

  @typedoc "An opaque decoder reference. Created with `new/1`."
  @type t :: reference()

  @typedoc "Result of decoding a chunk: `{:ok, decoded_string, had_errors}`"
  @type decode_result :: {:ok, String.t(), had_errors :: boolean()}

  @doc """
  Creates a new stateful decoder for the specified encoding.

  The decoder maintains internal state to handle multibyte characters
  that may be split across chunk boundaries.

  ## Arguments

  - `encoding` - The source encoding label (e.g., "shift_jis", "gbk", "euc-jp")

  ## Returns

  - `{:ok, decoder}` on success
  - `{:error, :unknown_encoding}` if the encoding is not recognized

  ## Examples

      iex> {:ok, decoder} = EncodingRs.Decoder.new("shift_jis")
      iex> is_reference(decoder)
      true

      iex> EncodingRs.Decoder.new("invalid-encoding")
      {:error, :unknown_encoding}
  """
  @spec new(EncodingRs.encoding()) :: {:ok, t()} | {:error, :unknown_encoding}
  def new(encoding) when is_binary(encoding) do
    case Native.decoder_new(encoding) do
      {:ok, decoder} when is_reference(decoder) -> {:ok, decoder}
      {:error, _} -> {:error, :unknown_encoding}
    end
  end

  @doc """
  Creates a new stateful decoder, raising on error.

  ## Examples

      iex> decoder = EncodingRs.Decoder.new!("shift_jis")
      iex> is_reference(decoder)
      true

      iex> EncodingRs.Decoder.new!("invalid-encoding")
      ** (ArgumentError) unknown encoding: invalid-encoding
  """
  @spec new!(EncodingRs.encoding()) :: t()
  def new!(encoding) when is_binary(encoding) do
    case new(encoding) do
      {:ok, decoder} -> decoder
      {:error, :unknown_encoding} -> raise ArgumentError, "unknown encoding: #{encoding}"
    end
  end

  @doc """
  Decodes a chunk of bytes using the stateful decoder.

  This function properly handles multibyte characters split across chunk
  boundaries by maintaining decoder state between calls.

  ## Arguments

  - `decoder` - The decoder reference from `new/1`
  - `chunk` - The binary chunk to decode
  - `is_last` - Set to `true` for the final chunk (default: `false`)

  ## Returns

  - `{:ok, output, had_errors}` on success
    - `output` - The decoded UTF-8 string for this chunk
    - `had_errors` - `true` if any bytes were replaced with U+FFFD

  ## Behavior

  - When `is_last` is `false`: Incomplete byte sequences at the end of the
    chunk are buffered internally and completed with the next chunk.
  - When `is_last` is `true`: Any remaining incomplete sequences are replaced
    with U+FFFD (the Unicode replacement character).

  ## Examples

      iex> {:ok, decoder} = EncodingRs.Decoder.new("shift_jis")
      iex> # Shift_JIS "あ" is <<0x82, 0xA0>> - split across chunks
      iex> {:ok, out1, false} = EncodingRs.Decoder.decode_chunk(decoder, <<0x82>>, false)
      iex> {:ok, out2, false} = EncodingRs.Decoder.decode_chunk(decoder, <<0xA0>>, true)
      iex> out1 <> out2
      "あ"
  """
  @spec decode_chunk(t(), binary(), boolean()) :: decode_result()
  def decode_chunk(decoder, chunk, is_last \\ false)
      when is_reference(decoder) and is_binary(chunk) and is_boolean(is_last) do
    if byte_size(chunk) > Native.dirty_threshold() do
      Native.decoder_decode_chunk_dirty(decoder, chunk, is_last)
    else
      Native.decoder_decode_chunk(decoder, chunk, is_last)
    end
  end

  @doc """
  Decodes a chunk, raising on error.

  See `decode_chunk/3` for details.

  ## Examples

      iex> decoder = EncodingRs.Decoder.new!("utf-8")
      iex> EncodingRs.Decoder.decode_chunk!(decoder, "hello", true)
      {"hello", false}
  """
  @spec decode_chunk!(t(), binary(), boolean()) :: {String.t(), boolean()}
  def decode_chunk!(decoder, chunk, is_last \\ false)
      when is_reference(decoder) and is_binary(chunk) and is_boolean(is_last) do
    case decode_chunk(decoder, chunk, is_last) do
      {:ok, output, had_errors} -> {output, had_errors}
    end
  end

  @doc """
  Creates a stream that decodes chunks from the given encoding to UTF-8.

  This is the recommended way to process streaming data in multibyte encodings.
  It properly handles characters split across chunk boundaries.

  ## Arguments

  - `chunks` - An enumerable of binary chunks (e.g., from `File.stream!/3`)
  - `encoding` - The source encoding label

  ## Returns

  A stream of decoded UTF-8 strings, one for each input chunk.

  ## Examples

      # Decode a Shift_JIS file
      File.stream!("japanese.txt", [], 4096)
      |> EncodingRs.Decoder.stream("shift_jis")
      |> Enum.join()

      # Process line by line (after decoding)
      File.stream!("data.csv", [], 8192)
      |> EncodingRs.Decoder.stream("gbk")
      |> Enum.join()
      |> String.split("\\n")

      # With error tracking
      File.stream!("data.txt", [], 4096)
      |> EncodingRs.Decoder.stream_with_errors("windows-1252")
      |> Enum.reduce({"", false}, fn {chunk, errors}, {acc, had_any} ->
        {acc <> chunk, had_any or errors}
      end)

  ## Notes

  - The stream automatically handles the `is_last` flag for the final chunk
  - Each output element corresponds to one input chunk
  - For better error visibility, use `stream_with_errors/2`
  """
  @spec stream(Enumerable.t(), EncodingRs.encoding()) :: Enumerable.t()
  def stream(chunks, encoding) when is_binary(encoding) do
    Stream.transform(
      chunks,
      fn -> new!(encoding) end,
      fn chunk, decoder ->
        {output, _had_errors} = decode_chunk!(decoder, chunk, false)
        {[output], decoder}
      end,
      fn decoder ->
        # Flush any remaining buffered bytes
        {output, _had_errors} = decode_chunk!(decoder, <<>>, true)

        if output == "" do
          {[], decoder}
        else
          {[output], decoder}
        end
      end,
      fn _decoder -> :ok end
    )
  end

  @doc """
  Creates a stream that decodes chunks, including error information.

  Like `stream/2`, but each element is a tuple `{decoded_string, had_errors}`.

  ## Examples

      File.stream!("data.txt", [], 4096)
      |> EncodingRs.Decoder.stream_with_errors("shift_jis")
      |> Enum.each(fn {chunk, had_errors} ->
        if had_errors, do: Logger.warning("Encountered invalid bytes")
        IO.write(chunk)
      end)
  """
  @spec stream_with_errors(Enumerable.t(), EncodingRs.encoding()) :: Enumerable.t()
  def stream_with_errors(chunks, encoding) when is_binary(encoding) do
    Stream.transform(
      chunks,
      fn -> new!(encoding) end,
      fn chunk, decoder ->
        result = decode_chunk!(decoder, chunk, false)
        {[result], decoder}
      end,
      fn decoder ->
        result = decode_chunk!(decoder, <<>>, true)
        {output, _had_errors} = result

        if output == "" do
          {[], decoder}
        else
          {[result], decoder}
        end
      end,
      fn _decoder -> :ok end
    )
  end
end
