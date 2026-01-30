defmodule EncodingRs do
  @moduledoc """
  High-performance string encoding/decoding using Rust's `encoding_rs` crate.

  This library provides fast character encoding conversion using the same
  encoding library that powers Firefox. It supports all encodings in the
  WHATWG Encoding Standard.

  ## Features

  - **High performance**: Uses `encoding_rs`, the same library used by Firefox
  - **Dirty schedulers**: Large binaries automatically use dirty CPU schedulers
    to avoid blocking the BEAM (configurable threshold, default 64KB)
  - **Safe error handling**: Returns `{:ok, result}` or `{:error, reason}` tuples
  - **WHATWG compliant**: Supports all encodings from the WHATWG Encoding Standard

  ## Configuration

  ### Dirty Scheduler Threshold (compile-time)

  The dirty scheduler threshold controls when operations are moved to dirty CPU
  schedulers. The BEAM VM has a limited number of normal schedulers, and long-running
  NIFs can block them, causing latency for other processes. By offloading large
  encoding/decoding operations to dirty schedulers, the normal schedulers remain
  available for other work.

  Configure in your `config.exs`:

      # Using multiplication for readability
      config :encoding_rs, dirty_threshold: 128 * 1024

      # Or using Elixir's underscore notation
      config :encoding_rs, dirty_threshold: 131_072

  The default is 64KB (65,536 bytes). This is a **compile-time** setting.

  **Increasing the threshold** reduces context switching overhead, which benefits
  batch processing and throughput-focused workloads. However, larger operations
  will block normal schedulers longer, potentially causing latency for other processes.

  **Decreasing the threshold** keeps normal schedulers more available, which benefits
  latency-sensitive and high-concurrency applications. However, more frequent context
  switching adds overhead that may reduce throughput.

  ### Maximum Input Size (runtime)

  A configurable safety limit on the maximum input size accepted by encoding/decoding
  operations. Inputs exceeding this limit return `{:error, :input_too_large}` before
  reaching the NIF. This guards against excessive memory allocation — a single large
  input can cause up to 3x memory amplification in the NIF (input buffer + output
  buffer + BEAM binary copy).

  Configure in your `config.exs` or `runtime.exs`:

      config :encoding_rs, max_input_size: 200 * 1024 * 1024

  The default is 100MB (104,857,600 bytes). This is a **runtime** setting — it can
  be changed without recompiling.

  Set to `:infinity` to disable the limit entirely:

      # Trusted environment — no size cap
      config :encoding_rs, max_input_size: :infinity

  The value must be a non-negative integer or `:infinity`. Invalid values
  (e.g., strings, negative numbers) will raise an `ArgumentError` on first use.

  > #### Warning {: .warning}
  >
  > Disabling the size limit or setting it very high removes a safety guardrail
  > against memory exhaustion. Only do this when inputs are trusted and bounded
  > by other means (e.g., request body limits, file size checks). For untrusted
  > input, prefer the streaming decoder (`EncodingRs.Decoder`) with bounded
  > chunk sizes.

  See `max_input_size/0` for more details.

  ## Supported Encodings

  * UTF-8, UTF-16LE, UTF-16BE
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

  # Configuration
  @dirty_threshold Application.compile_env(:encoding_rs, :dirty_threshold, 64 * 1024)
  @default_max_input_size 100 * 1024 * 1024

  # Types

  @typedoc """
  An encoding label string (e.g., `"utf-8"`, `"shift_jis"`, `"windows-1252"`).

  See `list_encodings/0` for all supported encodings, or check the
  [WHATWG Encoding Standard](https://encoding.spec.whatwg.org/#names-and-labels).
  """
  @type encoding :: String.t()

  @typedoc "Error reason atoms returned by encoding/decoding functions."
  @type error_reason :: :unknown_encoding | :no_bom | :input_too_large

  @typedoc "Result of BOM detection: encoding name and BOM length in bytes."
  @type bom_result :: {:ok, encoding(), bom_length :: non_neg_integer()} | {:error, :no_bom}

  # Functions

  @doc """
  Encodes a UTF-8 string to the specified encoding.

  Returns `{:ok, binary}` on success, or `{:error, reason}` on failure.
  Unmappable characters are replaced with a suitable fallback character.

  Automatically uses dirty CPU schedulers for strings larger than the
  configured threshold (see `dirty_threshold/0`).

  ## Examples

      iex> EncodingRs.encode("Hello", "windows-1252")
      {:ok, "Hello"}

      iex> EncodingRs.encode("Hello", "invalid-encoding")
      {:error, :unknown_encoding}
  """
  @spec encode(String.t(), encoding()) ::
          {:ok, binary()} | {:error, :unknown_encoding | :input_too_large}
  def encode(string, encoding) when is_binary(string) and is_binary(encoding) do
    with :ok <- validate_input_size(string) do
      string
      |> route_nif(encoding, &Native.encode_normal/2, &Native.encode_dirty/2)
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
  def encode!(string, encoding) when is_binary(string) and is_binary(encoding) do
    case encode(string, encoding) do
      {:ok, binary} ->
        binary

      {:error, :unknown_encoding} ->
        raise ArgumentError, "unknown encoding: #{encoding}"

      {:error, :input_too_large} ->
        raise ArgumentError,
              "input exceeds maximum size of #{max_input_size()} bytes"
    end
  end

  @doc """
  Decodes a binary from the specified encoding to a UTF-8 string.

  Returns `{:ok, string}` on success, or `{:error, reason}` on failure.
  Unmappable bytes are replaced with the Unicode replacement character (U+FFFD).

  Automatically uses dirty CPU schedulers for binaries larger than the
  configured threshold (see `dirty_threshold/0`).

  ## Examples

      iex> EncodingRs.decode(<<72, 101, 108, 108, 111>>, "windows-1252")
      {:ok, "Hello"}

      iex> EncodingRs.decode(<<0xFF>>, "invalid-encoding")
      {:error, :unknown_encoding}
  """
  @spec decode(binary(), encoding()) ::
          {:ok, String.t()} | {:error, :unknown_encoding | :input_too_large}
  def decode(binary, encoding) when is_binary(binary) and is_binary(encoding) do
    with :ok <- validate_input_size(binary) do
      binary
      |> route_nif(encoding, &Native.decode_normal/2, &Native.decode_dirty/2)
      |> normalize_result()
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
  def decode!(binary, encoding) when is_binary(binary) and is_binary(encoding) do
    case decode(binary, encoding) do
      {:ok, string} ->
        string

      {:error, :unknown_encoding} ->
        raise ArgumentError, "unknown encoding: #{encoding}"

      {:error, :input_too_large} ->
        raise ArgumentError,
              "input exceeds maximum size of #{max_input_size()} bytes"
    end
  end

  @doc """
  Checks if an encoding label is valid and supported.

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
  Returns a list of all supported encoding names.

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

  This value can be configured in your `config.exs`:

      # Using multiplication for readability
      config :encoding_rs, dirty_threshold: 128 * 1024

      # Or using Elixir's underscore notation
      config :encoding_rs, dirty_threshold: 131_072

  The default is 64KB (65,536 bytes).

  ## Examples

      iex> EncodingRs.dirty_threshold()
      65536
  """
  @spec dirty_threshold() :: non_neg_integer()
  def dirty_threshold do
    @dirty_threshold
  end

  @doc """
  Returns the maximum input size (in bytes) allowed for encoding/decoding operations.

  Inputs larger than this limit will return `{:error, :input_too_large}` instead
  of being passed to the NIF. This prevents excessive memory allocation from
  untrusted or unexpectedly large inputs.

  This value is read at **runtime** via `Application.get_env/3`, so it can be
  changed in `runtime.exs` or dynamically with `Application.put_env/3` without
  recompiling the library.

  Configure in your `config.exs` or `runtime.exs`:

      config :encoding_rs, max_input_size: 200 * 1024 * 1024

  The default is 100MB (104,857,600 bytes).

  Set to `:infinity` to disable the size limit entirely. This is appropriate for
  trusted environments where inputs are known to be safe, but should be avoided
  when processing untrusted data — a large input can cause memory amplification
  of up to 3x in the NIF (input buffer + output buffer + BEAM binary copy).

      # Disable size limit (trusted inputs only)
      config :encoding_rs, max_input_size: :infinity

  The value must be a non-negative integer or `:infinity`. Invalid values
  (e.g., strings, negative numbers) will raise an `ArgumentError` on first use.

  ## Examples

      iex> EncodingRs.max_input_size()
      104857600
  """
  @spec max_input_size() :: non_neg_integer() | :infinity
  def max_input_size do
    case Application.get_env(:encoding_rs, :max_input_size, @default_max_input_size) do
      :infinity ->
        :infinity

      value when is_integer(value) and value >= 0 ->
        value

      other ->
        raise ArgumentError,
              "expected :max_input_size to be a non-negative integer or :infinity, got: #{inspect(other)}"
    end
  end

  # Batch operations

  @typedoc "Input item for batch decoding: `{binary, encoding}`"
  @type decode_batch_item :: {binary(), encoding()}

  @typedoc "Input item for batch encoding: `{string, encoding}`"
  @type encode_batch_item :: {String.t(), encoding()}

  @typedoc "Result from batch operations"
  @type batch_result(t) :: {:ok, t} | {:error, :unknown_encoding | :input_too_large}

  @doc """
  Decodes multiple binaries in a single NIF call.

  This is more efficient than calling `decode/2` repeatedly when processing
  many items, as it amortizes the NIF dispatch overhead.

  Results are returned in the same order as the input items.

  **Note:** Batch operations always use dirty CPU schedulers, regardless of
  input size. See the [Batch Processing Guide](batch.md) for details.

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
  def decode_batch(items) when is_list(items) do
    {oversized_indices, valid_items} =
      split_by_size(items, fn {binary, _enc} -> byte_size(binary) end)

    if valid_items == [] do
      List.duplicate({:error, :input_too_large}, length(items))
    else
      nif_results =
        valid_items
        |> Enum.map(fn {item, _idx} -> item end)
        |> Native.decode_batch()
        |> Enum.map(&normalize_result/1)

      merge_results(oversized_indices, valid_items, nif_results, length(items))
    end
  end

  @doc """
  Encodes multiple strings in a single NIF call.

  This is more efficient than calling `encode/2` repeatedly when processing
  many items, as it amortizes the NIF dispatch overhead.

  Results are returned in the same order as the input items.

  **Note:** Batch operations always use dirty CPU schedulers, regardless of
  input size. See the [Batch Processing Guide](batch.md) for details.

  ## Arguments

  - `items` - List of `{string, encoding}` tuples to encode

  ## Returns

  List of `{:ok, binary}`, `{:error, :unknown_encoding}`, or
  `{:error, :input_too_large}` tuples.

  ## Examples

      iex> items = [{"Hello", "windows-1252"}, {"あ", "shift_jis"}]
      iex> EncodingRs.encode_batch(items)
      [{:ok, "Hello"}, {:ok, <<130, 160>>}]

      iex> EncodingRs.encode_batch([{"test", "invalid-encoding"}])
      [{:error, :unknown_encoding}]
  """
  @spec encode_batch([encode_batch_item()]) :: [batch_result(binary())]
  def encode_batch(items) when is_list(items) do
    {oversized_indices, valid_items} =
      split_by_size(items, fn {string, _enc} -> byte_size(string) end)

    if valid_items == [] do
      List.duplicate({:error, :input_too_large}, length(items))
    else
      nif_results =
        valid_items
        |> Enum.map(fn {item, _idx} -> item end)
        |> Native.encode_batch()
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
        <<_bom::binary-size(bom_length), rest::binary>> = data
        {:ok, encoding, rest}

      {:error, :no_bom} ->
        {:error, :no_bom}
    end
  end

  # Private helpers

  defp route_nif(input, encoding, normal_fn, dirty_fn) do
    if byte_size(input) > @dirty_threshold do
      dirty_fn.(input, encoding)
    else
      normal_fn.(input, encoding)
    end
  end

  defp normalize_result({:ok, value}), do: {:ok, value}
  defp normalize_result({:error, _}), do: {:error, :unknown_encoding}

  defp validate_input_size(input) do
    case max_input_size() do
      :infinity -> :ok
      max when byte_size(input) <= max -> :ok
      _ -> {:error, :input_too_large}
    end
  end

  defp split_by_size(items, size_fn) do
    max = max_input_size()

    {oversized, valid} =
      items
      |> Enum.with_index()
      |> Enum.split_with(fn {item, _idx} -> max != :infinity and size_fn.(item) > max end)

    oversized_indices =
      oversized
      |> Enum.map(fn {_item, idx} -> idx end)
      |> MapSet.new()

    {oversized_indices, valid}
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
