defmodule EncodingRs.Decoder do
  @moduledoc """
  Stateful streaming decoder for converting encoded byte streams to UTF-8.

  Use this module when decoding multibyte encodings (such as Shift_JIS, GBK,
  Big5, EUC-JP, or UTF-16) from chunked sources like `File.stream!/3` or
  network sockets. Incomplete byte sequences at the end of a chunk stay
  buffered until the next chunk completes them.

  ## Usage

  ### Stream pipelines

  Use `stream/3` when you want error tuples instead of exceptions, or `stream!/3`
  for pipelines that expect plain strings and raise on error:

      File.stream!("data.txt", [], 64 * 1024)
      |> EncodingRs.Decoder.stream!("shift_jis")
      |> Enum.join()

      File.stream!("data.txt", [], 64 * 1024)
      |> EncodingRs.Decoder.stream("shift_jis", on_error: :error)
      |> Enum.reduce_while([], fn
        {:ok, chunk}, acc -> {:cont, [chunk | acc]}
        {:error, reason}, _acc -> {:halt, {:error, reason}}
      end)

  ### Manual chunk loops

      {:ok, decoder} = EncodingRs.Decoder.new("shift_jis")
      {:ok, out1, false} = EncodingRs.Decoder.decode_chunk(decoder, chunk1, false)
      {:ok, out2, false} = EncodingRs.Decoder.decode_chunk(decoder, chunk2, true)
      result = out1 <> out2

  ## Important notes

  - Pass `is_last: true` on the final chunk to flush buffered bytes. Calling
    `decode_chunk/3` after `is_last: true` returns `{:error, :decoder_finished}`.
  - Each decoder holds mutable state. Use one decoder per stream and avoid
    sharing it across concurrent processes.
  - For complete binaries already in memory, prefer `EncodingRs.decode/3`.
  """

  alias EncodingRs.Native

  @enforce_keys [:resource, :dirty_threshold, :max_input_size]
  defstruct [:resource, :dirty_threshold, :max_input_size]

  @typedoc "An opaque decoder created with `new/1` or `new/2`."
  @opaque t :: %__MODULE__{
            resource: reference(),
            dirty_threshold: non_neg_integer(),
            max_input_size: non_neg_integer() | :infinity
          }

  @typedoc "Error reasons returned while decoding a chunk."
  @type chunk_error ::
          :input_too_large
          | :malformed_input
          | :decoder_finished
          | :allocation_failed
          | :lock_poisoned

  @typedoc "Error reasons emitted by non-bang decoder streams."
  @type stream_error :: :unknown_encoding | chunk_error()

  @typedoc "Result of decoding one chunk."
  @type decode_result :: {:ok, String.t(), had_errors :: boolean()} | {:error, chunk_error()}

  @doc """
  Creates a stateful decoder for the requested encoding.

  Accepts `:dirty_threshold`, `:max_input_size`, `:bom` (`:sniff`, `:strip`,
  or `:preserve`), and `:on_error` (`:replace` or `:error`). Options passed to
  `new/2` are validated once and reused for every `decode_chunk/3` call.

  ## Examples

      iex> {:ok, decoder} = EncodingRs.Decoder.new("shift_jis")
      iex> EncodingRs.Decoder.decode_chunk(decoder, <<0x82, 0xA0>>, true)
      {:ok, "あ", false}

      iex> EncodingRs.Decoder.new("invalid-encoding")
      {:error, :unknown_encoding}

      iex> {:ok, decoder} = EncodingRs.Decoder.new("utf-8", max_input_size: 4)
      iex> EncodingRs.Decoder.decode_chunk(decoder, "hello", true)
      {:error, :input_too_large}
  """
  @spec new(EncodingRs.encoding()) :: {:ok, t()} | {:error, :unknown_encoding}
  @spec new(EncodingRs.encoding(), EncodingRs.decode_options()) ::
          {:ok, t()} | {:error, :unknown_encoding}
  def new(encoding, opts \\ []) when is_binary(encoding) and is_list(opts) do
    {dirty_threshold, max_input_size, bom, on_error} = EncodingRs.resolve_decode_options(opts)

    case Native.decoder_new(encoding, bom, on_error) do
      {:ok, resource, _} when is_reference(resource) ->
        {:ok,
         %__MODULE__{
           resource: resource,
           dirty_threshold: dirty_threshold,
           max_input_size: max_input_size
         }}

      {:error, _, _} ->
        {:error, :unknown_encoding}
    end
  end

  @doc """
  Creates a stateful decoder, raising `ArgumentError` if the encoding is unknown.

  ## Examples

      iex> decoder = EncodingRs.Decoder.new!("shift_jis")
      iex> EncodingRs.Decoder.decode_chunk!(decoder, <<0x82, 0xA0>>, true)
      {"あ", false}

      iex> EncodingRs.Decoder.new!("invalid-encoding")
      ** (ArgumentError) unknown encoding: invalid-encoding
  """
  @spec new!(EncodingRs.encoding()) :: t()
  @spec new!(EncodingRs.encoding(), EncodingRs.decode_options()) :: t()
  def new!(encoding, opts \\ []) when is_binary(encoding) and is_list(opts) do
    case new(encoding, opts) do
      {:ok, decoder} -> decoder
      {:error, :unknown_encoding} -> raise ArgumentError, "unknown encoding: #{encoding}"
    end
  end

  @doc """
  Returns the decoder's active canonical encoding name.

  When the decoder uses `bom: :sniff` (default), this value updates after the
  first chunk if a leading UTF-8 or UTF-16 BOM switches the encoding.

  ## Examples

      iex> {:ok, decoder} = EncodingRs.Decoder.new("windows-1252")
      iex> {:ok, "H", false} = EncodingRs.Decoder.decode_chunk(decoder, <<0xFF, 0xFE, 0x48, 0x00>>, true)
      iex> EncodingRs.Decoder.encoding(decoder)
      {:ok, "UTF-16LE"}
  """
  @spec encoding(t()) :: {:ok, EncodingRs.encoding()} | {:error, :lock_poisoned}
  def encoding(%__MODULE__{resource: resource}) do
    case Native.decoder_encoding(resource) do
      {:ok, name} -> {:ok, name}
      {:error, "lock_poisoned"} -> {:error, :lock_poisoned}
    end
  end

  @doc """
  Decodes one chunk of bytes using the stateful decoder.

  Pass `is_last: true` on the final chunk to flush buffered bytes. Calling this
  function again after `is_last: true` (or after a strict-mode error) returns
  `{:error, :decoder_finished}`.

  ## Examples

      iex> {:ok, decoder} = EncodingRs.Decoder.new("shift_jis")
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

  @spec decode_chunk(t(), binary(), boolean(), EncodingRs.options()) :: decode_result()
  def decode_chunk(%__MODULE__{resource: resource}, chunk, is_last, opts)
      when is_binary(chunk) and is_boolean(is_last) and is_list(opts) do
    {dirty_threshold, max_input_size} = EncodingRs.resolve_options(opts)
    decode_chunk_resolved(resource, chunk, is_last, dirty_threshold, max_input_size)
  end

  defp decode_chunk_resolved(resource, chunk, is_last, dirty_threshold, max_input_size) do
    if max_input_size != :infinity and byte_size(chunk) > max_input_size do
      {:error, :input_too_large}
    else
      if byte_size(chunk) > dirty_threshold do
        Native.decoder_decode_chunk_dirty(resource, chunk, is_last)
      else
        Native.decoder_decode_chunk(resource, chunk, is_last)
      end
      |> normalize_decode_result()
    end
  end

  @doc """
  Decodes one chunk, returning `{output, had_errors}` or raising on error.

  ## Examples

      iex> decoder = EncodingRs.Decoder.new!("utf-8")
      iex> EncodingRs.Decoder.decode_chunk!(decoder, "hello", true)
      {"hello", false}
  """
  @spec decode_chunk!(t(), binary()) :: {String.t(), boolean()}
  @spec decode_chunk!(t(), binary(), boolean()) :: {String.t(), boolean()}
  def decode_chunk!(decoder, chunk, is_last \\ false)

  def decode_chunk!(%__MODULE__{} = decoder, chunk, is_last)
      when is_binary(chunk) and is_boolean(is_last) do
    decoder
    |> decode_chunk(chunk, is_last)
    |> unwrap_decode_result!()
  end

  @spec decode_chunk!(t(), binary(), boolean(), EncodingRs.options()) :: {String.t(), boolean()}
  def decode_chunk!(%__MODULE__{} = decoder, chunk, is_last, opts)
      when is_binary(chunk) and is_boolean(is_last) and is_list(opts) do
    decoder
    |> decode_chunk(chunk, is_last, opts)
    |> unwrap_decode_result!()
  end

  @doc """
  Returns a non-raising stream that decodes binary chunks to tagged UTF-8
  results.

  Each emitted element is `{:ok, string}` or `{:error, reason}`. If the
  encoding is unknown, the stream emits one `{:error, :unknown_encoding}` tuple
  without reading from `chunks`. If a chunk fails (for example
  `:input_too_large` or `:malformed_input` under `on_error: :error`), the
  stream emits one `{:error, reason}` tuple and stops. Invalid option keys or
  values still raise `ArgumentError` immediately.

  Use `stream!/3` when you want plain strings and exceptions on error.

  ## Examples

      iex> [<<0x82>>, <<0xA0>>] |> EncodingRs.Decoder.stream("shift_jis") |> Enum.to_list()
      [{:ok, ""}, {:ok, "あ"}]

      iex> ["hello"] |> EncodingRs.Decoder.stream("not-an-encoding") |> Enum.to_list()
      [{:error, :unknown_encoding}]
  """
  @spec stream(Enumerable.t(), EncodingRs.encoding()) :: Enumerable.t()
  @spec stream(Enumerable.t(), EncodingRs.encoding(), EncodingRs.decode_options()) ::
          Enumerable.t()
  def stream(chunks, encoding, opts \\ []) when is_binary(encoding) and is_list(opts) do
    resolved = EncodingRs.resolve_decode_options(opts)
    non_raising_stream(chunks, encoding, resolved, :plain)
  end

  @doc """
  Returns a stream that decodes binary chunks to UTF-8 strings, raising on error.

  Emits one string per input chunk, plus one final flush element if buffered
  bytes remain at the end of the stream.

  ## Examples

      iex> [<<0x82>>, <<0xA0>>] |> EncodingRs.Decoder.stream!("shift_jis") |> Enum.join()
      "あ"
  """
  @spec stream!(Enumerable.t(), EncodingRs.encoding()) :: Enumerable.t()
  @spec stream!(Enumerable.t(), EncodingRs.encoding(), EncodingRs.decode_options()) ::
          Enumerable.t()
  def stream!(chunks, encoding, opts \\ []) when is_binary(encoding) and is_list(opts) do
    resolved = EncodingRs.resolve_decode_options(opts)
    raising_stream(chunks, encoding, resolved, :plain)
  end

  @doc """
  Returns a non-raising stream that decodes binary chunks and reports
  replacement errors.

  Each emitted element is `{:ok, string, had_errors}` or `{:error, reason}`.
  On error, the stream emits one `{:error, reason}` tuple and stops.

  Use `stream_with_errors!/3` when you want `{string, had_errors}` tuples and
  exceptions on error.

  ## Examples

      iex> [<<"hello">>, <<0xFF>>] |> EncodingRs.Decoder.stream_with_errors("utf-8") |> Enum.to_list()
      [{:ok, "hello", false}, {:ok, "\uFFFD", true}]
  """
  @spec stream_with_errors(Enumerable.t(), EncodingRs.encoding()) :: Enumerable.t()
  @spec stream_with_errors(Enumerable.t(), EncodingRs.encoding(), EncodingRs.decode_options()) ::
          Enumerable.t()
  def stream_with_errors(chunks, encoding, opts \\ [])
      when is_binary(encoding) and is_list(opts) do
    resolved = EncodingRs.resolve_decode_options(opts)
    non_raising_stream(chunks, encoding, resolved, :with_errors)
  end

  @doc """
  Returns a stream that decodes binary chunks to `{string, had_errors}` tuples,
  raising on error.

  ## Examples

      iex> [<<"hello">>, <<0xFF>>] |> EncodingRs.Decoder.stream_with_errors!("utf-8") |> Enum.to_list()
      [{"hello", false}, {"\uFFFD", true}]
  """
  @spec stream_with_errors!(Enumerable.t(), EncodingRs.encoding()) :: Enumerable.t()
  @spec stream_with_errors!(Enumerable.t(), EncodingRs.encoding(), EncodingRs.decode_options()) ::
          Enumerable.t()
  def stream_with_errors!(chunks, encoding, opts \\ [])
      when is_binary(encoding) and is_list(opts) do
    resolved = EncodingRs.resolve_decode_options(opts)
    raising_stream(chunks, encoding, resolved, :with_errors)
  end

  # Stream implementations

  defp non_raising_stream(chunks, encoding, opts, mode) do
    if EncodingRs.encoding_exists?(encoding) do
      build_non_raising_stream(chunks, encoding, opts, mode)
    else
      error_stream(:unknown_encoding)
    end
  end

  defp build_non_raising_stream(
         chunks,
         encoding,
         {dirty_threshold, max_input_size, bom, on_error},
         mode
       ) do
    Stream.transform(
      chunks,
      fn ->
        {:ok, resource, _} = Native.decoder_new(encoding, bom, on_error)
        {:ok, resource, dirty_threshold, max_input_size}
      end,
      fn
        _chunk, :halted ->
          {:halt, :halted}

        chunk, {:ok, resource, dt, max} = state ->
          case decode_chunk_resolved(resource, chunk, false, dt, max) do
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
          case decode_chunk_resolved(resource, <<>>, true, dt, max) do
            {:ok, "", _had_errors} ->
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

  defp raising_stream(chunks, encoding, {dirty_threshold, max_input_size, bom, on_error}, mode) do
    Stream.transform(
      chunks,
      fn ->
        case Native.decoder_new(encoding, bom, on_error) do
          {:ok, resource, _} when is_reference(resource) ->
            {resource, dirty_threshold, max_input_size}

          {:error, _, _} ->
            raise ArgumentError, "unknown encoding: #{encoding}"
        end
      end,
      fn chunk, {resource, dt, max} = state ->
        {output, had_errors} = decode_chunk_resolved!(resource, chunk, false, dt, max)
        {[wrap_raising_ok(output, had_errors, mode)], state}
      end,
      fn {resource, dt, max} = state ->
        {output, had_errors} = decode_chunk_resolved!(resource, <<>>, true, dt, max)

        if output == "" do
          {[], state}
        else
          {[wrap_raising_ok(output, had_errors, mode)], state}
        end
      end,
      fn _state -> :ok end
    )
  end

  defp wrap_stream_ok(output, _had_errors, :plain), do: {:ok, output}
  defp wrap_stream_ok(output, had_errors, :with_errors), do: {:ok, output, had_errors}

  defp wrap_raising_ok(output, _had_errors, :plain), do: output
  defp wrap_raising_ok(output, had_errors, :with_errors), do: {output, had_errors}

  # Private helpers

  defp decode_chunk_resolved!(resource, chunk, is_last, dirty_threshold, max_input_size) do
    resource
    |> decode_chunk_resolved(chunk, is_last, dirty_threshold, max_input_size)
    |> unwrap_decode_result!()
  end

  defp unwrap_decode_result!({:ok, output, had_errors}), do: {output, had_errors}

  defp unwrap_decode_result!({:error, reason}),
    do: raise(RuntimeError, "decoder error: #{reason}")

  defp normalize_decode_result({:ok, output, had_errors}), do: {:ok, output, had_errors}
  defp normalize_decode_result({:error, "malformed_input", _}), do: {:error, :malformed_input}
  defp normalize_decode_result({:error, "decoder_finished", _}), do: {:error, :decoder_finished}
  defp normalize_decode_result({:error, "allocation_failed", _}), do: {:error, :allocation_failed}
  defp normalize_decode_result({:error, "lock_poisoned", _}), do: {:error, :lock_poisoned}
  defp normalize_decode_result({:error, reason, _}), do: {:error, reason}
end
