defmodule EncodingRs.Native do
  @moduledoc false
  # Low-level NIF bindings. Use EncodingRs module for the public API.

  version = Mix.Project.config()[:version]

  use RustlerPrecompiled,
    otp_app: :encoding_rs,
    crate: "encoding_rs_nif",
    path: "native/encoding_rs",
    base_url: "https://github.com/jeffhuen/encoding_rs/releases/download/v#{version}",
    force_build: System.get_env("ENCODING_RS_BUILD") in ["1", "true"],
    mode: if(Mix.env() == :prod, do: :release, else: :debug),
    targets:
      Enum.uniq(["aarch64-unknown-linux-musl" | RustlerPrecompiled.Config.default_targets()]),
    version: version

  # Decode functions (normal and dirty scheduler versions)
  def decode_normal(_binary, _encoding), do: :erlang.nif_error(:nif_not_loaded)
  def decode_dirty(_binary, _encoding), do: :erlang.nif_error(:nif_not_loaded)

  # Encode functions (normal and dirty scheduler versions)
  def encode_normal(_string, _encoding), do: :erlang.nif_error(:nif_not_loaded)
  def encode_dirty(_string, _encoding), do: :erlang.nif_error(:nif_not_loaded)

  # Utility functions
  def dirty_threshold, do: :erlang.nif_error(:nif_not_loaded)
  def encoding_exists(_encoding), do: :erlang.nif_error(:nif_not_loaded)
  def canonical_name(_encoding), do: :erlang.nif_error(:nif_not_loaded)
  def list_encodings, do: :erlang.nif_error(:nif_not_loaded)
  def detect_bom(_data), do: :erlang.nif_error(:nif_not_loaded)

  # Streaming decoder functions
  def decoder_new(_encoding), do: :erlang.nif_error(:nif_not_loaded)
  def decoder_decode_chunk(_decoder, _chunk, _is_last), do: :erlang.nif_error(:nif_not_loaded)

  def decoder_decode_chunk_dirty(_decoder, _chunk, _is_last),
    do: :erlang.nif_error(:nif_not_loaded)
end
