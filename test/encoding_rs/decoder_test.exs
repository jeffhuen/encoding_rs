defmodule EncodingRs.DecoderTest do
  use ExUnit.Case, async: true
  doctest EncodingRs.Decoder

  alias EncodingRs.Decoder

  describe "new/1" do
    test "creates decoder for valid encoding" do
      assert {:ok, decoder} = Decoder.new("shift_jis")
      assert is_reference(decoder)
    end

    test "creates decoder for encoding aliases" do
      assert {:ok, _} = Decoder.new("sjis")
      assert {:ok, _} = Decoder.new("Shift_JIS")
      assert {:ok, _} = Decoder.new("utf-8")
      assert {:ok, _} = Decoder.new("UTF-8")
    end

    test "returns error for unknown encoding" do
      assert {:error, :unknown_encoding} = Decoder.new("not-an-encoding")
    end
  end

  describe "new!/1" do
    test "creates decoder for valid encoding" do
      decoder = Decoder.new!("gbk")
      assert is_reference(decoder)
    end

    test "raises for unknown encoding" do
      assert_raise ArgumentError, ~r/unknown encoding/, fn ->
        Decoder.new!("invalid")
      end
    end
  end

  describe "decode_chunk/3" do
    test "decodes complete single-byte chunk" do
      {:ok, decoder} = Decoder.new("utf-8")
      assert {:ok, "hello", false} = Decoder.decode_chunk(decoder, "hello", true)
    end

    test "decodes complete multibyte chunk" do
      {:ok, decoder} = Decoder.new("shift_jis")
      # "あ" in Shift_JIS is <<0x82, 0xA0>>
      assert {:ok, "あ", false} = Decoder.decode_chunk(decoder, <<0x82, 0xA0>>, true)
    end

    test "handles split multibyte character - the critical fix" do
      {:ok, decoder} = Decoder.new("shift_jis")

      # "あ" (<<0x82, 0xA0>>) split across two chunks
      # First chunk: incomplete character, should buffer it
      {:ok, output1, false} = Decoder.decode_chunk(decoder, <<0x82>>, false)
      # Second chunk: completes the character
      {:ok, output2, false} = Decoder.decode_chunk(decoder, <<0xA0>>, true)

      assert output1 <> output2 == "あ"
    end

    test "handles multiple split characters" do
      {:ok, decoder} = Decoder.new("shift_jis")

      # "あい" = <<0x82, 0xA0, 0x82, 0xA2>> in Shift_JIS
      # Split: <<0x82>> | <<0xA0, 0x82>> | <<0xA2>>
      {:ok, out1, false} = Decoder.decode_chunk(decoder, <<0x82>>, false)
      {:ok, out2, false} = Decoder.decode_chunk(decoder, <<0xA0, 0x82>>, false)
      {:ok, out3, false} = Decoder.decode_chunk(decoder, <<0xA2>>, true)

      assert out1 <> out2 <> out3 == "あい"
    end

    test "handles mixed ASCII and multibyte split" do
      {:ok, decoder} = Decoder.new("shift_jis")

      # "Aあ" = <<0x41, 0x82, 0xA0>> in Shift_JIS
      # Split after ASCII: <<0x41, 0x82>> | <<0xA0>>
      {:ok, out1, false} = Decoder.decode_chunk(decoder, <<0x41, 0x82>>, false)
      {:ok, out2, false} = Decoder.decode_chunk(decoder, <<0xA0>>, true)

      assert out1 <> out2 == "Aあ"
    end

    test "reports errors for invalid bytes" do
      {:ok, decoder} = Decoder.new("utf-8")
      # 0xFF is invalid UTF-8
      {:ok, output, had_errors} = Decoder.decode_chunk(decoder, <<0xFF>>, true)
      assert had_errors == true
      assert output == "�"
    end

    test "flushes incomplete sequence on is_last=true" do
      {:ok, decoder} = Decoder.new("shift_jis")

      # Incomplete character at end with is_last=true should produce replacement
      {:ok, output, had_errors} = Decoder.decode_chunk(decoder, <<0x82>>, true)
      assert had_errors == true
      assert output == "�"
    end

    test "handles empty chunk" do
      {:ok, decoder} = Decoder.new("utf-8")
      assert {:ok, "", false} = Decoder.decode_chunk(decoder, <<>>, false)
      assert {:ok, "", false} = Decoder.decode_chunk(decoder, <<>>, true)
    end

    test "GBK encoding with split character" do
      {:ok, decoder} = Decoder.new("gbk")

      # "中" in GBK is <<0xD6, 0xD0>>
      {:ok, out1, false} = Decoder.decode_chunk(decoder, <<0xD6>>, false)
      {:ok, out2, false} = Decoder.decode_chunk(decoder, <<0xD0>>, true)

      assert out1 <> out2 == "中"
    end

    test "Big5 encoding with split character" do
      {:ok, decoder} = Decoder.new("big5")

      # "中" in Big5 is <<0xA4, 0xA4>>
      {:ok, out1, false} = Decoder.decode_chunk(decoder, <<0xA4>>, false)
      {:ok, out2, false} = Decoder.decode_chunk(decoder, <<0xA4>>, true)

      assert out1 <> out2 == "中"
    end

    test "EUC-JP encoding with split character" do
      {:ok, decoder} = Decoder.new("euc-jp")

      # "あ" in EUC-JP is <<0xA4, 0xA2>>
      {:ok, out1, false} = Decoder.decode_chunk(decoder, <<0xA4>>, false)
      {:ok, out2, false} = Decoder.decode_chunk(decoder, <<0xA2>>, true)

      assert out1 <> out2 == "あ"
    end

    @tag :slow
    test "rejects oversized chunk" do
      {:ok, decoder} = Decoder.new("utf-8")
      big = :binary.copy(<<0>>, EncodingRs.max_input_size() + 1)
      assert {:error, :input_too_large} = Decoder.decode_chunk(decoder, big, true)
    end
  end

  describe "decode_chunk!/3" do
    test "returns tuple without :ok" do
      decoder = Decoder.new!("utf-8")
      assert {"hello", false} = Decoder.decode_chunk!(decoder, "hello", true)
    end
  end

  describe "stream/2" do
    test "decodes stream of chunks" do
      # "あいう" in Shift_JIS = <<0x82, 0xA0, 0x82, 0xA2, 0x82, 0xA4>>
      chunks = [<<0x82, 0xA0>>, <<0x82, 0xA2>>, <<0x82, 0xA4>>]

      result =
        chunks
        |> Decoder.stream("shift_jis")
        |> Enum.join()

      assert result == "あいう"
    end

    test "handles split characters in stream" do
      # "あ" split across chunks
      chunks = [<<0x82>>, <<0xA0>>]

      result =
        chunks
        |> Decoder.stream("shift_jis")
        |> Enum.join()

      assert result == "あ"
    end

    test "handles complex split pattern" do
      # "ABあいCD" in Shift_JIS
      # Split in awkward places
      chunks = [
        <<0x41, 0x42, 0x82>>,
        <<0xA0, 0x82>>,
        <<0xA2, 0x43, 0x44>>
      ]

      result =
        chunks
        |> Decoder.stream("shift_jis")
        |> Enum.join()

      assert result == "ABあいCD"
    end

    test "handles empty chunks in stream" do
      chunks = [<<>>, <<0x82, 0xA0>>, <<>>, <<0x82, 0xA2>>, <<>>]

      result =
        chunks
        |> Decoder.stream("shift_jis")
        |> Enum.join()

      assert result == "あい"
    end

    test "works with single-byte encodings" do
      # ISO-8859-1 "café"
      chunks = [<<99, 97>>, <<102, 233>>]

      result =
        chunks
        |> Decoder.stream("iso-8859-1")
        |> Enum.join()

      assert result == "café"
    end

    test "handles UTF-16LE with split surrogate" do
      # UTF-16LE "A" is <<0x41, 0x00>>
      # Split the 2-byte sequence
      chunks = [<<0x41>>, <<0x00>>]

      result =
        chunks
        |> Decoder.stream("utf-16le")
        |> Enum.join()

      assert result == "A"
    end

    test "emits extra flush element for incomplete trailing sequence" do
      # Input ends with incomplete Shift_JIS lead byte 0x82 (no trailing byte)
      # The stream should emit an extra element with the replacement character
      chunks = [<<0x82, 0xA0, 0x82>>]

      elements =
        chunks
        |> Decoder.stream("shift_jis")
        |> Enum.to_list()

      # One element from the chunk, one from the flush
      assert length(elements) == 2
      assert Enum.at(elements, 0) == "あ"
      assert Enum.at(elements, 1) == "�"
    end

    test "no extra flush element when stream ends cleanly" do
      chunks = [<<0x82, 0xA0>>]

      elements =
        chunks
        |> Decoder.stream("shift_jis")
        |> Enum.to_list()

      # Only one element, no flush needed
      assert length(elements) == 1
      assert Enum.at(elements, 0) == "あ"
    end
  end

  describe "stream_with_errors/2" do
    test "includes error information" do
      # Mix of valid and invalid UTF-8
      chunks = [<<"hello">>, <<0xFF>>, <<"world">>]

      results =
        chunks
        |> Decoder.stream_with_errors("utf-8")
        |> Enum.to_list()

      assert [{"hello", false}, {"�", true}, {"world", false} | _] = results
    end

    test "tracks errors across split characters" do
      chunks = [<<0x82>>, <<0xA0>>]

      results =
        chunks
        |> Decoder.stream_with_errors("shift_jis")
        |> Enum.to_list()

      # First chunk outputs nothing (buffered), second outputs the character
      # Neither should have errors since it's valid split
      outputs = Enum.map(results, fn {out, _} -> out end)
      errors = Enum.map(results, fn {_, err} -> err end)

      assert Enum.join(outputs) == "あ"
      assert Enum.all?(errors, &(&1 == false))
    end

    test "flush element reports had_errors for incomplete trailing sequence" do
      # Input ends with incomplete Shift_JIS lead byte
      chunks = [<<0x82, 0xA0, 0x82>>]

      results =
        chunks
        |> Decoder.stream_with_errors("shift_jis")
        |> Enum.to_list()

      # Two elements: chunk result + flush result
      assert length(results) == 2
      assert {"あ", false} = Enum.at(results, 0)
      assert {"�", true} = Enum.at(results, 1)
    end
  end

  describe "comparison with one-shot decode (demonstrating the bug fix)" do
    test "one-shot decode corrupts split multibyte characters" do
      # This demonstrates the bug that streaming fixes
      chunks = [<<0x82>>, <<0xA0>>]

      # One-shot decode of each chunk independently (the bug)
      one_shot_result = Enum.map_join(chunks, &EncodingRs.decode!(&1, "shift_jis"))

      # Streaming decode (the fix)
      streaming_result =
        chunks
        |> Decoder.stream("shift_jis")
        |> Enum.join()

      # One-shot produces replacement characters (corruption)
      assert one_shot_result == "��"

      # Streaming produces the correct character
      assert streaming_result == "あ"
    end

    test "one-shot is fine for complete input" do
      # When input is complete, both approaches work
      complete_input = <<0x82, 0xA0>>

      one_shot = EncodingRs.decode!(complete_input, "shift_jis")
      streaming = [complete_input] |> Decoder.stream("shift_jis") |> Enum.join()

      assert one_shot == "あ"
      assert streaming == "あ"
      assert one_shot == streaming
    end
  end
end
