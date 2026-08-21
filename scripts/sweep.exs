#!/usr/bin/env elixir
Code.require_file("bench.exs", __DIR__)

arm =
  case System.argv() do
    [arm] when arm in ["smolquery", "clickhouse", "remote"] -> arm
    _ -> Bench.fatal!("usage: sweep.exs <smolquery|clickhouse|remote>")
  end

setup =
  case arm do
    "smolquery" -> &Bench.Smolquery.setup/0
    "clickhouse" -> &Bench.Clickhouse.setup/0
    "remote" -> &Bench.Remote.setup/0
  end

vus_list = "VUS_LIST" |> Bench.env("1 4 8 16 32 64") |> String.split()

Enum.each(vus_list, fn vus ->
  setup.()
  Bench.RunArm.run(arm, %{vus: vus})
end)

arm == "remote" || Bench.stop_arm(arm)
Bench.Report.main(Bench.results_dir(arm))
