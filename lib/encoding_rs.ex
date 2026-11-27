defmodule EncodingRs do
  @moduledoc """
  Character encoding conversion and detection powered by Mozilla's `encoding_rs`
  and `chardetng` crates.

  This library decodes all 40 encodings in the WHATWG Encoding Standard (with
  over 200 label aliases), encodes their 37 output encodings, and detects
  unlabeled byte streams heuristically.

  ## Features

  - **WHATWG conversion**: Implements the WHATWG decoding and encoding
    algorithms used by Firefox.
  - **Dirty schedulers**: Operations on inputs larger than `:dirty_threshold`
    (default 64 KB) run on dirty CPU schedulers to keep normal schedulers free.
  - **Strict and replacing error modes**: Choose between WHATWG replacement
    (`on_error: :replace`, default) and strict failure (`on_error: :error`).
  - **BOM handling**: Control Byte Order Mark handling with `bom: :sniff`
    (default), `bom: :strip`, or `bom: :preserve`.
  - **Streaming APIs**: Use `EncodingRs.Decoder` and `EncodingRs.Encoder` for
    chunked streams, and `EncodingRs.Detector` for incremental detection.

  ## Operation options

  All conversion and detection functions accept per-call options:

  - `:dirty_threshold` (default `65_536`): Byte count above which the call
    uses a dirty CPU scheduler. Must be a non-negative integer.
  - `:max_input_size` (default `104_857_600`): Maximum allowed input size in
    bytes, or `:infinity` for trusted inputs bounded elsewhere.
  - `:bom` (decode functions only, default `:sniff`): Controls BOM handling:
    `:sniff` switches encodings on a leading UTF-8 or UTF-16 BOM and removes
    it, `:strip` removes a BOM only when it matches the requested encoding,
    and `:preserve` keeps any leading BOM as `U+FEFF`.
  - `:on_error` (encode and decode functions, default `:replace`): `:replace`
    replaces malformed decode bytes with `U+FFFD` and unmappable encode
    characters with HTML decimal numeric character references (`&#128512;`).
    `:error` fails with `{:error, :malformed_input}` on decode or
    `{:error, :unmappable_character}` on encode.

  > #### Memory guardrail {: .warning}
  >
  > Setting `max_input_size: :infinity` removes the built-in allocation limit.
  > Use it only when inputs are trusted and bounded by other means. For large
  > files or untrusted streams, use `EncodingRs.Decoder` or `EncodingRs.Encoder`
  > with bounded chunk sizes.

  ## Supported encodings

  - Unicode: UTF-8 (encode and decode); UTF-16LE and UTF-16BE (decode only;
    use `:unicode.characters_to_binary/3` for UTF-16 output)
  - Windows code pages: 874, 1250 through 1258, 949, 932
  - ISO-8859 family: 2, 3, 4, 5, 6, 7, 8, 8-I, 10, 13, 14, 15, 16
  - IBM866, KOI8-R, KOI8-U, macintosh, x-mac-cyrillic, x-user-defined
  - East Asian: Shift_JIS, EUC-JP, ISO-2022-JP, EUC-KR, GBK, gb18030, Big5

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

      iex> EncodingRs.can_encode?("utf-16le")
      false
  """

  alias EncodingRs.Native

  @default_dirty_threshold 64 * 1024
  @default_max_input_size 100 * 1024 * 1024
  @default_bom :sniff
  @default_on_error :replace

  @option_keys [:dirty_threshold, :max_input_size]
  @decode_option_keys [:dirty_threshold, :max_input_size, :bom, :on_error]
  @encode_option_keys [:dirty_threshold, :max_input_size, :on_error]
  @detect_option_keys [
    :dirty_threshold,
    :max_input_size,
    :tld,
    :allow_utf8,
    :allow_iso_2022_jp,
    :bom
  ]

  # Types

  @typedoc """
  An encoding label string such as `"utf-8"`, `"shift_jis"`, or `"windows-1252"`.

  Call `list_encodings/0` for all canonical names, or see the
  [WHATWG Encoding Standard](https://encoding.spec.whatwg.org/#names-and-labels).
  """
  @type encoding :: String.t()

  @typedoc "BOM handling mode for decode operations."
  @type bom_mode :: :sniff | :strip | :preserve

  @typedoc "Error handling mode for encode and decode operations."
  @type on_error :: :replace | :error

  @typedoc "Per-operation scheduler and input-size options."
  @type options :: [
          {:dirty_threshold, non_neg_integer()}
          | {:max_input_size, non_neg_integer() | :infinity}
        ]

  @typedoc "Options accepted by decode operations."
  @type decode_options :: [
          {:dirty_threshold, non_neg_integer()}
          | {:max_input_size, non_neg_integer() | :infinity}
          | {:bom, bom_mode()}
          | {:on_error, on_error()}
        ]

  @typedoc "Options accepted by encode operations."
  @type encode_options :: [
          {:dirty_threshold, non_neg_integer()}
          | {:max_input_size, non_neg_integer() | :infinity}
          | {:on_error, on_error()}
        ]

  @typedoc "Options accepted by `detect/2` and `detect!/2`."
  @type detect_options :: [
          {:dirty_threshold, non_neg_integer()}
          | {:max_input_size, non_neg_integer() | :infinity}
          | {:tld, String.t() | nil}
          | {:allow_utf8, boolean()}
          | {:allow_iso_2022_jp, boolean()}
          | {:bom, boolean()}
        ]

  @typedoc "Error reason atoms returned by decode operations."
  @type decode_error ::
          :unknown_encoding | :malformed_input | :input_too_large | :allocation_failed

  @typedoc "Error reason atoms returned by encode operations."
  @type encode_error ::
          :unknown_encoding
          | :encoder_unavailable
          | :invalid_utf8
          | :unmappable_character
          | :input_too_large
          | :allocation_failed

  @typedoc "Error reason atoms returned by encoding, decoding, and BOM functions."
  @type error_reason :: decode_error() | encode_error() | :no_bom

  @typedoc "Detailed one-shot decode result, including BOM selection and replacements."
  @type decode_details_result ::
          {:ok, String.t(), actual_encoding :: encoding(), had_errors :: boolean()}
          | {:error, decode_error()}

  @typedoc "Detailed one-shot encode result, including replacement status."
  @type encode_details_result ::
          {:ok, binary(), had_errors :: boolean()}
          | {:error, encode_error()}

  @typedoc "Result of BOM detection: encoding name and BOM length in bytes."
  @type bom_result :: {:ok, encoding(), bom_length :: non_neg_integer()} | {:error, :no_bom}

  @typedoc "Input item for batch decoding: `{binary, encoding}`."
  @type decode_batch_item :: {binary(), encoding()}

  @typedoc "Input item for batch encoding: `{string, encoding}`."
  @type encode_batch_item :: {binary(), encoding()}

  @typedoc "Result item returned by `decode_batch/2`."
  @type decode_batch_result :: {:ok, String.t()} | {:error, decode_error()}

  @typedoc "Result item returned by `encode_batch/2`."
  @type encode_batch_result :: {:ok, binary()} | {:error, encode_error()}

  @typedoc "Result item returned by batch operations."
  @type batch_result(t) :: {:ok, t} | {:error, decode_error() | encode_error()}

  # One-shot encoding

  @doc """
  Encodes a UTF-8 string to the requested encoding.

  Returns `{:ok, binary}` on success, or `{:error, reason}` on failure.

  By default (`on_error: :replace`), unmappable characters become WHATWG HTML
  decimal numeric character references (for example, `"🎉"` encodes as
  `"&#127881;"` in `"windows-1252"`). Pass `on_error: :error` to reject
  unmappable characters with `{:error, :unmappable_character}`, or call
  `encode_with_details/3` to detect replacements without failing.

  Invalid UTF-8 binaries return `{:error, :invalid_utf8}`.

  UTF-16LE, UTF-16BE, and `replacement` are decode-only in the WHATWG Encoding
  Standard and return `{:error, :encoder_unavailable}`. To produce UTF-16 bytes
  in Elixir, use `:unicode.characters_to_binary(string, :utf8, {:utf16, :little})`
  or `{:utf16, :big}`.

  ## Examples

      iex> EncodingRs.encode("Hello", "windows-1252")
      {:ok, "Hello"}

      iex> EncodingRs.encode("🎉", "windows-1252")
      {:ok, "&#127881;"}

      iex> EncodingRs.encode("🎉", "windows-1252", on_error: :error)
      {:error, :unmappable_character}

      iex> EncodingRs.encode(<<0xFF>>, "windows-1252")
      {:error, :invalid_utf8}

      iex> EncodingRs.encode("Hello", "invalid-encoding")
      {:error, :unknown_encoding}
  """
  @spec encode(binary(), encoding()) :: {:ok, binary()} | {:error, encode_error()}
  @spec encode(binary(), encoding(), encode_options()) ::
          {:ok, binary()} | {:error, encode_error()}
  def encode(string, encoding) when is_binary(string) and is_binary(encoding) do
    encode_native(
      string,
      encoding,
      @default_dirty_threshold,
      @default_max_input_size,
      @default_on_error
    )
  end

  def encode(string, encoding, opts)
      when is_binary(string) and is_binary(encoding) and is_list(opts) do
    {dirty_threshold, max_input_size, on_error} = resolve_encode_options(opts)
    encode_native(string, encoding, dirty_threshold, max_input_size, on_error)
  end

  defp encode_native(string, encoding, dirty_threshold, max_input_size, on_error) do
    with :ok <- validate_input_size(string, max_input_size) do
      if byte_size(string) > dirty_threshold do
        Native.encode_dirty(string, encoding, on_error)
      else
        Native.encode_normal(string, encoding, on_error)
      end
      |> normalize_result()
    end
  end

  @doc """
  Encodes a UTF-8 string and reports whether any unmappable character was
  replaced with an HTML numeric character reference.

  Returns `{:ok, binary, had_errors}` on success, or `{:error, reason}` on
  failure.

  ## Examples

      iex> EncodingRs.encode_with_details("Hello", "windows-1252")
      {:ok, "Hello", false}

      iex> EncodingRs.encode_with_details("🎉", "windows-1252")
      {:ok, "&#127881;", true}

      iex> EncodingRs.encode_with_details("🎉", "windows-1252", on_error: :error)
      {:error, :unmappable_character}
  """
  @spec encode_with_details(binary(), encoding()) :: encode_details_result()
  @spec encode_with_details(binary(), encoding(), encode_options()) :: encode_details_result()
  def encode_with_details(string, encoding) when is_binary(string) and is_binary(encoding) do
    encode_with_details_native(
      string,
      encoding,
      @default_dirty_threshold,
      @default_max_input_size,
      @default_on_error
    )
  end

  def encode_with_details(string, encoding, opts)
      when is_binary(string) and is_binary(encoding) and is_list(opts) do
    {dirty_threshold, max_input_size, on_error} = resolve_encode_options(opts)
    encode_with_details_native(string, encoding, dirty_threshold, max_input_size, on_error)
  end

  defp encode_with_details_native(string, encoding, dirty_threshold, max_input_size, on_error) do
    with :ok <- validate_input_size(string, max_input_size) do
      if byte_size(string) > dirty_threshold do
        Native.encode_with_details_dirty(string, encoding, on_error)
      else
        Native.encode_with_details_normal(string, encoding, on_error)
      end
      |> normalize_encode_details()
    end
  end

  @doc """
  Encodes a UTF-8 string to the requested encoding, raising `ArgumentError` on
  failure.

  ## Examples

      iex> EncodingRs.encode!("Hello", "windows-1252")
      "Hello"

      iex> EncodingRs.encode!("Hello", "invalid-encoding")
      ** (ArgumentError) unknown encoding: invalid-encoding
  """
  @spec encode!(binary(), encoding()) :: binary()
  @spec encode!(binary(), encoding(), encode_options()) :: binary()
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

  # One-shot decoding

  @doc """
  Decodes a binary from the requested encoding to a UTF-8 string.

  Returns `{:ok, string}` on success, or `{:error, reason}` on failure.

  By default (`bom: :sniff`, `on_error: :replace`), a leading UTF-8 or UTF-16
  BOM overrides the requested encoding and is removed, and malformed byte
  sequences are replaced with `U+FFFD`. Pass `:bom` to control BOM handling,
  pass `on_error: :error` to return `{:error, :malformed_input}` on invalid
  bytes, or call `decode_with_details/3` to observe BOM overrides and
  replacements.

  ## Examples

      iex> EncodingRs.decode(<<72, 101, 108, 108, 111>>, "windows-1252")
      {:ok, "Hello"}

      iex> EncodingRs.decode(<<0xFF>>, "utf-8", on_error: :error)
      {:error, :malformed_input}

      iex> EncodingRs.decode(<<0xEF, 0xBB, 0xBF, "hi">>, "utf-8", bom: :preserve)
      {:ok, "\\uFEFFhi"}

      iex> EncodingRs.decode(<<0xFF>>, "invalid-encoding")
      {:error, :unknown_encoding}
  """
  @spec decode(binary(), encoding()) :: {:ok, String.t()} | {:error, decode_error()}
  @spec decode(binary(), encoding(), decode_options()) ::
          {:ok, String.t()} | {:error, decode_error()}
  def decode(binary, encoding) when is_binary(binary) and is_binary(encoding) do
    decode_native(
      binary,
      encoding,
      {@default_dirty_threshold, @default_max_input_size, @default_bom, @default_on_error},
      &Native.decode_normal/4,
      &Native.decode_dirty/4
    )
    |> normalize_result()
  end

  def decode(binary, encoding, opts)
      when is_binary(binary) and is_binary(encoding) and is_list(opts) do
    decode_native(
      binary,
      encoding,
      resolve_decode_options(opts),
      &Native.decode_normal/4,
      &Native.decode_dirty/4
    )
    |> normalize_result()
  end

  @doc """
  Decodes a complete binary and reports the encoding used and whether
  malformed input was replaced with `U+FFFD`.

  When `bom: :sniff` (default), `actual_encoding` differs from the requested
  label if a leading UTF-8 or UTF-16 BOM selects another encoding.

  ## Examples

      iex> EncodingRs.decode_with_details(<<0xFF>>, "utf-8")
      {:ok, "\uFFFD", "UTF-8", true}

      iex> EncodingRs.decode_with_details(<<0xFF, 0xFE, 0x48, 0x00>>, "windows-1252")
      {:ok, "H", "UTF-16LE", false}

      iex> EncodingRs.decode_with_details(<<0xFF, 0xFE, 0x48, 0x00>>, "windows-1252", bom: :strip)
      {:ok, "ÿþH\\0", "windows-1252", false}
  """
  @spec decode_with_details(binary(), encoding()) :: decode_details_result()
  @spec decode_with_details(binary(), encoding(), decode_options()) :: decode_details_result()
  def decode_with_details(binary, encoding) when is_binary(binary) and is_binary(encoding) do
    decode_native(
      binary,
      encoding,
      {@default_dirty_threshold, @default_max_input_size, @default_bom, @default_on_error},
      &Native.decode_with_details_normal/4,
      &Native.decode_with_details_dirty/4
    )
    |> normalize_decode_details()
  end

  def decode_with_details(binary, encoding, opts)
      when is_binary(binary) and is_binary(encoding) and is_list(opts) do
    decode_native(
      binary,
      encoding,
      resolve_decode_options(opts),
      &Native.decode_with_details_normal/4,
      &Native.decode_with_details_dirty/4
    )
    |> normalize_decode_details()
  end

  defp decode_native(
         binary,
         encoding,
         {dirty_threshold, max_input_size, bom, on_error},
         normal_fn,
         dirty_fn
       ) do
    with :ok <- validate_input_size(binary, max_input_size) do
      if byte_size(binary) > dirty_threshold do
        dirty_fn.(binary, encoding, bom, on_error)
      else
        normal_fn.(binary, encoding, bom, on_error)
      end
    end
  end

  @doc """
  Decodes a binary from the requested encoding to a UTF-8 string, raising
  `ArgumentError` on failure.

  ## Examples

      iex> EncodingRs.decode!(<<72, 101, 108, 108, 111>>, "windows-1252")
      "Hello"

      iex> EncodingRs.decode!(<<0xFF>>, "invalid-encoding")
      ** (ArgumentError) unknown encoding: invalid-encoding
  """
  @spec decode!(binary(), encoding()) :: String.t()
  @spec decode!(binary(), encoding(), decode_options()) :: String.t()
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

  # Encoding inspection

  @doc """
  Returns whether an encoding label is recognized for decoding.

  Returns `true` for all 40 WHATWG encodings and their aliases, including
  decode-only labels (`"utf-16le"`, `"utf-16be"`, `"replacement"`). Use
  `can_encode?/1` to test whether a label also supports encoding.

  ## Examples

      iex> EncodingRs.encoding_exists?("utf-8")
      true

      iex> EncodingRs.encoding_exists?("utf-16le")
      true

      iex> EncodingRs.encoding_exists?("not-an-encoding")
      false
  """
  @spec encoding_exists?(encoding()) :: boolean()
  def encoding_exists?(encoding) when is_binary(encoding) do
    Native.encoding_exists(encoding)
  end

  @doc """
  Returns whether an encoding label is recognized and supports encoding.

  Returns `false` for unknown labels and for decode-only WHATWG labels
  (`"utf-16le"`, `"utf-16be"`, and `"replacement"`).

  ## Examples

      iex> EncodingRs.can_encode?("shift_jis")
      true

      iex> EncodingRs.can_encode?("utf-16le")
      false

      iex> EncodingRs.can_encode?("not-an-encoding")
      false
  """
  @spec can_encode?(encoding()) :: boolean()
  def can_encode?(encoding) when is_binary(encoding) do
    Native.can_encode(encoding)
  end

  @doc """
  Returns whether the native NIF is loaded and callable.

  Never raises when the NIF is missing, allowing callers to guard optional
  encoding paths.

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
  Returns the canonical WHATWG name for an encoding label or alias.

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
  Returns the WHATWG output encoding name for an encoding label.

  Most encodings map to their own canonical name. Decode-only labels
  (`"utf-16le"`, `"utf-16be"`, `"replacement"`) map to `"UTF-8"` per the
  WHATWG Encoding Standard.

  ## Examples

      iex> EncodingRs.output_encoding("latin1")
      {:ok, "windows-1252"}

      iex> EncodingRs.output_encoding("utf-16le")
      {:ok, "UTF-8"}

      iex> EncodingRs.output_encoding("invalid")
      {:error, :unknown_encoding}
  """
  @spec output_encoding(encoding()) :: {:ok, encoding()} | {:error, :unknown_encoding}
  def output_encoding(encoding) when is_binary(encoding) do
    case Native.output_encoding(encoding) do
      {:ok, name} -> {:ok, name}
      {:error, _} -> {:error, :unknown_encoding}
    end
  end

  @doc """
  Returns all 40 canonical WHATWG encoding names supported for decoding,
  including decode-only encodings.

  ## Examples

      iex> "UTF-8" in EncodingRs.list_encodings()
      true

      iex> "UTF-16LE" in EncodingRs.list_encodings()
      true
  """
  @spec list_encodings() :: [encoding()]
  def list_encodings do
    Native.list_encodings()
  end

  @doc """
  Returns all 37 canonical WHATWG encoding names supported for encoding.

  Excludes decode-only encodings (`"UTF-16LE"`, `"UTF-16BE"`, and
  `"replacement"`).

  ## Examples

      iex> "Shift_JIS" in EncodingRs.list_output_encodings()
      true

      iex> "UTF-16LE" in EncodingRs.list_output_encodings()
      false
  """
  @spec list_output_encodings() :: [encoding()]
  def list_output_encodings do
    Native.list_output_encodings()
  end

  # Option defaults

  @doc """
  Returns the byte threshold above which operations use dirty CPU schedulers.

  Defaults to `65_536` bytes (64 KB). Pass `:dirty_threshold` in `opts` to
  validate an explicit override.

  ## Examples

      iex> EncodingRs.dirty_threshold()
      65536
  """
  @spec dirty_threshold() :: non_neg_integer()
  @spec dirty_threshold(options()) :: non_neg_integer()
  def dirty_threshold, do: @default_dirty_threshold

  def dirty_threshold(opts) when is_list(opts) do
    {dirty_threshold, _max_input_size} = resolve_options(opts)
    dirty_threshold
  end

  @doc """
  Returns the maximum allowed input size in bytes.

  Defaults to `104_857_600` bytes (100 MB). Pass `:max_input_size` in `opts` to
  validate an explicit override (`non_neg_integer()` or `:infinity`).

  ## Examples

      iex> EncodingRs.max_input_size()
      104857600
  """
  @spec max_input_size() :: non_neg_integer() | :infinity
  @spec max_input_size(options()) :: non_neg_integer() | :infinity
  def max_input_size, do: @default_max_input_size

  def max_input_size(opts) when is_list(opts) do
    {_dirty_threshold, max_input_size} = resolve_options(opts)
    max_input_size
  end

  @doc false
  @spec resolve_options(options()) :: {non_neg_integer(), non_neg_integer() | :infinity}
  def resolve_options(opts) when is_list(opts) do
    opts = Keyword.validate!(opts, @option_keys)
    extract_limits!(opts)
  end

  @doc false
  @spec resolve_decode_options(decode_options()) ::
          {non_neg_integer(), non_neg_integer() | :infinity, bom_mode(), on_error()}
  def resolve_decode_options(opts) when is_list(opts) do
    opts = Keyword.validate!(opts, @decode_option_keys)
    {dirty_threshold, max_input_size} = extract_limits!(opts)

    bom =
      opts
      |> Keyword.get(:bom, @default_bom)
      |> validate_bom_mode!()

    on_error =
      opts
      |> Keyword.get(:on_error, @default_on_error)
      |> validate_on_error!()

    {dirty_threshold, max_input_size, bom, on_error}
  end

  @doc false
  @spec resolve_encode_options(encode_options()) ::
          {non_neg_integer(), non_neg_integer() | :infinity, on_error()}
  def resolve_encode_options(opts) when is_list(opts) do
    opts = Keyword.validate!(opts, @encode_option_keys)
    {dirty_threshold, max_input_size} = extract_limits!(opts)

    on_error =
      opts
      |> Keyword.get(:on_error, @default_on_error)
      |> validate_on_error!()

    {dirty_threshold, max_input_size, on_error}
  end

  @doc false
  @spec resolve_detect_options(detect_options()) ::
          {non_neg_integer(), non_neg_integer() | :infinity, String.t() | nil, boolean(),
           boolean(), boolean()}
  def resolve_detect_options(opts) when is_list(opts) do
    opts = Keyword.validate!(opts, @detect_option_keys)
    {dirty_threshold, max_input_size} = extract_limits!(opts)
    tld = opts |> Keyword.get(:tld) |> validate_tld!()
    allow_utf8 = opts |> Keyword.get(:allow_utf8, true) |> validate_boolean!(:allow_utf8)

    allow_iso_2022_jp =
      opts
      |> Keyword.get(:allow_iso_2022_jp, false)
      |> validate_boolean!(:allow_iso_2022_jp)

    bom = opts |> Keyword.get(:bom, true) |> validate_boolean!(:bom)

    {dirty_threshold, max_input_size, tld, allow_utf8, allow_iso_2022_jp, bom}
  end

  @doc false
  @spec validate_tld!(term()) :: String.t() | nil
  def validate_tld!(nil), do: nil

  def validate_tld!(tld) when is_binary(tld) do
    if valid_tld?(tld) do
      tld
    else
      raise ArgumentError,
            "expected :tld to be a non-empty lowercase ASCII label without dots, got: #{inspect(tld)}"
    end
  end

  def validate_tld!(value) do
    raise ArgumentError,
          "expected :tld to be a lowercase ASCII string or nil, got: #{inspect(value)}"
  end

  @doc false
  @spec validate_boolean!(term(), atom()) :: boolean()
  def validate_boolean!(value, _key) when is_boolean(value), do: value

  def validate_boolean!(value, key) do
    raise ArgumentError, "expected #{inspect(key)} to be a boolean, got: #{inspect(value)}"
  end

  @doc false
  @spec validate_dirty_threshold!(term()) :: non_neg_integer()
  def validate_dirty_threshold!(value) when is_integer(value) and value >= 0, do: value

  def validate_dirty_threshold!(value) do
    raise ArgumentError,
          "expected :dirty_threshold to be a non-negative integer, got: #{inspect(value)}"
  end

  @doc false
  @spec validate_max_input_size!(term()) :: non_neg_integer() | :infinity
  def validate_max_input_size!(:infinity), do: :infinity
  def validate_max_input_size!(value) when is_integer(value) and value >= 0, do: value

  def validate_max_input_size!(value) do
    raise ArgumentError,
          "expected :max_input_size to be a non-negative integer or :infinity, got: #{inspect(value)}"
  end

  # Batch operations

  @doc """
  Decodes multiple `{binary, encoding}` items in one NIF call.

  Returns results in input order. The combined byte size of valid items selects
  whether the call runs on a normal or dirty CPU scheduler. Oversized items
  return `{:error, :input_too_large}` individually without affecting other items.

  Accepts the same options as `decode/3`, including `:bom` and `:on_error`.

  ## Examples

      iex> items = [{<<72, 101, 108, 108, 111>>, "windows-1252"}, {<<0x82, 0xA0>>, "shift_jis"}]
      iex> EncodingRs.decode_batch(items)
      [{:ok, "Hello"}, {:ok, "あ"}]

      iex> EncodingRs.decode_batch([{<<72>>, "invalid-encoding"}])
      [{:error, :unknown_encoding}]
  """
  @spec decode_batch([decode_batch_item()]) :: [decode_batch_result()]
  @spec decode_batch([decode_batch_item()], decode_options()) :: [decode_batch_result()]
  def decode_batch(items) when is_list(items) do
    run_batch(
      items,
      @default_dirty_threshold,
      @default_max_input_size,
      fn batch, dirty? ->
        if dirty?,
          do: Native.decode_batch(batch, @default_bom, @default_on_error),
          else: Native.decode_batch_normal(batch, @default_bom, @default_on_error)
      end,
      &normalize_result/1
    )
  end

  def decode_batch(items, opts) when is_list(items) and is_list(opts) do
    {dirty_threshold, max_input_size, bom, on_error} = resolve_decode_options(opts)

    run_batch(
      items,
      dirty_threshold,
      max_input_size,
      fn batch, dirty? ->
        if dirty?,
          do: Native.decode_batch(batch, bom, on_error),
          else: Native.decode_batch_normal(batch, bom, on_error)
      end,
      &normalize_result/1
    )
  end

  @doc """
  Decodes multiple binaries while reporting each item's selected encoding and
  replacement status.

  Results preserve input order. See `decode_with_details/3` for the tuple
  format.

  ## Examples

      iex> EncodingRs.decode_batch_with_details([{"hello", "utf-8"}, {<<0xFF>>, "utf-8"}])
      [{:ok, "hello", "UTF-8", false}, {:ok, "\uFFFD", "UTF-8", true}]
  """
  @spec decode_batch_with_details([decode_batch_item()]) :: [decode_details_result()]
  @spec decode_batch_with_details([decode_batch_item()], decode_options()) ::
          [decode_details_result()]
  def decode_batch_with_details(items) when is_list(items) do
    run_batch(
      items,
      @default_dirty_threshold,
      @default_max_input_size,
      fn batch, dirty? ->
        if dirty?,
          do: Native.decode_batch_with_details(batch, @default_bom, @default_on_error),
          else: Native.decode_batch_with_details_normal(batch, @default_bom, @default_on_error)
      end,
      &normalize_decode_details/1
    )
  end

  def decode_batch_with_details(items, opts) when is_list(items) and is_list(opts) do
    {dirty_threshold, max_input_size, bom, on_error} = resolve_decode_options(opts)

    run_batch(
      items,
      dirty_threshold,
      max_input_size,
      fn batch, dirty? ->
        if dirty?,
          do: Native.decode_batch_with_details(batch, bom, on_error),
          else: Native.decode_batch_with_details_normal(batch, bom, on_error)
      end,
      &normalize_decode_details/1
    )
  end

  @doc """
  Encodes multiple `{string, encoding}` items in one NIF call.

  Returns results in input order. Accepts the same options as `encode/3`,
  including `:on_error`.

  ## Examples

      iex> items = [{"Hello", "windows-1252"}, {"あ", "shift_jis"}]
      iex> EncodingRs.encode_batch(items)
      [{:ok, "Hello"}, {:ok, <<130, 160>>}]

      iex> EncodingRs.encode_batch([{"test", "invalid-encoding"}])
      [{:error, :unknown_encoding}]
  """
  @spec encode_batch([encode_batch_item()]) :: [encode_batch_result()]
  @spec encode_batch([encode_batch_item()], encode_options()) :: [encode_batch_result()]
  def encode_batch(items) when is_list(items) do
    run_batch(
      items,
      @default_dirty_threshold,
      @default_max_input_size,
      fn batch, dirty? ->
        if dirty?,
          do: Native.encode_batch(batch, @default_on_error),
          else: Native.encode_batch_normal(batch, @default_on_error)
      end,
      &normalize_result/1
    )
  end

  def encode_batch(items, opts) when is_list(items) and is_list(opts) do
    {dirty_threshold, max_input_size, on_error} = resolve_encode_options(opts)

    run_batch(
      items,
      dirty_threshold,
      max_input_size,
      fn batch, dirty? ->
        if dirty?,
          do: Native.encode_batch(batch, on_error),
          else: Native.encode_batch_normal(batch, on_error)
      end,
      &normalize_result/1
    )
  end

  @doc """
  Encodes multiple strings while reporting whether each item had unmappable
  characters replaced.

  Results preserve input order. See `encode_with_details/3` for the tuple
  format.

  ## Examples

      iex> EncodingRs.encode_batch_with_details([{"Hello", "windows-1252"}, {"🎉", "windows-1252"}])
      [{:ok, "Hello", false}, {:ok, "&#127881;", true}]
  """
  @spec encode_batch_with_details([encode_batch_item()]) :: [encode_details_result()]
  @spec encode_batch_with_details([encode_batch_item()], encode_options()) ::
          [encode_details_result()]
  def encode_batch_with_details(items) when is_list(items) do
    run_batch(
      items,
      @default_dirty_threshold,
      @default_max_input_size,
      fn batch, dirty? ->
        if dirty?,
          do: Native.encode_batch_with_details(batch, @default_on_error),
          else: Native.encode_batch_with_details_normal(batch, @default_on_error)
      end,
      &normalize_encode_details/1
    )
  end

  def encode_batch_with_details(items, opts) when is_list(items) and is_list(opts) do
    {dirty_threshold, max_input_size, on_error} = resolve_encode_options(opts)

    run_batch(
      items,
      dirty_threshold,
      max_input_size,
      fn batch, dirty? ->
        if dirty?,
          do: Native.encode_batch_with_details(batch, on_error),
          else: Native.encode_batch_with_details_normal(batch, on_error)
      end,
      &normalize_encode_details/1
    )
  end

  defp run_batch([], _dirty_threshold, _max_input_size, _nif_runner, _normalizer), do: []

  defp run_batch(items, dirty_threshold, max_input_size, nif_runner, normalizer) do
    case scan_batch_sizes(items, max_input_size) do
      {:all_valid, total_size} ->
        items
        |> nif_runner.(total_size > dirty_threshold)
        |> Enum.map(normalizer)

      {:has_oversized, _oversized_indices, [], _total_size, count} ->
        List.duplicate({:error, :input_too_large}, count)

      {:has_oversized, oversized_indices, valid_items, total_size, count} ->
        nif_results =
          valid_items
          |> Enum.map(fn {item, _idx} -> item end)
          |> nif_runner.(total_size > dirty_threshold)
          |> Enum.map(normalizer)

        merge_results(oversized_indices, valid_items, nif_results, count)
    end
  end

  # BOM and heuristic detection

  @doc """
  Detects the encoding from a Byte Order Mark (BOM) at the start of the binary.

  Supported BOMs:

  - UTF-8: `<<0xEF, 0xBB, 0xBF>>` (3 bytes)
  - UTF-16LE: `<<0xFF, 0xFE>>` (2 bytes)
  - UTF-16BE: `<<0xFE, 0xFF>>` (2 bytes)

  Returns `{:ok, encoding, bom_length}` or `{:error, :no_bom}`.

  ## Examples

      iex> EncodingRs.detect_bom(<<0xEF, 0xBB, 0xBF, "hello">>)
      {:ok, "UTF-8", 3}

      iex> EncodingRs.detect_bom(<<0xFF, 0xFE, 0x48, 0x00>>)
      {:ok, "UTF-16LE", 2}

      iex> EncodingRs.detect_bom(<<0xFE, 0xFF, 0x00, 0x48>>)
      {:ok, "UTF-16BE", 2}

      iex> EncodingRs.detect_bom("hello")
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
  Detects a leading BOM and removes it from the binary.

  Returns `{:ok, encoding, data_without_bom}` or `{:error, :no_bom}`.

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

  @doc """
  Detects the most likely WHATWG encoding of a binary.

  Checks for a leading UTF-8 or UTF-16 BOM first (unless `bom: false`), then
  runs Mozilla's `chardetng` heuristic detector. For incremental detection over
  large files or streams, use `EncodingRs.Detector`.

  ## Options

  - `:tld` (default `nil`): Lowercase ASCII top-level domain label without
    dots (such as `"jp"`, `"cn"`, or `"ru"`), or punycode for IDN TLDs, to bias
    ambiguous legacy text.
  - `:allow_utf8` (default `true`): Set to `false` to disallow `"UTF-8"` as a
    heuristic result.
  - `:allow_iso_2022_jp` (default `false`): Set to `true` when inspecting
    email or other inputs where `ISO-2022-JP` is expected.
  - `:bom` (default `true`): Set to `false` to ignore leading BOMs.
  - `:dirty_threshold` and `:max_input_size`: Standard scheduler and size
    limits.

  ## Examples

      iex> EncodingRs.detect("こんにちは")
      {:ok, "UTF-8"}

      iex> {:ok, sjis} = EncodingRs.encode("こんにちは世界、日本語のテストです。", "shift_jis")
      iex> EncodingRs.detect(sjis, tld: "jp")
      {:ok, "Shift_JIS"}

      iex> EncodingRs.detect(<<0xFF, 0xFE, 0x48, 0x00>>)
      {:ok, "UTF-16LE"}
  """
  @spec detect(binary()) :: {:ok, encoding()} | {:error, :input_too_large}
  @spec detect(binary(), detect_options()) :: {:ok, encoding()} | {:error, :input_too_large}
  def detect(data) when is_binary(data) do
    detect_native(
      data,
      {@default_dirty_threshold, @default_max_input_size, nil, true, false, true}
    )
  end

  def detect(data, opts) when is_binary(data) and is_list(opts) do
    detect_native(data, resolve_detect_options(opts))
  end

  @doc """
  Detects the most likely WHATWG encoding of a binary, raising `ArgumentError`
  on failure.

  See `detect/2` for options.

  ## Examples

      iex> EncodingRs.detect!("こんにちは")
      "UTF-8"
  """
  @spec detect!(binary()) :: encoding()
  @spec detect!(binary(), detect_options()) :: encoding()
  def detect!(data) when is_binary(data) do
    data
    |> detect()
    |> unwrap_result!("", :default)
  end

  def detect!(data, opts) when is_binary(data) and is_list(opts) do
    data
    |> detect(opts)
    |> unwrap_result!("", opts)
  end

  defp detect_native(
         data,
         {dirty_threshold, max_input_size, tld, allow_utf8, allow_iso_2022_jp, bom}
       ) do
    with :ok <- validate_input_size(data, max_input_size) do
      result =
        if byte_size(data) > dirty_threshold do
          Native.detect_dirty(data, tld, allow_utf8, allow_iso_2022_jp, bom)
        else
          Native.detect_normal(data, tld, allow_utf8, allow_iso_2022_jp, bom)
        end

      case result do
        {:ok, encoding} -> {:ok, encoding}
        {:error, reason} -> normalize_error(reason)
      end
    end
  end

  # Private helpers

  defp extract_limits!(opts) do
    dirty_threshold =
      opts
      |> Keyword.get(:dirty_threshold, @default_dirty_threshold)
      |> validate_dirty_threshold!()

    max_input_size =
      opts
      |> Keyword.get(:max_input_size, @default_max_input_size)
      |> validate_max_input_size!()

    {dirty_threshold, max_input_size}
  end

  defp validate_bom_mode!(mode) when mode in [:sniff, :strip, :preserve], do: mode

  defp validate_bom_mode!(value) do
    raise ArgumentError,
          "expected :bom to be :sniff, :strip, or :preserve, got: #{inspect(value)}"
  end

  defp validate_on_error!(mode) when mode in [:replace, :error], do: mode

  defp validate_on_error!(value) do
    raise ArgumentError,
          "expected :on_error to be :replace or :error, got: #{inspect(value)}"
  end

  defp valid_tld?(""), do: false
  defp valid_tld?(tld), do: valid_tld_bytes?(tld)

  defp valid_tld_bytes?(<<>>), do: true

  defp valid_tld_bytes?(<<byte, rest::binary>>)
       when byte < 128 and byte != ?. and not (byte >= ?A and byte <= ?Z) do
    valid_tld_bytes?(rest)
  end

  defp valid_tld_bytes?(_), do: false

  defp normalize_result({:ok, value}), do: {:ok, value}
  defp normalize_result({:error, reason}), do: normalize_error(reason)

  defp normalize_decode_details({:ok, value, actual_encoding, had_errors}),
    do: {:ok, value, actual_encoding, had_errors}

  defp normalize_decode_details({:error, reason, _actual_encoding, _had_errors}),
    do: normalize_error(reason)

  defp normalize_encode_details({:ok, value, had_errors}), do: {:ok, value, had_errors}

  defp normalize_encode_details({:error, reason, _had_errors}), do: normalize_error(reason)

  defp normalize_error(reason) when reason in ["", "unknown_encoding"],
    do: {:error, :unknown_encoding}

  defp normalize_error("encoder_unavailable"), do: {:error, :encoder_unavailable}
  defp normalize_error("invalid_utf8"), do: {:error, :invalid_utf8}
  defp normalize_error("unmappable_character"), do: {:error, :unmappable_character}
  defp normalize_error("malformed_input"), do: {:error, :malformed_input}
  defp normalize_error("allocation_failed"), do: {:error, :allocation_failed}
  defp normalize_error(reason), do: {:error, reason}

  defp unwrap_result!({:ok, value}, _encoding, _opts), do: value

  defp unwrap_result!({:error, :unknown_encoding}, encoding, _opts) do
    raise ArgumentError, "unknown encoding: #{encoding}"
  end

  defp unwrap_result!({:error, :encoder_unavailable}, encoding, _opts) do
    raise ArgumentError, "encoding is decode-only: #{encoding}"
  end

  defp unwrap_result!({:error, :invalid_utf8}, _encoding, _opts) do
    raise ArgumentError, "input is not valid UTF-8"
  end

  defp unwrap_result!({:error, :unmappable_character}, encoding, _opts) do
    raise ArgumentError, "unmappable character for encoding: #{encoding}"
  end

  defp unwrap_result!({:error, :malformed_input}, encoding, _opts) do
    raise ArgumentError, "malformed byte sequence for encoding: #{encoding}"
  end

  defp unwrap_result!({:error, :input_too_large}, _encoding, opts) do
    raise ArgumentError,
          "input exceeds maximum size of #{max_input_size_for_error(opts)} bytes"
  end

  defp unwrap_result!({:error, reason}, _encoding, _opts) do
    raise RuntimeError, "encoding_rs error: #{inspect(reason)}"
  end

  defp max_input_size_for_error(:default), do: @default_max_input_size

  defp max_input_size_for_error(opts) do
    Keyword.get(opts, :max_input_size, @default_max_input_size)
  end

  defp validate_input_size(input, max_input_size) do
    case max_input_size do
      :infinity -> :ok
      max when byte_size(input) <= max -> :ok
      _ -> {:error, :input_too_large}
    end
  end

  defp scan_batch_sizes(items, :infinity) do
    total_size = Enum.reduce(items, 0, fn {binary, _enc}, acc -> acc + byte_size(binary) end)
    {:all_valid, total_size}
  end

  defp scan_batch_sizes(items, max) do
    case scan_all_valid(items, max, 0) do
      {:all_valid, total_size} ->
        {:all_valid, total_size}

      :oversized ->
        split_by_size(items, max)
    end
  end

  defp scan_all_valid([], _max, total_size), do: {:all_valid, total_size}

  defp scan_all_valid([{binary, _enc} | rest], max, total_size) do
    size = byte_size(binary)

    if size > max do
      :oversized
    else
      scan_all_valid(rest, max, total_size + size)
    end
  end

  defp split_by_size(items, max) do
    {oversized_indices, valid_items, total_size, count} =
      Enum.reduce(items, {MapSet.new(), [], 0, 0}, fn {binary, _enc} = item,
                                                      {oversized, valid, total, idx} ->
        size = byte_size(binary)

        if size > max do
          {MapSet.put(oversized, idx), valid, total, idx + 1}
        else
          {oversized, [{item, idx} | valid], total + size, idx + 1}
        end
      end)

    {:has_oversized, oversized_indices, Enum.reverse(valid_items), total_size, count}
  end

  defp merge_results(oversized_indices, valid_items, nif_results, total) do
    valid_map =
      valid_items
      |> Enum.map(fn {_item, idx} -> idx end)
      |> Enum.zip(nif_results)
      |> Map.new()

    Enum.map(0..(total - 1), fn idx ->
      if MapSet.member?(oversized_indices, idx) do
        {:error, :input_too_large}
      else
        Map.fetch!(valid_map, idx)
      end
    end)
  end
end
