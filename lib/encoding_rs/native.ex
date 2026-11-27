defmodule EncodingRs.Native do
  @moduledoc false
  # Low-level NIF bindings. Use EncodingRs, EncodingRs.Decoder, EncodingRs.Encoder,
  # and EncodingRs.Detector for the public API.

  version = Mix.Project.config()[:version]

  use RustlerPrecompiled,
    otp_app: :encoding_rs,
    crate: "encoding_rs_nif",
    path: "native/encoding_rs",
    base_url: "https://github.com/jeffhuen/encoding_rs/releases/download/v#{version}",
    force_build: System.get_env("ENCODING_RS_BUILD") in ["1", "true"],
    mode: if(Mix.env() == :prod, do: :release, else: :debug),
    nif_versions: ["2.15", "2.16", "2.17", "2.18"],
    targets: RustlerPrecompiled.Config.default_targets(),
    version: version

  # Decode functions (normal and dirty scheduler versions)
  def decode_normal(_binary, _encoding, _bom_mode, _error_mode),
    do: :erlang.nif_error(:nif_not_loaded)

  def decode_dirty(_binary, _encoding, _bom_mode, _error_mode),
    do: :erlang.nif_error(:nif_not_loaded)

  def decode_with_details_normal(_binary, _encoding, _bom_mode, _error_mode),
    do: :erlang.nif_error(:nif_not_loaded)

  def decode_with_details_dirty(_binary, _encoding, _bom_mode, _error_mode),
    do: :erlang.nif_error(:nif_not_loaded)

  # Encode functions (normal and dirty scheduler versions)
  def encode_normal(_binary, _encoding, _error_mode), do: :erlang.nif_error(:nif_not_loaded)
  def encode_dirty(_binary, _encoding, _error_mode), do: :erlang.nif_error(:nif_not_loaded)

  def encode_with_details_normal(_binary, _encoding, _error_mode),
    do: :erlang.nif_error(:nif_not_loaded)

  def encode_with_details_dirty(_binary, _encoding, _error_mode),
    do: :erlang.nif_error(:nif_not_loaded)

  # Inspection utilities
  def encoding_exists(_encoding), do: :erlang.nif_error(:nif_not_loaded)
  def can_encode(_encoding), do: :erlang.nif_error(:nif_not_loaded)
  def canonical_name(_encoding), do: :erlang.nif_error(:nif_not_loaded)
  def output_encoding(_encoding), do: :erlang.nif_error(:nif_not_loaded)
  def list_encodings, do: :erlang.nif_error(:nif_not_loaded)
  def list_output_encodings, do: :erlang.nif_error(:nif_not_loaded)

  # BOM and heuristic detection
  def detect_bom(_data), do: :erlang.nif_error(:nif_not_loaded)

  def detect_normal(_data, _tld, _allow_utf8, _allow_iso_2022_jp, _check_bom),
    do: :erlang.nif_error(:nif_not_loaded)

  def detect_dirty(_data, _tld, _allow_utf8, _allow_iso_2022_jp, _check_bom),
    do: :erlang.nif_error(:nif_not_loaded)

  def detector_new(_allow_iso_2022_jp, _check_bom), do: :erlang.nif_error(:nif_not_loaded)
  def detector_feed(_detector, _chunk, _is_last), do: :erlang.nif_error(:nif_not_loaded)
  def detector_feed_dirty(_detector, _chunk, _is_last), do: :erlang.nif_error(:nif_not_loaded)
  def detector_guess(_detector, _tld, _allow_utf8), do: :erlang.nif_error(:nif_not_loaded)

  # Streaming decoder functions
  def decoder_new(_encoding, _bom_mode, _error_mode), do: :erlang.nif_error(:nif_not_loaded)
  def decoder_encoding(_decoder), do: :erlang.nif_error(:nif_not_loaded)
  def decoder_decode_chunk(_decoder, _chunk, _is_last), do: :erlang.nif_error(:nif_not_loaded)

  def decoder_decode_chunk_dirty(_decoder, _chunk, _is_last),
    do: :erlang.nif_error(:nif_not_loaded)

  # Streaming encoder functions
  def encoder_new(_encoding, _error_mode), do: :erlang.nif_error(:nif_not_loaded)
  def encoder_encode_chunk(_encoder, _chunk, _is_last), do: :erlang.nif_error(:nif_not_loaded)

  def encoder_encode_chunk_dirty(_encoder, _chunk, _is_last),
    do: :erlang.nif_error(:nif_not_loaded)

  # Batch operations
  def decode_batch_normal(_items, _bom_mode, _error_mode),
    do: :erlang.nif_error(:nif_not_loaded)

  def decode_batch(_items, _bom_mode, _error_mode), do: :erlang.nif_error(:nif_not_loaded)

  def decode_batch_with_details_normal(_items, _bom_mode, _error_mode),
    do: :erlang.nif_error(:nif_not_loaded)

  def decode_batch_with_details(_items, _bom_mode, _error_mode),
    do: :erlang.nif_error(:nif_not_loaded)

  def encode_batch_normal(_items, _error_mode), do: :erlang.nif_error(:nif_not_loaded)
  def encode_batch(_items, _error_mode), do: :erlang.nif_error(:nif_not_loaded)

  def encode_batch_with_details_normal(_items, _error_mode),
    do: :erlang.nif_error(:nif_not_loaded)

  def encode_batch_with_details(_items, _error_mode), do: :erlang.nif_error(:nif_not_loaded)
end
