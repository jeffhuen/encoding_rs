defmodule EncodingRs do
  @moduledoc """
  High-performance string encoding/decoding using Rust's `encoding_rs` crate.

  This library provides fast character encoding conversion using the same
  encoding library that powers Firefox. It supports all encodings in the
  WHATWG Encoding Standard.

  ## Features

  - **High performance**: Uses `encoding_rs`, the same library used by Firefox
  - **Dirty schedulers**: Large binaries (>64KB) automatically use dirty CPU
    schedulers to avoid blocking the BEAM
  - **Safe error handling**: Returns `{:ok, result}` or `{:error, reason}` tuples
  - **WHATWG compliant**: Supports all encodings from the WHATWG Encoding Standard

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

  # Types

  @typedoc """
  An encoding label string (e.g., `"utf-8"`, `"shift_jis"`, `"windows-1252"`).

  See `list_encodings/0` for all supported encodings, or check the
  [WHATWG Encoding Standard](https://encoding.spec.whatwg.org/#names-and-labels).
  """
  @type encoding :: String.t()

  @typedoc "Error reason atoms returned by encoding/decoding functions."
  @type error_reason :: :unknown_encoding | :no_bom

  @typedoc "Result of BOM detection: encoding name and BOM length in bytes."
  @type bom_result :: {:ok, encoding(), bom_length :: non_neg_integer()} | {:error, :no_bom}

  # Functions

  @doc """
  Encodes a UTF-8 string to the specified encoding.

  Returns `{:ok, binary}` on success, or `{:error, reason}` on failure.
  Unmappable characters are replaced with a suitable fallback character.

  Automatically uses dirty CPU schedulers for strings larger than 64KB.

  ## Examples

      iex> EncodingRs.encode("Hello", "windows-1252")
      {:ok, "Hello"}

      iex> EncodingRs.encode("Hello", "invalid-encoding")
      {:error, :unknown_encoding}
  """
  @spec encode(String.t(), encoding()) :: {:ok, binary()} | {:error, :unknown_encoding}
  def encode(string, encoding) when is_binary(string) and is_binary(encoding) do
    if byte_size(string) > Native.dirty_threshold() do
      case Native.encode_dirty(string, encoding) do
        {:ok, binary} -> {:ok, binary}
        {:error, _} -> {:error, :unknown_encoding}
      end
    else
      case Native.encode_normal(string, encoding) do
        {:ok, binary} -> {:ok, binary}
        {:error, _} -> {:error, :unknown_encoding}
      end
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
      {:ok, binary} -> binary
      {:error, :unknown_encoding} -> raise ArgumentError, "unknown encoding: #{encoding}"
    end
  end

  @doc """
  Decodes a binary from the specified encoding to a UTF-8 string.

  Returns `{:ok, string}` on success, or `{:error, reason}` on failure.
  Unmappable bytes are replaced with the Unicode replacement character (U+FFFD).

  Automatically uses dirty CPU schedulers for binaries larger than 64KB.

  ## Examples

      iex> EncodingRs.decode(<<72, 101, 108, 108, 111>>, "windows-1252")
      {:ok, "Hello"}

      iex> EncodingRs.decode(<<0xFF>>, "invalid-encoding")
      {:error, :unknown_encoding}
  """
  @spec decode(binary(), encoding()) :: {:ok, String.t()} | {:error, :unknown_encoding}
  def decode(binary, encoding) when is_binary(binary) and is_binary(encoding) do
    if byte_size(binary) > Native.dirty_threshold() do
      case Native.decode_dirty(binary, encoding) do
        {:ok, string} -> {:ok, string}
        {:error, _} -> {:error, :unknown_encoding}
      end
    else
      case Native.decode_normal(binary, encoding) do
        {:ok, string} -> {:ok, string}
        {:error, _} -> {:error, :unknown_encoding}
      end
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
      {:ok, string} -> string
      {:error, :unknown_encoding} -> raise ArgumentError, "unknown encoding: #{encoding}"
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
  automatically use dirty CPU schedulers to avoid blocking the BEAM.

  ## Examples

      iex> EncodingRs.dirty_threshold()
      65536
  """
  @spec dirty_threshold() :: non_neg_integer()
  def dirty_threshold do
    Native.dirty_threshold()
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
end
