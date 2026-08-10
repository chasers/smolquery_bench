#!/usr/bin/env elixir
Code.require_file("bench.exs", __DIR__)

arms =
  case System.argv() do
    [] -> ["smolquery", "clickhouse"]
    argv -> argv
  end

Enum.each(arms, &Bench.stop_arm/1)
