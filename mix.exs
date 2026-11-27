defmodule EncodingRs.MixProject do
  use Mix.Project

  @version "0.5.0"

  def project do
    [
      app: :encoding_rs,
      version: @version,
      elixir: "~> 1.16",
      deps: deps(),
      description:
        "High-performance WHATWG text conversion and encoding detection for Elixir. Decodes all 40 encodings with 200+ aliases, encodes their output encodings, and detects unknown encodings. Includes streaming, strict mode, and batch APIs. Powered by Mozilla's encoding_rs and chardetng.",
      package: package(),
      docs: docs(),
      dialyzer: [
        plt_local_path: "_build/plts"
      ]
    ]
  end

  defp deps do
    [
      {:rustler_precompiled, "~> 0.10.1"},
      {:rustler, "~> 0.38", optional: true},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false},
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
        "guides/migrating-0.4-to-0.5.md",
        "guides/migrating-0.3-to-0.4.md",
        "guides/migrating-0.2-to-0.3.md",
        "guides/streaming.md",
        "guides/batch.md",
        "guides/comparison.md",
        "CHANGELOG.md"
      ],
      groups_for_extras: [
        Guides: ~r/guides\/.*/
      ],
      groups_for_modules: [
        "Core API": [EncodingRs],
        Streaming: [EncodingRs.Decoder, EncodingRs.Encoder],
        Detection: [EncodingRs.Detector]
      ]
    ]
  end
end
