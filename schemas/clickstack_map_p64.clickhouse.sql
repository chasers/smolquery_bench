CREATE TABLE IF NOT EXISTS clickstack_map_p64
(
  `project` String,
  `timestamp` DateTime64(6),
  `trace_id` Nullable(String),
  `span_id` Nullable(String),
  `trace_flags` Nullable(Int64),
  `severity_text` Nullable(String),
  `severity_number` Nullable(Int64),
  `service_name` Nullable(String),
  `body` Nullable(String),
  `resource_schema_url` Nullable(String),
  `resource_attributes` Map(String, String),
  `scope_schema_url` Nullable(String),
  `scope_name` Nullable(String),
  `scope_version` Nullable(String),
  `scope_attributes` Map(String, String),
  `log_attributes` Map(String, String),
  `event_name` Nullable(String),
  `inserted_at` Nullable(DateTime64(6))
)
ENGINE = MergeTree
PARTITION BY (project, toDate(timestamp))
ORDER BY (project, timestamp)
SETTINGS index_granularity = 8192;
