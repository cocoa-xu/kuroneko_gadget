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
      compilers: [:elixir_make | Mix.compilers()],
      make_targets: ["all"],
      make_clean: ["clean"],
      make_error_message: make_error_message(),
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      docs: docs(),
      dialyzer: [flags: [:missing_return, :extra_return, :unmatched_returns, :error_handling]]
    ]
  end

  def application do
    [mod: {Kuroneko.Gadget.Application, []}, extra_applications: [:logger, :crypto]]
  end

  def cli do
    [
      preferred_envs: [
        docs: :docs,
        "hex.build": :docs,
        "hex.publish": :docs,
        dialyzer: :test,
        credo: :test
      ]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp description do
    "The USB side of a KVM on Linux, with a module for each USB gadget function driver: " <>
      "HID keyboards, mice and pens, mass storage drives and discs, a USB sound card, " <>
      "network, serial ports, and functions written in Elixir on FunctionFS."
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "https://hexdocs.pm/kuroneko_gadget/changelog.html"
      },
      files: [
        "lib",
        "c_src",
        "Makefile",
        "mix.exs",
        "README.md",
        "CHANGELOG.md",
        "LICENSE",
        ".formatter.exs"
      ]
    ]
  end

  defp deps do
    [
      {:elixir_make, "~> 0.9", runtime: false},
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
        Functions: [
          Kuroneko.Gadget.Function,
          Kuroneko.Gadget.HID,
          Kuroneko.Gadget.MassStorage,
          Kuroneko.Gadget.NCM,
          Kuroneko.Gadget.UAC2,
          Kuroneko.Gadget.ACM,
          Kuroneko.Gadget.FunctionFS
        ],
        "Keyboard and mouse": [
          Kuroneko.Gadget.Input,
          Kuroneko.Gadget.HID.Keymap,
          Kuroneko.Gadget.HID.Report
        ]
      ]
    ]
  end

  defp make_error_message do
    """
    Could not build kuroneko_ffs, the program of Kuroneko.Gadget.FunctionFS.
    It needs a Linux C toolchain; Nerves provides one for its targets.
    """
  end
end
