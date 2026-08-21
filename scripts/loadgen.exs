#!/usr/bin/env elixir
Code.require_file("bench.exs", __DIR__)
Code.require_file("report_html.exs", __DIR__)

defmodule Bench.Loadgen do
  @moduledoc """
  An in-region k6 box, so a sweep measures the cluster instead of the operator's
  uplink.

  The instance lives in the cluster's VPC and carries the EKS cluster security
  group, which permits traffic from itself — so it reaches pod IPs directly, on
  plain HTTP, with no new rule and no Cloudflare, NLB or TLS in the path.

  Everything moves over SSM: no public IP, no SSH key, no inbound rule. Code
  goes up as an inline base64 tarball rather than a `git clone`, so a run always
  ships the working tree instead of whatever landed on `main`. Results come back
  the same way. The api key does not ride in command text — SSM keeps command
  history, and anyone with `ssm:GetCommandInvocation` can read it — so `sweep`
  puts the key in SSM Parameter Store and the box reads it from there.

  `k6` and `genbody` run on the box; `Bench.WatchPods` stays on this machine,
  because pod sampling needs the kubeconfig.
  """

  @tag "smolquery-bench-loadgen"
  @role "smolquery-bench-loadgen"
  @ssm_output_limit 24_000

  def main(argv) do
    case argv do
      ["up"] -> up()
      ["status"] -> status()
      ["sweep"] -> sweep()
      ["fetch"] -> fetch()
      ["down"] -> down()
      ["ssh"] -> session()
      _ -> Bench.fatal!("usage: loadgen.exs <up|status|sweep|fetch|down|ssh>")
    end
  end

  # ── configuration ──────────────────────────────────────────────────────────

  defp region, do: Bench.env("AWS_REGION", "eu-central-1")
  defp profile, do: Bench.env("AWS_PROFILE", "sandbox")
  defp cluster, do: Bench.env("CLUSTER_NAME", "smolquery-dev")
  defp instance_type, do: Bench.env("LOADGEN_INSTANCE_TYPE", "c7i.2xlarge")
  defp rows, do: Bench.env("ROWS", "3062")

  defp body_file, do: "bodies/#{Bench.body_name(Bench.shape(), rows())}"

  defp vus_list, do: Bench.env("VUS_LIST", "8 16 32 64 128") |> String.split()
  defp duration_s, do: Bench.env("DURATION_S", "30")
  defp warmup_s, do: Bench.env("WARMUP_S", "10")
  defp pause_s, do: Bench.env_int("PAUSE_S", 8)
  defp results_dir, do: Bench.env("RESULTS", Path.join(Bench.root(), "results/raw-loadgen"))
  defp label_suffix, do: Bench.env("LABEL_SUFFIX", "")
  defp k6_version, do: Bench.env("K6_VERSION", "v2.2.0")
  defp go_version, do: Bench.env("GO_VERSION", "go1.26.4")
  defp remote_dir, do: "/opt/bench"

  # ── aws plumbing ───────────────────────────────────────────────────────────

  defp aws!(args) do
    case System.cmd("aws", args ++ ["--region", region(), "--profile", profile()],
           stderr_to_stdout: true
         ) do
      {out, 0} ->
        String.trim(out)

      {out, _} ->
        if String.contains?(out, "sso") and String.contains?(out, "expired") do
          Bench.fatal!("AWS SSO token expired. Run: aws sso login --profile #{profile()}")
        end

        Bench.fatal!("aws #{Enum.join(args, " ")} failed:\n#{out}")
    end
  end

  defp aws_json!(args) do
    args |> Kernel.++(["--output", "json"]) |> aws!() |> JSON.decode!()
  end

  # ── discovery ──────────────────────────────────────────────────────────────

  defp vpc_config do
    aws_json!([
      "eks",
      "describe-cluster",
      "--name",
      cluster(),
      "--query",
      "cluster.resourcesVpcConfig.{vpc:vpcId,sg:clusterSecurityGroupId,subnets:subnetIds}"
    ])
  end

  @doc """
  The security group the cluster's nodes actually carry.

  Not the EKS cluster security group — that one is attached to the control
  plane's ENIs, and the managed node group uses a separate shared node group
  instead. Only the node group has the self-referencing `tcp 1025-65535` rule
  that lets one member reach a pod port on another, so the load generator has
  to wear this one to reach the api pod on 4000.
  """
  def node_security_group do
    aws!([
      "ec2",
      "describe-instances",
      "--filters",
      "Name=tag:eks:cluster-name,Values=#{cluster()}",
      "Name=instance-state-name,Values=running",
      "--query",
      "Reservations[0].Instances[0].SecurityGroups[0].GroupId",
      "--output",
      "text"
    ])
    |> case do
      id when id in ["", "None"] ->
        Bench.fatal!("could not find the cluster's node security group")

      id ->
        id
    end
  end

  defp instance_id do
    aws!([
      "ec2",
      "describe-instances",
      "--filters",
      "Name=tag:Name,Values=#{@tag}",
      "Name=instance-state-name,Values=pending,running",
      "--query",
      "Reservations[0].Instances[0].InstanceId",
      "--output",
      "text"
    ])
    |> case do
      "" -> nil
      "None" -> nil
      id -> id
    end
  end

  defp instance_id! do
    instance_id() || Bench.fatal!("no running #{@tag} instance. Run: mise run bench-up")
  end

  def api_pod_ip, do: hd(api_pod_ips())

  @doc """
  Every ready api pod's IP, so load spreads across the whole api tier.

  The load generator sits outside the cluster, so it cannot route to the
  `smolquery-api` ClusterIP — kube-proxy only balances from inside. VPC-CNI
  gives each pod a real VPC address instead, and the Service's endpoint list is
  the set of pods that are ready to take traffic. `API_POD` pins the run to one
  pod, which is what every sweep before 2026-08-16 measured by accident.
  """
  def api_pod_ips do
    case Bench.env("API_POD", nil) do
      nil -> endpoint_ips()
      pod -> [pod_ip(pod)]
    end
  end

  @ipv4 ~r/^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$/

  defp endpoint_ips do
    args = [
      "get",
      "endpointslices",
      "-l",
      "kubernetes.io/service-name=smolquery-api",
      "-o",
      "jsonpath={range .items[*].endpoints[?(@.conditions.ready==true)]}{.addresses[0]}{\" \"}{end}"
    ]

    case Bench.Kube.cmd(args) do
      {output, 0} ->
        ips =
          output
          |> String.split(~r/\s+/, trim: true)
          |> Enum.filter(&Regex.match?(@ipv4, &1))
          |> Enum.uniq()
          |> Enum.sort()

        ips != [] || Bench.fatal!("the smolquery-api service has no ready endpoints")
        ips

      {out, _} ->
        Bench.fatal!("could not resolve the smolquery-api endpoints:\n#{out}")
    end
  end

  defp pod_ip(pod) do
    case Bench.Kube.cmd(["get", "pod", pod, "-o", "jsonpath={.status.podIP}"]) do
      {ip, 0} ->
        ip = String.trim(ip)
        ip != "" || Bench.fatal!("api pod #{pod} has no IP yet")
        ip

      {out, _} ->
        Bench.fatal!("could not resolve the api pod IP:\n#{out}")
    end
  end

  # ── iam ────────────────────────────────────────────────────────────────────

  defp ensure_instance_profile do
    exists? =
      match?(
        {_, 0},
        System.cmd(
          "aws",
          ["iam", "get-instance-profile", "--instance-profile-name", @role] ++
            ["--profile", profile()],
          stderr_to_stdout: true
        )
      )

    if exists? do
      IO.puts("instance profile #{@role} exists")
    else
      IO.puts("creating instance profile #{@role}")

      trust =
        ~s({"Version":"2012-10-17","Statement":[{"Effect":"Allow",) <>
          ~s("Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]})

      aws!(["iam", "create-role", "--role-name", @role, "--assume-role-policy-document", trust])

      aws!([
        "iam",
        "attach-role-policy",
        "--role-name",
        @role,
        "--policy-arn",
        "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
      ])

      aws!(["iam", "create-instance-profile", "--instance-profile-name", @role])

      aws!([
        "iam",
        "add-role-to-instance-profile",
        "--instance-profile-name",
        @role,
        "--role-name",
        @role
      ])

      IO.puts("waiting 10s for the instance profile to propagate")
      Process.sleep(10_000)
    end
  end

  # ── up ─────────────────────────────────────────────────────────────────────

  def up do
    case instance_id() do
      nil -> launch()
      id -> IO.puts("#{@tag} already running: #{id}")
    end

    wait_for_ssm(instance_id!(), 60)
    bootstrap(instance_id!())
    status()
  end

  defp launch do
    ensure_instance_profile()
    config = vpc_config()
    subnet = Bench.env("LOADGEN_SUBNET", hd(config["subnets"]))
    sg = Bench.env("LOADGEN_SG", node_security_group())

    ami =
      aws!([
        "ssm",
        "get-parameter",
        "--name",
        "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64",
        "--query",
        "Parameter.Value",
        "--output",
        "text"
      ])

    IO.puts("launching #{instance_type()} in #{subnet} with sg #{sg}, ami #{ami}")

    id =
      aws!([
        "ec2",
        "run-instances",
        "--image-id",
        ami,
        "--instance-type",
        instance_type(),
        "--subnet-id",
        subnet,
        "--security-group-ids",
        sg,
        "--iam-instance-profile",
        "Name=#{@role}",
        "--metadata-options",
        "HttpTokens=required,HttpEndpoint=enabled",
        "--tag-specifications",
        "ResourceType=instance,Tags=[{Key=Name,Value=#{@tag}}]",
        "--query",
        "Instances[0].InstanceId",
        "--output",
        "text"
      ])

    IO.puts("launched #{id}, waiting for it to run")
    aws!(["ec2", "wait", "instance-running", "--instance-ids", id])
    id
  end

  defp wait_for_ssm(_id, 0), do: Bench.fatal!("timed out waiting for the SSM agent")

  defp wait_for_ssm(id, attempts) do
    online? =
      aws!([
        "ssm",
        "describe-instance-information",
        "--filters",
        "Key=InstanceIds,Values=#{id}",
        "--query",
        "InstanceInformationList[0].PingStatus",
        "--output",
        "text"
      ]) == "Online"

    if online? do
      IO.puts("SSM agent online")
    else
      Process.sleep(5000)
      wait_for_ssm(id, attempts - 1)
    end
  end

  defp bootstrap(id) do
    IO.puts("installing k6 and go")

    run!(id, """
    set -euo pipefail
    command -v tar >/dev/null || dnf install -y tar gzip >/dev/null
    if [ ! -x /usr/local/go/bin/go ]; then
      curl -fsSL -o /tmp/go.tgz https://go.dev/dl/#{go_version()}.linux-amd64.tar.gz
      rm -rf /usr/local/go
      tar -C /usr/local -xzf /tmp/go.tgz
      rm -f /tmp/go.tgz
    fi
    export PATH=/usr/local/go/bin:$PATH
    if ! command -v k6 >/dev/null; then
      cd /tmp
      curl -fsSL -o k6.tgz \
        https://github.com/grafana/k6/releases/download/#{k6_version()}/k6-#{k6_version()}-linux-amd64.tar.gz
      tar xzf k6.tgz
      install -m 0755 k6-#{k6_version()}-linux-amd64/k6 /usr/local/bin/k6
      rm -rf k6.tgz k6-#{k6_version()}-linux-amd64
    fi
    mkdir -p #{remote_dir()}/results #{remote_dir()}/bodies
    k6 version && go version
    """)

    IO.puts("pushing the harness and building the body")
    push_code(id)
    build_body(id)
  end

  defp build_body(id) do
    base_date =
      case Bench.env("BASE_DATE", "") do
        "" -> ""
        date -> " -base-date #{date}"
      end

    run!(id, """
    set -euo pipefail
    cd #{remote_dir()}
    export PATH=/usr/local/go/bin:$PATH GOTOOLCHAIN=local GOPATH=/opt/go GOCACHE=/opt/go/cache
    go build -o genbody ./tools/genbody
    ./genbody -shape #{Bench.shape()} -rows #{rows()} -projects 1000 -seed 42#{base_date} -out #{body_file()}
    ls -l #{body_file()}
    """)
  end

  defp push_code(id) do
    tarball = Path.join(System.tmp_dir!(), "bench-code.tgz")

    Bench.sh!("tar", ["czf", tarball, "k6", "tools/genbody", "go.mod", "schemas"],
      cd: Bench.root(),
      env: [{"COPYFILE_DISABLE", "1"}]
    )

    payload = tarball |> File.read!() |> Base.encode64()
    File.rm(tarball)

    run!(id, """
    set -euo pipefail
    mkdir -p #{remote_dir()}/bodies
    cd #{remote_dir()}
    echo '#{payload}' | base64 -d | tar xzf -
    """)
  end

  # ── ssm command execution ──────────────────────────────────────────────────

  defp run!(id, script), do: run(id, script, true)

  defp run(id, script, raise_on_error) do
    doc = JSON.encode!(%{"commands" => [script]})

    command_id =
      aws!([
        "ssm",
        "send-command",
        "--instance-ids",
        id,
        "--document-name",
        "AWS-RunShellScript",
        "--parameters",
        doc,
        "--timeout-seconds",
        "3600",
        "--query",
        "Command.CommandId",
        "--output",
        "text"
      ])

    await_command(id, command_id, raise_on_error)
  end

  defp await_command(id, command_id, raise_on_error) do
    Process.sleep(2000)

    invocation =
      aws_json!([
        "ssm",
        "get-command-invocation",
        "--instance-id",
        id,
        "--command-id",
        command_id
      ])

    case invocation["Status"] do
      status when status in ["Pending", "InProgress", "Delayed"] ->
        await_command(id, command_id, raise_on_error)

      "Success" ->
        invocation["StandardOutputContent"]

      status ->
        message =
          "remote command #{status}:\n#{invocation["StandardErrorContent"]}\n" <>
            invocation["StandardOutputContent"]

        if raise_on_error, do: Bench.fatal!(message), else: message
    end
  end

  # ── status ─────────────────────────────────────────────────────────────────

  def status do
    case instance_id() do
      nil ->
        IO.puts("no #{@tag} instance. Run: mise run bench-up")

      id ->
        info =
          aws_json!([
            "ec2",
            "describe-instances",
            "--instance-ids",
            id,
            "--query",
            "Reservations[0].Instances[0].{state:State.Name,ip:PrivateIpAddress," <>
              "type:InstanceType,az:Placement.AvailabilityZone}"
          ])

        ping =
          aws!([
            "ssm",
            "describe-instance-information",
            "--filters",
            "Key=InstanceIds,Values=#{id}",
            "--query",
            "InstanceInformationList[0].PingStatus",
            "--output",
            "text"
          ])

        ips = api_pod_ips()

        IO.puts("""
        instance   #{id}
        type       #{info["type"]} in #{info["az"]}
        state      #{info["state"]}
        private ip #{info["ip"]}
        ssm        #{ping}
        targets    #{length(ips)} api pod(s)
        #{Enum.map_join(ips, "\n", &"           http://#{&1}:4000")}
        """)
    end
  end

  def session do
    id = instance_id!()
    IO.puts("aws ssm start-session --target #{id} --region #{region()} --profile #{profile()}")
  end

  # ── sweep ──────────────────────────────────────────────────────────────────

  def sweep do
    benches = Bench.benches()
    ingest? = "ingest" in benches

    pod_ips = api_pod_ips()
    dataset = Bench.Remote.dataset()
    table = Bench.Remote.table()
    key = Bench.Remote.api_key()

    urls =
      Enum.map_join(pod_ips, ",", fn ip ->
        "http://#{ip}:4000/v1/datasets/#{dataset}/tables/#{table}/insert"
      end)

    File.mkdir_p!(results_dir())

    # Sampling starts before anything touches the cluster, so every run opens
    # with an idle baseline and the setup work — instance lookup, table setup,
    # preflight insert — is on the record too.
    watcher = Bench.WatchMetrics.start(metrics_db())

    id = if ingest?, do: instance_id!(), else: nil

    if ingest?, do: ingest_preflight(key)

    IO.puts("== benches: #{Enum.join(benches, ", ")}")

    Enum.each(benches, fn bench ->
      Bench.WatchMetrics.set_phase(watcher, bench)

      case bench do
        "ingest" -> run_ingest(id, dataset, table, urls, key, watcher)
        "pruning" -> run_pruning(dataset, table, key)
        "compaction" -> run_compaction()
      end
    end)

    db = Bench.WatchMetrics.stop(watcher)

    Bench.ReportHtml.generate(db)

    IO.puts("\n== done → #{results_dir()}")
  end

  defp metrics_db do
    stamp = DateTime.utc_now() |> Calendar.strftime("%Y%m%dT%H%M%SZ")
    Bench.WatchMetrics.db_path(results_dir(), "loadgen-#{stamp}#{label_suffix()}")
  end

  defp ingest_preflight(key) do
    body_path = Path.join(Bench.root(), body_file())

    File.exists?(body_path) ||
      Bench.fatal!("body file missing: #{body_path} (run scripts/gen-bodies.exs)")

    Bench.Remote.setup()

    IO.puts("== preflight via #{Bench.Remote.insert_url()}")

    Bench.RunArm.preflight(
      Bench.Remote.insert_url(),
      "application/x-ndjson",
      "Bearer #{key}",
      body_path
    )
  end

  # ── bench: ingest ──────────────────────────────────────────────────────────

  defp run_ingest(id, dataset, table, urls, key, watcher) do
    IO.puts("\n== ingest: pushing the working tree, rebuilding the body")
    push_code(id)
    build_body(id)

    put_api_key(key)
    run!(id, "rm -f #{remote_dir()}/results/*.json")

    targets = urls |> String.split(",") |> length()

    IO.puts("\n== ingest: loadgen sweep across #{targets} api pod(s)")
    Enum.each(String.split(urls, ","), &IO.puts("     #{&1}"))
    IO.puts("== VUs: #{Enum.join(vus_list(), " ")}, #{duration_s()}s each\n")

    Enum.each(vus_list(), fn vus ->
      label = "loadgen-vus#{vus}#{label_suffix()}"

      Bench.WatchMetrics.set_phase(watcher, "drain-vus#{vus}")
      drain = await_hot_drain(dataset, table, key)
      IO.puts("== #{label}: hot tier #{drain_outcome(drain)}")

      Bench.WatchMetrics.set_phase(watcher, "ingest-vus#{vus}")

      IO.puts("== #{label}: warm-up #{warmup_s()}s")
      run!(id, warmup_script(urls, vus))

      IO.puts("== #{label}: pause #{pause_s()}s, then #{duration_s()}s measured")
      Process.sleep(pause_s() * 1000)

      pods_task =
        Task.async(fn -> Bench.WatchPods.sample(String.to_integer(duration_s())) end)

      out = run!(id, measure_script(urls, vus, label))
      IO.puts(String.trim(out))

      pods =
        pods_task
        |> Task.await(:infinity)
        |> Map.put("drain_wait_s", drain.waited_s)
        |> Map.put("drain_hot_files_left", drain.hot_files)

      File.write!(Path.join(results_dir(), "#{label}.pods.json"), JSON.encode!(pods) <> "\n")

      Process.sleep(pause_s() * 1000)
    end)

    delete_api_key()
    fetch()
  end

  defp drain_wait_s, do: Bench.env_int("DRAIN_WAIT_S", 300)

  defp drain_poll_s, do: Bench.env_int("DRAIN_POLL_S", 10)

  defp await_hot_drain(dataset, table, key) do
    url = "#{Bench.Remote.base_url()}/v1/queries"
    sql = count_query("#{dataset}.#{table}", "1971-01-01")
    started = System.monotonic_time(:second)
    deadline = started + drain_wait_s()
    hot_files = poll_hot_drain(url, key, sql, deadline)
    %{waited_s: System.monotonic_time(:second) - started, hot_files: hot_files}
  end

  defp poll_hot_drain(url, key, sql, deadline) do
    files = hot_files(url, key, sql)

    cond do
      files == 0 ->
        0

      System.monotonic_time(:second) >= deadline ->
        files

      true ->
        Process.sleep(drain_poll_s() * 1000)
        poll_hot_drain(url, key, sql, deadline)
    end
  end

  defp hot_files(url, key, sql) do
    headers = [{"authorization", "Bearer #{key}"}]
    body = JSON.encode!(%{"query" => sql, "timeoutMs" => 60_000, "maxResults" => 1})

    case Bench.http(:post, url, headers, "application/json", body, 90_000) do
      {:ok, status, response} when status in 200..299 ->
        response |> JSON.decode!() |> get_in(["job", "statistics", "hot", "filesTotal"]) ||
          :unknown

      _failure ->
        :unknown
    end
  end

  defp drain_outcome(%{waited_s: waited_s, hot_files: 0}), do: "empty after #{waited_s}s"

  defp drain_outcome(%{waited_s: waited_s, hot_files: hot_files}),
    do: "NOT drained after #{waited_s}s (#{inspect(hot_files)} hot files) — continuing"

  # ── bench: pruning ─────────────────────────────────────────────────────────

  defp prune_repeats, do: Bench.env_int("PRUNE_REPEATS", 3)

  defp prune_column, do: Bench.env("PRUNE_COLUMN", "duration_ms")

  defp prune_settle_s, do: Bench.env_int("PRUNE_SETTLE_S", 30)

  defp prune_dates do
    case Bench.env("PRUNE_DATES", "") do
      "" -> [Date.utc_today() |> Date.to_iso8601()]
      dates -> dates |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
    end
  end

  defp run_pruning(dataset, table, key) do
    IO.puts("\n== pruning: settling #{prune_settle_s()}s so writes seal")
    Process.sleep(prune_settle_s() * 1000)

    url = "#{Bench.Remote.base_url()}/v1/queries"
    IO.puts("== pruning: querying #{url}")
    ref = "#{dataset}.#{table}"
    empty_date = "1971-01-01"

    dated =
      Enum.flat_map(prune_dates(), fn date ->
        [
          {"count-date-#{date}", count_query(ref, date)},
          {"scan-date-#{date}", scan_query(ref, date)}
        ]
      end)

    cases =
      dated ++
        [
          {"count-date-empty-#{empty_date}", count_query(ref, empty_date)},
          {"scan-date-empty-#{empty_date}", scan_query(ref, empty_date)},
          {"count-no-filter", "SELECT count(*) AS n FROM #{ref}"},
          {"scan-no-filter", "SELECT sum(#{prune_column()}) AS s FROM #{ref}"}
        ]

    results =
      Enum.map(cases, fn {name, sql} ->
        measured = Enum.map(1..prune_repeats(), fn _ -> time_query(url, key, sql) end)
        ok = Enum.filter(measured, &(&1.error == nil))
        explained = explain_query(url, key, sql)

        summary = %{
          "case" => name,
          "sql" => sql,
          "repeats" => prune_repeats(),
          "wall_ms_min" => ok |> Enum.map(& &1.wall_ms) |> min_or_nil(),
          "wall_ms_med" => ok |> Enum.map(& &1.wall_ms) |> median_or_nil(),
          "duration_ms_med" => ok |> Enum.map(& &1.duration_ms) |> median_or_nil(),
          "rows" => ok |> Enum.map(& &1.rows) |> List.first(),
          "errors" => Enum.count(measured, &(&1.error != nil)),
          "first_error" =>
            case Enum.find(measured, &(&1.error != nil)) do
              nil -> nil
              failed -> failed.error
            end,
          "engine_total_s" => explained.engine_total_s,
          "explain_analyze" => explained.plan,
          "explain_error" => explained.error
        }

        IO.puts(
          "== #{name}: wall med #{summary["wall_ms_med"]}ms, " <>
            "durationMs med #{summary["duration_ms_med"]}, rows #{summary["rows"]}, " <>
            "errors #{summary["errors"]}, engine #{summary["engine_total_s"] || "?"}s"
        )

        summary
      end)

    label = "loadgen-prune#{label_suffix()}"
    payload = %{"inserted_at" => now_iso(), "table" => ref, "cases" => results}
    File.write!(Path.join(results_dir(), "#{label}.prune.json"), JSON.encode!(payload) <> "\n")
    IO.puts("== pruning → #{label}.prune.json")
  end

  defp count_query(ref, date), do: "SELECT count(*) AS n FROM #{ref} #{date_where(date)}"

  defp scan_query(ref, date) do
    "SELECT sum(#{prune_column()}) AS s FROM #{ref} #{date_where(date)}"
  end

  defp date_where(date) do
    "WHERE inserted_at >= TIMESTAMP '#{date} 00:00:00' " <>
      "AND inserted_at < TIMESTAMP '#{date} 00:00:00' + INTERVAL 1 DAY"
  end

  defp time_query(url, key, sql) do
    headers = [{"authorization", "Bearer #{key}"}]
    timeout_ms = Bench.env_int("PRUNE_TIMEOUT_MS", 180_000)
    body = JSON.encode!(%{"query" => sql, "timeoutMs" => timeout_ms, "maxResults" => 1})
    started = System.monotonic_time(:microsecond)

    case Bench.http(:post, url, headers, "application/json", body, timeout_ms + 30_000) do
      {:ok, status, response} when status in 200..299 ->
        wall_ms = (System.monotonic_time(:microsecond) - started) / 1000
        decoded = JSON.decode!(response)

        %{
          wall_ms: Float.round(wall_ms, 1),
          duration_ms: get_in(decoded, ["job", "durationMs"]),
          rows: first_count(decoded),
          error: nil
        }

      {:ok, status, response} ->
        %{
          wall_ms: nil,
          duration_ms: nil,
          rows: nil,
          error: "HTTP #{status}: #{trunc_text(response)}"
        }

      {:error, reason} ->
        %{wall_ms: nil, duration_ms: nil, rows: nil, error: inspect(reason)}
    end
  end

  defp explain_query(url, key, sql) do
    headers = [{"authorization", "Bearer #{key}"}]
    timeout_ms = Bench.env_int("PRUNE_TIMEOUT_MS", 180_000)

    body =
      JSON.encode!(%{"query" => sql, "explain" => "analyze", "timeoutMs" => timeout_ms})

    case Bench.http(:post, url, headers, "application/json", body, timeout_ms + 30_000) do
      {:ok, status, response} when status in 200..299 ->
        plan = response |> JSON.decode!() |> get_in(["job", "explain"])
        %{plan: plan, engine_total_s: engine_total_s(plan), error: nil}

      {:ok, status, response} ->
        %{plan: nil, engine_total_s: nil, error: "HTTP #{status}: #{trunc_text(response)}"}

      {:error, reason} ->
        %{plan: nil, engine_total_s: nil, error: inspect(reason)}
    end
  end

  defp engine_total_s(nil), do: nil

  defp engine_total_s(plan) do
    with [_, seconds] <- Regex.run(~r/Total Time: ([0-9.]+)s/, plan),
         {value, _rest} <- Float.parse(seconds) do
      value
    else
      _no_match -> nil
    end
  end

  defp first_count(%{"rows" => [row | _]}) when is_map(row),
    do: row |> Map.values() |> List.first()

  defp first_count(%{"totalRows" => n}), do: n
  defp first_count(_body), do: nil

  defp trunc_text(text), do: text |> String.trim() |> String.slice(0, 200)

  defp min_or_nil([]), do: nil
  defp min_or_nil(values), do: Enum.min(values)

  defp median_or_nil([]), do: nil

  defp median_or_nil(values) do
    sorted = Enum.sort(values)
    middle = div(length(sorted), 2)

    case rem(length(sorted), 2) do
      1 -> Enum.at(sorted, middle)
      0 -> Float.round((Enum.at(sorted, middle - 1) + Enum.at(sorted, middle)) / 2, 1)
    end
  end

  # ── bench: compaction ──────────────────────────────────────────────────────

  defp compact_watch_s, do: Bench.env_int("COMPACT_WATCH_S", 900)

  defp run_compaction do
    seconds = compact_watch_s()
    pods = storage_pods()

    IO.puts("\n== compaction: watching #{length(pods)} storage pod(s) for #{seconds}s")
    Enum.each(pods, &IO.puts("     #{&1}"))

    window_start = now_iso()
    deadline = System.monotonic_time(:second) + seconds

    events = watch_compaction(pods, deadline, [])

    label = "loadgen-compact#{label_suffix()}"

    payload = %{
      "inserted_at" => now_iso(),
      "watch_s" => seconds,
      "window_start" => window_start,
      "log_lookback" => "30m",
      "pods" => pods,
      "restarts" => Enum.map(pods, &pod_restart_json/1),
      "events" => events,
      "compacted" => Enum.count(events, &(&1["kind"] == "compacted")),
      "failed" => Enum.count(events, &(&1["kind"] == "failed")),
      "oom" => Enum.count(events, &(&1["kind"] == "failed" and &1["oom"]))
    }

    File.write!(Path.join(results_dir(), "#{label}.compact.json"), JSON.encode!(payload) <> "\n")

    IO.puts(
      "== compaction: #{payload["compacted"]} compacted, #{payload["failed"]} failed " <>
        "(#{payload["oom"]} out-of-memory) → #{label}.compact.json"
    )
  end

  defp storage_pods do
    args = [
      "get",
      "pods",
      "-l",
      "app=smolquery-storage",
      "-o",
      "jsonpath={.items[*].metadata.name}"
    ]

    case Bench.Kube.cmd(args) do
      {output, 0} ->
        case output
             |> String.split(~r/\s+/, trim: true)
             |> Enum.filter(&(&1 =~ ~r/^smolquery-/)) do
          [] -> Bench.fatal!("no storage pods found for label app=smolquery-storage")
          pods -> Enum.sort(pods)
        end

      {out, _} ->
        Bench.fatal!("could not list the storage pods:\n#{out}")
    end
  end

  defp watch_compaction(pods, deadline, seen) do
    events =
      pods
      |> Enum.flat_map(&compaction_events/1)
      |> Enum.reject(&(&1 in seen))

    Enum.each(events, fn event ->
      IO.puts("   #{event["pod"]} #{event["kind"]} #{event["table"]} #{event["at"]}")
    end)

    all = seen ++ events

    if System.monotonic_time(:second) >= deadline do
      all
    else
      Process.sleep(30_000)
      watch_compaction(pods, deadline, all)
    end
  end

  defp compaction_events(pod) do
    case Bench.Kube.cmd(["logs", pod, "--since=30m"]) do
      {output, 0} ->
        output |> String.split("\n") |> Enum.flat_map(&parse_compaction_line(&1, pod))

      _failed ->
        []
    end
  end

  defp parse_compaction_line(line, pod) do
    cond do
      line =~ "compacted" and line =~ "segment(s) of" ->
        [compaction_event(line, pod, "compacted")]

      line =~ "compaction of" and line =~ "failed" ->
        [compaction_event(line, pod, "failed")]

      true ->
        []
    end
  end

  defp compaction_event(line, pod, kind) do
    %{
      "pod" => pod,
      "kind" => kind,
      "at" => line |> String.slice(0, 12) |> String.trim(),
      "table" => extract_table(line),
      "segments" => extract_segments(line),
      "oom" => line =~ "Out of Memory",
      "line" => trunc_text(line)
    }
  end

  defp extract_table(line) do
    case Regex.run(~r/\{"([^"]+)",\s*"([^"]+)"\}/, line) do
      [_, dataset, table] -> "#{dataset}.#{table}"
      _no_match -> nil
    end
  end

  defp extract_segments(line) do
    case Regex.run(~r/compacted (\d+) segment/, line) do
      [_, count] -> String.to_integer(count)
      _no_match -> nil
    end
  end

  defp pod_restart_json(pod) do
    path = "jsonpath={.status.containerStatuses[0].restartCount}"

    restarts =
      case Bench.Kube.cmd(["get", "pod", pod, "-o", path]) do
        {output, 0} ->
          case output |> String.trim() |> Integer.parse() do
            {count, _rest} -> count
            :error -> nil
          end

        _failed ->
          nil
      end

    %{"pod" => pod, "restarts" => restarts}
  end

  defp now_iso, do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp api_key_param, do: "/smolquery-bench/api-key"

  defp put_api_key(key) do
    aws!(
      ["ssm", "put-parameter", "--name", api_key_param(), "--type", "SecureString"] ++
        ["--value", key, "--overwrite"]
    )
  end

  defp delete_api_key do
    System.cmd(
      "aws",
      ["ssm", "delete-parameter", "--name", api_key_param()] ++
        ["--region", region(), "--profile", profile()],
      stderr_to_stdout: true
    )
  end

  defp fetch_auth do
    """
    AUTH="Bearer $(aws ssm get-parameter --name #{api_key_param()} --with-decryption \
      --query Parameter.Value --output text --region #{region()})"
    """
  end

  defp warmup_script(urls, vus) do
    """
    set -euo pipefail
    cd #{remote_dir()}
    #{fetch_auth()}
    k6 run --quiet -e URLS='#{urls}' -e AUTH="$AUTH" -e ROWS=#{rows()} \
      -e BODY=#{remote_dir()}/#{body_file()} \
      -e VUS=#{vus} -e DURATION=#{warmup_s()}s k6/insert.js >/dev/null
    """
  end

  defp measure_script(urls, vus, label) do
    """
    set -euo pipefail
    cd #{remote_dir()}
    #{fetch_auth()}
    k6 run --quiet -e URLS='#{urls}' -e AUTH="$AUTH" -e ROWS=#{rows()} \
      -e BODY=#{remote_dir()}/#{body_file()} \
      -e VUS=#{vus} -e DURATION=#{duration_s()}s \
      -e JSON_OUT=results/#{label}.k6.json k6/insert.js
    """
  end

  # ── fetch ──────────────────────────────────────────────────────────────────

  def fetch do
    id = instance_id!()
    File.mkdir_p!(results_dir())

    payload =
      run!(id, """
      set -euo pipefail
      cd #{remote_dir()}
      tar czf - results | base64 -w0
      """)
      |> String.trim()

    byte_size(payload) < @ssm_output_limit ||
      Bench.fatal!(
        "results are #{byte_size(payload)} base64 bytes, over the #{@ssm_output_limit} " <>
          "SSM inline limit — the tarball would be truncated. Fetch fewer runs at a time."
      )

    tarball = Path.join(System.tmp_dir!(), "bench-results.tgz")
    File.write!(tarball, Base.decode64!(payload))

    Bench.sh!("tar", ["xzf", tarball, "--strip-components", "1", "-C", results_dir()])
    File.rm(tarball)

    count = results_dir() |> Path.join("*.k6.json") |> Path.wildcard() |> length()
    IO.puts("fetched #{count} k6 results → #{results_dir()}")
  end

  # ── down ───────────────────────────────────────────────────────────────────

  def down do
    case instance_id() do
      nil ->
        IO.puts("no #{@tag} instance to terminate")

      id ->
        aws!(["ec2", "terminate-instances", "--instance-ids", id])
        IO.puts("terminating #{id}")
    end
  end
end

Bench.Loadgen.main(System.argv())
