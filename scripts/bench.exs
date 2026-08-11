defmodule Bench do
  @root Path.expand("..", __DIR__)

  def root, do: @root

  def env(name, default), do: System.get_env(name, default)

  def env_int(name, default), do: String.to_integer(env(name, Integer.to_string(default)))

  def run_dir, do: env("RUN_DIR", "/tmp/sqbench")

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

    args = [
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
    ]

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
    ch!(File.read!(Path.join(Bench.root(), "schemas/otel_logs.clickhouse.sql")))

    if fsync == "1" do
      ch!(
        "ALTER TABLE bench.otel_logs MODIFY SETTING fsync_after_insert = 1, fsync_part_directory = 1"
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
      case System.get_env("WRITE_ENGINE_THREADS") do
        nil -> server_env
        threads -> server_env ++ [{"SMOLQUERY_WRITE_ENGINE_THREADS", threads}]
      end

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
    schema = File.read!(Path.join(Bench.root(), "schemas/otel_logs.smolquery.json"))

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
      @base_url <> "/v1/datasets/logs/tables/otel_logs",
      headers,
      "application/json",
      ~s({"clustering":["project_id","timestamp"]}),
      "set clustering"
    )
  end
end

defmodule Bench.RunArm do
  def main(argv) do
    case argv do
      [arm] when arm in ["smolquery", "clickhouse"] -> run(arm)
      _ -> Bench.fatal!("usage: run-arm.exs <smolquery|clickhouse>")
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
    api_key = Bench.env("API_KEY", "benchkey")
    results = Bench.env("RESULTS", Path.join(Bench.root(), "results/raw"))
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

    watch_args = [
      "-match",
      server_match,
      "-match",
      "k6 run",
      "-duration",
      "#{duration_s + 8}s",
      "-out",
      Path.join(results, "#{label}.watch.json")
    ]

    watch_task = Task.async(fn -> System.cmd(watch_bin, watch_args, stderr_to_stdout: true) end)

    k6!(
      k6_env ++
        [DURATION: "#{duration_s}s", JSON_OUT: Path.join(results, "#{label}.k6.json")],
      into: IO.stream(:stdio, :line)
    )

    case Task.await(watch_task, :infinity) do
      {_, 0} -> :ok
      {output, status} -> Bench.fatal!("watch exited with status #{status}: #{output}")
    end

    IO.puts("== #{label}: done → #{results}/#{label}.{k6,watch}.json")
  end

  defp arm_config("smolquery", api_key) do
    {
      "http://127.0.0.1:4000/v1/datasets/logs/tables/otel_logs/insert",
      "application/x-ndjson",
      "Bearer #{api_key}",
      ~S(beam\.smp.*mix run --no-halt)
    }
  end

  defp arm_config("clickhouse", _api_key) do
    {
      "http://127.0.0.1:8123/?query=INSERT%20INTO%20bench.otel_logs%20FORMAT%20JSONEachRow",
      "text/plain",
      "",
      "clickhouse server"
    }
  end

  defp preflight(url, content_type, auth, body_path) do
    headers = if auth == "", do: [], else: [{"authorization", auth}]
    body = File.read!(body_path)
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
  def main do
    results = Bench.env("RESULTS", Path.join(Bench.root(), "results/raw"))
    files = results |> Path.join("*.k6.json") |> Path.wildcard() |> Enum.sort()
    files != [] || Bench.fatal!("no results in #{results}")

    IO.puts(
      "| run | rows/s | p50 ms | p95 ms | p99 ms | refused | server cpu avg % | " <>
        "server cpu peak % | server rss peak MB |"
    )

    IO.puts("|---|---|---|---|---|---|---|---|---|")
    Enum.each(files, &IO.puts(row(&1, results)))
  end

  defp row(k6_file, results) do
    label = k6_file |> Path.basename() |> String.trim_trailing(".k6.json")
    k6 = k6_file |> File.read!() |> JSON.decode!()
    latency = Map.get(k6, "latency_ms", %{})

    cells = [
      label,
      round_cell(k6["rows_per_s"]),
      round_cell(latency["med"]),
      round_cell(latency["p95"]),
      round_cell(latency["p99"]),
      k6["requests_refused"],
      server_cells(Path.join(results, "#{label}.watch.json"))
    ]

    "| " <> Enum.join(cells, " | ") <> " |"
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
