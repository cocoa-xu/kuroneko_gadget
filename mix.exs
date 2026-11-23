defmodule Kuroneko.Gadget.MixProject do
  use Mix.Project

  @version "0.3.0"
  @source_url "https://github.com/cocoa-xu/kuroneko_gadget"

  def project do
    [
      app: :kuroneko_gadget,
      version: @version,
      elixir: "~> 1.15",
      description: description(),
      package: package(),
      source_url: @source_url,
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      docs: docs(),
      dialyzer: [flags: [:missing_return, :extra_return, :unmatched_returns, :error_handling]]
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  def cli do
    [preferred_envs: [docs: :docs, "hex.build": :docs, dialyzer: :test, credo: :test]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp description do
    "The USB side of a KVM on Linux: keyboard, mouse, pen and touch screen, mass storage, " <>
      "a two-way USB sound card and the USB network's addresses, on a configfs USB gadget."
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @source_url},
      files: ["lib", "mix.exs", "README.md", "CHANGELOG.md", "LICENSE", ".formatter.exs"]
    ]
  end

  defp deps do
    [
      {:ex_doc, "~> 0.34", only: :docs, runtime: false},
      {:dialyxir, "~> 1.4", only: :test, runtime: false},
      {:credo, "~> 1.7", only: :test, runtime: false}
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md", "CHANGELOG.md", "LICENSE"],
      source_ref: "v#{@version}",
      groups_for_modules: [
        "Keyboard and mouse": [
          Kuroneko.Gadget.HID,
          Kuroneko.Gadget.HID.Keymap,
          Kuroneko.Gadget.HID.Report
        ],
        "Mass storage": [Kuroneko.Gadget.Storage]
      ]
    ]
  end
end
