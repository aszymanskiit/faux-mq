%{
  configs: [
    %{
      name: "default",
      files: %{
        included: ["lib/", "test/", "config/", "mix.exs"],
        excluded: []
      },
      checks: [
        {Credo.Check.Readability.ModuleDoc, false},
        {Credo.Check.Readability.PreferImplicitTry, false},
        {Credo.Check.Refactor.CyclomaticComplexity, [max_complexity: 22]},
        {Credo.Check.Refactor.Nesting, [max_nesting: 3]}
      ]
    }
  ]
}

