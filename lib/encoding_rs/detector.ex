defmodule EncodingRs.Detector do
  @moduledoc """
  Stateful streaming character encoding detector powered by Mozilla's
  `chardetng` crate.

  Use this module to guess the encoding of large files or network streams
  incrementally without loading the entire input into memory. For complete
  binaries already in memory, use `EncodingRs.detect/2`.

  ## Usage

  ### Detecting from a stream

      {:ok, encoding} =
        File.stream!("unknown.txt", [], 64 * 1024)
        |> Stream.take(4)
        |> EncodingRs.Detector.detect_stream(tld: "jp")

  ### Manual chunk feeding

      detector = EncodingRs.Detector.new()
      {:ok, _non_ascii?} = EncodingRs.Detector.feed(detector, chunk1, false)
      {:ok, _non_ascii?} = EncodingRs.Detector.feed(detector, chunk2, true)
      {:ok, encoding} = EncodingRs.Detector.guess(detector, tld: "jp")

  ## Important notes

  - Leading UTF-8 and UTF-16 BOMs take precedence over heuristics unless
    `bom: false` is passed to `new/1` or `detect_stream/2`.
  - Pass `is_last: true` only when the full stream ends. If you feed only a
    prefix of a larger file, pass `is_last: false` and call `guess/2` directly.
  - Calling `feed/3` after `is_last: true` returns `{:error, :detector_finished}`.
  - Each detector holds mutable state. Use one detector per stream.
  """

  alias EncodingRs.Native

  @new_option_keys [:dirty_threshold, :max_input_size, :allow_iso_2022_jp, :bom]
  @guess_option_keys [:tld, :allow_utf8]

  @enforce_keys [:resource, :dirty_threshold, :max_input_size]
  defstruct [:resource, :dirty_threshold, :max_input_size]

  @typedoc "An opaque detector created with `new/0` or `new/1`."
  @opaque t :: %__MODULE__{
            resource: reference(),
            dirty_threshold: non_neg_integer(),
            max_input_size: non_neg_integer() | :infinity
          }

  @typedoc "Options accepted by `new/1`."
  @type new_options :: [
          {:dirty_threshold, non_neg_integer()}
          | {:max_input_size, non_neg_integer() | :infinity}
          | {:allow_iso_2022_jp, boolean()}
          | {:bom, boolean()}
        ]

  @typedoc "Options accepted by `guess/2` and `guess!/2`."
  @type guess_options :: [
          {:tld, String.t() | nil}
          | {:allow_utf8, boolean()}
        ]

  @typedoc "Error reasons returned while feeding chunks."
  @type feed_error :: :input_too_large | :detector_finished | :lock_poisoned

  @doc """
  Creates a new streaming encoding detector.

  ## Options

  - `:allow_iso_2022_jp` (default `false`): Set to `true` when detecting email
    or inputs that may use `ISO-2022-JP`.
  - `:bom` (default `true`): Set to `false` to ignore leading UTF-8 and UTF-16
    BOMs.
  - `:dirty_threshold` (default `65_536`): Chunk byte threshold for dirty CPU
    schedulers.
  - `:max_input_size` (default `104_857_600`): Maximum chunk size in bytes, or
    `:infinity`.

  ## Examples

      iex> detector = EncodingRs.Detector.new()
      iex> {:ok, true} = EncodingRs.Detector.feed(detector, "こんにちは", true)
      iex> EncodingRs.Detector.guess(detector)
      {:ok, "UTF-8"}
  """
  @spec new() :: t()
  @spec new(new_options()) :: t()
  def new(opts \\ []) when is_list(opts) do
    opts = Keyword.validate!(opts, @new_option_keys)

    dirty_threshold =
      opts
      |> Keyword.get(:dirty_threshold, EncodingRs.dirty_threshold())
      |> EncodingRs.validate_dirty_threshold!()

    max_input_size =
      opts
      |> Keyword.get(:max_input_size, EncodingRs.max_input_size())
      |> EncodingRs.validate_max_input_size!()

    allow_iso_2022_jp =
      opts
      |> Keyword.get(:allow_iso_2022_jp, false)
      |> EncodingRs.validate_boolean!(:allow_iso_2022_jp)

    bom =
      opts
      |> Keyword.get(:bom, true)
      |> EncodingRs.validate_boolean!(:bom)

    resource = Native.detector_new(allow_iso_2022_jp, bom)

    %__MODULE__{
      resource: resource,
      dirty_threshold: dirty_threshold,
      max_input_size: max_input_size
    }
  end

  @doc """
  Feeds a chunk of bytes into the detector.

  Returns `{:ok, non_ascii_seen?}` on success, where `non_ascii_seen?` is
  `true` once any non-ASCII byte (or BOM) has been observed.

  Set `is_last` to `true` only on the final chunk of a complete stream. Calling
  `feed/3` again after `is_last: true` returns `{:error, :detector_finished}`.

  ## Examples

      iex> detector = EncodingRs.Detector.new()
      iex> EncodingRs.Detector.feed(detector, "ascii only", false)
      {:ok, false}
  """
  @spec feed(t(), binary()) :: {:ok, boolean()} | {:error, feed_error()}
  @spec feed(t(), binary(), boolean()) :: {:ok, boolean()} | {:error, feed_error()}
  def feed(detector, chunk, is_last \\ false)

  def feed(
        %__MODULE__{
          resource: resource,
          dirty_threshold: dirty_threshold,
          max_input_size: max_input_size
        },
        chunk,
        is_last
      )
      when is_binary(chunk) and is_boolean(is_last) do
    feed_resolved(resource, chunk, is_last, dirty_threshold, max_input_size)
  end

  @spec feed(t(), binary(), boolean(), EncodingRs.options()) ::
          {:ok, boolean()} | {:error, feed_error()}
  def feed(%__MODULE__{resource: resource}, chunk, is_last, opts)
      when is_binary(chunk) and is_boolean(is_last) and is_list(opts) do
    {dirty_threshold, max_input_size} = EncodingRs.resolve_options(opts)
    feed_resolved(resource, chunk, is_last, dirty_threshold, max_input_size)
  end

  @doc """
  Feeds a chunk of bytes into the detector, returning `non_ascii_seen?` or
  raising on error.

  ## Examples

      iex> detector = EncodingRs.Detector.new()
      iex> EncodingRs.Detector.feed!(detector, "hello", true)
      false
  """
  @spec feed!(t(), binary()) :: boolean()
  @spec feed!(t(), binary(), boolean()) :: boolean()
  def feed!(detector, chunk, is_last \\ false)

  def feed!(%__MODULE__{} = detector, chunk, is_last)
      when is_binary(chunk) and is_boolean(is_last) do
    detector
    |> feed(chunk, is_last)
    |> unwrap_feed_result!()
  end

  @spec feed!(t(), binary(), boolean(), EncodingRs.options()) :: boolean()
  def feed!(%__MODULE__{} = detector, chunk, is_last, opts)
      when is_binary(chunk) and is_boolean(is_last) and is_list(opts) do
    detector
    |> feed(chunk, is_last, opts)
    |> unwrap_feed_result!()
  end

  @doc """
  Returns the current guessed WHATWG encoding name for all bytes fed so far.

  You can call `guess/2` multiple times with different `:tld` or `:allow_utf8`
  options without re-feeding the input.

  ## Options

  - `:tld` (default `nil`): Lowercase ASCII top-level domain label without
    dots (such as `"jp"`, `"cn"`, or `"ru"`), or punycode for IDN TLDs.
  - `:allow_utf8` (default `true`): Set to `false` to exclude `"UTF-8"` from
    heuristic guesses.

  ## Examples

      iex> detector = EncodingRs.Detector.new()
      iex> {:ok, false} = EncodingRs.Detector.feed(detector, "hello", true)
      iex> EncodingRs.Detector.guess(detector)
      {:ok, "UTF-8"}
      iex> EncodingRs.Detector.guess(detector, allow_utf8: false)
      {:ok, "windows-1252"}
  """
  @spec guess(t()) :: {:ok, EncodingRs.encoding()} | {:error, :lock_poisoned}
  @spec guess(t(), guess_options()) :: {:ok, EncodingRs.encoding()} | {:error, :lock_poisoned}
  def guess(%__MODULE__{resource: resource}, opts \\ []) when is_list(opts) do
    opts = Keyword.validate!(opts, @guess_option_keys)
    tld = opts |> Keyword.get(:tld) |> EncodingRs.validate_tld!()

    allow_utf8 =
      opts |> Keyword.get(:allow_utf8, true) |> EncodingRs.validate_boolean!(:allow_utf8)

    case Native.detector_guess(resource, tld, allow_utf8) do
      {:ok, encoding} -> {:ok, encoding}
      {:error, "lock_poisoned"} -> {:error, :lock_poisoned}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Returns the guessed encoding name directly, raising on error.

  ## Examples

      iex> detector = EncodingRs.Detector.new()
      iex> EncodingRs.Detector.feed!(detector, "hello", true)
      false
      iex> EncodingRs.Detector.guess!(detector)
      "UTF-8"
  """
  @spec guess!(t()) :: EncodingRs.encoding()
  @spec guess!(t(), guess_options()) :: EncodingRs.encoding()
  def guess!(%__MODULE__{} = detector, opts \\ []) when is_list(opts) do
    case guess(detector, opts) do
      {:ok, encoding} -> encoding
      {:error, reason} -> raise RuntimeError, "detector error: #{reason}"
    end
  end

  @doc """
  Feeds an enumerable of binary chunks into a detector and returns the guessed
  encoding.

  Accepts all options supported by `EncodingRs.detect/2`.

  ## Examples

      iex> ["こん", "にちは"] |> EncodingRs.Detector.detect_stream()
      {:ok, "UTF-8"}
  """
  @spec detect_stream(Enumerable.t()) :: {:ok, EncodingRs.encoding()} | {:error, feed_error()}
  @spec detect_stream(Enumerable.t(), EncodingRs.detect_options()) ::
          {:ok, EncodingRs.encoding()} | {:error, feed_error()}
  def detect_stream(chunks, opts \\ []) when is_list(opts) do
    {dirty_threshold, max_input_size, tld, allow_utf8, allow_iso_2022_jp, bom} =
      EncodingRs.resolve_detect_options(opts)

    detector =
      new(
        dirty_threshold: dirty_threshold,
        max_input_size: max_input_size,
        allow_iso_2022_jp: allow_iso_2022_jp,
        bom: bom
      )

    result =
      Enum.reduce_while(chunks, :ok, fn chunk, :ok ->
        case feed(detector, chunk, false) do
          {:ok, _non_ascii?} -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    with :ok <- result,
         {:ok, _} <- feed(detector, <<>>, true) do
      guess(detector, tld: tld, allow_utf8: allow_utf8)
    end
  end

  @doc """
  Feeds an enumerable of binary chunks into a detector and returns the guessed
  encoding directly, raising on error.

  ## Examples

      iex> ["こん", "にちは"] |> EncodingRs.Detector.detect_stream!()
      "UTF-8"
  """
  @spec detect_stream!(Enumerable.t()) :: EncodingRs.encoding()
  @spec detect_stream!(Enumerable.t(), EncodingRs.detect_options()) :: EncodingRs.encoding()
  def detect_stream!(chunks, opts \\ []) when is_list(opts) do
    case detect_stream(chunks, opts) do
      {:ok, encoding} -> encoding
      {:error, reason} -> raise RuntimeError, "detector error: #{reason}"
    end
  end

  # Private helpers

  defp feed_resolved(resource, chunk, is_last, dirty_threshold, max_input_size) do
    if max_input_size != :infinity and byte_size(chunk) > max_input_size do
      {:error, :input_too_large}
    else
      result =
        if byte_size(chunk) > dirty_threshold do
          Native.detector_feed_dirty(resource, chunk, is_last)
        else
          Native.detector_feed(resource, chunk, is_last)
        end

      case result do
        {:ok, non_ascii_seen, _} -> {:ok, non_ascii_seen}
        {:error, _, "detector_finished"} -> {:error, :detector_finished}
        {:error, _, "lock_poisoned"} -> {:error, :lock_poisoned}
        {:error, _, reason} -> {:error, reason}
      end
    end
  end

  defp unwrap_feed_result!({:ok, non_ascii_seen}), do: non_ascii_seen

  defp unwrap_feed_result!({:error, reason}),
    do: raise(RuntimeError, "detector error: #{reason}")
end
