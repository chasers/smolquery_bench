#!/usr/bin/env elixir
Code.require_file("bench.exs", __DIR__)
Code.require_file("report_html.exs", __DIR__)
Bench.ReportHtml.main(System.argv())
