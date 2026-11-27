defmodule EncodingRs.Encoder do
  @moduledoc """
  Stateful streaming encoder for converting UTF-8 byte streams to legacy or
  UTF-8 encodings.

  Use this module when encoding chunked text streams such as `File.stream!/3`
  or transcoding pipelines. Unlike repeated one-shot `EncodingRs.encode/3`
  calls, a streaming encoder:

  - Preserves encoder shift state across chunks for stateful encodings such as
    `ISO-2022-JP`, emitting only one final return-to-ASCII sequence at EOF.
  - Buffers incomplete multi-byte UTF-8 sequences split across raw byte chunk
    boundaries until the next chunk completes the code point.

  ## Usage

  ### Stream pipelines

      File.stream!("utf8.txt", [], 64 * 1024)
      |> EncodingRs.Encoder.stream!("shift_jis")
      |> Stream.into(File.stream!("sjis.txt"))
      |> Stream.run()

      File.stream!("utf8.txt", [], 64 * 1024)
      |> EncodingRs.Encoder.stream("windows-1252", on_error: :error)
      |> Enum.reduce_while([], fn
        {:ok, chunk}, acc -> {:cont, [chunk | acc]}
        {:error, reason}, _acc -> {:halt, {:error, reason}}
      end)

  ### Manual chunk loops

      {:ok, encoder} = EncodingRs.Encoder.new("iso-2022-jp")
      {:ok, out1, false} = EncodingRs.Encoder.encode_chunk(encoder, "こん", false)
      {:ok, out2, false} = EncodingRs.Encoder.encode_chunk(encoder, "にちは", true)
      result = out1 <> out2

  ## Important notes

  - Pass `is_last: true` on the final chunk so stateful encodings flush their
    closing escape sequence and trailing incomplete UTF-8 bytes are validated.
    Calling `encode_chunk/3` after `is_last: true` returns
    `{:error, :encoder_finished}`.
  - Decode-only labels (`"utf-16le"`, `"utf-16be"`, `"replacement"`) return
    `{:error, :encoder_unavailable}`.
  - Each encoder holds mutable state. Use one encoder per stream and avoid
    sharing it across concurrent processes.
  """

  alias EncodingRs.Native

  @enforce_keys [:resource, :dirty_threshold, :max_input_size]
  defstruct [:resource, :dirty_threshold, :max_input_size]

  @typedoc "An opaque encoder created with `new/1` or `new/2`."
  @opaque t :: %__MODULE__{
            resource: reference(),
            dirty_threshold: non_neg_integer(),
            max_input_size: non_neg_integer() | :infinity
          }

  @typedoc "Error reasons returned when creating an encoder."
  @type new_error :: :unknown_encoding | :encoder_unavailable

  @typedoc "Error reasons returned while encoding a chunk."
  @type chunk_error ::
          :input_too_large
          | :invalid_utf8
          | :unmappable_character
          | :encoder_finished
          | :allocation_failed
          | :lock_poisoned

  @typedoc "Error reasons emitted by non-bang encoder streams."
  @type stream_error :: new_error() | chunk_error()

  @typedoc "Result of encoding one chunk."
  @type encode_result :: {:ok, binary(), had_errors :: boolean()} | {:error, chunk_error()}

  @doc """
  Creates a stateful encoder for the requested output encoding.

  Accepts `:dirty_threshold`, `:max_input_size`, and `:on_error` (`:replace` or
  `:error`). Options passed to `new/2` are validated once and reused for every
  `encode_chunk/3` call.

  Returns `{:error, :encoder_unavailable}` for decode-only labels (`"utf-16le"`,
  `"utf-16be"`, `"replacement"`).

  ## Examples

      iex> {:ok, encoder} = EncodingRs.Encoder.new("shift_jis")
      iex> EncodingRs.Encoder.encode_chunk(encoder, "あ", true)
      {:ok, <<0x82, 0xA0>>, false}

      iex> EncodingRs.Encoder.new("utf-16le")
      {:error, :encoder_unavailable}

      iex> EncodingRs.Encoder.new("invalid-encoding")
      {:error, :unknown_encoding}
  """
  @spec new(EncodingRs.encoding()) :: {:ok, t()} | {:error, new_error()}
  @spec new(EncodingRs.encoding(), EncodingRs.encode_options()) ::
          {:ok, t()} | {:error, new_error()}
  def new(encoding, opts \\ []) when is_binary(encoding) and is_list(opts) do
    {dirty_threshold, max_input_size, on_error} = EncodingRs.resolve_encode_options(opts)

    case Native.encoder_new(encoding, on_error) do
      {:ok, resource, _} when is_reference(resource) ->
        {:ok,
         %__MODULE__{
           resource: resource,
           dirty_threshold: dirty_threshold,
           max_input_size: max_input_size
         }}

      {:error, _, reason} ->
        normalize_new_error(reason)
    end
  end

  @doc """
  Creates a stateful encoder, raising `ArgumentError` if the encoding is unknown
  or decode-only.

  ## Examples

      iex> encoder = EncodingRs.Encoder.new!("shift_jis")
      iex> EncodingRs.Encoder.encode_chunk!(encoder, "あ", true)
      {<<0x82, 0xA0>>, false}

      iex> EncodingRs.Encoder.new!("utf-16le")
      ** (ArgumentError) encoding is decode-only: utf-16le
  """
  @spec new!(EncodingRs.encoding()) :: t()
  @spec new!(EncodingRs.encoding(), EncodingRs.encode_options()) :: t()
  def new!(encoding, opts \\ []) when is_binary(encoding) and is_list(opts) do
    case new(encoding, opts) do
      {:ok, encoder} -> encoder
      {:error, reason} -> raise_new_error!(reason, encoding)
    end
  end

  @doc """
  Encodes one UTF-8 chunk using the stateful encoder.

  Incomplete multi-byte UTF-8 sequences at the end of `chunk` are buffered when
  `is_last` is `false`. Pass `is_last: true` on the final chunk to flush shift
  state and validate that no incomplete UTF-8 sequence remains.

  ## Examples

      iex> {:ok, encoder} = EncodingRs.Encoder.new("shift_jis")
      iex> <<b1, b2, b3>> = "あ"
      iex> {:ok, out1, false} = EncodingRs.Encoder.encode_chunk(encoder, <<b1, b2>>, false)
      iex> {:ok, out2, false} = EncodingRs.Encoder.encode_chunk(encoder, <<b3>>, true)
      iex> out1 <> out2
      <<0x82, 0xA0>>
  """
  @spec encode_chunk(t(), binary()) :: encode_result()
  @spec encode_chunk(t(), binary(), boolean()) :: encode_result()
  def encode_chunk(encoder, chunk, is_last \\ false)

  def encode_chunk(
        %__MODULE__{
          resource: resource,
          dirty_threshold: dirty_threshold,
          max_input_size: max_input_size
        },
        chunk,
        is_last
      )
      when is_binary(chunk) and is_boolean(is_last) do
    encode_chunk_resolved(resource, chunk, is_last, dirty_threshold, max_input_size)
  end

  @spec encode_chunk(t(), binary(), boolean(), EncodingRs.options()) :: encode_result()
  def encode_chunk(%__MODULE__{resource: resource}, chunk, is_last, opts)
      when is_binary(chunk) and is_boolean(is_last) and is_list(opts) do
    {dirty_threshold, max_input_size} = EncodingRs.resolve_options(opts)
    encode_chunk_resolved(resource, chunk, is_last, dirty_threshold, max_input_size)
  end

  defp encode_chunk_resolved(resource, chunk, is_last, dirty_threshold, max_input_size) do
    if max_input_size != :infinity and byte_size(chunk) > max_input_size do
      {:error, :input_too_large}
    else
      if byte_size(chunk) > dirty_threshold do
        Native.encoder_encode_chunk_dirty(resource, chunk, is_last)
      else
        Native.encoder_encode_chunk(resource, chunk, is_last)
      end
      |> normalize_encode_result()
    end
  end

  @doc """
  Encodes one UTF-8 chunk, returning `{binary, had_errors}` or raising on error.

  ## Examples

      iex> encoder = EncodingRs.Encoder.new!("windows-1252")
      iex> EncodingRs.Encoder.encode_chunk!(encoder, "hello", true)
      {"hello", false}
  """
  @spec encode_chunk!(t(), binary()) :: {binary(), boolean()}
  @spec encode_chunk!(t(), binary(), boolean()) :: {binary(), boolean()}
  def encode_chunk!(encoder, chunk, is_last \\ false)

  def encode_chunk!(%__MODULE__{} = encoder, chunk, is_last)
      when is_binary(chunk) and is_boolean(is_last) do
    encoder
    |> encode_chunk(chunk, is_last)
    |> unwrap_encode_result!()
  end

  @spec encode_chunk!(t(), binary(), boolean(), EncodingRs.options()) :: {binary(), boolean()}
  def encode_chunk!(%__MODULE__{} = encoder, chunk, is_last, opts)
      when is_binary(chunk) and is_boolean(is_last) and is_list(opts) do
    encoder
    |> encode_chunk(chunk, is_last, opts)
    |> unwrap_encode_result!()
  end

  @doc """
  Returns a non-raising stream that encodes UTF-8 chunks to tagged binary
  results.

  Each emitted element is `{:ok, binary}` or `{:error, reason}`. If the
  encoding is unknown or decode-only, the stream emits one `{:error, reason}`
  tuple without reading from `chunks`. Invalid option keys or values raise
  `ArgumentError` immediately.

  Use `stream!/3` when you want plain binaries and exceptions on error.

  ## Examples

      iex> ["こん", "にちは"] |> EncodingRs.Encoder.stream("shift_jis") |> Enum.to_list()
      [{:ok, <<130, 177, 130, 241>>}, {:ok, <<130, 201, 130, 191, 130, 205>>}]

      iex> ["hello"] |> EncodingRs.Encoder.stream("utf-16le") |> Enum.to_list()
      [{:error, :encoder_unavailable}]
  """
  @spec stream(Enumerable.t(), EncodingRs.encoding()) :: Enumerable.t()
  @spec stream(Enumerable.t(), EncodingRs.encoding(), EncodingRs.encode_options()) ::
          Enumerable.t()
  def stream(chunks, encoding, opts \\ []) when is_binary(encoding) and is_list(opts) do
    resolved = EncodingRs.resolve_encode_options(opts)
    non_raising_stream(chunks, encoding, resolved, :plain)
  end

  @doc """
  Returns a stream that encodes UTF-8 chunks to binaries, raising on error.

  ## Examples

      iex> ["こん", "にちは"] |> EncodingRs.Encoder.stream!("shift_jis") |> Enum.into(<<>>)
      <<130, 177, 130, 241, 130, 201, 130, 191, 130, 205>>
  """
  @spec stream!(Enumerable.t(), EncodingRs.encoding()) :: Enumerable.t()
  @spec stream!(Enumerable.t(), EncodingRs.encoding(), EncodingRs.encode_options()) ::
          Enumerable.t()
  def stream!(chunks, encoding, opts \\ []) when is_binary(encoding) and is_list(opts) do
    resolved = EncodingRs.resolve_encode_options(opts)
    raising_stream(chunks, encoding, resolved, :plain)
  end

  @doc """
  Returns a non-raising stream that encodes UTF-8 chunks and reports
  unmappable-character replacements.

  Each emitted element is `{:ok, binary, had_errors}` or `{:error, reason}`.

  ## Examples

      iex> ["Hello", "🎉"] |> EncodingRs.Encoder.stream_with_errors("windows-1252") |> Enum.to_list()
      [{:ok, "Hello", false}, {:ok, "&#127881;", true}]
  """
  @spec stream_with_errors(Enumerable.t(), EncodingRs.encoding()) :: Enumerable.t()
  @spec stream_with_errors(Enumerable.t(), EncodingRs.encoding(), EncodingRs.encode_options()) ::
          Enumerable.t()
  def stream_with_errors(chunks, encoding, opts \\ [])
      when is_binary(encoding) and is_list(opts) do
    resolved = EncodingRs.resolve_encode_options(opts)
    non_raising_stream(chunks, encoding, resolved, :with_errors)
  end

  @doc """
  Returns a stream that encodes UTF-8 chunks to `{binary, had_errors}` tuples,
  raising on error.

  ## Examples

      iex> ["Hello", "🎉"] |> EncodingRs.Encoder.stream_with_errors!("windows-1252") |> Enum.to_list()
      [{"Hello", false}, {"&#127881;", true}]
  """
  @spec stream_with_errors!(Enumerable.t(), EncodingRs.encoding()) :: Enumerable.t()
  @spec stream_with_errors!(Enumerable.t(), EncodingRs.encoding(), EncodingRs.encode_options()) ::
          Enumerable.t()
  def stream_with_errors!(chunks, encoding, opts \\ [])
      when is_binary(encoding) and is_list(opts) do
    resolved = EncodingRs.resolve_encode_options(opts)
    raising_stream(chunks, encoding, resolved, :with_errors)
  end

  # Stream implementations

  defp non_raising_stream(chunks, encoding, opts, mode) do
    case validate_stream_encoding(encoding) do
      {:error, reason} -> error_stream(reason)
      :ok -> build_non_raising_stream(chunks, encoding, opts, mode)
    end
  end

  defp build_non_raising_stream(
         chunks,
         encoding,
         {dirty_threshold, max_input_size, on_error},
         mode
       ) do
    Stream.transform(
      chunks,
      fn ->
        {:ok, resource, _} = Native.encoder_new(encoding, on_error)
        {:ok, resource, dirty_threshold, max_input_size}
      end,
      fn
        _chunk, :halted ->
          {:halt, :halted}

        chunk, {:ok, resource, dt, max} = state ->
          case encode_chunk_resolved(resource, chunk, false, dt, max) do
            {:ok, output, had_errors} ->
              {[wrap_stream_ok(output, had_errors, mode)], state}

            {:error, reason} ->
              {[{:error, reason}], :halted}
          end
      end,
      fn
        :halted ->
          {[], :halted}

        {:ok, resource, dt, max} = state ->
          case encode_chunk_resolved(resource, <<>>, true, dt, max) do
            {:ok, <<>>, _had_errors} ->
              {[], state}

            {:ok, output, had_errors} ->
              {[wrap_stream_ok(output, had_errors, mode)], state}

            {:error, reason} ->
              {[{:error, reason}], :halted}
          end
      end,
      fn _state -> :ok end
    )
  end

  defp raising_stream(chunks, encoding, {dirty_threshold, max_input_size, on_error}, mode) do
    Stream.transform(
      chunks,
      fn ->
        case Native.encoder_new(encoding, on_error) do
          {:ok, resource, _} when is_reference(resource) ->
            {resource, dirty_threshold, max_input_size}

          {:error, _, reason} ->
            {:error, atom} = normalize_new_error(reason)
            raise_new_error!(atom, encoding)
        end
      end,
      fn chunk, {resource, dt, max} = state ->
        {output, had_errors} = encode_chunk_resolved!(resource, chunk, false, dt, max)
        {[wrap_raising_ok(output, had_errors, mode)], state}
      end,
      fn {resource, dt, max} = state ->
        {output, had_errors} = encode_chunk_resolved!(resource, <<>>, true, dt, max)

        if output == <<>> do
          {[], state}
        else
          {[wrap_raising_ok(output, had_errors, mode)], state}
        end
      end,
      fn _state -> :ok end
    )
  end

  defp validate_stream_encoding(encoding) do
    cond do
      EncodingRs.can_encode?(encoding) -> :ok
      EncodingRs.encoding_exists?(encoding) -> {:error, :encoder_unavailable}
      true -> {:error, :unknown_encoding}
    end
  end

  defp error_stream(reason) do
    Stream.resource(
      fn -> :emit end,
      fn
        :emit -> {[{:error, reason}], :done}
        :done -> {:halt, :done}
      end,
      fn _ -> :ok end
    )
  end

  defp wrap_stream_ok(output, _had_errors, :plain), do: {:ok, output}
  defp wrap_stream_ok(output, had_errors, :with_errors), do: {:ok, output, had_errors}

  defp wrap_raising_ok(output, _had_errors, :plain), do: output
  defp wrap_raising_ok(output, had_errors, :with_errors), do: {output, had_errors}

  # Private helpers

  defp encode_chunk_resolved!(resource, chunk, is_last, dirty_threshold, max_input_size) do
    resource
    |> encode_chunk_resolved(chunk, is_last, dirty_threshold, max_input_size)
    |> unwrap_encode_result!()
  end

  defp unwrap_encode_result!({:ok, output, had_errors}), do: {output, had_errors}

  defp unwrap_encode_result!({:error, reason}),
    do: raise(RuntimeError, "encoder error: #{reason}")

  defp normalize_new_error("encoder_unavailable"), do: {:error, :encoder_unavailable}
  defp normalize_new_error(_), do: {:error, :unknown_encoding}

  defp raise_new_error!(:unknown_encoding, encoding) do
    raise ArgumentError, "unknown encoding: #{encoding}"
  end

  defp raise_new_error!(:encoder_unavailable, encoding) do
    raise ArgumentError, "encoding is decode-only: #{encoding}"
  end

  defp normalize_encode_result({:ok, output, had_errors}), do: {:ok, output, had_errors}
  defp normalize_encode_result({:error, "invalid_utf8", _}), do: {:error, :invalid_utf8}

  defp normalize_encode_result({:error, "unmappable_character", _}),
    do: {:error, :unmappable_character}

  defp normalize_encode_result({:error, "encoder_finished", _}), do: {:error, :encoder_finished}
  defp normalize_encode_result({:error, "allocation_failed", _}), do: {:error, :allocation_failed}
  defp normalize_encode_result({:error, "lock_poisoned", _}), do: {:error, :lock_poisoned}
  defp normalize_encode_result({:error, reason, _}), do: {:error, reason}
end
