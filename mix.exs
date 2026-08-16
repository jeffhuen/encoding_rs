defmodule EncodingRs.MixProject do
  use Mix.Project

  @version "0.3.0"

  def project do
    [
      app: :encoding_rs,
      version: @version,
      elixir: "~> 1.15",
      deps: deps(),
      description:
        "High-performance WHATWG text conversion for Elixir. Decodes all 40 encodings with 200+ aliases and encodes their output encodings. Includes streaming and batch APIs. Powered by Mozilla's encoding_rs.",
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
      {:rustler_precompiled, "~> 0.9"},
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
        Streaming: [EncodingRs.Decoder]
      ]
    ]
  end
end
