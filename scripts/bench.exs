defmodule Bench do
  @root Path.expand("..", __DIR__)

  def root, do: @root

  def env(name, default), do: System.get_env(name, default)

  def env_int(name, default), do: String.to_integer(env(name, Integer.to_string(default)))

  def run_dir, do: env("RUN_DIR", "/tmp/sqbench")

  def results_dir("remote"), do: env("RESULTS", Path.join(root(), "results/raw-remote"))
  def results_dir(_arm), do: env("RESULTS", Path.join(root(), "results/raw"))

  @doc """
  The table every arm targets. `otel_logs_v3` partitions by the `inserted_at`
  date on ClickHouse and clusters by `project_id` on smolquery.
  """
  def table, do: env("TABLE", "otel_logs_v3")

  @doc """
  The clustering key sent to smolquery, as a JSON array string.

  `otel_logs_v3` clusters by `project_id` alone. The older tables keep the
  two-column key they were measured with. `CLUSTERING` overrides both, as a
  comma-separated column list; an empty value clears clustering.
  """
  def clustering(table \\ table()) do
    case env("CLUSTERING", nil) do
      nil -> default_clustering(table)
      "" -> []
      columns -> columns |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
    end
    |> JSON.encode!()
  end

  defp default_clustering("otel_logs_v3"), do: ["project_id"]
  defp default_clustering(_table), do: ["project_id", "timestamp"]

  @bench_types ~w(ingest pruning compaction)

  @doc """
  The bench types to run, from `BENCHES`, as a comma-separated list.

  Defaults to `ingest`. The returned list keeps the order the types must run
  in — ingest writes the rows pruning reads, and compaction needs those rows
  sealed — not the order the operator typed. An unknown or empty selection is
  fatal, because a silent skip costs a whole sweep before anyone notices.
  """
  def benches do
    requested =
      "BENCHES"
      |> env("ingest")
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    unknown = Enum.reject(requested, &(&1 in @bench_types))

    cond do
      requested == [] ->
        fatal!("BENCHES is empty (expected any of: #{Enum.join(@bench_types, ", ")})")

      unknown != [] ->
        fatal!(
          "unknown bench type(s): #{Enum.join(unknown, ", ")} " <>
            "(expected any of: #{Enum.join(@bench_types, ", ")})"
        )

      true ->
        Enum.filter(@bench_types, &(&1 in requested))
    end
  end

  def bench?(type), do: type in benches()

  @doc """
  The schema or DDL file for a table, per arm. A table without its own file
  falls back to the original `otel_logs` definition, which v1 and v2 share.
  """
  def schema_path(arm, table \\ table()) do
    extension = if arm == "clickhouse", do: "clickhouse.sql", else: "smolquery.json"
    specific = Path.join(root(), "schemas/#{table}.#{extension}")

    if File.exists?(specific),
      do: specific,
      else: Path.join(root(), "schemas/otel_logs.#{extension}")
  end

  def fatal!(message) do
    IO.puts(:stderr, message)
    System.halt(1)
  end

  def sh!(cmd, args, opts \\ []) do
    {output, status} = sh(cmd, args, opts)
    status == 0 || fatal!("#{cmd} #{Enum.join(args, " ")} exited with status #{status}")
    output
  end

  def sh(cmd, args, opts \\ []) do
    System.cmd(cmd, args, Keyword.merge([stderr_to_stdout: true], opts))
  end

  def stream!(cmd, args, opts \\ []) do
    opts = Keyword.merge([into: IO.stream(:stdio, :line), stderr_to_stdout: true], opts)
    {_, status} = System.cmd(cmd, args, opts)
    status == 0 || fatal!("#{cmd} exited with status #{status}")
    :ok
  end

  def http(method, url, headers \\ [], content_type \\ nil, body \\ nil, timeout_ms \\ 120_000) do
    request =
      if body do
        {String.to_charlist(url), erl_headers(headers), String.to_charlist(content_type), body}
      else
        {String.to_charlist(url), erl_headers(headers)}
      end

    case :httpc.request(method, request, [timeout: timeout_ms], body_format: :binary) do
      {:ok, {{_, status, _}, _, response_body}} -> {:ok, status, response_body}
      {:error, reason} -> {:error, reason}
    end
  end

  def http_2xx!(method, url, headers, content_type, body, context) do
    case http(method, url, headers, content_type, body) do
      {:ok, status, response_body} when status in 200..299 ->
        response_body

      {:ok, status, response_body} ->
        fatal!("#{context} got HTTP #{status}: #{response_body}")

      {:error, reason} ->
        fatal!("#{context} failed: #{inspect(reason)}")
    end
  end

  defp erl_headers(headers) do
    Enum.map(headers, fn {name, value} ->
      {String.to_charlist(name), String.to_charlist(value)}
    end)
  end

  def start_daemon(command, log, pidfile, opts \\ []) do
    shell = "nohup #{command} >#{log} 2>&1 & echo $!"
    {output, 0} = System.cmd("/bin/sh", ["-c", shell], Keyword.take(opts, [:cd, :env]))
    pid = String.trim(output)
    File.write!(pidfile, pid)
    pid
  end

  def alive?(nil), do: false

  def alive?(pid) do
    match?({_, 0}, System.cmd("kill", ["-0", pid], stderr_to_stdout: true))
  end

  def pidfile_pid(pidfile) do
    case File.read(pidfile) do
      {:ok, contents} -> String.trim(contents)
      _ -> nil
    end
  end

  def stop_arm(arm) do
    pidfile = Path.join(run_dir(), "#{arm}.pid")
    pid = pidfile_pid(pidfile)

    if alive?(pid) do
      System.cmd("kill", [pid], stderr_to_stdout: true)
      wait_for_exit(pid, 30)
      IO.puts("stopped #{arm} (#{pid})")
    end

    File.rm(pidfile)
    :ok
  end

  def wait_for_exit(pid, attempts) do
    Enum.reduce_while(1..attempts, :ok, fn _, _ ->
      if alive?(pid) do
        Process.sleep(1000)
        {:cont, :ok}
      else
        {:halt, :ok}
      end
    end)
  end

  def log_tail(log, lines) do
    case File.read(log) do
      {:ok, contents} ->
        contents |> String.split("\n") |> Enum.take(-lines) |> Enum.join("\n")

      _ ->
        "(no log at #{log})"
    end
  end
end

defmodule Bench.Genbody do
  def main do
    out_dir = Bench.env("OUT_DIR", Path.join(Bench.root(), "bodies"))
    rows = Bench.env("ROWS", "3062")
    projects = Bench.env("PROJECTS", "1000")
    seed = Bench.env("SEED", "42")
    base_date = Bench.env("BASE_DATE", "")

    args =
      [
        "run",
        "./tools/genbody",
        "-rows",
        rows,
        "-projects",
        projects,
        "-seed",
        seed,
        "-out",
        Path.join(out_dir, "eachrow.#{rows}.ndjson")
      ] ++ if base_date == "", do: [], else: ["-base-date", base_date]

    Bench.stream!("go", args, cd: Bench.root())
  end
end

defmodule Bench.Clickhouse do
  @base_url "http://127.0.0.1:8123"

  def setup do
    run_dir = Bench.run_dir()
    data_dir = Bench.env("DATA_DIR", Path.join(run_dir, "clickhouse-data"))
    pidfile = Path.join(run_dir, "clickhouse.pid")
    log = Path.join(run_dir, "clickhouse.log")
    fsync = Bench.env("FSYNC", "1")

    File.mkdir_p!(run_dir)
    Bench.stop_arm("clickhouse")
    File.rm_rf!(data_dir)
    File.mkdir_p!(data_dir)

    pid =
      Bench.start_daemon(
        "clickhouse server -- --path #{data_dir} --listen_host 127.0.0.1",
        log,
        pidfile,
        cd: data_dir
      )

    IO.puts("waiting for clickhouse on :8123 (log: #{log})")
    wait_for_ping(pid, log, 60)

    ch!("CREATE DATABASE IF NOT EXISTS bench")
    ch!(File.read!(Bench.schema_path("clickhouse")))

    if fsync == "1" do
      ch!(
        "ALTER TABLE bench.#{Bench.table()} " <>
          "MODIFY SETTING fsync_after_insert = 1, fsync_part_directory = 1"
      )
    end

    IO.puts("clickhouse ready: #{String.trim(ch!("SELECT version()"))} fsync=#{fsync}")
  end

  defp wait_for_ping(_pid, log, 0) do
    Bench.fatal!("timed out waiting for clickhouse; tail of #{log}:\n#{Bench.log_tail(log, 20)}")
  end

  defp wait_for_ping(pid, log, attempts) do
    case Bench.http(:get, @base_url <> "/ping") do
      {:ok, 200, "Ok.\n"} ->
        :ok

      _ ->
        if Bench.alive?(pid) do
          Process.sleep(1000)
          wait_for_ping(pid, log, attempts - 1)
        else
          Bench.fatal!(
            "clickhouse exited during boot; tail of #{log}:\n#{Bench.log_tail(log, 20)}"
          )
        end
    end
  end

  defp ch!(query) do
    Bench.http_2xx!(:post, @base_url <> "/", [], "text/plain", query, "clickhouse query")
  end
end

defmodule Bench.Smolquery do
  @base_url "http://127.0.0.1:4000"

  def setup do
    run_dir = Bench.run_dir()
    smolquery_dir = Bench.env("SMOLQUERY_DIR", Path.expand("~/Dev/supabase/smolquery"))
    data_dir = Bench.env("DATA_DIR", Path.join(run_dir, "smolquery-data"))
    api_key = Bench.env("API_KEY", "benchkey")
    pidfile = Path.join(run_dir, "smolquery.pid")
    log = Path.join(run_dir, "smolquery.log")

    server_env = [
      {"SMOLQUERY_DATA_DIR", data_dir},
      {"SMOLQUERY_API_KEY", api_key},
      {"SMOLQUERY_FLUSH_MAX_BYTES", Bench.env("FLUSH_MAX_BYTES", "50331648")},
      {"SMOLQUERY_FLUSH_INTERVAL_MS", Bench.env("FLUSH_INTERVAL_MS", "1000")},
      {"SMOLQUERY_MAX_BUFFERED_BYTES", Bench.env("MAX_BUFFERED_BYTES", "134217728")},
      {"SMOLQUERY_WRITE_POOL_SIZE", Bench.env("WRITE_POOL_SIZE", "10")},
      {"SMOLQUERY_ENCODE_CONCURRENCY", Bench.env("ENCODE_CONCURRENCY", "10")},
      {"SMOLQUERY_FLUSH_WRITER", Bench.env("FLUSH_WRITER", "duckdb")}
    ]

    server_env =
      Enum.reduce(
        [
          {"WRITE_ENGINE_THREADS", "SMOLQUERY_WRITE_ENGINE_THREADS"},
          {"COMMIT_SIBLINGS", "SMOLQUERY_COMMIT_SIBLINGS"},
          {"FLUSH_IDLE_INTERVAL_MS", "SMOLQUERY_FLUSH_IDLE_INTERVAL_MS"},
          {"SEAL_ROW_GROUP_SIZE", "SMOLQUERY_SEAL_ROW_GROUP_SIZE"}
        ],
        server_env,
        fn {name, server_name}, acc ->
          case System.get_env(name) do
            nil -> acc
            value -> acc ++ [{server_name, value}]
          end
        end
      )

    File.mkdir_p!(run_dir)
    Bench.stop_arm("smolquery")

    IO.puts("waiting for smolquery on :4000 (log: #{log})")
    boot_with_retries(smolquery_dir, data_dir, server_env, log, pidfile, 3)

    create_dataset_and_table(api_key)

    settings =
      server_env
      |> Enum.drop(2)
      |> Enum.map_join(" ", fn {name, value} ->
        "#{name |> String.trim_leading("SMOLQUERY_") |> String.downcase()}=#{value}"
      end)

    IO.puts("smolquery ready: #{settings}")
  end

  defp boot_with_retries(_smolquery_dir, _data_dir, _server_env, log, _pidfile, 0) do
    Bench.fatal!("smolquery kept exiting during boot; tail of #{log}:\n#{Bench.log_tail(log, 5)}")
  end

  defp boot_with_retries(smolquery_dir, data_dir, server_env, log, pidfile, attempts) do
    case boot(smolquery_dir, data_dir, server_env, log, pidfile) do
      :ok ->
        :ok

      :exited ->
        IO.puts(
          :stderr,
          "smolquery exited during boot; tail of #{log}:\n#{Bench.log_tail(log, 5)}"
        )

        boot_with_retries(smolquery_dir, data_dir, server_env, log, pidfile, attempts - 1)
    end
  end

  defp boot(smolquery_dir, data_dir, server_env, log, pidfile) do
    File.rm_rf!(data_dir)
    File.mkdir_p!(data_dir)

    pid =
      Bench.start_daemon("mix run --no-halt", log, pidfile,
        cd: smolquery_dir,
        env: server_env
      )

    wait_for_health(pid, 180)
  end

  defp wait_for_health(_pid, 0), do: Bench.fatal!("timed out waiting for smolquery")

  defp wait_for_health(pid, attempts) do
    healthy = match?({:ok, 200, _}, Bench.http(:get, @base_url <> "/healthz"))

    cond do
      healthy ->
        Process.sleep(1000)
        if Bench.alive?(pid), do: :ok, else: :exited

      Bench.alive?(pid) ->
        Process.sleep(1000)
        wait_for_health(pid, attempts - 1)

      true ->
        :exited
    end
  end

  defp create_dataset_and_table(api_key) do
    headers = [{"authorization", "Bearer #{api_key}"}]

    schema =
      "smolquery"
      |> Bench.schema_path()
      |> File.read!()
      |> JSON.decode!()
      |> Map.put("id", Bench.table())
      |> JSON.encode!()

    Bench.http_2xx!(
      :post,
      @base_url <> "/v1/datasets",
      headers,
      "application/json",
      ~s({"id":"logs"}),
      "create dataset"
    )

    Bench.http_2xx!(
      :post,
      @base_url <> "/v1/datasets/logs/tables",
      headers,
      "application/json",
      schema,
      "create table"
    )

    Bench.http_2xx!(
      :patch,
      @base_url <> "/v1/datasets/logs/tables/#{Bench.table()}",
      headers,
      "application/json",
      ~s({"clustering":#{Bench.clustering()}}),
      "set clustering"
    )
  end
end

defmodule Bench.Remote do
  @moduledoc """
  The already-deployed arm: a smolquery cluster this harness does not own.

  There is no server lifecycle and no cold table — the router exposes no table
  delete — so every run appends to the same table. `Bench.WatchPods` supplies
  the server-side CPU that `tools/watch` cannot see from here.

  Every control-plane call retries. A saturated api pod answers a control
  request slowly enough that Cloudflare gives up and returns 520 — seen between
  sweep steps, with the pod healthy and never restarted. A 409 counts as
  success, because the dataset and the table survive the previous step.
  """

  def base_url, do: Bench.env("BASE_URL", "https://eu-central-1-sandbox.smolquery.com:8443")

  def dataset, do: Bench.env("DATASET", "bench")

  def table, do: Bench.table()

  def api_key do
    case System.get_env("API_KEY") do
      nil -> api_key_from_secrets()
      key -> key
    end
  end

  def schema_file do
    Bench.env("SCHEMA_FILE", Bench.schema_path("smolquery"))
  end

  def insert_url, do: "#{base_url()}/v1/datasets/#{dataset()}/tables/#{table()}/insert"

  def setup do
    key = api_key()
    headers = [{"authorization", "Bearer #{key}"}]

    schema =
      schema_file()
      |> File.read!()
      |> JSON.decode!()
      |> Map.put("id", table())
      |> JSON.encode!()

    wait_healthy(30)

    ensure(:post, "/v1/datasets", headers, ~s({"id":"#{dataset()}"}), "create dataset")
    ensure(:post, "/v1/datasets/#{dataset()}/tables", headers, schema, "create table")

    ensure(
      :patch,
      "/v1/datasets/#{dataset()}/tables/#{table()}",
      headers,
      ~s({"clustering":#{Bench.clustering()}}),
      "set clustering"
    )

    IO.puts("remote ready: #{insert_url()}")
  end

  defp wait_healthy(0) do
    Bench.fatal!("#{base_url()}/healthz never returned 200")
  end

  defp wait_healthy(attempts) do
    case Bench.http(:get, base_url() <> "/healthz") do
      {:ok, 200, _} ->
        :ok

      _ ->
        Process.sleep(2000)
        wait_healthy(attempts - 1)
    end
  end

  defp ensure(method, path, headers, body, context, attempts \\ 5) do
    case Bench.http(method, base_url() <> path, headers, "application/json", body) do
      {:ok, status, _} when status in 200..299 ->
        :ok

      {:ok, 409, _} ->
        :ok

      {:ok, status, response} when attempts > 1 ->
        IO.puts(
          :stderr,
          "#{context} got HTTP #{status}, retrying: #{String.slice(response, 0, 120)}"
        )

        Process.sleep(3000)
        ensure(method, path, headers, body, context, attempts - 1)

      {:error, reason} when attempts > 1 ->
        IO.puts(:stderr, "#{context} failed, retrying: #{inspect(reason)}")
        Process.sleep(3000)
        ensure(method, path, headers, body, context, attempts - 1)

      {:ok, status, response} ->
        Bench.fatal!("#{context} got HTTP #{status}: #{response}")

      {:error, reason} ->
        Bench.fatal!("#{context} failed: #{inspect(reason)}")
    end
  end

  defp api_key_from_secrets do
    path =
      System.get_env("SECRETS_FILE") ||
        Bench.fatal!(
          "set API_KEY, or set SECRETS_FILE to a file holding SMOLQUERY_API_KEY " <>
            "(mise.toml sets SECRETS_FILE)"
        )

    with {:ok, contents} <- File.read(path),
         {:ok, %{"SMOLQUERY_API_KEY" => key}} <- JSON.decode(contents) do
      key
    else
      _ -> Bench.fatal!("no SMOLQUERY_API_KEY in #{path}; set API_KEY or fix SECRETS_FILE")
    end
  end
end

defmodule Bench.Kube do
  @moduledoc """
  The one place that builds kubectl invocations for the deployed cluster.

  `KUBECONFIG` must come from the environment — `mise.toml` sets it — because a
  kubeconfig path is machine-specific and does not belong in code.
  """

  def cmd!(args, context) do
    case cmd(args) do
      {output, 0} -> output
      {output, _} -> Bench.fatal!("#{context} failed: #{output}")
    end
  end

  def cmd(args) do
    System.cmd("kubectl", base_args() ++ args, env: env(), stderr_to_stdout: true)
  end

  def namespace, do: Bench.env("K8S_NAMESPACE", "smolquery")

  defp base_args do
    ["--context", Bench.env("KUBE_CONTEXT", "eks-smolquery-dev"), "-n", namespace()]
  end

  defp env do
    kubeconfig =
      System.get_env("KUBECONFIG") ||
        Bench.fatal!("set KUBECONFIG to the cluster's kubeconfig (mise.toml sets it)")

    [{"KUBECONFIG", kubeconfig}]
  end
end

defmodule Bench.WatchPods do
  @moduledoc """
  Server-side CPU and memory for the remote arm, read from each pod's cgroup.

  The sandbox cluster runs no metrics-server, so `kubectl top` fails. One
  long-lived `kubectl exec` per pod prints `<uptime_s> <usage_usec> <rss_bytes>`
  once a second. CPU percent comes from the deltas, where 100% is one core.
  """

  def main(argv) do
    {seconds, out} =
      case argv do
        [seconds, out] -> {String.to_integer(seconds), out}
        _ -> Bench.fatal!("usage: watch-pods.exs <seconds> <out.json>")
      end

    File.write!(out, JSON.encode!(sample(seconds)) <> "\n")
    IO.puts("pods → #{out}")
  end

  def sample(seconds) do
    pods = pods()
    pods == [] && Bench.fatal!("no pods matched in namespace #{Bench.Kube.namespace()}")

    pods
    |> Enum.map(fn pod -> Task.async(fn -> {pod, series(pod, seconds)} end) end)
    |> Task.await_many((seconds + 30) * 1000)
    |> Enum.map(fn {pod, series} -> summarize(pod, series) end)
    |> then(
      &%{
        "inserted_at" =>
          DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
        "pods" => &1,
        "cpu_total_avg_pct" => total_avg(&1)
      }
    )
  end

  def pods do
    selector = Bench.env("POD_SELECTOR", "cluster=smolquery")

    args =
      ["get", "pods", "-l", selector] ++
        ["-o", "jsonpath={range .items[*]}{.metadata.name} {end}"]

    args
    |> Bench.Kube.cmd!("kubectl get pods")
    |> String.split()
    |> Enum.sort()
  end

  defp series(pod, seconds) do
    script = """
    i=0
    while [ $i -lt #{seconds} ]; do
      u=$(cut -d' ' -f1 /proc/uptime)
      c=$(awk '/^usage_usec/{print $2}' /sys/fs/cgroup/cpu.stat)
      m=$(cat /sys/fs/cgroup/memory.current)
      echo "$u $c $m"
      i=$((i+1))
      sleep 1
    done
    """

    case Bench.Kube.cmd(["exec", pod, "-c", "smolquery", "--", "sh", "-c", script]) do
      {output, 0} -> parse(output)
      {_, _} -> []
    end
  end

  defp parse(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case String.split(line) do
        [uptime, usage, rss] ->
          with {u, _} <- Float.parse(uptime),
               {c, ""} <- Integer.parse(usage),
               {m, ""} <- Integer.parse(rss) do
            [{u, c, m}]
          else
            _ -> []
          end

        _ ->
          []
      end
    end)
  end

  defp summarize(pod, []), do: %{"name" => pod, "samples" => 0}

  defp summarize(pod, series) do
    percents =
      series
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.flat_map(fn [{u0, c0, _}, {u1, c1, _}] ->
        if u1 > u0, do: [(c1 - c0) / 1_000_000 / (u1 - u0) * 100], else: []
      end)

    rss_peak = series |> Enum.map(fn {_, _, m} -> m end) |> Enum.max()

    %{
      "name" => pod,
      "samples" => length(series),
      "cpu_avg_pct" => avg(percents),
      "cpu_peak_pct" => if(percents == [], do: nil, else: Enum.max(percents)),
      "rss_peak_mb" => rss_peak / 1_048_576
    }
  end

  defp total_avg(pods) do
    pods |> Enum.map(&Map.get(&1, "cpu_avg_pct")) |> Enum.reject(&is_nil/1) |> Enum.sum()
  end

  defp avg([]), do: nil
  defp avg(values), do: Enum.sum(values) / length(values)
end

defmodule Bench.RunArm do
  @arms ["smolquery", "clickhouse", "remote"]

  def main(argv) do
    case argv do
      [arm] when arm in @arms -> run(arm)
      _ -> Bench.fatal!("usage: run-arm.exs <#{Enum.join(@arms, "|")}>")
    end
  end

  def run(arm, overrides \\ %{}) do
    vus = Map.get(overrides, :vus, Bench.env("VUS", "4"))
    mode = Bench.env("MODE", "vus")
    rate = Bench.env("RATE", "")
    rows = Bench.env("ROWS", "3062")
    duration_s = Bench.env_int("DURATION_S", 60)
    warmup_s = Bench.env("WARMUP_S", "20")
    pause_s = Bench.env_int("PAUSE_S", 15)
    body_path = Bench.env("BODY", Path.join(Bench.root(), "bodies/eachrow.#{rows}.ndjson"))

    api_key =
      if arm == "remote", do: Bench.Remote.api_key(), else: Bench.env("API_KEY", "benchkey")

    results = Bench.results_dir(arm)
    label_suffix = Bench.env("LABEL_SUFFIX", "")

    File.exists?(body_path) ||
      Bench.fatal!("body file missing: #{body_path} (run scripts/gen-bodies.exs)")

    {url, content_type, auth, server_match} = arm_config(arm, api_key)

    label =
      case mode do
        "rate" ->
          rate != "" || Bench.fatal!("RATE is required when MODE=rate")
          "#{arm}-rate#{rate}#{label_suffix}"

        _ ->
          "#{arm}-vus#{vus}#{label_suffix}"
      end

    File.mkdir_p!(results)
    watch_bin = ensure_watch_built()

    IO.puts("== #{label}: preflight")
    preflight(url, content_type, auth, body_path)

    k6_env =
      [URL: url, BODY: body_path, ROWS: rows, MODE: mode, CONTENT_TYPE: content_type] ++
        if(auth == "", do: [], else: [AUTH: auth]) ++
        if(mode == "rate", do: [RATE: rate], else: [VUS: vus])

    IO.puts("== #{label}: warm-up #{warmup_s}s")
    k6!(k6_env ++ [DURATION: "#{warmup_s}s"], into: "")

    IO.puts("== #{label}: pause #{pause_s}s")
    Process.sleep(pause_s * 1000)

    IO.puts("== #{label}: measuring #{duration_s}s")

    watch_args =
      if(server_match, do: ["-match", server_match], else: []) ++
        [
          "-match",
          "k6 run",
          "-duration",
          "#{duration_s + 8}s",
          "-out",
          Path.join(results, "#{label}.watch.json")
        ]

    watch_task = Task.async(fn -> System.cmd(watch_bin, watch_args, stderr_to_stdout: true) end)

    pods_task =
      if arm == "remote" do
        pods_out = Path.join(results, "#{label}.pods.json")

        Task.async(fn ->
          File.write!(pods_out, JSON.encode!(Bench.WatchPods.sample(duration_s)) <> "\n")
        end)
      end

    k6!(
      k6_env ++
        [DURATION: "#{duration_s}s", JSON_OUT: Path.join(results, "#{label}.k6.json")],
      into: IO.stream(:stdio, :line)
    )

    case Task.await(watch_task, :infinity) do
      {_, 0} -> :ok
      {output, status} -> Bench.fatal!("watch exited with status #{status}: #{output}")
    end

    pods_task && Task.await(pods_task, :infinity)

    IO.puts("== #{label}: done → #{results}/#{label}.{k6,watch}.json")
  end

  defp arm_config("smolquery", api_key) do
    {
      "http://127.0.0.1:4000/v1/datasets/logs/tables/#{Bench.table()}/insert",
      "application/x-ndjson",
      "Bearer #{api_key}",
      ~S(beam\.smp.*mix run --no-halt)
    }
  end

  defp arm_config("remote", api_key) do
    {Bench.Remote.insert_url(), "application/x-ndjson", "Bearer #{api_key}", nil}
  end

  defp arm_config("clickhouse", _api_key) do
    query = URI.encode("INSERT INTO bench.#{Bench.table()} FORMAT JSONEachRow")

    {
      "http://127.0.0.1:8123/?query=#{query}",
      "text/plain",
      "",
      "clickhouse server"
    }
  end

  @inserted_at_placeholder "____INSERTED_AT___________"

  def preflight(url, content_type, auth, body_path) do
    headers = if auth == "", do: [], else: [{"authorization", auth}]
    body = body_path |> File.read!() |> stamp_inserted_at()
    response = Bench.http_2xx!(:post, url, headers, content_type, body, "preflight")

    if String.trim(response) != "" do
      case JSON.decode(response) do
        {:ok, decoded} ->
          errors = Map.get(decoded, "insertErrors", [])
          errors == [] || Bench.fatal!("preflight rows were rejected: #{response}")

        {:error, _} ->
          Bench.fatal!("preflight response is not JSON: #{response}")
      end
    end
  end

  defp stamp_inserted_at(body) do
    String.replace(
      body,
      @inserted_at_placeholder,
      DateTime.utc_now() |> DateTime.to_naive() |> NaiveDateTime.to_iso8601()
    )
  end

  defp ensure_watch_built do
    watch_bin = Path.join(Bench.root(), "bin/watch")

    unless File.exists?(watch_bin) do
      Bench.sh!("go", ["build", "-o", "bin/watch", "./tools/watch"], cd: Bench.root())
    end

    watch_bin
  end

  defp k6!(k6_env, opts) do
    env_flags = Enum.flat_map(k6_env, fn {name, value} -> ["-e", "#{name}=#{value}"] end)
    script = Path.join(Bench.root(), "k6/insert.js")

    {_, status} =
      System.cmd("k6", ["run", "--quiet"] ++ env_flags ++ [script],
        into: Keyword.fetch!(opts, :into),
        stderr_to_stdout: true
      )

    status == 0 || Bench.fatal!("k6 exited with status #{status}")
  end
end

defmodule Bench.Report do
  def main(results \\ nil) do
    results = results || Bench.env("RESULTS", Path.join(Bench.root(), "results/raw"))
    files = results |> Path.join("*.k6.json") |> Path.wildcard() |> Enum.sort_by(&sort_key/1)
    files != [] || Bench.fatal!("no results in #{results}")

    remote? = results |> Path.join("*.pods.json") |> Path.wildcard() != []

    header =
      if remote? do
        "| run | rows/s | MiB/s | p50 ms | p95 ms | p99 ms | refused | api cpu avg % | " <>
          "api cpu peak % | api rss peak MB | cluster cpu avg % |"
      else
        "| run | rows/s | p50 ms | p95 ms | p99 ms | refused | server cpu avg % | " <>
          "server cpu peak % | server rss peak MB |"
      end

    IO.puts(header)
    IO.puts(separator(header))
    Enum.each(files, &IO.puts(row(&1, results, remote?)))
  end

  defp sort_key(path) do
    label = path |> Path.basename() |> String.trim_trailing(".k6.json")

    load =
      case Regex.run(~r/(?:vus|rate)(\d+)/, label) do
        [_, digits] -> String.to_integer(digits)
        _ -> 0
      end

    {label |> String.split(~r/(?:vus|rate)\d+/) |> List.first(), load, label}
  end

  defp separator(header) do
    count = header |> String.split("|", trim: true) |> length()
    "|" <> String.duplicate("---|", count)
  end

  defp row(k6_file, results, remote?) do
    label = k6_file |> Path.basename() |> String.trim_trailing(".k6.json")
    k6 = k6_file |> File.read!() |> JSON.decode!()
    latency = Map.get(k6, "latency_ms", %{})

    throughput =
      if remote? do
        [round_cell(k6["rows_per_s"]), mib_per_s(k6)]
      else
        [round_cell(k6["rows_per_s"])]
      end

    server =
      if remote? do
        pod_cells(Path.join(results, "#{label}.pods.json"))
      else
        server_cells(Path.join(results, "#{label}.watch.json"))
      end

    cells =
      [label] ++
        throughput ++
        [
          round_cell(latency["med"]),
          round_cell(latency["p95"]),
          round_cell(latency["p99"]),
          k6["requests_refused"],
          server
        ]

    "| " <> Enum.join(cells, " | ") <> " |"
  end

  defp mib_per_s(k6) do
    sent = k6["data_sent_mib"]
    duration = k6["duration_s"]

    if is_number(sent) and is_number(duration) and duration > 0 do
      :erlang.float_to_binary(sent / duration, decimals: 1)
    else
      "-"
    end
  end

  defp pod_cells(pods_file) do
    with {:ok, contents} <- File.read(pods_file),
         %{"pods" => pods} = decoded <- JSON.decode!(contents),
         api when not is_nil(api) <- Enum.find(pods, &String.contains?(&1["name"], "api")) do
      Enum.map_join(
        [
          api["cpu_avg_pct"],
          api["cpu_peak_pct"],
          api["rss_peak_mb"],
          decoded["cpu_total_avg_pct"]
        ],
        " | ",
        &round_cell/1
      )
    else
      _ -> "- | - | - | -"
    end
  end

  defp server_cells(watch_file) do
    with {:ok, contents} <- File.read(watch_file),
         %{"processes" => [server | _]} <- JSON.decode!(contents) do
      Enum.map_join(
        [server["cpu_avg_pct"], server["cpu_peak_pct"], server["rss_peak_mb"]],
        " | ",
        &round_cell/1
      )
    else
      _ -> "- | - | -"
    end
  end

  defp round_cell(value) when is_number(value), do: Integer.to_string(round(value))
  defp round_cell(_), do: "-"
end

{:ok, _} = Application.ensure_all_started(:inets)
{:ok, _} = Application.ensure_all_started(:ssl)
