defmodule EncodingRs.MixProject do
  use Mix.Project

  @version "0.2.0"

  def project do
    [
      app: :encoding_rs,
      version: @version,
      elixir: "~> 1.12",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description:
        "High-performance character encoding/decoding for Elixir. Supports 200+ encodings (Shift_JIS, GBK, Big5, Windows-1252, ISO-8859, UTF-16, and more). Streaming and batch APIs. Powered by Mozilla's encoding_rs.",
      package: package(),
      docs: docs(),
      dialyzer: [
        plt_local_path: "_build/plts"
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:rustler_precompiled, "~> 0.8"},
      {:rustler, "~> 0.37", optional: true},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp package do
    [
      name: "encoding_rs",
      maintainers: ["Jeff Huen"],
      licenses: ["MIT"],
      links: %{
        "GitHub" => "https://github.com/jeffhuen/encoding_rs",
        "Original" => "https://github.com/elixir-ecto/excoding"
      },
      files: [
        "lib",
        "native/encoding_rs/.cargo",
        "native/encoding_rs/src",
        "native/encoding_rs/Cargo*",
        "checksum-*.exs",
        "mix.exs",
        "README.md",
        "CHANGELOG.md",
        "LICENSE",
        "guides",
        "usage-rules.md"
      ]
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: [
        "README.md",
        "guides/streaming.md",
        "guides/batch.md",
        "CHANGELOG.md"
      ],
      groups_for_extras: [
        Guides: ~r/guides\/.*/
      ],
      groups_for_modules: [
        "Core API": [EncodingRs],
        Streaming: [EncodingRs.Decoder]
      ]
    ]
  end
end
