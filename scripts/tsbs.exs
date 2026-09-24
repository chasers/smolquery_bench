#!/usr/bin/env elixir
Code.require_file("bench.exs", __DIR__)

defmodule Bench.Tsbs do
  @moduledoc """
  The Time Series Benchmark Suite (TSBS) `cpu-only` workload against one
  smolquery node's VictoriaMetrics edge, for two or more smolquery builds.

  It runs on the machine that runs the node (the dev box). Every build is a
  git worktree of `SQ_REPO` at a ref, built with `MIX_ENV=prod`, and started
  on its own empty data directory, so two builds load the same generated file
  from the same start.

    * `setup` — install the three TSBS commands at `TSBS_REF` and build
      `tools/tsbsrw` into `$TSBS_DIR/bin`.
    * `build <label> <ref>` — a worktree of `SQ_REPO` at `<ref>` in
      `$TSBS_DIR/sq-<label>`, its deps fetched and compiled for prod.
    * `gen` — the data file and one query file per query type for `SCALE`,
      over `HOURS` hours ending at `TS_END` (default: this hour, UTC). A
      second `gen` at the same scale reuses both.
    * `start <label>` / `stop` — the node, on a fresh data directory.
    * `load <label>` — create `metrics.samples`, load the data file through
      remote write with `tsbsrw`, then wait until the buffer holds no
      unsealed entry, so every read runs against Parquet.
    * `query <label>` — each query type, `QUERY_WORKERS` passes. A pass
      whose first answer is not a 200 stops (TSBS panics on it); its error
      is kept as the result.
    * `verify <label>` — the first `VERIFY_QUERIES` answers of each type,
      printed, for `report` to compare across builds.
    * `run <label>` — `start`, `load`, `verify`, `query`, `stop`.
    * `report` — the markdown tables for `LABELS` at `SCALE`.

  Results land in `results/raw-tsbs/s<scale>-<label>.*`.
  """

  @query_types ~w(
    single-groupby-1-1-1 single-groupby-1-1-12 single-groupby-1-8-1
    single-groupby-5-1-1 single-groupby-5-1-12 single-groupby-5-8-1
    cpu-max-all-1 cpu-max-all-8
    double-groupby-1 double-groupby-5 double-groupby-all
  )

  @tsbs_commands ~w(tsbs_generate_data tsbs_generate_queries tsbs_run_queries_victoriametrics)

  def main(["setup"]), do: setup()
  def main(["build", label, ref]), do: build(label, ref)
  def main(["gen"]), do: gen()
  def main(["start", label]), do: start(label)
  def main(["stop"]), do: stop()
  def main(["load", label]), do: load(label)
  def main(["query", label]), do: query(label)
  def main(["verify", label]), do: verify(label)
  def main(["run", label]), do: run(label)
  def main(["report"]), do: report()

  def main(_),
    do:
      Bench.fatal!(
        "usage: tsbs.exs setup | build <label> <ref> | gen | start <label> | stop | " <>
          "load <label> | query <label> | verify <label> | run <label> | report"
      )

  # ── configuration ──────────────────────────────────────────────────────────

  defp tsbs_dir, do: Bench.env("TSBS_DIR", Path.expand("~/tsbs"))
  defp tsbs_ref, do: Bench.env("TSBS_REF", "8323e59")
  defp sq_repo, do: Bench.env("SQ_REPO", Path.expand("~/smolquery"))
  defp scale, do: Bench.env_int("SCALE", 100)
  defp hours, do: Bench.env_int("HOURS", 24)
  defp seed, do: Bench.env_int("SEED", 123)
  defp interval, do: Bench.env("LOG_INTERVAL", "10s")
  defp queries, do: Bench.env_int("QUERIES", 100)
  defp query_workers, do: Bench.env("QUERY_WORKERS", "1 4") |> String.split()
  defp query_types, do: Bench.env("QUERY_TYPES", Enum.join(@query_types, " ")) |> String.split()
  defp verify_queries, do: Bench.env_int("VERIFY_QUERIES", 3)
  defp load_workers, do: Bench.env_int("LOAD_WORKERS", 8)
  defp load_samples, do: Bench.env_int("LOAD_SAMPLES", 10_000)
  defp drain_timeout_s, do: Bench.env_int("DRAIN_TIMEOUT_S", 1800)
  defp labels, do: Bench.env("LABELS", "before after") |> String.split()
  defp api_key, do: Bench.env("SMOLQUERY_API_KEY", "tsbs-bench")
  defp internal_secret, do: Bench.env("SMOLQUERY_INTERNAL_SECRET", "tsbs-internal")
  defp vm_port, do: Bench.env("VM_PORT", "8428")
  defp api_port, do: Bench.env("API_PORT", "4000")
  defp metrics_port, do: Bench.env("METRICS_PORT", "4003")
  defp hot_port, do: Bench.env("HOT_PORT", "4001")
  defp roles, do: Bench.env("SMOLQUERY_ROLES", "api,ingest,buffer,storage,query,victoriametrics")
  defp results_dir, do: Bench.env("RESULTS", Path.join(Bench.root(), "results/raw-tsbs"))

  defp bin(name), do: Path.join([tsbs_dir(), "bin", name])
  defp checkout(label), do: Path.join(tsbs_dir(), "sq-#{label}")
  defp data_dir(label), do: Path.join(tsbs_dir(), "node-#{label}-s#{scale()}")
  defp run_dir, do: Path.join(tsbs_dir(), "run")
  defp pidfile, do: Path.join(run_dir(), "node.pid")
  defp node_log(label), do: Path.join(run_dir(), "node-#{label}-s#{scale()}.log")
  defp gen_dir, do: Path.join(tsbs_dir(), "gen/s#{scale()}-h#{hours()}")
  defp data_file, do: Path.join(gen_dir(), "cpu-only.lp")
  defp window_file, do: Path.join(gen_dir(), "window.json")
  defp query_file(type), do: Path.join(gen_dir(), "#{type}.q")
  defp result(label, suffix), do: Path.join(results_dir(), "s#{scale()}-#{label}.#{suffix}")

  defp vm_url, do: "http://127.0.0.1:#{vm_port()}"
  defp api_url, do: "http://127.0.0.1:#{api_port()}"
  defp auth, do: [{"authorization", "Bearer #{api_key()}"}]

  @tuning %{
    "SMOLQUERY_MEMORY_LIMIT" => "1GB",
    "SMOLQUERY_WRITE_ENGINE_MEMORY_LIMIT" => "512MB",
    "SMOLQUERY_STORAGE_MEMORY_LIMIT" => "3584MiB",
    "SMOLQUERY_SEAL_ROW_GROUP_SIZE" => "100000",
    "SMOLQUERY_SEAL_MAX_BYTES" => "25165824",
    "SMOLQUERY_MAX_CONCURRENT_SEALS" => "4",
    "SMOLQUERY_MAX_LIVE_CLAIMS" => "8",
    "SMOLQUERY_CLAIM_VALVE_FACTOR" => "1"
  }

  # ── setup and build ────────────────────────────────────────────────────────

  defp setup do
    File.mkdir_p!(Path.join(tsbs_dir(), "bin"))
    env = [{"GOBIN", Path.join(tsbs_dir(), "bin")}]

    for command <- @tsbs_commands do
      IO.puts("== go install #{command}@#{tsbs_ref()}")

      Bench.stream!("go", ["install", "github.com/timescale/tsbs/cmd/#{command}@#{tsbs_ref()}"],
        env: env
      )
    end

    IO.puts("== go build tsbsrw")
    Bench.stream!("go", ["build", "-o", bin("tsbsrw"), "./tools/tsbsrw"], cd: Bench.root())
  end

  defp build(label, ref) do
    dir = checkout(label)
    Bench.sh!("git", ["-C", sq_repo(), "fetch", "--quiet", "origin"])

    if File.dir?(dir) do
      Bench.sh!("git", ["-C", dir, "checkout", "--quiet", "--detach", ref])
    else
      Bench.sh!("git", ["-C", sq_repo(), "worktree", "add", "--quiet", "--detach", dir, ref])
    end

    sha = Bench.sh!("git", ["-C", dir, "rev-parse", "--short", "HEAD"]) |> String.trim()
    IO.puts("== #{label}: #{ref} at #{sha}, building for prod")
    env = [{"MIX_ENV", "prod"}]
    Bench.stream!("mix", ["local.hex", "--force", "--if-missing"], cd: dir, env: env)
    Bench.stream!("mix", ["local.rebar", "--force", "--if-missing"], cd: dir, env: env)
    Bench.stream!("mix", ["deps.get", "--only", "prod"], cd: dir, env: env)
    Bench.stream!("mix", ["compile"], cd: dir, env: env)
    File.write!(Path.join(dir, ".tsbs-ref"), "#{ref} #{sha}\n")
  end

  # ── generation ─────────────────────────────────────────────────────────────

  defp window do
    if File.exists?(window_file()) do
      window_file() |> File.read!() |> JSON.decode!()
    else
      finish =
        case System.get_env("TS_END") do
          nil ->
            %{DateTime.utc_now() | minute: 0, second: 0, microsecond: {0, 0}}

          value ->
            {:ok, at, 0} = DateTime.from_iso8601(value)
            at
        end

      start = DateTime.add(finish, -hours() * 3600, :second)
      %{"start" => DateTime.to_iso8601(start), "end" => DateTime.to_iso8601(finish)}
    end
  end

  defp gen do
    File.mkdir_p!(gen_dir())
    w = window()
    File.write!(window_file(), JSON.encode!(w))
    common = ["--use-case=cpu-only", "--seed=#{seed()}", "--scale=#{scale()}"]
    stamps = ["--timestamp-start=#{w["start"]}", "--timestamp-end=#{w["end"]}"]

    if File.exists?(data_file()) do
      IO.puts("== data: #{data_file()} exists, kept")
    else
      IO.puts("== data: scale #{scale()}, #{w["start"]} to #{w["end"]}, every #{interval()}")

      Bench.sh!(
        bin("tsbs_generate_data"),
        common ++
          stamps ++
          [
            "--log-interval=#{interval()}",
            "--format=victoriametrics",
            "--file=#{data_file()}.tmp"
          ]
      )

      File.rename!(data_file() <> ".tmp", data_file())
    end

    for type <- @query_types, not File.exists?(query_file(type)) do
      IO.puts("== queries: #{type} × #{queries()}")

      Bench.sh!(
        bin("tsbs_generate_queries"),
        common ++
          stamps ++
          [
            "--format=victoriametrics",
            "--query-type=#{type}",
            "--queries=#{queries()}",
            "--file=#{query_file(type)}"
          ]
      )
    end

    %{size: size} = File.stat!(data_file())
    IO.puts("== #{gen_dir()}: data #{div(size, 1_048_576)} MiB")
  end

  # ── the node ───────────────────────────────────────────────────────────────

  defp node_env(label) do
    Map.merge(@tuning, %{
      "MIX_ENV" => "prod",
      "SMOLQUERY_ROLES" => roles(),
      "SMOLQUERY_API_KEY" => api_key(),
      "SMOLQUERY_INTERNAL_SECRET" => internal_secret(),
      "SMOLQUERY_SECRET_KEY_BASE" => String.duplicate("tsbs", 16),
      "SMOLQUERY_DATA_DIR" => data_dir(label),
      "SMOLQUERY_VICTORIAMETRICS_PORT" => vm_port(),
      "SMOLQUERY_METRICS_PORT" => metrics_port(),
      "SMOLQUERY_API_PORT" => api_port(),
      "SMOLQUERY_HOT_SERVER_PORT" => hot_port()
    })
    |> Map.merge(Map.new(passthrough_env()))
    |> Enum.to_list()
  end

  defp passthrough_env do
    System.get_env()
    |> Enum.filter(fn {name, _} ->
      String.starts_with?(name, "SMOLQUERY_") or name == "CATALOG_DATABASE_URL"
    end)
  end

  defp start(label) do
    File.dir?(checkout(label)) ||
      Bench.fatal!("no build for #{label}: run `build #{label} <ref>`")

    stop()
    File.mkdir_p!(run_dir())
    File.rm_rf!(data_dir(label))
    File.mkdir_p!(data_dir(label))

    pid =
      Bench.start_daemon("mix run --no-halt", node_log(label), pidfile(),
        cd: checkout(label),
        env: node_env(label)
      )

    IO.puts("== #{label}: node pid #{pid}, log #{node_log(label)}")
    wait_healthy!(label, 120)
  end

  defp wait_healthy!(label, 0),
    do:
      Bench.fatal!(
        "#{label}: edge never answered /health\n#{Bench.log_tail(node_log(label), 40)}"
      )

  defp wait_healthy!(label, attempts) do
    case Bench.http(:get, "#{vm_url()}/health", [], nil, nil, 2_000) do
      {:ok, 200, _} ->
        IO.puts("== #{label}: edge healthy on #{vm_url()}")

      _ ->
        Bench.alive?(Bench.pidfile_pid(pidfile())) ||
          Bench.fatal!("#{label}: node exited\n#{Bench.log_tail(node_log(label), 40)}")

        Process.sleep(1000)
        wait_healthy!(label, attempts - 1)
    end
  end

  defp stop do
    pid = Bench.pidfile_pid(pidfile())

    if Bench.alive?(pid) do
      System.cmd("pkill", ["-TERM", "-P", pid], stderr_to_stdout: true)
      System.cmd("kill", [pid], stderr_to_stdout: true)
      Bench.wait_for_exit(pid, 60)
      IO.puts("== stopped node #{pid}")
    end

    File.rm(pidfile())
    :ok
  end

  # ── load ───────────────────────────────────────────────────────────────────

  defp load(label) do
    File.exists?(data_file()) || Bench.fatal!("no data at #{data_file()}: run `gen` first")
    File.mkdir_p!(results_dir())
    create_table!()
    IO.puts("== #{label}: loading #{data_file()} with #{load_workers()} writers")

    {output, status} =
      System.cmd(
        bin("tsbsrw"),
        [
          "-file=#{data_file()}",
          "-urls=#{vm_url()}/api/v1/write",
          "-workers=#{load_workers()}",
          "-samples=#{load_samples()}",
          "-progress=#{result(label, "load.progress.json")}",
          "-out=#{result(label, "load.json")}"
        ],
        env: [{"AUTH", "Bearer #{api_key()}"}],
        stderr_to_stdout: true
      )

    File.write!(result(label, "load.log"), output)

    status == 0 ||
      Bench.fatal!(
        "#{label}: tsbsrw exited #{status}\n#{Bench.log_tail(result(label, "load.log"), 20)}"
      )

    summary = result(label, "load.json") |> File.read!() |> JSON.decode!()

    IO.puts(
      "== #{label}: #{summary["samples_accepted"]} samples in #{round(summary["duration_s"])} s, " <>
        "#{round(summary["samples_per_s"])}/s, #{summary["retries_busy"]} busy retries"
    )

    {drain_s, entries} = drain(System.monotonic_time(:millisecond), nil)

    summary
    |> Map.merge(%{
      "drain_s" => drain_s,
      "unsealed_entries_at_end" => entries,
      "build" => build_ref(label)
    })
    |> then(&File.write!(result(label, "load.json"), JSON.encode!(&1)))

    IO.puts("== #{label}: drained in #{drain_s} s, #{entries} unsealed entries left")
  end

  defp create_table! do
    schema = [
      %{"name" => "name", "type" => "STRING", "nullable" => false},
      %{"name" => "series", "type" => "INT64", "nullable" => false},
      %{"name" => "labels", "type" => "MAP(STRING, STRING)"},
      %{"name" => "ts", "type" => "TIMESTAMP", "nullable" => false},
      %{"name" => "value", "type" => "FLOAT64", "nullable" => false}
    ]

    json = "application/json"

    Bench.http(
      :post,
      "#{api_url()}/v1/datasets",
      auth(),
      json,
      JSON.encode!(%{"id" => "metrics"})
    )

    case Bench.http(
           :post,
           "#{api_url()}/v1/datasets/metrics/tables",
           auth(),
           json,
           JSON.encode!(%{"id" => "samples", "schema" => schema})
         ) do
      {:ok, status, _} when status in [200, 201, 409] -> :ok
      other -> Bench.fatal!("create metrics.samples: #{inspect(other)}")
    end

    Bench.http_2xx!(
      :patch,
      "#{api_url()}/v1/datasets/metrics/tables/samples",
      auth(),
      json,
      JSON.encode!(%{"clustering" => ["name", "ts"]}),
      "cluster metrics.samples by name, ts"
    )
  end

  defp drain(started, last) do
    elapsed = div(System.monotonic_time(:millisecond) - started, 1000)
    entries = unsealed_entries()

    cond do
      entries == 0 ->
        {elapsed, 0}

      elapsed >= drain_timeout_s() ->
        {elapsed, entries}

      true ->
        if entries != last, do: IO.puts("   #{elapsed} s: #{entries} unsealed entries")
        Process.sleep(5_000)
        drain(started, entries)
    end
  end

  defp unsealed_entries do
    headers = [{"x-smolquery-internal", internal_secret()}]

    with {:ok, 200, body} <-
           Bench.http(:get, "http://127.0.0.1:#{metrics_port()}/metrics", headers),
         [_, value] <- Regex.run(~r/^smolquery_buffer_unsealed_entries(?:\{\})? (\S+)$/m, body) do
      value |> Float.parse() |> elem(0) |> round()
    else
      _ -> -1
    end
  end

  defp build_ref(label) do
    case File.read(Path.join(checkout(label), ".tsbs-ref")) do
      {:ok, ref} -> String.trim(ref)
      _ -> "unknown"
    end
  end

  # ── queries ────────────────────────────────────────────────────────────────

  defp urls, do: "http://tsbs:#{api_key()}@127.0.0.1:#{vm_port()}"

  defp query(label) do
    File.mkdir_p!(results_dir())

    for type <- query_types(), workers <- query_workers() do
      out = result(label, "#{type}.w#{workers}.json")
      File.rm(out)

      {output, status} =
        System.cmd(
          bin("tsbs_run_queries_victoriametrics"),
          [
            "--file=#{query_file(type)}",
            "--urls=#{urls()}",
            "--workers=#{workers}",
            "--print-interval=0",
            "--results-file=#{out}"
          ],
          stderr_to_stdout: true
        )

      File.write!(result(label, "#{type}.w#{workers}.log"), output)

      if status == 0 and File.exists?(out) do
        %{"q50" => q50, "q99" => q99} = quantiles(out)
        IO.puts("   #{label} #{type} w#{workers}: p50 #{q50} ms, p99 #{q99} ms")
      else
        error = first_error(output)
        File.write!(out, JSON.encode!(%{"error" => error, "exit" => status}))
        IO.puts("   #{label} #{type} w#{workers}: failed, #{error}")
      end
    end
  end

  defp quantiles(path) do
    %{"Totals" => %{"overallQuantiles" => %{"all_queries" => q}}} =
      path |> File.read!() |> JSON.decode!()

    q
  end

  defp first_error(output) do
    output
    |> String.split("\n")
    |> Enum.find("no output", &String.contains?(&1, ["panic:", "statuscode", "error"]))
    |> String.slice(0, 400)
  end

  defp verify(label) do
    File.mkdir_p!(results_dir())

    for type <- query_types() do
      {output, _} =
        System.cmd(
          bin("tsbs_run_queries_victoriametrics"),
          [
            "--file=#{query_file(type)}",
            "--urls=#{urls()}",
            "--workers=1",
            "--max-queries=#{verify_queries()}",
            "--print-interval=0",
            "--print-responses"
          ],
          stderr_to_stdout: true
        )

      File.write!(result(label, "#{type}.verify.txt"), output)
    end

    IO.puts("== #{label}: answers kept for #{length(query_types())} query types")
  end

  defp run(label) do
    start(label)
    load(label)
    verify(label)
    query(label)
    stop()
  end

  # ── report ─────────────────────────────────────────────────────────────────

  defp report do
    labels = labels()
    IO.puts("## TSBS cpu-only, scale #{scale()}\n")
    IO.puts("| build | ref | samples | load s | samples/s | busy retries | drain s |")
    IO.puts("|---|---|---:|---:|---:|---:|---:|")

    for label <- labels do
      case File.read(result(label, "load.json")) do
        {:ok, body} ->
          s = JSON.decode!(body)

          IO.puts(
            "| #{label} | #{s["build"]} | #{s["samples_accepted"]} | #{round(s["duration_s"])} | " <>
              "#{round(s["samples_per_s"])} | #{s["retries_busy"]} | #{s["drain_s"]} |"
          )

        _ ->
          IO.puts("| #{label} | — | — | — | — | — | — |")
      end
    end

    for workers <- query_workers() do
      IO.puts("\n### #{workers} worker(s), p50 / p99 ms\n")

      IO.puts(
        "| query | " <>
          Enum.join(labels, " | ") <> " | #{List.last(labels)} ÷ #{hd(labels)} p50 |"
      )

      IO.puts("|---|" <> String.duplicate("---:|", length(labels) + 1))

      for type <- query_types() do
        cells = Enum.map(labels, &cell(&1, type, workers))

        IO.puts(
          "| #{type} | " <>
            Enum.join(Enum.map(cells, &elem(&1, 0)), " | ") <> " | #{ratio(cells)} |"
        )
      end
    end

    IO.puts("\n### Answers\n")

    for type <- query_types() do
      IO.puts("- #{type}: #{compare_answers(labels, type)}")
    end
  end

  defp cell(label, type, workers) do
    with {:ok, body} <- File.read(result(label, "#{type}.w#{workers}.json")),
         %{"Totals" => %{"overallQuantiles" => %{"all_queries" => q}}} <- JSON.decode!(body) do
      {"#{fmt(q["q50"])} / #{fmt(q["q99"])}", q["q50"]}
    else
      {:error, _} -> {"—", nil}
      %{"error" => error} -> {"refused: #{short(error)}", nil}
    end
  end

  defp ratio([{_, first} | _] = cells) do
    {_, last} = List.last(cells)

    if is_number(first) and is_number(last) and first > 0,
      do: "#{Float.round(last / first, 2)}",
      else: "—"
  end

  defp fmt(ms) when ms >= 100, do: "#{round(ms)}"
  defp fmt(ms), do: "#{Float.round(ms * 1.0, 1)}"

  defp short(error) do
    case Regex.run(~r/non-200 statuscode received: (\d+).*"error":"([^"]{0,80})/, error) do
      [_, code, message] -> "#{code} #{message}"
      _ -> String.slice(error, 0, 60)
    end
  end

  defp compare_answers(labels, type) do
    answers = Enum.map(labels, &answers(&1, type))

    cond do
      Enum.any?(answers, &(&1 in [:missing, []])) -> "no answer on every build"
      refused?(answers) -> "an answer was refused: #{refusals(labels, answers)}"
      Enum.uniq(answers) |> length() == 1 -> "identical on every build"
      close?(answers) -> "equal to 1e-9 on every build"
      true -> "**differ**"
    end
  end

  defp refused?(answers),
    do:
      Enum.any?(answers, fn list ->
        Enum.any?(list, &(is_binary(&1) and not String.contains?(&1, "status=success")))
      end)

  defp refusals(labels, answers) do
    labels
    |> Enum.zip(answers)
    |> Enum.map_join("; ", fn {label, list} ->
      bad = Enum.count(list, &(is_binary(&1) and not String.contains?(&1, "status=success")))
      "#{label} #{bad}/#{length(list)}"
    end)
  end

  defp answers(label, type) do
    case File.read(result(label, "#{type}.digest")) do
      {:ok, text} -> String.split(text, "\n", trim: true)
      _ -> parsed_answers(label, type)
    end
  end

  defp parsed_answers(label, type) do
    case File.read(result(label, "#{type}.verify.txt")) do
      {:ok, text} ->
        text
        |> String.split("\n")
        |> Enum.flat_map(fn line ->
          case Regex.run(~r/^ID (\d+): (.*)$/, line) do
            [_, id, rest] -> [{id, rest}]
            _ -> []
          end
        end)
        |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
        |> Enum.sort()
        |> Enum.map(fn {id, lines} ->
          {id, lines |> Enum.join("\n") |> JSON.decode() |> answer()}
        end)

      _ ->
        :missing
    end
  end

  defp answer({:ok, %{} = body}), do: {:ok, Map.take(body, ["status", "data", "error"])}
  defp answer(other), do: other

  defp close?([first | rest]), do: Enum.all?(rest, &near?(first, &1))

  defp near?(a, b) when is_list(a) and is_list(b),
    do: length(a) == length(b) and Enum.all?(Enum.zip(a, b), fn {x, y} -> near?(x, y) end)

  defp near?(a, b) when is_map(a) and is_map(b),
    do: Map.keys(a) == Map.keys(b) and Enum.all?(a, fn {k, v} -> near?(v, b[k]) end)

  defp near?({ka, a}, {kb, b}), do: ka == kb and near?(a, b)

  defp near?(a, b) when is_binary(a) and is_binary(b) do
    case {Float.parse(a), Float.parse(b)} do
      {{x, ""}, {y, ""}} -> abs(x - y) <= 1.0e-9 * max(1.0, max(abs(x), abs(y)))
      _ -> a == b
    end
  end

  defp near?(a, b), do: a == b
end

Bench.Tsbs.main(System.argv())
