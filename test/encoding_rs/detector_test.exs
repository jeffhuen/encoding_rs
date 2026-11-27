defmodule EncodingRs.DetectorTest do
  use ExUnit.Case, async: true
  doctest EncodingRs.Detector

  alias EncodingRs.Detector

  describe "manual feed/3 and guess/2" do
    test "detects Shift_JIS incrementally and allows multiple guess calls with different options" do
      {:ok, sjis} = EncodingRs.encode("日本語のテキストをストリームで検出します。", "shift_jis")
      half = div(byte_size(sjis), 2)
      <<chunk1::binary-size(^half), chunk2::binary>> = sjis

      detector = Detector.new()
      assert {:ok, true} = Detector.feed(detector, chunk1, false)
      assert {:ok, true} = Detector.feed(detector, chunk2, true)
      assert {:ok, "Shift_JIS"} = Detector.guess(detector, tld: "jp")
      assert "Shift_JIS" = Detector.guess!(detector, tld: "jp", allow_utf8: false)
    end

    test "detects BOM split across 1-byte chunks" do
      detector = Detector.new()
      assert {:ok, true} = Detector.feed(detector, <<0xEF>>, false)
      assert {:ok, true} = Detector.feed(detector, <<0xBB>>, false)
      assert {:ok, true} = Detector.feed(detector, <<0xBF, "hello">>, true)
      assert {:ok, "UTF-8"} = Detector.guess(detector)

      utf16 = Detector.new()
      assert {:ok, true} = Detector.feed(utf16, <<0xFF>>, false)
      assert {:ok, true} = Detector.feed(utf16, <<0xFE, 0x48, 0x00>>, true)
      assert {:ok, "UTF-16LE"} = Detector.guess(utf16)
    end

    test "returns {:error, :detector_finished} instead of panicking after is_last: true" do
      detector = Detector.new()
      assert {:ok, false} = Detector.feed(detector, "ascii", true)
      assert {:error, :detector_finished} = Detector.feed(detector, "more", true)
      assert {:ok, "UTF-8"} = Detector.guess(detector)
    end

    test "respects allow_iso_2022_jp and bom options" do
      {:ok, iso2022} = EncodingRs.encode("日本語のメール本文テスト", "iso-2022-jp")

      det_allow = Detector.new(allow_iso_2022_jp: true)
      assert {:ok, false} = Detector.feed(det_allow, iso2022, true)
      assert {:ok, "ISO-2022-JP"} = Detector.guess(det_allow)

      det_no_bom = Detector.new(bom: false)
      assert {:ok, true} = Detector.feed(det_no_bom, <<0xEF, 0xBB, 0xBF, "hello">>, true)
      assert {:ok, "windows-1252"} = Detector.guess(det_no_bom, allow_utf8: false)
    end

    test "enforces max_input_size and dirty_threshold" do
      detector = Detector.new(max_input_size: 4, dirty_threshold: 0)
      assert {:error, :input_too_large} = Detector.feed(detector, "hello", true)
      assert {:ok, false} = Detector.feed(detector, "hello", true, max_input_size: 5)
    end
  end

  describe "detect_stream/2 and detect_stream!/2" do
    test "detects encoding from chunked streams" do
      {:ok, gbk} = EncodingRs.encode("这是一个流式字符编码检测测试样本。", "gbk")
      chunks = for <<c::binary-size(5) <- gbk>>, do: c

      assert {:ok, "GBK"} = Detector.detect_stream(chunks, tld: "cn")
      assert "GBK" = Detector.detect_stream!(chunks, tld: "cn")
    end

    test "halts and returns {:error, :input_too_large} when a chunk exceeds max_input_size" do
      assert {:error, :input_too_large} =
               Detector.detect_stream(["ok", "too big", "after"], max_input_size: 4)

      assert_raise RuntimeError, ~r/input_too_large/, fn ->
        Detector.detect_stream!(["too big"], max_input_size: 4)
      end
    end
  end
end
