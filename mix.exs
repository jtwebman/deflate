defmodule Deflate.MixProject do
  use Mix.Project

  @version "1.0.0"
  @source_url "https://github.com/jtwebman/deflate"

  def project do
    [
      app: :deflate,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package(),
      docs: docs(),
      name: "Deflate",
      source_url: @source_url,
      aliases: aliases(),
      dialyzer: [plt_add_apps: [:mix]]
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:benchee, "~> 1.3", only: :dev}
    ]
  end

  defp description do
    """
    Pure Elixir DEFLATE (RFC 1951) and zlib (RFC 1950) decompression with exact byte tracking.

    Features: chunked input for network streams, streaming output, byte consumption tracking.
    No NIFs, works anywhere BEAM runs. Essential for git pack files, PNG, PDF, ZIP parsing.
    """
  end

  defp package do
    [
      name: "deflate",
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url
      },
      maintainers: ["JT Turner"],
      files: ~w(lib .formatter.exs mix.exs README.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "Deflate",
      source_ref: "v#{@version}",
      source_url: @source_url
    ]
  end

  defp aliases do
    [
      lint: ["format --check-formatted", "credo --strict"],
      ci: ["lint", "test", "dialyzer"]
    ]
  end
end
