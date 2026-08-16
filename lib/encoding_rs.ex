defmodule EncodingRs do
  @moduledoc """
  High-performance string encoding/decoding using Rust's `encoding_rs` crate.

  This library provides fast character encoding conversion using the same
  encoding library that powers Firefox. It decodes all encodings in the WHATWG
  Encoding Standard and encodes their output encodings.

  ## Features

  - **High performance**: Uses `encoding_rs`, the same library used by Firefox
  - **Dirty schedulers**: Large binaries automatically use dirty CPU schedulers
    to avoid blocking the BEAM (default threshold: 64KB)
  - **Safe error handling**: Returns `{:ok, result}` or `{:error, reason}` tuples
  - **WHATWG compliant**: Implements the WHATWG decoding and encoding algorithms

  ## Operation options

  Encoding, decoding, batch, and streaming functions accept per-call options:

  - `:dirty_threshold` — byte size above which dirty CPU schedulers are used
    (default: 65,536).
  - `:max_input_size` — maximum input or chunk size (default: 104,857,600).
    Set it to `:infinity` only for trusted, externally bounded input.

      EncodingRs.decode(data, "shift_jis",
        dirty_threshold: 128 * 1024,
        max_input_size: 10 * 1024 * 1024
      )

  > #### Warning {: .warning}
  >
  > Disabling the size limit or setting it very high removes a safety guardrail
  > against memory exhaustion. Only do this when inputs are trusted and bounded
  > by other means (e.g., request body limits, file size checks). For untrusted
  > input, prefer the streaming decoder (`EncodingRs.Decoder`) with bounded
  > chunk sizes.

  New code should prefer explicit options. Existing application configuration
  remains supported as a compatibility fallback.

  ## Supported Encodings

  * UTF-8 (encode/decode); UTF-16LE and UTF-16BE (decode only)
  * Windows code pages: 874, 1250-1258, 949, 932
  * ISO-8859 family: 2, 3, 4, 5, 6, 7, 8, 8-I, 10, 13, 14, 15, 16
  * IBM866
  * KOI8-R, KOI8-U
  * macintosh, x-mac-cyrillic
  * Asian encodings: Shift_JIS, EUC-JP, ISO-2022-JP, EUC-KR, GBK, GB18030, Big5
  * x-user-defined

  ## Examples

      iex> EncodingRs.encode("Hello", "windows-1252")
      {:ok, "Hello"}

      iex> EncodingRs.decode(<<72, 101, 108, 108, 111>>, "windows-1252")
      {:ok, "Hello"}

      iex> EncodingRs.encode!("¥₪ש", "windows-1255")
      <<165, 164, 249>>

      iex> EncodingRs.decode!(<<165, 164, 249>>, "windows-1255")
      "¥₪ש"

      iex> EncodingRs.encoding_exists?("utf-8")
      true

      iex> EncodingRs.encoding_exists?("not-an-encoding")
      false
  """

  alias EncodingRs.Native

  @default_dirty_threshold Application.compile_env(
                             :encoding_rs,
                             :dirty_threshold,
                             64 * 1024
                           )
  @default_max_input_size 100 * 1024 * 1024
  @option_keys [:dirty_threshold, :max_input_size]

  unless is_integer(@default_dirty_threshold) and @default_dirty_threshold >= 0 do
    raise ArgumentError,
          "expected :dirty_threshold to be a non-negative integer, got: #{inspect(@default_dirty_threshold)}"
  end

  # Types

  @typedoc """
  An encoding label string (e.g., `"utf-8"`, `"shift_jis"`, `"windows-1252"`).

  See `list_encodings/0` for all recognized encodings, or check the
  [WHATWG Encoding Standard](https://encoding.spec.whatwg.org/#names-and-labels).
  """
  @type encoding :: String.t()

  @typedoc "Per-operation scheduler and input-size options."
  @type options :: [
          {:dirty_threshold, non_neg_integer()}
          | {:max_input_size, non_neg_integer() | :infinity}
        ]

  @typedoc "Error reason atoms returned by encoding/decoding functions."
  @type error_reason ::
          :unknown_encoding | :encoder_unavailable | :no_bom | :input_too_large

  @typedoc "Detailed one-shot decode result, including BOM selection and replacements."
  @type decode_details_result ::
          {:ok, String.t(), actual_encoding :: encoding(), had_errors :: boolean()}
          | {:error, :unknown_encoding | :input_too_large}

  @typedoc "Result of BOM detection: encoding name and BOM length in bytes."
  @type bom_result :: {:ok, encoding(), bom_length :: non_neg_integer()} | {:error, :no_bom}

  # Functions

  @doc """
  Encodes a UTF-8 string to the specified encoding.

  Returns `{:ok, binary}` on success, or `{:error, reason}` on failure.
  Unmappable characters are replaced with a suitable fallback character.

  UTF-16LE and UTF-16BE are decode-only in the WHATWG Encoding Standard.
  Those labels and `replacement` return `{:error, :encoder_unavailable}`;
  this function never returns bytes in a different encoding than requested.

  Automatically uses dirty CPU schedulers for strings larger than the selected
  threshold (see `dirty_threshold/1`).

  ## Examples

      iex> EncodingRs.encode("Hello", "windows-1252")
      {:ok, "Hello"}

      iex> EncodingRs.encode("Hello", "invalid-encoding")
      {:error, :unknown_encoding}
  """
  @spec encode(String.t(), encoding()) ::
          {:ok, binary()}
          | {:error, :unknown_encoding | :encoder_unavailable | :input_too_large}
  @spec encode(String.t(), encoding(), options()) ::
          {:ok, binary()}
          | {:error, :unknown_encoding | :encoder_unavailable | :input_too_large}
  def encode(string, encoding) when is_binary(string) and is_binary(encoding) do
    encode_native(string, encoding, @default_dirty_threshold, max_input_size())
  end

  def encode(string, encoding, opts)
      when is_binary(string) and is_binary(encoding) and is_list(opts) do
    {dirty_threshold, max_input_size} = options!(opts)

    encode_native(string, encoding, dirty_threshold, max_input_size)
  end

  defp encode_native(string, encoding, dirty_threshold, max_input_size) do
    with :ok <- validate_input_size(string, max_input_size) do
      string
      |> route_nif(encoding, &Native.encode_normal/2, &Native.encode_dirty/2, dirty_threshold)
      |> normalize_result()
    end
  end

  @doc """
  Encodes a UTF-8 string to the specified encoding.

  Returns the encoded binary on success, or raises an `ArgumentError` on failure.

  ## Examples

      iex> EncodingRs.encode!("Hello", "windows-1252")
      "Hello"

      iex> EncodingRs.encode!("Hello", "invalid-encoding")
      ** (ArgumentError) unknown encoding: invalid-encoding
  """
  @spec encode!(String.t(), encoding()) :: binary()
  @spec encode!(String.t(), encoding(), options()) :: binary()
  def encode!(string, encoding) when is_binary(string) and is_binary(encoding) do
    string
    |> encode(encoding)
    |> unwrap_result!(encoding, :default)
  end

  def encode!(string, encoding, opts)
      when is_binary(string) and is_binary(encoding) and is_list(opts) do
    string
    |> encode(encoding, opts)
    |> unwrap_result!(encoding, opts)
  end

  @doc """
  Decodes a binary from the specified encoding to a UTF-8 string.

  Returns `{:ok, string}` on success, or `{:error, reason}` on failure.
  Malformed byte sequences are replaced with the Unicode replacement character (U+FFFD).
  An input BOM may override the requested encoding. Use `decode_with_details/3`
  when either behavior must be observed.

  Automatically uses dirty CPU schedulers for binaries larger than the selected
  threshold (see `dirty_threshold/1`).

  ## Examples

      iex> EncodingRs.decode(<<72, 101, 108, 108, 111>>, "windows-1252")
      {:ok, "Hello"}

      iex> EncodingRs.decode(<<0xFF>>, "invalid-encoding")
      {:error, :unknown_encoding}
  """
  @spec decode(binary(), encoding()) ::
          {:ok, String.t()} | {:error, :unknown_encoding | :input_too_large}
  @spec decode(binary(), encoding(), options()) ::
          {:ok, String.t()} | {:error, :unknown_encoding | :input_too_large}
  def decode(binary, encoding) when is_binary(binary) and is_binary(encoding) do
    binary
    |> decode_native(
      encoding,
      &Native.decode_normal/2,
      &Native.decode_dirty/2,
      @default_dirty_threshold,
      max_input_size()
    )
    |> normalize_result()
  end

  def decode(binary, encoding, opts)
      when is_binary(binary) and is_binary(encoding) and is_list(opts) do
    {dirty_threshold, max_input_size} = options!(opts)

    binary
    |> decode_native(
      encoding,
      &Native.decode_normal/2,
      &Native.decode_dirty/2,
      dirty_threshold,
      max_input_size
    )
    |> normalize_result()
  end

  @doc """
  Decodes a complete binary and reports the encoding actually used and whether
  malformed input was replaced with U+FFFD.

  The actual encoding can differ from the requested label when the input starts
  with a UTF-8 or UTF-16 BOM.

  ## Examples

      iex> EncodingRs.decode_with_details(<<0xFF>>, "utf-8")
      {:ok, "�", "UTF-8", true}

      iex> EncodingRs.decode_with_details(<<0xFF, 0xFE, 0x48, 0x00>>, "windows-1252")
      {:ok, "H", "UTF-16LE", false}
  """
  @spec decode_with_details(binary(), encoding()) :: decode_details_result()
  @spec decode_with_details(binary(), encoding(), options()) :: decode_details_result()
  def decode_with_details(binary, encoding)
      when is_binary(binary) and is_binary(encoding) do
    binary
    |> decode_native(
      encoding,
      &Native.decode_with_details_normal/2,
      &Native.decode_with_details_dirty/2,
      @default_dirty_threshold,
      max_input_size()
    )
    |> normalize_decode_details()
  end

  def decode_with_details(binary, encoding, opts)
      when is_binary(binary) and is_binary(encoding) and is_list(opts) do
    {dirty_threshold, max_input_size} = options!(opts)

    binary
    |> decode_native(
      encoding,
      &Native.decode_with_details_normal/2,
      &Native.decode_with_details_dirty/2,
      dirty_threshold,
      max_input_size
    )
    |> normalize_decode_details()
  end

  defp decode_native(binary, encoding, normal_fn, dirty_fn, dirty_threshold, max_input_size) do
    with :ok <- validate_input_size(binary, max_input_size) do
      route_nif(binary, encoding, normal_fn, dirty_fn, dirty_threshold)
    end
  end

  @doc """
  Decodes a binary from the specified encoding to a UTF-8 string.

  Returns the decoded string on success, or raises an `ArgumentError` on failure.

  ## Examples

      iex> EncodingRs.decode!(<<72, 101, 108, 108, 111>>, "windows-1252")
      "Hello"

      iex> EncodingRs.decode!(<<0xFF>>, "invalid-encoding")
      ** (ArgumentError) unknown encoding: invalid-encoding
  """
  @spec decode!(binary(), encoding()) :: String.t()
  @spec decode!(binary(), encoding(), options()) :: String.t()
  def decode!(binary, encoding) when is_binary(binary) and is_binary(encoding) do
    binary
    |> decode(encoding)
    |> unwrap_result!(encoding, :default)
  end

  def decode!(binary, encoding, opts)
      when is_binary(binary) and is_binary(encoding) and is_list(opts) do
    binary
    |> decode(encoding, opts)
    |> unwrap_result!(encoding, opts)
  end

  @doc """
  Checks if an encoding label is recognized for decoding.

  This returns `true` for decode-only labels such as UTF-16LE and UTF-16BE.

  ## Examples

      iex> EncodingRs.encoding_exists?("utf-8")
      true

      iex> EncodingRs.encoding_exists?("UTF-8")
      true

      iex> EncodingRs.encoding_exists?("not-an-encoding")
      false
  """
  @spec encoding_exists?(encoding()) :: boolean()
  def encoding_exists?(encoding) when is_binary(encoding) do
    Native.encoding_exists(encoding)
  end

  @doc """
  Returns whether the native implementation is loaded and callable.

  This check never raises when the NIF is unavailable, allowing applications
  to disable optional encoding features cleanly.

  ## Examples

      iex> EncodingRs.available?()
      true
  """
  @spec available?() :: boolean()
  def available? do
    Native.encoding_exists("utf-8")
  catch
    :error, reason when reason in [:nif_not_loaded, :undef] -> false
  end

  @doc """
  Returns the canonical name for an encoding label.

  Encoding labels have many aliases (e.g., "latin1", "iso-8859-1", "iso_8859-1").
  This function returns the canonical WHATWG name for any valid alias.

  ## Examples

      iex> EncodingRs.canonical_name("latin1")
      {:ok, "windows-1252"}

      iex> EncodingRs.canonical_name("utf8")
      {:ok, "UTF-8"}

      iex> EncodingRs.canonical_name("invalid")
      {:error, :unknown_encoding}
  """
  @spec canonical_name(encoding()) :: {:ok, encoding()} | {:error, :unknown_encoding}
  def canonical_name(encoding) when is_binary(encoding) do
    case Native.canonical_name(encoding) do
      {:ok, name} -> {:ok, name}
      {:error, _} -> {:error, :unknown_encoding}
    end
  end

  @doc """
  Returns all recognized encoding names, including decode-only encodings.

  ## Examples

      iex> "UTF-8" in EncodingRs.list_encodings()
      true

      iex> "Shift_JIS" in EncodingRs.list_encodings()
      true
  """
  @spec list_encodings() :: [encoding()]
  def list_encodings do
    Native.list_encodings()
  end

  @doc """
  Returns the threshold (in bytes) above which dirty schedulers are used.

  Encode/decode operations on binaries larger than this threshold will
  automatically use dirty CPU schedulers to avoid blocking the BEAM's normal
  schedulers. This prevents long-running encoding operations from causing
  latency for other processes.

  Pass `:dirty_threshold` to an operation to override the 64KB default for that
  call. The value must be a non-negative integer.

  ## Examples

      iex> EncodingRs.dirty_threshold()
      65536
  """
  @spec dirty_threshold() :: non_neg_integer()
  @spec dirty_threshold(options()) :: non_neg_integer()
  def dirty_threshold, do: @default_dirty_threshold

  def dirty_threshold(opts) when is_list(opts) do
    {dirty_threshold, _max_input_size} = options!(opts)
    dirty_threshold
  end

  @doc """
  Returns the maximum input size (in bytes) allowed for encoding/decoding operations.

  Inputs larger than this limit will return `{:error, :input_too_large}` instead
  of being passed to the NIF. This prevents excessive memory allocation from
  untrusted or unexpectedly large inputs.

  Pass `:max_input_size` to an operation to override the 100MB default for that
  call.

  Set to `:infinity` to disable the size limit entirely. This is appropriate for
  trusted environments where inputs are known to be safe, but should be avoided
  when processing untrusted data — a large input can cause memory amplification
  of up to 3x in the NIF (input buffer + output buffer + BEAM binary copy).

      EncodingRs.decode(data, "utf-8", max_input_size: :infinity)

  The value must be a non-negative integer or `:infinity`. Invalid values
  (e.g., strings, negative numbers) will raise an `ArgumentError` on first use.

  ## Examples

      iex> EncodingRs.max_input_size()
      104857600
  """
  @spec max_input_size() :: non_neg_integer() | :infinity
  @spec max_input_size(options()) :: non_neg_integer() | :infinity
  def max_input_size, do: configured_max_input_size!()

  def max_input_size(opts) when is_list(opts) do
    {_dirty_threshold, max_input_size} = options!(opts)
    max_input_size
  end

  @doc false
  @spec resolve_options(options()) :: {non_neg_integer(), non_neg_integer() | :infinity}
  def resolve_options(opts) when is_list(opts), do: options!(opts)

  # Batch operations

  @typedoc "Input item for batch decoding: `{binary, encoding}`"
  @type decode_batch_item :: {binary(), encoding()}

  @typedoc "Input item for batch encoding: `{string, encoding}`"
  @type encode_batch_item :: {String.t(), encoding()}

  @typedoc "Result from batch operations"
  @type batch_result(t) ::
          {:ok, t}
          | {:error, :unknown_encoding | :encoder_unavailable | :input_too_large}

  @doc """
  Decodes multiple binaries in a single NIF call.

  This is more efficient than calling `decode/2` repeatedly when processing
  many items, as it amortizes the NIF dispatch overhead.

  Results are returned in the same order as the input items.

  The combined byte size determines whether the batch uses a normal or dirty
  CPU scheduler. See the [Batch Processing Guide](batch.md) for details.

  ## Arguments

  - `items` - List of `{binary, encoding}` tuples to decode

  ## Returns

  List of `{:ok, string}`, `{:error, :unknown_encoding}`, or
  `{:error, :input_too_large}` tuples.

  ## Examples

      iex> items = [{<<72, 101, 108, 108, 111>>, "windows-1252"}, {<<0x82, 0xA0>>, "shift_jis"}]
      iex> EncodingRs.decode_batch(items)
      [{:ok, "Hello"}, {:ok, "あ"}]

      iex> EncodingRs.decode_batch([{<<72>>, "invalid-encoding"}])
      [{:error, :unknown_encoding}]
  """
  @spec decode_batch([decode_batch_item()]) :: [batch_result(String.t())]
  @spec decode_batch([decode_batch_item()], options()) :: [batch_result(String.t())]
  def decode_batch(items) when is_list(items) do
    run_decode_batch(
      items,
      @default_dirty_threshold,
      max_input_size(),
      &Native.decode_batch_normal/1,
      &Native.decode_batch/1,
      &normalize_result/1
    )
  end

  def decode_batch(items, opts) when is_list(items) and is_list(opts) do
    {dirty_threshold, max_input_size} = options!(opts)

    run_decode_batch(
      items,
      dirty_threshold,
      max_input_size,
      &Native.decode_batch_normal/1,
      &Native.decode_batch/1,
      &normalize_result/1
    )
  end

  @doc """
  Decodes multiple binaries while reporting each actual encoding and whether
  malformed input was replaced.

  Results have the same order as the inputs. See `decode_with_details/3` for
  the detailed success tuple.

  ## Examples

      iex> EncodingRs.decode_batch_with_details([{"hello", "utf-8"}, {<<0xFF>>, "utf-8"}])
      [{:ok, "hello", "UTF-8", false}, {:ok, "�", "UTF-8", true}]
  """
  @spec decode_batch_with_details([decode_batch_item()]) :: [decode_details_result()]
  @spec decode_batch_with_details([decode_batch_item()], options()) ::
          [decode_details_result()]
  def decode_batch_with_details(items) when is_list(items) do
    run_decode_batch(
      items,
      @default_dirty_threshold,
      max_input_size(),
      &Native.decode_batch_with_details_normal/1,
      &Native.decode_batch_with_details/1,
      &normalize_decode_details/1
    )
  end

  def decode_batch_with_details(items, opts) when is_list(items) and is_list(opts) do
    {dirty_threshold, max_input_size} = options!(opts)

    run_decode_batch(
      items,
      dirty_threshold,
      max_input_size,
      &Native.decode_batch_with_details_normal/1,
      &Native.decode_batch_with_details/1,
      &normalize_decode_details/1
    )
  end

  defp run_decode_batch(
         items,
         dirty_threshold,
         max_input_size,
         normal_nif,
         dirty_nif,
         normalizer
       ) do
    {oversized_indices, valid_items, total_size} =
      split_by_size(items, fn {binary, _enc} -> byte_size(binary) end, max_input_size)

    if valid_items == [] do
      List.duplicate({:error, :input_too_large}, length(items))
    else
      nif = if total_size > dirty_threshold, do: dirty_nif, else: normal_nif

      nif_results =
        valid_items
        |> Enum.map(fn {item, _idx} -> item end)
        |> nif.()
        |> Enum.map(normalizer)

      merge_results(oversized_indices, valid_items, nif_results, length(items))
    end
  end

  @doc """
  Encodes multiple strings in a single NIF call.

  This is more efficient than calling `encode/2` repeatedly when processing
  many items, as it amortizes the NIF dispatch overhead.

  Results are returned in the same order as the input items.

  The combined byte size determines whether the batch uses a normal or dirty
  CPU scheduler. See the [Batch Processing Guide](batch.md) for details.

  ## Arguments

  - `items` - List of `{string, encoding}` tuples to encode

  ## Returns

  List of `{:ok, binary}`, `{:error, :unknown_encoding}`,
  `{:error, :encoder_unavailable}`, or `{:error, :input_too_large}` tuples.

  ## Examples

      iex> items = [{"Hello", "windows-1252"}, {"あ", "shift_jis"}]
      iex> EncodingRs.encode_batch(items)
      [{:ok, "Hello"}, {:ok, <<130, 160>>}]

      iex> EncodingRs.encode_batch([{"test", "invalid-encoding"}])
      [{:error, :unknown_encoding}]
  """
  @spec encode_batch([encode_batch_item()]) :: [batch_result(binary())]
  @spec encode_batch([encode_batch_item()], options()) :: [batch_result(binary())]
  def encode_batch(items) when is_list(items) do
    run_encode_batch(items, @default_dirty_threshold, max_input_size())
  end

  def encode_batch(items, opts) when is_list(items) and is_list(opts) do
    {dirty_threshold, max_input_size} = options!(opts)
    run_encode_batch(items, dirty_threshold, max_input_size)
  end

  defp run_encode_batch(items, dirty_threshold, max_input_size) do
    {oversized_indices, valid_items, total_size} =
      split_by_size(items, fn {string, _enc} -> byte_size(string) end, max_input_size)

    if valid_items == [] do
      List.duplicate({:error, :input_too_large}, length(items))
    else
      nif =
        if total_size > dirty_threshold,
          do: &Native.encode_batch/1,
          else: &Native.encode_batch_normal/1

      nif_results =
        valid_items
        |> Enum.map(fn {item, _idx} -> item end)
        |> nif.()
        |> Enum.map(&normalize_result/1)

      merge_results(oversized_indices, valid_items, nif_results, length(items))
    end
  end

  @doc """
  Detects the encoding from a Byte Order Mark (BOM) at the start of the data.

  BOMs are special byte sequences at the beginning of a file that indicate
  the encoding. This function checks the first few bytes of the input and
  returns the detected encoding if a BOM is found.

  Supported BOMs:
  - UTF-8: `<<0xEF, 0xBB, 0xBF>>` (3 bytes)
  - UTF-16LE: `<<0xFF, 0xFE>>` (2 bytes)
  - UTF-16BE: `<<0xFE, 0xFF>>` (2 bytes)

  ## Returns

  - `{:ok, encoding, bom_length}` - BOM detected, returns encoding name and BOM size
  - `{:error, :no_bom}` - No BOM found at the start of the data

  ## Examples

      iex> EncodingRs.detect_bom(<<0xEF, 0xBB, 0xBF, "hello">>)
      {:ok, "UTF-8", 3}

      iex> EncodingRs.detect_bom(<<0xFF, 0xFE, 0x48, 0x00>>)
      {:ok, "UTF-16LE", 2}

      iex> EncodingRs.detect_bom(<<0xFE, 0xFF, 0x00, 0x48>>)
      {:ok, "UTF-16BE", 2}

      iex> EncodingRs.detect_bom("hello")
      {:error, :no_bom}

      iex> EncodingRs.detect_bom(<<>>)
      {:error, :no_bom}
  """
  @spec detect_bom(binary()) :: bom_result()
  def detect_bom(data) when is_binary(data) do
    case Native.detect_bom(data) do
      {:ok, encoding, bom_length} -> {:ok, encoding, bom_length}
      {:error, _, _} -> {:error, :no_bom}
    end
  end

  @doc """
  Detects the encoding from a BOM and strips it from the data.

  Convenience function that combines BOM detection with stripping the BOM
  from the input data. Useful when you want to both detect the encoding
  and get the data without the BOM prefix.

  ## Returns

  - `{:ok, encoding, data_without_bom}` - BOM detected and stripped
  - `{:error, :no_bom}` - No BOM found, data unchanged

  ## Examples

      iex> EncodingRs.detect_and_strip_bom(<<0xEF, 0xBB, 0xBF, "hello">>)
      {:ok, "UTF-8", "hello"}

      iex> EncodingRs.detect_and_strip_bom("hello")
      {:error, :no_bom}
  """
  @spec detect_and_strip_bom(binary()) :: {:ok, encoding(), binary()} | {:error, :no_bom}
  def detect_and_strip_bom(data) when is_binary(data) do
    case detect_bom(data) do
      {:ok, encoding, bom_length} ->
        <<_bom::binary-size(^bom_length), rest::binary>> = data
        {:ok, encoding, rest}

      {:error, :no_bom} ->
        {:error, :no_bom}
    end
  end

  # Private helpers

  defp route_nif(input, encoding, normal_fn, dirty_fn, dirty_threshold) do
    if byte_size(input) > dirty_threshold do
      dirty_fn.(input, encoding)
    else
      normal_fn.(input, encoding)
    end
  end

  defp normalize_result({:ok, value}), do: {:ok, value}
  defp normalize_result({:error, reason}), do: normalize_error(reason)

  defp unwrap_result!({:ok, value}, _encoding, _opts), do: value

  defp unwrap_result!({:error, :unknown_encoding}, encoding, _opts) do
    raise ArgumentError, "unknown encoding: #{encoding}"
  end

  defp unwrap_result!({:error, :encoder_unavailable}, encoding, _opts) do
    raise ArgumentError, "encoding is decode-only: #{encoding}"
  end

  defp unwrap_result!({:error, :input_too_large}, _encoding, opts) do
    raise ArgumentError,
          "input exceeds maximum size of #{max_input_size_for_error(opts)} bytes"
  end

  defp max_input_size_for_error(:default), do: max_input_size()
  defp max_input_size_for_error(opts), do: max_input_size(opts)

  defp normalize_decode_details({:ok, value, actual_encoding, had_errors}),
    do: {:ok, value, actual_encoding, had_errors}

  defp normalize_decode_details({:error, reason, _actual_encoding, _had_errors}),
    do: normalize_error(reason)

  defp normalize_error(reason) when reason in ["", "unknown_encoding"],
    do: {:error, :unknown_encoding}

  defp normalize_error("encoder_unavailable"), do: {:error, :encoder_unavailable}

  defp normalize_error(reason), do: {:error, reason}

  defp validate_input_size(input, max_input_size) do
    case max_input_size do
      :infinity -> :ok
      max when byte_size(input) <= max -> :ok
      _ -> {:error, :input_too_large}
    end
  end

  defp split_by_size(items, size_fn, max) do
    {oversized_indices, valid_items, total_size} =
      items
      |> Enum.with_index()
      |> Enum.reduce({MapSet.new(), [], 0}, fn {item, idx}, {oversized, valid, total} ->
        size = size_fn.(item)

        if max != :infinity and size > max do
          {MapSet.put(oversized, idx), valid, total}
        else
          {oversized, [{item, idx} | valid], total + size}
        end
      end)

    {oversized_indices, Enum.reverse(valid_items), total_size}
  end

  defp options!(opts) do
    opts = Keyword.validate!(opts, @option_keys)

    dirty_threshold =
      opts
      |> Keyword.get(:dirty_threshold, @default_dirty_threshold)
      |> validate_dirty_threshold!()

    max_input_size =
      opts
      |> Keyword.get_lazy(:max_input_size, &configured_max_input_size!/0)
      |> validate_max_input_size!()

    {dirty_threshold, max_input_size}
  end

  defp configured_max_input_size! do
    :encoding_rs
    |> Application.get_env(:max_input_size, @default_max_input_size)
    |> validate_max_input_size!()
  end

  defp validate_dirty_threshold!(value) when is_integer(value) and value >= 0, do: value

  defp validate_dirty_threshold!(value) do
    raise ArgumentError,
          "expected :dirty_threshold to be a non-negative integer, got: #{inspect(value)}"
  end

  defp validate_max_input_size!(:infinity), do: :infinity

  defp validate_max_input_size!(value) when is_integer(value) and value >= 0, do: value

  defp validate_max_input_size!(value) do
    raise ArgumentError,
          "expected :max_input_size to be a non-negative integer or :infinity, got: #{inspect(value)}"
  end

  defp merge_results(_oversized_indices, _valid_items, _nif_results, 0), do: []

  defp merge_results(oversized_indices, valid_items, nif_results, total) do
    valid_map =
      valid_items
      |> Enum.map(fn {_item, idx} -> idx end)
      |> Enum.zip(nif_results)
      |> Map.new()

    Enum.map(0..(total - 1), &merge_result_at(&1, oversized_indices, valid_map))
  end

  defp merge_result_at(idx, oversized_indices, valid_map) do
    if MapSet.member?(oversized_indices, idx) do
      {:error, :input_too_large}
    else
      Map.fetch!(valid_map, idx)
    end
  end
end
