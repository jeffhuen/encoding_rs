defmodule EncodingRs.DecoderTest do
  use ExUnit.Case, async: true
  doctest EncodingRs.Decoder

  alias EncodingRs.Decoder

  describe "new/1 and new/2" do
    test "creates decoder for valid encodings and aliases" do
      assert {:ok, decoder} = Decoder.new("shift_jis")
      assert {:ok, "Shift_JIS"} = Decoder.encoding(decoder)
      assert {:ok, _} = Decoder.new("sjis")
      assert {:ok, _} = Decoder.new("UTF-8")
      assert {:error, :unknown_encoding} = Decoder.new("not-an-encoding")
    end

    test "stores options once for manual chunk loops" do
      assert {:ok, decoder} =
               Decoder.new("utf-8", dirty_threshold: 0, max_input_size: 4)

      assert {:error, :input_too_large} = Decoder.decode_chunk(decoder, "hello", true)

      assert {:ok, "hello", false} =
               Decoder.decode_chunk(decoder, "hello", true, max_input_size: 5)

      assert_raise ArgumentError, ~r/unknown keys/, fn ->
        Decoder.new("utf-8", dirty_treshold: 0)
      end
    end

    test "supports bom modes and encoding/1 inspection" do
      {:ok, sniff_dec} = Decoder.new("windows-1252", bom: :sniff)
      assert {:ok, "windows-1252"} = Decoder.encoding(sniff_dec)

      assert {:ok, "H", false} =
               Decoder.decode_chunk(sniff_dec, <<0xFF, 0xFE, 0x48, 0x00>>, true)

      assert {:ok, "UTF-16LE"} = Decoder.encoding(sniff_dec)

      {:ok, strip_dec} = Decoder.new("windows-1252", bom: :strip)

      assert {:ok, "ÿþH\0", false} =
               Decoder.decode_chunk(strip_dec, <<0xFF, 0xFE, 0x48, 0x00>>, true)

      assert {:ok, "windows-1252"} = Decoder.encoding(strip_dec)

      {:ok, preserve_dec} = Decoder.new("utf-8", bom: :preserve)

      assert {:ok, "\uFEFFhi", false} =
               Decoder.decode_chunk(preserve_dec, <<0xEF, 0xBB, 0xBF, "hi">>, true)
    end
  end

  describe "new!/1 and new!/2" do
    test "creates decoder or raises on unknown encoding" do
      decoder = Decoder.new!("gbk")
      assert {:ok, "GBK"} = Decoder.encoding(decoder)

      assert_raise ArgumentError, ~r/unknown encoding/, fn ->
        Decoder.new!("invalid")
      end
    end
  end

  describe "decode_chunk/3 and decode_chunk/4" do
    test "handles split multibyte characters across chunks" do
      for {enc, chunks, expected} <- [
            {"shift_jis", [<<0x82>>, <<0xA0>>], "あ"},
            {"shift_jis", [<<0x41, 0x82>>, <<0xA0>>], "Aあ"},
            {"gbk", [<<0xD6>>, <<0xD0>>], "中"},
            {"big5", [<<0xA4>>, <<0xA4>>], "中"},
            {"euc-jp", [<<0xA4>>, <<0xA2>>], "あ"},
            {"utf-16le", [<<0x41>>, <<0x00>>], "A"}
          ] do
        {:ok, decoder} = Decoder.new(enc)
        [first, last] = chunks
        {:ok, out1, false} = Decoder.decode_chunk(decoder, first, false)
        {:ok, out2, false} = Decoder.decode_chunk(decoder, last, true)
        assert out1 <> out2 == expected
      end
    end

    test "returns {:error, :decoder_finished} instead of panicking after is_last: true" do
      {:ok, decoder} = Decoder.new("utf-8")
      assert {:ok, "hi", false} = Decoder.decode_chunk(decoder, "hi", true)
      assert {:error, :decoder_finished} = Decoder.decode_chunk(decoder, "more", true)
      assert {:error, :decoder_finished} = Decoder.decode_chunk(decoder, "still", false)
    end

    test "strict mode rejects malformed sequences and incomplete trailing bytes" do
      # 0x80 cannot start a BOM or valid UTF-8 sequence, so it fails immediately
      {:ok, dec1} = Decoder.new("utf-8", on_error: :error)
      assert {:error, :malformed_input} = Decoder.decode_chunk(dec1, <<0x80>>, false)
      assert {:error, :decoder_finished} = Decoder.decode_chunk(dec1, "ok", true)

      # Under bom: :sniff, 0xFF alone is buffered as a possible UTF-16LE BOM until EOF or next byte
      {:ok, dec_bom} = Decoder.new("utf-8", bom: :sniff, on_error: :error)
      assert {:ok, "", false} = Decoder.decode_chunk(dec_bom, <<0xFF>>, false)
      assert {:error, :malformed_input} = Decoder.decode_chunk(dec_bom, <<>>, true)

      # Under bom: :preserve, 0xFF fails immediately without waiting for a BOM byte
      {:ok, dec_preserve} = Decoder.new("utf-8", bom: :preserve, on_error: :error)
      assert {:error, :malformed_input} = Decoder.decode_chunk(dec_preserve, <<0xFF>>, false)

      {:ok, dec2} = Decoder.new("shift_jis", on_error: :error)
      assert {:ok, "", false} = Decoder.decode_chunk(dec2, <<0x82>>, false)
      assert {:error, :malformed_input} = Decoder.decode_chunk(dec2, <<>>, true)
    end

    test "reports errors for invalid bytes in replace mode" do
      {:ok, decoder} = Decoder.new("utf-8")
      assert {:ok, "\uFFFD", true} = Decoder.decode_chunk(decoder, <<0xFF>>, true)
    end
  end

  describe "stream/2 and stream/3 (non-raising)" do
    test "emits {:ok, chunk} tuples and handles split multibyte characters" do
      chunks = [<<0x41, 0x42, 0x82>>, <<0xA0, 0x82>>, <<0xA2, 0x43, 0x44>>]

      results = chunks |> Decoder.stream("shift_jis") |> Enum.to_list()
      assert Enum.all?(results, &match?({:ok, _}, &1))
      assert Enum.map_join(results, fn {:ok, s} -> s end) == "ABあいCD"
    end

    test "emits {:error, :unknown_encoding} without pulling from the upstream stream" do
      never_pulled = Stream.map([1], fn _ -> raise "upstream should not be enumerated" end)

      assert [{:error, :unknown_encoding}] =
               never_pulled |> Decoder.stream("not-an-encoding") |> Enum.to_list()

      assert [{:error, :unknown_encoding}] =
               [] |> Decoder.stream("not-an-encoding") |> Enum.to_list()
    end

    test "emits {:error, reason} and halts on oversized chunk or strict malformed input" do
      assert [{:ok, "ok"}, {:error, :input_too_large}] =
               ["ok", "too big", "never"]
               |> Decoder.stream("utf-8", max_input_size: 4)
               |> Enum.to_list()

      assert [{:ok, "ok"}, {:error, :malformed_input}] =
               ["ok", <<0xFF>>, "never"]
               |> Decoder.stream("utf-8", on_error: :error)
               |> Enum.to_list()

      # Incomplete trailing multibyte sequence fails during flush in strict mode
      assert [{:ok, "あ"}, {:error, :malformed_input}] =
               [<<0x82, 0xA0, 0x82>>]
               |> Decoder.stream("shift_jis", on_error: :error)
               |> Enum.to_list()
    end

    test "emits extra flush element for incomplete trailing sequence in replace mode" do
      assert [{:ok, "あ"}, {:ok, "\uFFFD"}] =
               [<<0x82, 0xA0, 0x82>>] |> Decoder.stream("shift_jis") |> Enum.to_list()

      assert [{:ok, "あ"}] =
               [<<0x82, 0xA0>>] |> Decoder.stream("shift_jis") |> Enum.to_list()
    end

    test "validates option keys immediately" do
      assert_raise ArgumentError, ~r/unknown keys/, fn ->
        Decoder.stream(["hi"], "utf-8", bogus: true)
      end
    end
  end

  describe "stream!/2 and stream!/3 (raising)" do
    test "emits plain strings and handles split characters" do
      assert "あいう" ==
               [<<0x82, 0xA0>>, <<0x82, 0xA2>>, <<0x82, 0xA4>>]
               |> Decoder.stream!("shift_jis")
               |> Enum.join()

      assert "あ" == [<<0x82>>, <<0xA0>>] |> Decoder.stream!("shift_jis") |> Enum.join()
    end

    test "raises on unknown encoding, oversized chunk, or strict malformed input" do
      assert_raise ArgumentError, ~r/unknown encoding/, fn ->
        ["hi"] |> Decoder.stream!("invalid") |> Enum.to_list()
      end

      assert_raise RuntimeError, ~r/input_too_large/, fn ->
        ["hello"] |> Decoder.stream!("utf-8", max_input_size: 4) |> Enum.to_list()
      end

      assert_raise RuntimeError, ~r/malformed_input/, fn ->
        [<<0xFF>>] |> Decoder.stream!("utf-8", on_error: :error) |> Enum.to_list()
      end
    end
  end

  describe "stream_with_errors/2,3 and stream_with_errors!/2,3" do
    test "non-raising stream_with_errors emits {:ok, chunk, had_errors} or {:error, reason}" do
      assert [{:ok, "あ", false}, {:ok, "\uFFFD", true}] =
               [<<0x82, 0xA0, 0x82>>]
               |> Decoder.stream_with_errors("shift_jis")
               |> Enum.to_list()

      assert [{:error, :unknown_encoding}] =
               ["hi"] |> Decoder.stream_with_errors("invalid") |> Enum.to_list()
    end

    test "raising stream_with_errors! emits {chunk, had_errors} tuples" do
      assert [{"hello", false}, {"\uFFFD", true}, {"world", false}] =
               [<<"hello">>, <<0xFF>>, <<"world">>]
               |> Decoder.stream_with_errors!("utf-8")
               |> Enum.to_list()

      assert [{"あ", false}, {"\uFFFD", true}] =
               [<<0x82, 0xA0, 0x82>>]
               |> Decoder.stream_with_errors!("shift_jis")
               |> Enum.to_list()
    end
  end
end
