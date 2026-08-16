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
  - The decoder resource is mutable; use one decoder per logical stream and do
    not share it across concurrent processes. Calls are serialized, but their
    order determines the decoded output.
  - For single complete binaries, use `EncodingRs.decode/2` instead (more efficient)
  """

  alias EncodingRs.Native

  @enforce_keys [:resource, :dirty_threshold, :max_input_size]
  defstruct [:resource, :dirty_threshold, :max_input_size]

  @typedoc "An opaque decoder created with `new/1` or `new/2`."
  @opaque t ::
            reference()
            | %__MODULE__{
                resource: reference(),
                dirty_threshold: non_neg_integer(),
                max_input_size: non_neg_integer() | :infinity
              }

  @typedoc "Result of decoding a chunk: `{:ok, decoded_string, had_errors}` or `{:error, reason}`"
  @type decode_result ::
          {:ok, String.t(), had_errors :: boolean()}
          | {:error, :allocation_failed | :lock_poisoned | :input_too_large}

  @doc """
  Creates a new stateful decoder for the specified encoding.

  The decoder maintains internal state to handle multibyte characters
  that may be split across chunk boundaries.

  Pass options to `new/2` for manual chunk loops. They are validated and stored
  once instead of being resolved again for every `decode_chunk/3` call.

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

      iex> {:ok, decoder} = EncodingRs.Decoder.new("utf-8", max_input_size: 4)
      iex> EncodingRs.Decoder.decode_chunk(decoder, "hello", true)
      {:error, :input_too_large}
  """
  @spec new(EncodingRs.encoding()) :: {:ok, t()} | {:error, :unknown_encoding}
  def new(encoding) when is_binary(encoding) do
    case Native.decoder_new(encoding) do
      {:ok, decoder} when is_reference(decoder) -> {:ok, decoder}
      {:error, _} -> {:error, :unknown_encoding}
    end
  end

  @spec new(EncodingRs.encoding(), EncodingRs.options()) ::
          {:ok, t()} | {:error, :unknown_encoding}
  def new(encoding, opts) when is_binary(encoding) and is_list(opts) do
    {dirty_threshold, max_input_size} = EncodingRs.resolve_options(opts)

    case new(encoding) do
      {:ok, resource} ->
        {:ok,
         %__MODULE__{
           resource: resource,
           dirty_threshold: dirty_threshold,
           max_input_size: max_input_size
         }}

      error ->
        error
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

  @spec new!(EncodingRs.encoding(), EncodingRs.options()) :: t()
  def new!(encoding, opts) when is_binary(encoding) and is_list(opts) do
    case new(encoding, opts) do
      {:ok, decoder} -> decoder
      {:error, :unknown_encoding} -> raise ArgumentError, "unknown encoding: #{encoding}"
    end
  end

  @doc """
  Decodes a chunk of bytes using the stateful decoder.

  This function properly handles multibyte characters split across chunk
  boundaries by maintaining decoder state between calls.

  ## Arguments

  - `decoder` - The decoder from `new/1` or `new/2`
  - `chunk` - The binary chunk to decode
  - `is_last` - Set to `true` for the final chunk (default: `false`)

  ## Returns

  - `{:ok, output, had_errors}` on success
    - `output` - The decoded UTF-8 string for this chunk
    - `had_errors` - `true` if any bytes were replaced with U+FFFD
  - `{:error, :input_too_large}` if the chunk exceeds the selected maximum input size
  - `{:error, :allocation_failed}` if an output buffer cannot be allocated
  - `{:error, :lock_poisoned}` if the internal decoder mutex is poisoned (extremely rare)

  ## Behavior

  - When `is_last` is `false`: Incomplete byte sequences at the end of the
    chunk are buffered internally and completed with the next chunk.
  - When `is_last` is `true`: Any remaining incomplete sequences are replaced
    with U+FFFD (the Unicode replacement character).
  - Chunks exceeding `:max_input_size` are rejected before reaching the NIF.

  ## Examples

      iex> {:ok, decoder} = EncodingRs.Decoder.new("shift_jis")
      iex> # Shift_JIS "あ" is <<0x82, 0xA0>> - split across chunks
      iex> {:ok, out1, false} = EncodingRs.Decoder.decode_chunk(decoder, <<0x82>>, false)
      iex> {:ok, out2, false} = EncodingRs.Decoder.decode_chunk(decoder, <<0xA0>>, true)
      iex> out1 <> out2
      "あ"
  """
  @spec decode_chunk(t(), binary()) :: decode_result()
  @spec decode_chunk(t(), binary(), boolean()) :: decode_result()
  def decode_chunk(decoder, chunk, is_last \\ false)

  def decode_chunk(
        %__MODULE__{
          resource: resource,
          dirty_threshold: dirty_threshold,
          max_input_size: max_input_size
        },
        chunk,
        is_last
      )
      when is_binary(chunk) and is_boolean(is_last) do
    decode_chunk_resolved(resource, chunk, is_last, dirty_threshold, max_input_size)
  end

  def decode_chunk(decoder, chunk, is_last)
      when is_reference(decoder) and is_binary(chunk) and is_boolean(is_last) do
    decode_chunk_resolved(
      decoder,
      chunk,
      is_last,
      EncodingRs.dirty_threshold(),
      EncodingRs.max_input_size()
    )
  end

  @spec decode_chunk(t(), binary(), boolean(), EncodingRs.options()) :: decode_result()
  def decode_chunk(decoder, chunk, is_last, opts)
      when (is_reference(decoder) or is_struct(decoder, __MODULE__)) and is_binary(chunk) and
             is_boolean(is_last) and is_list(opts) do
    {dirty_threshold, max_input_size} = EncodingRs.resolve_options(opts)

    decode_chunk_resolved(
      decoder_resource(decoder),
      chunk,
      is_last,
      dirty_threshold,
      max_input_size
    )
  end

  defp decode_chunk_resolved(decoder, chunk, is_last, dirty_threshold, max_input_size) do
    if max_input_size != :infinity and byte_size(chunk) > max_input_size do
      {:error, :input_too_large}
    else
      if byte_size(chunk) > dirty_threshold do
        Native.decoder_decode_chunk_dirty(decoder, chunk, is_last)
      else
        Native.decoder_decode_chunk(decoder, chunk, is_last)
      end
      |> normalize_decode_result()
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
  @spec decode_chunk!(t(), binary()) :: {String.t(), boolean()}
  @spec decode_chunk!(t(), binary(), boolean()) :: {String.t(), boolean()}
  def decode_chunk!(decoder, chunk, is_last \\ false)

  def decode_chunk!(decoder, chunk, is_last)
      when (is_reference(decoder) or is_struct(decoder, __MODULE__)) and is_binary(chunk) and
             is_boolean(is_last) do
    decoder
    |> decode_chunk(chunk, is_last)
    |> unwrap_decode_result!()
  end

  @spec decode_chunk!(t(), binary(), boolean(), EncodingRs.options()) :: {String.t(), boolean()}
  def decode_chunk!(decoder, chunk, is_last, opts)
      when (is_reference(decoder) or is_struct(decoder, __MODULE__)) and is_binary(chunk) and
             is_boolean(is_last) and is_list(opts) do
    decoder
    |> decode_chunk(chunk, is_last, opts)
    |> unwrap_decode_result!()
  end

  @doc """
  Creates a stream that decodes chunks from the given encoding to UTF-8.

  This is the recommended way to process streaming data in multibyte encodings.
  It properly handles characters split across chunk boundaries.

  ## Arguments

  - `chunks` - An enumerable of binary chunks (e.g., from `File.stream!/3`)
  - `encoding` - The source encoding label

  ## Returns

  A stream of decoded UTF-8 strings. One element is emitted per input chunk,
  plus an additional element may be emitted at the end if the decoder has
  buffered bytes remaining (e.g., an incomplete multibyte sequence that gets
  flushed as a replacement character).

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
  - The output may contain one more element than the input if buffered bytes
    are flushed at the end of the stream
  - For better error visibility, use `stream_with_errors/2`
  """
  @spec stream(Enumerable.t(), EncodingRs.encoding()) :: Enumerable.t()
  @spec stream(Enumerable.t(), EncodingRs.encoding(), EncodingRs.options()) :: Enumerable.t()
  def stream(chunks, encoding) when is_binary(encoding) do
    stream_resolved(chunks, encoding, :default)
  end

  def stream(chunks, encoding, opts) when is_binary(encoding) and is_list(opts) do
    stream_resolved(chunks, encoding, opts)
  end

  defp stream_resolved(chunks, encoding, opts) do
    Stream.transform(
      chunks,
      fn ->
        {dirty_threshold, max_input_size} = stream_options(opts)
        {new!(encoding), dirty_threshold, max_input_size}
      end,
      fn chunk, {decoder, dirty_threshold, max_input_size} = state ->
        {output, _had_errors} =
          decode_chunk_resolved!(decoder, chunk, false, dirty_threshold, max_input_size)

        {[output], state}
      end,
      fn {decoder, dirty_threshold, max_input_size} = state ->
        # Flush any remaining buffered bytes
        {output, _had_errors} =
          decode_chunk_resolved!(decoder, <<>>, true, dirty_threshold, max_input_size)

        if output == "" do
          {[], state}
        else
          {[output], state}
        end
      end,
      fn _state -> :ok end
    )
  end

  @doc """
  Creates a stream that decodes chunks, including error information.

  Like `stream/2`, but each element is a tuple `{decoded_string, had_errors}`.
  A single `Stream.map/2` can inspect the flag and return `decoded_string` when
  downstream stages should keep receiving plain strings.

  ## Examples

      File.stream!("data.txt", [], 4096)
      |> EncodingRs.Decoder.stream_with_errors("shift_jis")
      |> Enum.each(fn {chunk, had_errors} ->
        if had_errors, do: Logger.warning("Encountered invalid bytes")
        IO.write(chunk)
      end)
  """
  @spec stream_with_errors(Enumerable.t(), EncodingRs.encoding()) :: Enumerable.t()
  @spec stream_with_errors(Enumerable.t(), EncodingRs.encoding(), EncodingRs.options()) ::
          Enumerable.t()
  def stream_with_errors(chunks, encoding) when is_binary(encoding) do
    stream_with_errors_resolved(chunks, encoding, :default)
  end

  def stream_with_errors(chunks, encoding, opts)
      when is_binary(encoding) and is_list(opts) do
    stream_with_errors_resolved(chunks, encoding, opts)
  end

  defp stream_with_errors_resolved(chunks, encoding, opts) do
    Stream.transform(
      chunks,
      fn ->
        {dirty_threshold, max_input_size} = stream_options(opts)
        {new!(encoding), dirty_threshold, max_input_size}
      end,
      fn chunk, {decoder, dirty_threshold, max_input_size} = state ->
        result = decode_chunk_resolved!(decoder, chunk, false, dirty_threshold, max_input_size)
        {[result], state}
      end,
      fn {decoder, dirty_threshold, max_input_size} = state ->
        result = decode_chunk_resolved!(decoder, <<>>, true, dirty_threshold, max_input_size)
        {output, _had_errors} = result

        if output == "" do
          {[], state}
        else
          {[result], state}
        end
      end,
      fn _state -> :ok end
    )
  end

  # Private helpers

  defp decoder_resource(%__MODULE__{resource: resource}), do: resource
  defp decoder_resource(resource), do: resource

  defp stream_options(:default),
    do: {EncodingRs.dirty_threshold(), EncodingRs.max_input_size()}

  defp stream_options(opts), do: EncodingRs.resolve_options(opts)

  defp decode_chunk_resolved!(decoder, chunk, is_last, dirty_threshold, max_input_size) do
    decoder
    |> decode_chunk_resolved(chunk, is_last, dirty_threshold, max_input_size)
    |> unwrap_decode_result!()
  end

  defp unwrap_decode_result!({:ok, output, had_errors}), do: {output, had_errors}

  defp unwrap_decode_result!({:error, reason}),
    do: raise(RuntimeError, "decoder error: #{reason}")

  defp normalize_decode_result({:ok, output, had_errors}), do: {:ok, output, had_errors}
  defp normalize_decode_result({:error, "allocation_failed", _}), do: {:error, :allocation_failed}
  defp normalize_decode_result({:error, "lock_poisoned", _}), do: {:error, :lock_poisoned}
end
