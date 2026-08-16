# Benchmark: encoding_rs vs codepagex vs iconv
#
# Run with: mix run bench/comparison_bench.exs
#
# Results will be saved to bench/output/

defmodule BenchHelper do
  @moduledoc """
  Helper functions to normalize API differences between libraries.
  """

  # Generate test data of specified size with mixed character types
  # for realistic benchmarking across different encoding scenarios
  def generate_utf8_data(size, encoding \\ :mixed) do
    ranges = character_ranges_for(encoding)

    weighted_ranges =
      Enum.flat_map(ranges, fn {range, weight} ->
        List.duplicate(range, weight)
      end)

    generate_chars(size, weighted_ranges, [])
    |> List.to_string()
  end

  # Character ranges appropriate for each target encoding
  defp character_ranges_for(:mixed) do
    # General purpose mix for decode tests (any valid UTF-8)
    [
      {32..126, 5},       # ASCII - 50% weight
      {192..255, 3},      # Latin-1 accented chars - 30%
      {0x3040..0x309F, 2} # Hiragana - 20% (for Shift_JIS)
    ]
  end

  defp character_ranges_for("iso-8859-1") do
    # ISO-8859-1 (Latin-1) compatible characters
    [
      {32..126, 6},       # ASCII - 60%
      {160..255, 4}       # Latin-1 supplement - 40% (160-255 for iso-8859-1)
    ]
  end

  defp character_ranges_for("shift_jis") do
    # Shift_JIS compatible: ASCII + Hiragana + Katakana
    [
      {32..126, 4},       # ASCII - 40%
      {0x3040..0x309F, 3}, # Hiragana - 30%
      {0x30A0..0x30FF, 3}  # Katakana - 30%
    ]
  end

  defp character_ranges_for(_), do: character_ranges_for(:mixed)

  defp generate_chars(0, _ranges, acc), do: Enum.reverse(acc)
  defp generate_chars(remaining, ranges, acc) do
    range = Enum.random(ranges)
    char = Enum.random(range)
    # Calculate how many bytes this character takes in UTF-8
    bytes_used = byte_size(List.to_string([char]))
    if bytes_used <= remaining do
      generate_chars(remaining - bytes_used, ranges, [char | acc])
    else
      # Fill remaining with ASCII
      remaining_chars = for _ <- 1..remaining, do: Enum.random(32..126)
      Enum.reverse(remaining_chars ++ acc)
    end
  end

  # Generate ASCII-only data for baseline comparisons
  def generate_ascii_data(size) do
    1..size
    |> Enum.map(fn _ -> Enum.random(32..126) end)
    |> IO.iodata_to_binary()
  end

  # Encoding wrappers to normalize APIs
  def encode_encoding_rs(data, encoding) do
    EncodingRs.encode(data, encoding)
  end

  def decode_encoding_rs(data, encoding) do
    EncodingRs.decode(data, encoding)
  end

  # Pre-computed encoding atoms for codepagex (avoids atom conversion in hot path)
  def codepagex_encoding(encoding) do
    case encoding do
      "iso-8859-1" -> :iso_8859_1
      "shift_jis" -> nil
      _ -> nil
    end
  end

  def encode_codepagex(data, codepagex_encoding) when is_atom(codepagex_encoding) do
    Codepagex.from_string!(data, codepagex_encoding)
  rescue
    _ -> {:error, :encoding_failed}
  end

  def decode_codepagex(data, codepagex_encoding) when is_atom(codepagex_encoding) do
    Codepagex.to_string!(data, codepagex_encoding)
  rescue
    _ -> {:error, :decoding_failed}
  end

  def encode_iconv(data, iconv_encoding) when is_binary(iconv_encoding) do
    :iconv.convert("UTF-8", iconv_encoding, data)
  rescue
    _ -> {:error, :encoding_failed}
  end

  def decode_iconv(data, iconv_encoding) when is_binary(iconv_encoding) do
    :iconv.convert(iconv_encoding, "UTF-8", data)
  rescue
    _ -> {:error, :decoding_failed}
  end

  # Pre-computed encoding strings for iconv
  def iconv_encoding(encoding) do
    case encoding do
      "iso-8859-1" -> "ISO-8859-1"
      "shift_jis" -> "SHIFT_JIS"
      _ -> String.upcase(encoding)
    end
  end

  # Check if codepagex supports an encoding
  def codepagex_supports?(encoding) do
    codepagex_encoding(encoding) != nil
  end
end

# Ensure output directory exists
File.mkdir_p!("bench/output")

IO.puts("""
================================================================================
                    Encoding Library Comparison Benchmark
================================================================================

Comparing: encoding_rs (Rust NIF) vs codepagex (Pure Elixir) vs iconv (C NIF)

Libraries loaded:
  - encoding_rs: #{Application.spec(:encoding_rs, :vsn)}
  - codepagex:   #{Application.spec(:codepagex, :vsn)}
  - iconv:       #{Application.spec(:iconv, :vsn)}

""")

# Define input sizes
input_sizes = %{
  "small (100 B)" => 100,
  "medium (10 KB)" => 10 * 1024,
  "large (1 MB)" => 1024 * 1024
}

# Define encodings to test
# Using iso-8859-1 instead of windows-1252 for fair comparison (codepagex supports it)
encodings = [
  {"iso-8859-1", "Western European (Latin-1)"},
  {"shift_jis", "Japanese multibyte encoding"}
]

# Generate generic test data for display
generic_test_data =
  for {name, size} <- input_sizes, into: %{} do
    {name, BenchHelper.generate_utf8_data(size, :mixed)}
  end

IO.puts("Test data sizes:")
for {name, data} <- generic_test_data do
  IO.puts("  #{name}: #{byte_size(data)} bytes")
end
IO.puts("\nNote: Encode tests use encoding-specific character sets for fair comparison.")
IO.puts("      Decode tests use mixed UTF-8 data (ASCII + Latin-1 + Hiragana).\n")

# Run benchmarks for each encoding
for {encoding, description} <- encodings do
  IO.puts("""
  ================================================================================
  Encoding: #{encoding}
  #{description}
  ================================================================================
  """)

  # Pre-compute encoding names for each library (avoids overhead in hot path)
  codepagex_enc = BenchHelper.codepagex_encoding(encoding)
  iconv_enc = BenchHelper.iconv_encoding(encoding)
  codepagex_available = codepagex_enc != nil

  unless codepagex_available do
    IO.puts("Note: codepagex does not support #{encoding}, skipping in comparison\n")
  end

  # Generate encoding-specific UTF-8 data for encode benchmarks
  # This ensures all characters can be encoded without replacement
  encode_test_data =
    for {name, size} <- input_sizes, into: %{} do
      {name, BenchHelper.generate_utf8_data(size, encoding)}
    end

  # Prepare encoded data for decode benchmarks
  encoded_data =
    for {name, data} <- encode_test_data, into: %{} do
      case BenchHelper.encode_encoding_rs(data, encoding) do
        {:ok, encoded} -> {name, encoded}
        {:error, _} -> {name, data}  # Fallback for encodings that may fail
      end
    end

  # Build benchmark jobs for encode (using pre-computed encoding names)
  encode_jobs =
    for {size_name, data} <- encode_test_data, into: %{} do
      base_jobs = %{
        "encoding_rs" => fn -> BenchHelper.encode_encoding_rs(data, encoding) end,
        "iconv" => fn -> BenchHelper.encode_iconv(data, iconv_enc) end
      }

      jobs =
        if codepagex_available do
          Map.put(base_jobs, "codepagex", fn -> BenchHelper.encode_codepagex(data, codepagex_enc) end)
        else
          base_jobs
        end

      {size_name, jobs}
    end

  # Build benchmark jobs for decode (using pre-computed encoding names)
  decode_jobs =
    for {size_name, data} <- encoded_data, into: %{} do
      base_jobs = %{
        "encoding_rs" => fn -> BenchHelper.decode_encoding_rs(data, encoding) end,
        "iconv" => fn -> BenchHelper.decode_iconv(data, iconv_enc) end
      }

      jobs =
        if codepagex_available do
          Map.put(base_jobs, "codepagex", fn -> BenchHelper.decode_codepagex(data, codepagex_enc) end)
        else
          base_jobs
        end

      {size_name, jobs}
    end

  # Run encode benchmarks
  IO.puts("\n--- Encode: UTF-8 → #{encoding} ---\n")

  for {size_name, jobs} <- Enum.sort(encode_jobs) do
    IO.puts("Input size: #{size_name}")

    Benchee.run(
      jobs,
      warmup: 1,
      time: 3,
      memory_time: 1,
      formatters: [
        Benchee.Formatters.Console,
        {Benchee.Formatters.HTML,
         file: "bench/output/encode_#{encoding}_#{String.replace(size_name, ~r/[^a-z0-9]/i, "_")}.html",
         auto_open: false}
      ],
      print: [
        benchmarking: false,
        configuration: false
      ]
    )
    IO.puts("")
  end

  # Run decode benchmarks
  IO.puts("\n--- Decode: #{encoding} → UTF-8 ---\n")

  for {size_name, jobs} <- Enum.sort(decode_jobs) do
    IO.puts("Input size: #{size_name}")

    Benchee.run(
      jobs,
      warmup: 1,
      time: 3,
      memory_time: 1,
      formatters: [
        Benchee.Formatters.Console,
        {Benchee.Formatters.HTML,
         file: "bench/output/decode_#{encoding}_#{String.replace(size_name, ~r/[^a-z0-9]/i, "_")}.html",
         auto_open: false}
      ],
      print: [
        benchmarking: false,
        configuration: false
      ]
    )
    IO.puts("")
  end
end

IO.puts("""

================================================================================
                              Benchmark Complete
================================================================================

HTML reports saved to: bench/output/
Open in browser: open bench/output/*.html

""")
