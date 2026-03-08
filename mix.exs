defmodule FauxMQ.MixProject do
  use Mix.Project

  def project do
    [
      app: :faux_mq,
      version: "0.1.0",
      elixir: "~> 1.13",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: "Dummy AMQP 0-9-1 broker for integration testing with powerful mocking API.",
      package: package(),
      source_url: "https://github.com/aszymanskiit/faux-mq",
      docs: docs(),
      dialyzer: dialyzer(),
      elixirc_paths: elixirc_paths(Mix.env())
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {FauxMQ.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:amqp, "~> 3.3", only: :test},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{
        "GitHub" => "https://github.com/aszymanskiit/faux-mq"
      }
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md"],
      source_url: "https://github.com/aszymanskiit/faux-mq",
      source_ref: "main"
    ]
  end

  defp dialyzer do
    [
      plt_add_apps: [:mix, :amqp],
      flags: [:error_handling, :unknown]
    ]
  end
end
