CREATE TABLE IF NOT EXISTS clickstack_variant_v2
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
  `resource_attributes` JSON,
  `scope_schema_url` Nullable(String),
  `scope_name` Nullable(String),
  `scope_version` Nullable(String),
  `scope_attributes` JSON,
  `log_attributes` JSON,
  `event_name` Nullable(String),
  `inserted_at` Nullable(DateTime64(6))
)
ENGINE = MergeTree
PARTITION BY toDate(inserted_at)
ORDER BY (project, timestamp)
SETTINGS index_granularity = 8192;
