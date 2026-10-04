defmodule DialectoPhoenix.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/dialecto-eu/dialecto-phoenix"

  def project do
    [
      app: :dialecto_phoenix,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: false,
      deps: deps(),
      description:
        "Dev-only in-context editing for Phoenix apps translated with gettext (Dialecto).",
      package: package(),
      source_url: @source_url,
      homepage_url: "https://dialecto.eu/docs"
    ]
  end

  def application do
    [
      mod: {DialectoPhoenix.Application, []},
      extra_applications: [:logger]
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "Documentation" => "https://dialecto.eu/docs"
      },
      files: ~w(lib mix.exs README.md LICENSE .formatter.exs)
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  # JSON comes from Elixir itself (1.18+); Expo reads the catalogs' Plural-Forms.
  defp deps do
    [
      {:gettext, "~> 1.0"},
      {:expo, "~> 1.0"},
      {:plug, "~> 1.15"}
    ]
  end
end
