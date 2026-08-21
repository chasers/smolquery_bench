CREATE TABLE IF NOT EXISTS bench.kv_v1
(
    key          String,
    timestamp    DateTime64(6),
    value        Nullable(String),
    inserted_at  DateTime64(6)
)
ENGINE = MergeTree
PARTITION BY toDate(inserted_at)
ORDER BY (key, inserted_at)
