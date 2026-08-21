defmodule Bench.ReportHtml do
  @moduledoc """
  One self-contained HTML report per load test, built from that run's
  `*.metrics.sqlite3` and the sidecar JSON beside it.

  The database holds raw counters: one row per metric per pod per scrape.
  This module turns them into bucketed series and charts them — throughput,
  the ingest pipeline stage by stage, seal, and compaction — so a run can be
  read without hand-written SQL.

      elixir scripts/report-html.exs results/raw-loadgen/<run>.metrics.sqlite3

  The output lands in `results/<run>.html` unless a second argument names a
  path. `BUCKET_S` overrides the bucket width; `MIN_OPS` overrides the
  denominator floor.

  ## How the numbers are derived

  Counters are node-local and monotonic, so every figure is a delta between
  consecutive scrapes of one pod. Three rules keep a degrading cluster from
  producing fiction:

    * A value that falls is a pod restart. That interval leaves every ratio
      it touches, and the bucket is marked as a reset.
    * An interval longer than `gap_s` is a scrape the sampler missed. It
      leaves every series, and a bucket with no surviving interval renders
      as a hole rather than a zero.
    * A per-operation figure divides the summed time delta by the summed
      operation delta over the same intervals, so a slow pod carries its own
      weight. Buckets under `MIN_OPS` operations are dropped — a pod that
      boots and dies inside one bucket otherwise reports a mean commit of
      several seconds.

  Rates sum per-pod rates instead of dividing a tier delta by a wall clock,
  which keeps a partly scraped bucket honest.
  """

  @assets Path.join(__DIR__, "report")

  @void_note "A shaded bucket is one the sampler never covered. A dash in the table is the same thing, or a bucket dropped for a counter reset or too few operations."

  # ── metric keys ────────────────────────────────────────────────────────
  # Unlabelled metrics store an empty string, not "{}". Key every series by
  # the exact pair the database holds.

  defp k(metric, labels \\ ""), do: metric <> "|" <> labels

  @doc false
  def keys_like(ctx, metric, contains) do
    Enum.filter(ctx.all_keys, fn key ->
      case String.split(key, "|", parts: 2) do
        [^metric, labels] -> Enum.all?(contains, &String.contains?(labels, &1))
        _other -> false
      end
    end)
  end

  defp inserts, do: [k("smolquery_ingest_inserts_total")]

  defp commits,
    do: [
      k("smolquery_buffer_commits_total", ~s({result="ok"})),
      k("smolquery_buffer_commits_total", ~s({result="error"}))
    ]

  defp requests,
    do: [
      k("smolquery_api_requests_total", ~s({class="2xx"})),
      k("smolquery_api_requests_total", ~s({class="4xx"})),
      k("smolquery_api_requests_total", ~s({class="5xx"}))
    ]

  @commit_phases ~w(encode queue replicate manifest accumulate)

  # ── entry points ───────────────────────────────────────────────────────

  def main(argv) do
    case argv do
      [db] -> generate(db)
      [db, out] -> generate(db, out)
      _ -> Bench.fatal!("usage: report-html.exs <run.metrics.sqlite3> [out.html]")
    end
  end

  def generate(db, out \\ nil) do
    File.exists?(db) || Bench.fatal!("no such metrics database: #{db}")
    label = db |> Path.basename() |> String.replace_suffix(".metrics.sqlite3", "")
    out = out || Path.join(Bench.root(), "results/#{label}.html")

    samples = load(db)
    samples != [] || Bench.fatal!("#{db} holds no samples")

    ctx = context(samples)
    series = series(ctx)
    cards = sidecars(Path.dirname(db), ctx)

    File.mkdir_p!(Path.dirname(out))
    File.write!(out, document(label, ctx, series, cards))

    IO.puts(
      "== report: #{ctx.nb} bucket(s) of #{ctx.bucket_s}s, #{length(samples)} sample(s) → #{out}"
    )

    out
  end

  # ── loading ────────────────────────────────────────────────────────────

  defp load(db) do
    query =
      "select sampled_at, phase, pod, metric, labels, value from samples order by sampled_at;"

    case Bench.sh!("sqlite3", ["-json", db, query]) |> String.trim() do
      "" -> []
      text -> text |> JSON.decode!() |> Enum.map(&row/1)
    end
  end

  defp row(r) do
    %{
      t: unix(r["sampled_at"]),
      phase: blank(r["phase"]),
      pod: r["pod"],
      key: k(r["metric"], r["labels"] || ""),
      v: r["value"] / 1
    }
  end

  defp blank(nil), do: nil
  defp blank(""), do: nil
  defp blank(text), do: text

  defp unix(stamp) do
    {:ok, at, _} = DateTime.from_iso8601(stamp)
    DateTime.to_unix(at)
  end

  # ── bucketing ──────────────────────────────────────────────────────────

  defp context(samples) do
    times = samples |> Enum.map(& &1.t) |> Enum.uniq() |> Enum.sort()
    span = List.last(times) - List.first(times)
    interval = median(deltas(times)) || 15
    gap_s = max(round(interval * 2.5), 90)
    bucket_s = Bench.env_int("BUCKET_S", if(span <= 600, do: 30, else: 60))

    origin = div(List.first(times), bucket_s) * bucket_s
    nb = div(List.last(times) - origin, bucket_s) + 1

    by_pod =
      samples
      |> Enum.group_by(& &1.pod)
      |> Map.new(fn {pod, rows} ->
        {pod,
         rows
         |> Enum.group_by(& &1.t)
         |> Map.new(fn {t, rs} -> {t, Map.new(rs, &{&1.key, &1.v})} end)}
      end)

    all =
      Enum.flat_map(by_pod, fn {pod, at} ->
        at
        |> Map.keys()
        |> Enum.sort()
        |> Enum.chunk_every(2, 1, :discard)
        |> Enum.map(fn [a, b] -> interval_of(pod, at[a], at[b], a, b, origin, bucket_s) end)
      end)

    # A restart during a missed scrape is still a restart. Gap intervals leave
    # the series math but keep their reset marks.
    ivs = Enum.reject(all, &(&1.dur > gap_s))
    resets = Enum.filter(all, &(MapSet.size(&1.reset) > 0))

    %{
      samples: samples,
      by_pod: by_pod,
      ivs: ivs,
      resets: resets,
      nb: nb,
      origin: origin,
      bucket_s: bucket_s,
      gap_s: gap_s,
      interval: interval,
      span: span,
      first: List.first(times),
      last: List.last(times),
      min_ops: Bench.env_int("MIN_OPS", 20),
      pods: by_pod |> Map.keys() |> Enum.sort(),
      all_keys: samples |> Enum.map(& &1.key) |> Enum.uniq()
    }
  end

  defp interval_of(pod, prev, cur, a, b, origin, bucket_s) do
    {d, resets} =
      Enum.reduce(cur, {%{}, MapSet.new()}, fn {key, v}, {d, resets} ->
        case Map.fetch(prev, key) do
          {:ok, p} when v >= p -> {Map.put(d, key, v - p), resets}
          {:ok, _fell} -> {Map.put(d, key, v), MapSet.put(resets, key)}
          :error -> {d, resets}
        end
      end)

    %{pod: pod, t0: a, t1: b, dur: b - a, d: d, reset: resets, bucket: div(b - origin, bucket_s)}
  end

  defp deltas(times),
    do: times |> Enum.chunk_every(2, 1, :discard) |> Enum.map(fn [a, b] -> b - a end)

  defp median([]), do: nil

  defp median(list) do
    sorted = Enum.sort(list)
    Enum.at(sorted, div(length(sorted), 2))
  end

  defp label_at(ctx, i) do
    at = DateTime.from_unix!(ctx.origin + i * ctx.bucket_s)
    pad = &String.pad_leading(Integer.to_string(&1), 2, "0")

    if ctx.bucket_s >= 60,
      do: "#{pad.(at.hour)}:#{pad.(at.minute)}",
      else: "#{pad.(at.hour)}:#{pad.(at.minute)}:#{pad.(at.second)}"
  end

  # ── series math ────────────────────────────────────────────────────────

  defp sum(iv, keys), do: Enum.reduce(keys, 0.0, &(&2 + Map.fetch!(iv.d, &1)))

  defp ratio(ctx, num_keys, den_keys, scale, min_ops) do
    {num, den} =
      Enum.reduce(ctx.ivs, {%{}, %{}}, fn iv, {num, den} = acc ->
        dk = Enum.filter(den_keys, &Map.has_key?(iv.d, &1))
        used = num_keys ++ dk

        cond do
          not Enum.all?(num_keys, &Map.has_key?(iv.d, &1)) -> acc
          dk == [] -> acc
          Enum.any?(used, &MapSet.member?(iv.reset, &1)) -> acc
          true -> {bump(num, iv.bucket, sum(iv, num_keys)), bump(den, iv.bucket, sum(iv, dk))}
        end
      end)

    for i <- 0..(ctx.nb - 1) do
      d = Map.get(den, i, 0.0)
      if d >= min_ops, do: round_to(Map.get(num, i, 0.0) / d * scale, 3), else: nil
    end
  end

  defp rate(ctx, keys) do
    acc =
      Enum.reduce(ctx.ivs, %{}, fn iv, acc ->
        case Enum.filter(keys, &Map.has_key?(iv.d, &1)) do
          [] ->
            acc

          ks ->
            Map.update(acc, {iv.bucket, iv.pod}, {sum(iv, ks), iv.dur}, fn {t, d} ->
              {t + sum(iv, ks), d + iv.dur}
            end)
        end
      end)

    by_bucket = Enum.group_by(acc, fn {{i, _pod}, _} -> i end)

    for i <- 0..(ctx.nb - 1) do
      case by_bucket[i] do
        nil ->
          nil

        list ->
          list
          |> Enum.map(fn {_, {total, dur}} -> if dur > 0, do: total / dur, else: 0.0 end)
          |> Enum.sum()
          |> round_to(1)
      end
    end
  end

  @doc false
  # A gauge is the last value seen in a bucket, never a delta — `bench_pod_*`
  # report a level, not a running total.
  def gauge(ctx, key, pods_match, agg, scale) do
    by_bucket =
      Enum.reduce(ctx.by_pod, %{}, fn {pod, at}, acc ->
        if String.contains?(pod, pods_match) do
          Enum.reduce(at, acc, fn {t, kv}, acc ->
            case Map.fetch(kv, key) do
              {:ok, v} when v > 0 ->
                i = div(t - ctx.origin, ctx.bucket_s)

                Map.update(
                  acc,
                  i,
                  %{pod => {t, v}},
                  &Map.update(&1, pod, {t, v}, fn {t0, v0} ->
                    if t >= t0, do: {t, v}, else: {t0, v0}
                  end)
                )

              _absent ->
                acc
            end
          end)
        else
          acc
        end
      end)

    for i <- 0..(ctx.nb - 1) do
      case by_bucket[i] do
        nil ->
          nil

        pods ->
          pods
          |> Map.values()
          |> Enum.map(&elem(&1, 1))
          |> agg.()
          |> Kernel.*(scale)
          |> round_to(1)
      end
    end
  end

  defp count(ctx, keys) do
    acc =
      Enum.reduce(ctx.ivs, %{}, fn iv, acc ->
        case Enum.filter(keys, &Map.has_key?(iv.d, &1)) do
          [] -> acc
          ks -> bump(acc, iv.bucket, sum(iv, ks))
        end
      end)

    for i <- 0..(ctx.nb - 1), do: acc[i] && round_to(acc[i], 1)
  end

  defp bump(map, key, add), do: Map.update(map, key, add, &(&1 + add))

  defp round_to(value, places), do: Float.round(value * 1.0, places)

  defp combine(lists, fun) do
    lists
    |> Enum.zip()
    |> Enum.map(fn tuple ->
      values = Tuple.to_list(tuple)
      if Enum.all?(values, &is_number/1), do: round_to(fun.(values), 1), else: nil
    end)
  end

  defp minus(a, b) do
    Enum.zip_with(a, b, fn
      x, y when is_number(x) and is_number(y) -> round_to(x - y, 1)
      _, _ -> nil
    end)
  end

  defp series(ctx) do
    ops = ctx.min_ops

    phase_ms = fn phase ->
      ratio(
        ctx,
        [k("smolquery_ingest_phase_microseconds_total", ~s({phase="#{phase}"}))],
        inserts(),
        1.0e-3,
        ops
      )
    end

    commit_ms = fn phase ->
      ratio(
        ctx,
        [k("smolquery_buffer_commit_phase_microseconds_total", ~s({phase="#{phase}"}))],
        commits(),
        1.0e-3,
        ops
      )
    end

    wire_ms = fn transport ->
      ratio(
        ctx,
        [k("smolquery_buffer_wire_microseconds_total", ~s({transport="#{transport}"}))],
        inserts(),
        1.0e-3,
        ops
      )
    end

    seal_s = fn result ->
      ratio(
        ctx,
        [k("smolquery_seal_microseconds_total", ~s({result="#{result}"}))],
        [k("smolquery_seal_attempts_total", ~s({result="#{result}"}))],
        1.0e-6,
        1
      )
    end

    seal_segments = fn result ->
      ratio(
        ctx,
        [k("smolquery_seal_segments_total", ~s({result="#{result}"}))],
        [k("smolquery_seal_attempts_total", ~s({result="#{result}"}))],
        1.0,
        1
      )
    end

    base = %{
      "api_request_ms" =>
        ratio(ctx, [k("smolquery_api_request_microseconds_total")], requests(), 1.0e-3, ops),
      "parse_ms" => phase_ms.("parse"),
      "write_ms" => phase_ms.("write"),
      "wire_local_ms" => wire_ms.("local"),
      "wire_remote_ms" => wire_ms.("remote"),
      "commit_ms" =>
        ratio(ctx, [k("smolquery_buffer_commit_microseconds_total")], commits(), 1.0e-3, ops),
      "seal_ok_s" => seal_s.("ok"),
      "seal_err_s" => seal_s.("error"),
      "seal_segs_ok" => seal_segments.("ok"),
      "seal_segs_err" => seal_segments.("error"),
      "compact_s" =>
        ratio(
          ctx,
          [k("smolquery_compaction_microseconds_total", ~s({result="ok"}))],
          [k("smolquery_compactions_total", ~s({result="ok"}))],
          1.0e-6,
          1
        ),
      "compact_segs" =>
        ratio(
          ctx,
          [k("smolquery_compaction_segments_replaced_total")],
          [k("smolquery_compactions_total", ~s({result="ok"}))],
          1.0,
          1
        ),
      "query_ms" =>
        ratio(
          ctx,
          [k("smolquery_query_job_milliseconds_total")],
          [k("smolquery_query_jobs_total", ~s({state="done"}))],
          1.0,
          1
        ),
      "rows_accepted_s" => rate(ctx, [k("smolquery_ingest_rows_accepted_total")]),
      "rows_committed_s" => rate(ctx, [k("smolquery_buffer_rows_committed_total")]),
      "rows_refused_s" => rate(ctx, [k("smolquery_buffer_admission_refused_rows_total")]),
      "inserts" => count(ctx, inserts()),
      "commits" => count(ctx, commits()),
      "commits_err" => count(ctx, [k("smolquery_buffer_commits_total", ~s({result="error"}))]),
      "req_2xx" => count(ctx, [k("smolquery_api_requests_total", ~s({class="2xx"}))]),
      "req_4xx" => count(ctx, [k("smolquery_api_requests_total", ~s({class="4xx"}))]),
      "req_5xx" => count(ctx, [k("smolquery_api_requests_total", ~s({class="5xx"}))]),
      "seal_attempts_ok" => count(ctx, [k("smolquery_seal_attempts_total", ~s({result="ok"}))]),
      "seal_attempts_err" =>
        count(ctx, [k("smolquery_seal_attempts_total", ~s({result="error"}))]),
      "seal_segments_ok" => count(ctx, [k("smolquery_seal_segments_total", ~s({result="ok"}))]),
      "seal_segments_err" =>
        count(ctx, [k("smolquery_seal_segments_total", ~s({result="error"}))]),
      "compactions_ok" => count(ctx, [k("smolquery_compactions_total", ~s({result="ok"}))]),
      "compactions_err" => count(ctx, [k("smolquery_compactions_total", ~s({result="error"}))]),
      "compact_replaced" => count(ctx, [k("smolquery_compaction_segments_replaced_total")]),
      "gc_segments" => count(ctx, [k("smolquery_gc_segments_swept_total")]),
      "gc_staged" => count(ctx, [k("smolquery_gc_staged_files_swept_total")]),
      "snapshots_expired" => count(ctx, [k("smolquery_snapshots_expired_total")]),
      "bc_commit" => count(ctx, [k("smolquery_lifecycle_broadcasts_total", ~s({kind="commit"}))]),
      "bc_seal" => count(ctx, [k("smolquery_lifecycle_broadcasts_total", ~s({kind="seal"}))]),
      "bc_compaction" =>
        count(ctx, [k("smolquery_lifecycle_broadcasts_total", ~s({kind="compaction"}))]),
      "jobs_done" => count(ctx, [k("smolquery_query_jobs_total", ~s({state="done"}))]),
      "jobs_error" => count(ctx, [k("smolquery_query_jobs_total", ~s({state="error"}))]),
      "jobs_cancelled" => count(ctx, [k("smolquery_query_jobs_total", ~s({state="cancelled"}))])
    }

    phases = Map.new(@commit_phases, fn phase -> {"commit_#{phase}_ms", commit_ms.(phase)} end)

    base = base |> Map.merge(hot_tier_series(ctx)) |> Map.merge(pod_series(ctx))

    base
    |> Map.merge(phases)
    |> Map.put("unattributed_ms", minus(base["write_ms"], base["commit_ms"]))
  end

  @mib 1 / 1_048_576

  defp pod_series(ctx) do
    mem = "bench_pod_memory_bytes|"
    lim = "bench_pod_memory_max_bytes|"

    Enum.reduce(~w(api buffer storage), %{}, fn tier, acc ->
      acc
      |> Map.put("rss_#{tier}_max_mb", gauge(ctx, mem, tier, &Enum.max/1, @mib))
      |> Map.put("rss_#{tier}_min_mb", gauge(ctx, mem, tier, &Enum.min/1, @mib))
      |> Map.put("rss_#{tier}_limit_mb", gauge(ctx, lim, tier, &Enum.max/1, @mib))
      |> Map.put("cpu_#{tier}_pct", tier_cpu(ctx, tier))
    end)
  end

  defp tier_cpu(ctx, tier) do
    keys = [k("bench_pod_cpu_usec_total")]

    acc =
      Enum.reduce(ctx.ivs, %{}, fn iv, acc ->
        if String.contains?(iv.pod, tier) and Map.has_key?(iv.d, hd(keys)) and
             not MapSet.member?(iv.reset, hd(keys)) do
          Map.update(acc, iv.bucket, {sum(iv, keys), iv.dur}, fn {u, d} ->
            {u + sum(iv, keys), d + iv.dur}
          end)
        else
          acc
        end
      end)

    for i <- 0..(ctx.nb - 1) do
      case acc[i] do
        {usec, dur} when dur > 0 -> round_to(usec / dur / 10_000, 1)
        _ -> nil
      end
    end
  end

  @hot_routes [
    {"manifest", ~s(route="manifest",), "manifest (get)"},
    {"manifest_scoped", ~s(route="manifest_scoped",), "manifest scoped (post)"},
    {"segment", ~s(route="segment",), "segment"}
  ]

  @hot_ops ~w(entries claimable retired_before)

  defp hot_tier_series(ctx) do
    route =
      Enum.flat_map(@hot_routes, fn {slug, match, _name} ->
        reqs = keys_like(ctx, "smolquery_hot_server_requests_total", [match])
        us = keys_like(ctx, "smolquery_hot_server_microseconds_total", [match])
        bytes = keys_like(ctx, "smolquery_hot_server_response_bytes_total", [match])
        entries = keys_like(ctx, "smolquery_hot_manifest_entries_total", [match])

        [
          {"hot_#{slug}_ms", ratio(ctx, us, reqs, 1.0e-3, 1)},
          {"hot_#{slug}_kb", ratio(ctx, bytes, reqs, 1.0e-3, 1)},
          {"hot_#{slug}_entries", ratio(ctx, entries, reqs, 1.0, 1)},
          {"hot_#{slug}_reqs", count(ctx, reqs)}
        ]
      end)

    reads =
      Enum.flat_map(@hot_ops, fn op ->
        match = ~s(op="#{op}")
        reads = keys_like(ctx, "smolquery_hot_manifest_reads_total", [match])

        [
          {"hotread_#{op}_us",
           ratio(
             ctx,
             keys_like(ctx, "smolquery_hot_manifest_read_microseconds_total", [match]),
             reads,
             1.0,
             1
           )},
          {"hotread_#{op}_entries",
           ratio(
             ctx,
             keys_like(ctx, "smolquery_hot_manifest_read_entries_total", [match]),
             reads,
             1.0,
             1
           )},
          {"hotread_#{op}_n", count(ctx, reads)}
        ]
      end)

    change = fn kind ->
      count(
        ctx,
        keys_like(ctx, "smolquery_hot_manifest_index_entries_total", [~s(change="#{kind}")])
      )
    end

    added = change.("added")
    retired = change.("retired")
    reaped = change.("reaped")
    recovered = change.("recovered")

    # T-320: resident = added + recovered - reaped. `retired` behind `added` means
    # sealing is not keeping up, which is the one condition under which nothing is
    # ever reaped and the index grows without bound.
    index = [
      {"hotindex_added", added},
      {"hotindex_retired", retired},
      {"hotindex_reaped", reaped},
      {"hotindex_recovered", recovered},
      {"hotindex_resident", combine([added, recovered, reaped], fn [a, c, r] -> a + c - r end)},
      {"hotindex_seal_lag", minus(added, retired)},
      {"hotindex_reap_lag", minus(retired, reaped)}
    ]

    ranges =
      {"hot_range_responses",
       count(ctx, keys_like(ctx, "smolquery_hot_server_range_responses_total", [""]))}

    Map.new(route ++ reads ++ index ++ [ranges])
  end

  # ── sidecars ───────────────────────────────────────────────────────────

  @covered ~w(
    smolquery_api_request_microseconds_total smolquery_api_requests_total
    smolquery_ingest_inserts_total smolquery_ingest_rows_accepted_total
    smolquery_ingest_phase_microseconds_total smolquery_ingest_shape_info
    smolquery_buffer_wire_microseconds_total smolquery_buffer_commits_total
    smolquery_buffer_commit_microseconds_total smolquery_buffer_commit_phase_microseconds_total
    smolquery_buffer_rows_committed_total smolquery_buffer_admission_refused_rows_total
    smolquery_buffer_shape_info smolquery_seal_attempts_total smolquery_seal_microseconds_total
    smolquery_seal_segments_total smolquery_compactions_total smolquery_compaction_microseconds_total
    smolquery_compaction_segments_replaced_total smolquery_gc_segments_swept_total
    smolquery_gc_staged_files_swept_total smolquery_snapshots_expired_total
    smolquery_lifecycle_broadcasts_total smolquery_query_jobs_total
    smolquery_query_job_milliseconds_total
    smolquery_hot_server_requests_total smolquery_hot_server_microseconds_total
    smolquery_hot_server_response_bytes_total smolquery_hot_server_range_responses_total
    smolquery_hot_manifest_entries_total smolquery_hot_manifest_index_entries_total
    smolquery_hot_manifest_reads_total smolquery_hot_manifest_read_microseconds_total
    smolquery_hot_manifest_read_entries_total
    bench_pod_memory_bytes bench_pod_memory_max_bytes bench_pod_cpu_usec_total
  )

  defp sidecars(dir, ctx) do
    window = {ctx.first - 90, ctx.last + 300}

    %{
      points: points(dir, window),
      compaction: read_all(dir, "compact", window),
      pruning: read_all(dir, "prune", window)
    }
  end

  defp read_all(dir, kind, window) do
    dir
    |> Path.join("*.#{kind}.json")
    |> Path.wildcard()
    |> Enum.map(&{&1, decode(&1)})
    |> Enum.filter(fn {_path, json} -> in_window?(json["inserted_at"], window) end)
    |> Enum.sort_by(fn {_path, json} -> json["inserted_at"] end)
  end

  defp points(dir, window) do
    dir
    |> Path.join("*.k6.json")
    |> Path.wildcard()
    |> Enum.map(fn path ->
      label = path |> Path.basename() |> String.replace_suffix(".k6.json", "")
      {label, decode(path), decode(Path.join(dir, "#{label}.pods.json"))}
    end)
    |> Enum.filter(fn {_label, k6, _pods} -> in_window?(k6["inserted_at"], window) end)
    |> Enum.sort_by(fn {_label, k6, _pods} -> k6["inserted_at"] end)
  end

  defp decode(path) do
    case File.read(path) do
      {:ok, text} -> JSON.decode!(text)
      {:error, _missing} -> %{}
    end
  end

  defp in_window?(nil, _window), do: false

  defp in_window?(stamp, {from, to}) do
    case DateTime.from_iso8601(stamp) do
      {:ok, at, _} -> DateTime.to_unix(at) >= from and DateTime.to_unix(at) <= to
      _unparsable -> false
    end
  end

  # ── payload ────────────────────────────────────────────────────────────

  defp payload(ctx, series, cards) do
    buckets = Enum.map(0..(ctx.nb - 1), &label_at(ctx, &1))
    covered = MapSet.new(Enum.map(ctx.ivs, & &1.bucket))

    %{
      buckets: buckets,
      phases: bucket_phases(ctx),
      voids: Enum.reject(0..(ctx.nb - 1), &MapSet.member?(covered, &1)),
      resetMinutes: reset_buckets(ctx, buckets),
      liveness: liveness(ctx),
      series: series,
      sections: sections(ctx, series, cards, buckets)
    }
  end

  defp bucket_phases(ctx) do
    by_bucket =
      ctx.samples
      |> Enum.filter(& &1.phase)
      |> Enum.group_by(&div(&1.t - ctx.origin, ctx.bucket_s), & &1.phase)

    for i <- 0..(ctx.nb - 1) do
      case by_bucket[i] do
        nil -> nil
        list -> list |> Enum.frequencies() |> Enum.max_by(&elem(&1, 1)) |> elem(0)
      end
    end
  end

  defp reset_buckets(ctx, buckets) do
    ctx.resets
    |> Enum.map(&Enum.at(buckets, &1.bucket))
    |> Enum.uniq()
    |> Enum.reject(&is_nil/1)
  end

  defp tier(pod) do
    cond do
      String.contains?(pod, "api") -> "api"
      String.contains?(pod, "buffer") -> "buffer"
      String.contains?(pod, "storage") -> "storage"
      true -> "pods"
    end
  end

  defp liveness(ctx) do
    ctx.by_pod
    |> Enum.group_by(fn {pod, _at} -> tier(pod) end)
    |> Enum.sort_by(fn {name, _} ->
      Enum.find_index(~w(api buffer storage pods), &(&1 == name)) || 9
    end)
    |> Enum.map(fn {name, entries} ->
      counts =
        for i <- 0..(ctx.nb - 1) do
          Enum.count(entries, fn {_pod, at} ->
            Enum.any?(Map.keys(at), &(div(&1 - ctx.origin, ctx.bucket_s) == i))
          end)
        end

      %{tier: name, total: length(entries), counts: counts}
    end)
  end

  # ── sections ───────────────────────────────────────────────────────────

  defp s(key, name, colour), do: %{key: key, name: name, c: colour}

  defp panel(title, unit, chart, opts \\ []) do
    %{kind: "panel", title: title, unit: unit, chart: chart}
    |> put_opt(:note, opts[:note])
    |> put_opt(:emptyNote, opts[:empty])
  end

  defp put_opt(map, _key, nil), do: map
  defp put_opt(map, key, value), do: Map.put(map, key, value)

  defp chart(type, fmt, series, opts \\ []) do
    %{type: type, fmt: fmt, series: series}
    |> put_opt(:valid, opts[:valid])
    |> put_opt(:h, opts[:h])
    |> put_opt(:wide, opts[:wide])
  end

  defp sections(ctx, series, cards, buckets) do
    [
      points_section(cards),
      throughput_section(ctx),
      pipeline_section(series),
      resources_section(),
      hot_tier_section(),
      seal_section(),
      compaction_section(cards),
      housekeeping_section(),
      pruning_section(cards),
      data_section(series, buckets),
      unclassified_section(ctx)
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp points_section(%{points: []}), do: nil

  defp points_section(%{points: points}) do
    rows =
      Enum.map(points, fn {label, k6, pods} ->
        latency = Map.get(k6, "latency_ms", %{})
        list = Map.get(pods, "pods", [])

        %{
          cells: [
            label,
            load_of(k6),
            num(k6["rows_per_s"]),
            mib_per_s(k6),
            num(k6["requests"]),
            num(k6["requests_refused"]),
            num(latency["med"]),
            num(latency["p95"]),
            num(latency["p99"]),
            rss_peak(list, "buffer"),
            rss_peak(list, "storage"),
            num(pods["cpu_total_avg_pct"])
          ]
        }
      end)

    %{
      id: "points",
      eyebrow: "01 · load points",
      title: "What k6 offered, and what the pods paid",
      intro:
        "One row per <span class=\"mono\">*.k6.json</span> whose timestamp falls inside this run's sampling window. " <>
          "RSS and CPU come from the matching <span class=\"mono\">*.pods.json</span>, which samples the container, not the counters.",
      blocks: [
        %{
          kind: "table",
          columns:
            ~w(point load rows/s MiB/s requests refused p50·ms p95·ms p99·ms) ++
              ["buffer RSS peak MB", "storage RSS peak MB", "cluster CPU avg %"],
          rows: rows
        }
      ]
    }
  end

  defp load_of(k6) do
    case k6["mode"] do
      "rate" -> "rate #{k6["rate"]}/s"
      _vus -> "#{k6["vus"]} VUs"
    end
  end

  defp mib_per_s(k6) do
    with sent when is_number(sent) <- k6["data_sent_mib"],
         seconds when is_number(seconds) and seconds > 0 <- k6["duration_s"] do
      :erlang.float_to_binary(sent / seconds, decimals: 1)
    else
      _unknown -> nil
    end
  end

  defp rss_peak(pods, match) do
    pods
    |> Enum.filter(&String.contains?(&1["name"] || "", match))
    |> Enum.map(& &1["rss_peak_mb"])
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      values -> values |> Enum.max() |> num()
    end
  end

  defp num(nil), do: nil
  defp num(value) when is_integer(value), do: Integer.to_string(value)
  defp num(value) when is_float(value), do: value |> round() |> Integer.to_string()
  defp num(value), do: to_string(value)

  defp throughput_section(ctx) do
    %{
      id: "throughput",
      eyebrow: "02 · throughput",
      title: "Rows in, rows committed, and what the api tier answered",
      intro:
        "Accepted counts rows the api tier took from k6. Committed counts rows the buffer tier durably wrote. " <>
          "The two track each other when nothing is lost in flight.",
      blocks: [
        panel(
          "Row throughput",
          "rows per second · summed over pods",
          chart(
            "line",
            "rows",
            [
              s("rows_accepted_s", "accepted", "s1"),
              s("rows_committed_s", "committed", "s2"),
              s("rows_refused_s", "refused by admission", "s3")
            ],
            h: 210
          ),
          note: @void_note
        ),
        panel(
          "API responses",
          "requests per bucket · stacked",
          chart(
            "sbars",
            "req",
            [
              s("req_2xx", "2xx accepted", "good"),
              s("req_4xx", "4xx refused", "warn"),
              s("req_5xx", "5xx failed", "crit")
            ],
            h: 200
          ),
          note:
            "A 4xx is admission control shedding load on purpose. A 5xx is the tier failing. " <>
              "A run that fails without refusing is the shape to look for."
        ),
        %{
          kind: "strip",
          title: "Pods answering a scrape",
          unit: "per bucket · a triangle marks a counter reset",
          note:
            "A counter that falls between scrapes means the pod restarted. The sampler catches OOMKills " <>
              "this way that the log watcher misses. Pod totals are the distinct pods seen anywhere in the run (#{ctx.bucket_s}s buckets)."
        }
      ]
    }
  end

  defp pipeline_section(series) do
    wired? =
      Enum.any?(
        series["wire_remote_ms"] ++ series["wire_local_ms"],
        &(is_number(&1) and &1 > 0.5)
      )

    blocks =
      [
        panel(
          "Ingest stage time, per insert",
          "milliseconds",
          chart("line", "ms", [
            s("api_request_ms", "request total", "s1"),
            s("write_ms", "write phase", "s2"),
            s("commit_ms", "buffer commit", "s3"),
            s("parse_ms", "parse phase", "s4"),
            s("unattributed_ms", "write minus commit", "s8")
          ]),
          note:
            "Parse and write are measured on the api pods over inserts; commit is measured on the buffer pods over commits. " <>
              "The two denominators are comparable only while inserts and commits track 1:1 — check the table below before reading " <>
              "<em>write minus commit</em> as the unattributed span."
        ),
        panel(
          "Commit phase time, per commit",
          "milliseconds · stacked",
          chart(
            "stack",
            "ms",
            [
              s("commit_encode_ms", "encode", "s1"),
              s("commit_queue_ms", "queue", "s2"),
              s("commit_replicate_ms", "replicate", "s3"),
              s("commit_manifest_ms", "manifest", "s4"),
              s("commit_accumulate_ms", "accumulate", "s5")
            ],
            valid: "commit_ms"
          ),
          note:
            "The five phases sum to the commit total. Queue time falling while the total rises means the buffer is starved, not backed up."
        )
      ] ++
        if wired? do
          [
            panel(
              "Buffer transport time, per insert",
              "milliseconds · measured on the api pods",
              chart(
                "line",
                "ms",
                [
                  s("wire_remote_ms", "remote", "s1"),
                  s("wire_local_ms", "local", "s2")
                ],
                h: 200
              )
            )
          ]
        else
          [
            %{
              kind: "callout",
              tone: "crit",
              k: "the wire counter is not carrying the transport",
              text:
                "<span class=\"mono\">smolquery_buffer_wire_microseconds_total</span> stayed under half a millisecond per insert for this " <>
                  "whole run. Whatever the write phase waits on, this counter is not measuring it, so the gap between the write phase and " <>
                  "the buffer commit has no attribution."
            }
          ]
        end

    %{
      id: "pipeline",
      eyebrow: "03 · ingest pipeline",
      title: "Where an insert spends its time",
      intro:
        "Every stage the pipeline instruments, divided by the operations that passed through it.",
      blocks: blocks
    }
  end

  defp resources_section do
    %{
      id: "resources",
      eyebrow: "04 · pod resources",
      title: "Memory and CPU, read from each pod's own cgroup",
      intro:
        "Counters cannot say whether a tier is stable. A pod at 3.9 GiB and climbing looks identical to one at 1.2 GiB " <>
          "and flat until the moment it OOMs. These come from <span class=\"mono\">/sys/fs/cgroup</span> in the same " <>
          "scrape as the counters, so memory and work share one timeline.",
      blocks: [
        panel(
          "Buffer tier memory",
          "MB · busiest and quietest pod, against the container limit",
          chart(
            "line",
            "int",
            [
              s("rss_buffer_max_mb", "busiest buffer pod", "s8"),
              s("rss_buffer_min_mb", "quietest buffer pod", "s1"),
              s("rss_buffer_limit_mb", "container limit", "s4")
            ],
            h: 220
          ),
          note:
            "The stability test: flat or falling over the second half of a hold is sustainable, a rising trend is not, " <>
              "however far the peak stays below the limit.",
          empty: "This run predates cgroup sampling in the metrics database."
        ),
        panel(
          "Storage and api memory",
          "MB · busiest pod per tier",
          chart(
            "line",
            "int",
            [
              s("rss_storage_max_mb", "busiest storage pod", "s2"),
              s("rss_storage_limit_mb", "storage limit", "s4"),
              s("rss_api_max_mb", "busiest api pod", "s3")
            ],
            h: 200
          ),
          empty: "This run predates cgroup sampling in the metrics database."
        ),
        panel(
          "CPU by tier",
          "percent of one core · summed across the tier's pods",
          chart(
            "line",
            "num",
            [
              s("cpu_buffer_pct", "buffer", "s1"),
              s("cpu_storage_pct", "storage", "s2"),
              s("cpu_api_pct", "api", "s3")
            ],
            h: 200
          ),
          empty: "This run predates cgroup sampling in the metrics database."
        )
      ]
    }
  end

  defp hot_tier_section do
    %{
      id: "hot",
      eyebrow: "04 · hot tier reads",
      title: "What the sealer and the query planner pull off the buffer pods",
      intro:
        "Micro-segments live on the buffer node's own disk, so everything outside the buffer service reads them over HTTP from " <>
          "<span class=\"mono\">BufferService.HotServer</span> — the sealer pulling a claim's inputs, the planner unioning the hot tier " <>
          "into a plan. The segment route is cheap; a manifest response grows with the backlog unless the caller scopes it.",
      blocks: [
        panel(
          "Bytes per hot-tier request",
          "KB per request · by route",
          chart(
            "line",
            "num",
            [
              s("hot_manifest_kb", "manifest (get)", "s1"),
              s("hot_manifest_scoped_kb", "manifest scoped (post)", "s3"),
              s("hot_segment_kb", "segment", "s2")
            ],
            h: 210
          ),
          note:
            "The series that prices an O(backlog) manifest. A scoped fetch should stay flat as the backlog grows; " <>
              "an unscoped one should not.",
          empty: "This build serves no hot-tier telemetry (added by T-315)."
        ),
        panel(
          "Entries per manifest response",
          "manifest entries per request",
          chart(
            "line",
            "num",
            [
              s("hot_manifest_entries", "manifest (get)", "s1"),
              s("hot_manifest_scoped_entries", "manifest scoped (post)", "s3")
            ],
            h: 200
          ),
          note:
            "A scoped fetch is bounded by the claim valve — 16 x seal_max_files. An unscoped one returns the whole hot tier.",
          empty: "This build serves no hot-tier telemetry (added by T-315)."
        ),
        panel(
          "Time per hot-tier request",
          "milliseconds · by route",
          chart(
            "line",
            "ms",
            [
              s("hot_manifest_ms", "manifest (get)", "s1"),
              s("hot_manifest_scoped_ms", "manifest scoped (post)", "s3"),
              s("hot_segment_ms", "segment", "s2")
            ],
            h: 200
          ),
          empty: "This build serves no hot-tier telemetry (added by T-315)."
        ),
        panel(
          "Hot-tier requests per bucket",
          "requests · by route",
          chart(
            "bars",
            "int",
            [
              s("hot_manifest_reqs", "manifest (get)", "s1"),
              s("hot_manifest_scoped_reqs", "manifest scoped (post)", "s3"),
              s("hot_segment_reqs", "segment", "s2"),
              s("hot_range_responses", "range responses", "s4")
            ],
            h: 190
          ),
          note:
            "One DuckDB read_parquet input is a HEAD plus several ranged GETs, so segment requests price inputs, not files.",
          empty: "This build serves no hot-tier telemetry (added by T-315)."
        ),
        panel(
          "Manifest index churn",
          "entries per bucket",
          chart(
            "bars",
            "int",
            [
              s("hotindex_added", "added", "s1"),
              s("hotindex_retired", "retired", "s3"),
              s("hotindex_reaped", "reaped", "s2"),
              s("hotindex_recovered", "recovered", "s4")
            ],
            h: 200
          ),
          empty: "This build does not report manifest index churn (added by T-320)."
        ),
        panel(
          "Is the hot tier in steady state?",
          "entries per bucket · T-320",
          chart(
            "line",
            "int",
            [
              s("hotindex_resident", "resident growth", "s1"),
              s("hotindex_seal_lag", "seal lag (added - retired)", "s8"),
              s("hotindex_reap_lag", "reap lag (retired - reaped)", "s4")
            ],
            h: 210
          ),
          note:
            "Resident entries are added + recovered - reaped. Seal lag above zero means sealing is not keeping pace, " <>
              "the one condition under which nothing is ever reaped and the index grows without bound. Reap lag is " <>
              "normal for retire_grace_ms and abnormal after it.",
          empty: "This build does not report manifest index churn (added by T-320)."
        ),
        panel(
          "HotManifest read cost, per read",
          "microseconds · by operation",
          chart(
            "line",
            "num",
            [
              s("hotread_entries_us", "entries", "s1"),
              s("hotread_claimable_us", "claimable", "s2"),
              s("hotread_retired_before_us", "retired_before", "s3")
            ],
            h: 190
          ),
          note:
            "ETS read cost inside the buffer (T-318). A read whose cost tracks the backlog is a read on the commit path worth scoping.",
          empty: "This build does not report HotManifest read cost (added by T-318)."
        )
      ]
    }
  end

  defp seal_section do
    %{
      id: "seal",
      eyebrow: "04 · seal",
      title: "Moving the hot tier into sealed Parquet",
      intro:
        "A seal attempt takes a share of the hot backlog and writes it out. Watch time per attempt against segments per attempt: " <>
          "if the first grows faster than the second, the batch is unbounded.",
      blocks: [
        %{
          kind: "duo",
          panels: [
            panel(
              "Time per seal attempt",
              "seconds",
              chart(
                "bars",
                "s",
                [s("seal_ok_s", "succeeded", "s1"), s("seal_err_s", "errored", "s8")],
                h: 190,
                wide: false
              )
            ),
            panel(
              "Segments per seal attempt",
              "segments",
              chart(
                "bars",
                "num",
                [s("seal_segs_ok", "succeeded", "s1"), s("seal_segs_err", "errored", "s8")],
                h: 190,
                wide: false
              ),
              note:
                "A failed batch that always lands on the same round number is a fixed batch size, not a coincidence."
            )
          ]
        },
        panel(
          "Seal work per bucket",
          "attempts and segments",
          chart(
            "bars",
            "int",
            [
              s("seal_segments_ok", "segments sealed", "s1"),
              s("seal_segments_err", "segments in failed batches", "s8"),
              s("seal_attempts_ok", "attempts ok", "s3"),
              s("seal_attempts_err", "attempts errored", "s4")
            ],
            h: 200
          )
        )
      ]
    }
  end

  defp compaction_section(cards) do
    events =
      cards.compaction
      |> Enum.flat_map(fn {_path, json} -> Map.get(json, "events", []) end)
      |> Enum.sort_by(& &1["at"])

    log_block =
      if events == [] do
        []
      else
        [
          %{
            kind: "table",
            title: "Compaction log events",
            columns: ~w(at pod table outcome segments oom line),
            rows:
              Enum.map(events, fn e ->
                %{
                  wrap: 6,
                  cells: [
                    e["at"],
                    e["pod"],
                    e["table"],
                    e["kind"],
                    num(e["segments"]),
                    if(e["oom"], do: "yes", else: nil),
                    e["line"] && String.slice(e["line"], 0, 220)
                  ]
                }
              end),
            note:
              "From the <span class=\"mono\">*.compact.json</span> beside this run. The counters above and this log are independent readings."
          }
        ]
      end

    %{
      id: "compaction",
      eyebrow: "05 · compaction",
      title: "Merging sealed segments",
      blocks:
        [
          %{
            kind: "duo",
            panels: [
              panel(
                "Time per compaction",
                "seconds",
                chart("bars", "s", [s("compact_s", "compaction", "s1")], h: 190, wide: false),
                empty: "No compaction completed while the sampler ran."
              ),
              panel(
                "Segments replaced per compaction",
                "segments",
                chart("bars", "num", [s("compact_segs", "segments", "s1")], h: 190, wide: false),
                empty: "No compaction completed while the sampler ran."
              )
            ]
          },
          panel(
            "Compaction work per bucket",
            "compactions and segments",
            chart(
              "bars",
              "int",
              [
                s("compactions_ok", "compactions ok", "s1"),
                s("compactions_err", "compactions errored", "s8"),
                s("compact_replaced", "segments replaced", "s3")
              ],
              h: 200
            ),
            empty: "No compaction counter moved while the sampler ran."
          )
        ] ++ log_block
    }
  end

  defp housekeeping_section do
    %{
      id: "housekeeping",
      eyebrow: "06 · housekeeping",
      title: "Sweeps, snapshots, broadcasts, and queries",
      intro: "The background work that competes with ingest for the same pods.",
      blocks: [
        panel(
          "Garbage collection and snapshots",
          "per bucket",
          chart(
            "bars",
            "int",
            [
              s("gc_segments", "segments swept", "s1"),
              s("gc_staged", "staged files swept", "s2"),
              s("snapshots_expired", "snapshots expired", "s3")
            ],
            h: 190
          )
        ),
        panel(
          "Lifecycle broadcasts",
          "per bucket",
          chart(
            "bars",
            "int",
            [
              s("bc_commit", "commit", "s1"),
              s("bc_seal", "seal", "s2"),
              s("bc_compaction", "compaction", "s3")
            ],
            h: 190
          )
        ),
        panel(
          "Query jobs",
          "per bucket",
          chart(
            "bars",
            "int",
            [
              s("jobs_done", "done", "s1"),
              s("jobs_error", "errored", "s8"),
              s("jobs_cancelled", "cancelled", "s4")
            ],
            h: 190
          ),
          empty: "No query job finished while the sampler ran."
        )
      ]
    }
  end

  defp pruning_section(%{pruning: []}), do: nil

  defp pruning_section(%{pruning: files}) do
    rows =
      Enum.flat_map(files, fn {_path, json} ->
        Enum.map(Map.get(json, "cases", []), fn c ->
          %{
            wrap: 6,
            cells: [
              c["case"],
              num(c["repeats"]),
              num(c["duration_ms_med"]),
              num(c["wall_ms_med"]),
              num(c["wall_ms_min"]),
              num(c["rows"]),
              num(c["errors"])
            ]
          }
        end)
      end)

    %{
      id: "pruning",
      eyebrow: "07 · pruning",
      title: "Query cases run against this table",
      intro:
        "Judge pruning by the <span class=\"mono\">scan</span> cases, never the <span class=\"mono\">count</span> ones — " <>
          "a count is answered from Parquet footer statistics whether pruning works or not.",
      blocks: [
        %{
          kind: "table",
          columns: [
            "case",
            "repeats",
            "engine ms med",
            "wall ms med",
            "wall ms min",
            "rows",
            "errors"
          ],
          rows: rows
        }
      ]
    }
  end

  @table_groups [
    {"Ingest pipeline, ms per insert",
     [
       {"api_request_ms", "request total"},
       {"parse_ms", "parse phase"},
       {"write_ms", "write phase"},
       {"unattributed_ms", "write minus commit"},
       {"wire_remote_ms", "wire remote"},
       {"wire_local_ms", "wire local"}
     ]},
    {"Buffer commit, ms per commit",
     [
       {"commit_ms", "commit total"},
       {"commit_encode_ms", "encode"},
       {"commit_queue_ms", "queue"},
       {"commit_replicate_ms", "replicate"},
       {"commit_manifest_ms", "manifest"},
       {"commit_accumulate_ms", "accumulate"}
     ]},
    {"Throughput",
     [
       {"rows_accepted_s", "rows accepted / s"},
       {"rows_committed_s", "rows committed / s"},
       {"rows_refused_s", "rows refused / s"},
       {"inserts", "inserts"},
       {"commits", "commits ok + error"},
       {"commits_err", "commit errors"}
     ]},
    {"API responses", [{"req_2xx", "2xx"}, {"req_4xx", "4xx"}, {"req_5xx", "5xx"}]},
    {"Seal",
     [
       {"seal_ok_s", "seconds per attempt ok"},
       {"seal_err_s", "seconds per attempt errored"},
       {"seal_segs_ok", "segments per attempt ok"},
       {"seal_segs_err", "segments per attempt errored"},
       {"seal_attempts_ok", "attempts ok"},
       {"seal_attempts_err", "attempts errored"},
       {"seal_segments_ok", "segments sealed"},
       {"seal_segments_err", "segments in failed batches"}
     ]},
    {"Pod resources",
     [
       {"rss_buffer_max_mb", "buffer RSS max MB"},
       {"rss_buffer_min_mb", "buffer RSS min MB"},
       {"rss_buffer_limit_mb", "buffer limit MB"},
       {"rss_storage_max_mb", "storage RSS max MB"},
       {"rss_api_max_mb", "api RSS max MB"},
       {"cpu_buffer_pct", "buffer CPU %"},
       {"cpu_storage_pct", "storage CPU %"},
       {"cpu_api_pct", "api CPU %"}
     ]},
    {"Hot tier reads",
     [
       {"hot_manifest_kb", "KB per manifest get"},
       {"hot_manifest_scoped_kb", "KB per manifest scoped post"},
       {"hot_segment_kb", "KB per segment request"},
       {"hot_manifest_entries", "entries per manifest get"},
       {"hot_manifest_scoped_entries", "entries per scoped post"},
       {"hot_manifest_ms", "ms per manifest get"},
       {"hot_manifest_scoped_ms", "ms per scoped post"},
       {"hot_segment_ms", "ms per segment request"},
       {"hot_manifest_reqs", "manifest gets"},
       {"hot_manifest_scoped_reqs", "scoped posts"},
       {"hot_segment_reqs", "segment requests"},
       {"hot_range_responses", "range responses"},
       {"hotindex_added", "index entries added"},
       {"hotindex_retired", "index entries retired"},
       {"hotindex_recovered", "index entries recovered"},
       {"hotindex_reaped", "index entries reaped"},
       {"hotindex_resident", "index resident growth"},
       {"hotindex_seal_lag", "index seal lag"},
       {"hotindex_reap_lag", "index reap lag"},
       {"hotread_entries_us", "us per entries read"},
       {"hotread_claimable_us", "us per claimable read"},
       {"hotread_retired_before_us", "us per retired_before read"},
       {"hotread_entries_entries", "entries per entries read"},
       {"hotread_claimable_entries", "entries per claimable read"},
       {"hotread_entries_n", "entries reads"},
       {"hotread_claimable_n", "claimable reads"},
       {"hotread_retired_before_n", "retired_before reads"}
     ]},
    {"Compaction",
     [
       {"compact_s", "seconds per compaction"},
       {"compact_segs", "segments per compaction"},
       {"compactions_ok", "compactions ok"},
       {"compactions_err", "compactions errored"},
       {"compact_replaced", "segments replaced"}
     ]},
    {"Housekeeping",
     [
       {"gc_segments", "gc segments swept"},
       {"gc_staged", "gc staged files swept"},
       {"snapshots_expired", "snapshots expired"},
       {"bc_commit", "broadcasts commit"},
       {"bc_seal", "broadcasts seal"},
       {"bc_compaction", "broadcasts compaction"}
     ]},
    {"Query jobs",
     [
       {"query_ms", "ms per finished job"},
       {"jobs_done", "done"},
       {"jobs_error", "errored"},
       {"jobs_cancelled", "cancelled"}
     ]}
  ]

  defp data_section(series, buckets) do
    rows =
      Enum.flat_map(@table_groups, fn {title, keys} ->
        body =
          keys
          |> Enum.filter(fn {key, _label} -> Enum.any?(series[key] || [], &is_number/1) end)
          |> Enum.map(fn {key, label} ->
            %{cells: [label | Enum.map(series[key], &cell/1)]}
          end)

        if body == [], do: [], else: [%{group: title} | body]
      end)

    %{
      id: "data",
      eyebrow: "08 · every series",
      title: "The full bucketed table",
      intro: @void_note <> " A series that never moved is left out of this table entirely.",
      blocks: [%{kind: "table", columns: ["series" | buckets], rows: rows}]
    }
  end

  defp cell(nil), do: nil

  defp cell(value) when is_number(value) do
    cond do
      value == trunc(value) and abs(value) < 1.0e15 -> value |> trunc() |> Integer.to_string()
      abs(value) >= 100 -> :erlang.float_to_binary(value / 1, decimals: 0)
      abs(value) >= 1 -> :erlang.float_to_binary(value / 1, decimals: 1)
      true -> :erlang.float_to_binary(value / 1, decimals: 3)
    end
  end

  defp metric_of(key), do: key |> String.split("|", parts: 2) |> hd()

  defp unclassified_section(ctx) do
    rows =
      ctx.ivs
      |> Enum.flat_map(fn iv -> Enum.map(iv.d, fn {key, delta} -> {key, iv.pod, delta} end) end)
      |> Enum.reject(fn {key, _pod, _delta} -> metric_of(key) in @covered end)
      |> Enum.group_by(fn {key, _pod, _delta} -> key end, fn {_key, pod, delta} ->
        {pod, delta}
      end)
      |> Enum.sort_by(fn {key, _} -> key end)
      |> Enum.map(fn {key, entries} ->
        [metric, labels] = String.split(key, "|", parts: 2)
        total = entries |> Enum.map(&elem(&1, 1)) |> Enum.sum()
        pods = entries |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> length()
        %{cells: [metric, labels, Integer.to_string(pods), cell(total)]}
      end)

    if rows == [] do
      nil
    else
      %{
        id: "unclassified",
        eyebrow: "09 · not charted",
        title: "Counters this report does not cover yet",
        intro:
          "Every metric in the database that no panel above reads. A new counter shows up here rather than disappearing.",
        blocks: [
          %{
            kind: "table",
            columns: ["metric", "labels", "pods", "delta over the run"],
            rows: rows
          }
        ]
      }
    end
  end

  # ── document ───────────────────────────────────────────────────────────

  defp tiles(ctx, series, cards) do
    peak = series["rows_accepted_s"] |> Enum.filter(&is_number/1) |> Enum.max(fn -> nil end)
    rows = series["inserts"] |> total() |> then(&(&1 && &1 * rows_per_insert(cards)))
    ok = total(series["req_2xx"]) || 0
    bad = total(series["req_5xx"]) || 0
    refused = total(series["req_4xx"]) || 0
    resets = length(ctx.resets)

    buffer_rss =
      cards.points
      |> Enum.flat_map(fn {_label, _k6, pods} -> Map.get(pods, "pods", []) end)
      |> Enum.filter(&String.contains?(&1["name"] || "", "buffer"))
      |> Enum.map(& &1["rss_peak_mb"])
      |> Enum.reject(&is_nil/1)
      |> Enum.max(fn -> nil end)

    [
      peak &&
        tile(
          "Peak accepted",
          commas(peak),
          " rows/s",
          "Best single #{ctx.bucket_s}s bucket of the run."
        ),
      rows && rows > 0 &&
        tile("Rows accepted", compact(rows), "", "Over #{fmt_duration(ctx.span)} of sampling."),
      ok + bad + refused > 0 &&
        tile(
          "Failed requests",
          pct(bad, ok + bad + refused),
          "%",
          "#{commas(bad)} 5xx against #{commas(ok)} 2xx and #{commas(refused)} 4xx."
        ),
      buffer_rss &&
        tile(
          "Buffer RSS peak",
          commas(buffer_rss),
          " MB",
          "Highest single buffer pod, from the pod sampler."
        ),
      tile(
        "Counter resets",
        Integer.to_string(resets),
        "",
        if(resets == 0,
          do: "No counter fell between scrapes.",
          else:
            "Scrapes where a counter fell across #{reset_pods(ctx)} pod(s) — each is a restart."
        )
      )
    ]
    |> Enum.filter(&is_map/1)
    |> Enum.take(4)
  end

  defp reset_pods(ctx), do: ctx.resets |> Enum.map(& &1.pod) |> Enum.uniq() |> length()

  defp tile(key, value, unit, note), do: %{k: key, v: value, unit: unit, n: note}

  defp total(list) do
    case Enum.filter(list, &is_number/1) do
      [] -> nil
      values -> Enum.sum(values)
    end
  end

  defp rows_per_insert(%{points: []}), do: 1

  defp rows_per_insert(%{points: [{_label, k6, _pods} | _]}), do: k6["rows_per_request"] || 1

  defp pct(_part, 0), do: "0"
  defp pct(part, whole), do: :erlang.float_to_binary(part * 100 / whole, decimals: 1)

  defp commas(value) when is_number(value),
    do: value |> round() |> Integer.to_string() |> group_digits()

  defp group_digits(text) do
    text
    |> String.reverse()
    |> String.to_charlist()
    |> Enum.chunk_every(3)
    |> Enum.map_join(",", &List.to_string/1)
    |> String.reverse()
  end

  defp compact(value) when value >= 1_000_000,
    do: :erlang.float_to_binary(value / 1_000_000, decimals: 1) <> "M"

  defp compact(value) when value >= 1_000,
    do: :erlang.float_to_binary(value / 1_000, decimals: 0) <> "k"

  defp compact(value), do: commas(value)

  defp fmt_duration(seconds) when seconds >= 90, do: "#{div(seconds, 60)} min"
  defp fmt_duration(seconds), do: "#{seconds} s"

  defp shape(ctx) do
    ctx.samples
    |> Enum.filter(&String.contains?(&1.key, "shape_info"))
    |> Enum.map(fn sample ->
      [_metric, labels] = String.split(sample.key, "|", parts: 2)
      labels |> String.trim_leading("{") |> String.trim_trailing("}") |> String.replace("\"", "")
    end)
    |> Enum.uniq()
  end

  defp document(label, ctx, series, cards) do
    css = File.read!(Path.join(@assets, "report.css"))
    js = File.read!(Path.join(@assets, "report.js"))
    data = payload(ctx, series, cards) |> JSON.encode!() |> String.replace("</", "<\\/")

    tiles =
      tiles(ctx, series, cards)
      |> Enum.map_join("\n", fn t ->
        ~s(      <div class="tile"><div class="k">#{esc(t.k)}</div>) <>
          ~s(<div class="v">#{esc(t.v)}<small>#{esc(t.unit)}</small></div>) <>
          ~s(<div class="n">#{esc(t.n)}</div></div>)
      end)

    """
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>#{esc(label)}</title>
    <link rel="preconnect" href="https://fonts.googleapis.com">
    <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
    <link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=IBM+Plex+Mono:wght@400;500;600&family=IBM+Plex+Sans+Condensed:wght@500;600;700&family=IBM+Plex+Sans:wght@400;500;600&display=swap">
    <style>
    #{css}
    </style>
    </head>
    <body>
    <div class="wrap">
      <header>
        <div class="eyebrow">smolquery load test · pod counters</div>
        <h1>#{esc(label)}</h1>
        <p>Every counter on every pod, sampled every #{ctx.interval}&nbsp;s and bucketed to #{ctx.bucket_s}&nbsp;s. Hover any chart to read one bucket across the run.</p>
        <div class="runbar">
          <span><b>window</b> #{esc(stamp(ctx.first))} &rarr; #{esc(stamp(ctx.last))} (#{fmt_duration(ctx.span)})</span>
          <span><b>samples</b> #{commas(length(ctx.samples))} across #{length(ctx.pods)} pod(s)</span>
          <span><b>buckets</b> #{ctx.nb} &times; #{ctx.bucket_s}s</span>
          <span><b>gap cut</b> #{ctx.gap_s}s</span>
        </div>
      </header>
      <div class="tiles">
    #{tiles}
      </div>
      <div id="sections"></div>
      <footer>
        <p class="mono">method</p>
        <p>Counters are node-local and monotonic. Each pod's series is differenced between consecutive scrapes. An interval whose value falls is a pod restart and leaves every ratio it touches. An interval longer than #{ctx.gap_s}&nbsp;s is a missed scrape and leaves every series. Per-operation figures divide the summed time delta by the summed operation delta over the same intervals, so a slow pod carries its own weight; buckets under #{ctx.min_ops} operations are dropped. Rates sum per-pod rates rather than dividing a tier delta by a wall clock.</p>
    #{Enum.map_join(shape(ctx), "\n", &~s(    <p class="mono">#{esc(&1)}</p>))}
      </footer>
    </div>
    <div id="tt" role="status" aria-live="off"></div>
    <script>
    const D = #{data};
    #{js}
    </script>
    </body>
    </html>
    """
  end

  defp stamp(unix) do
    unix |> DateTime.from_unix!() |> DateTime.to_iso8601() |> String.replace("+00:00", "Z")
  end

  defp esc(nil), do: ""

  defp esc(text) do
    text
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end
end
