CREATE TABLE IF NOT EXISTS bench.onebrc_v1
(
    station      String,
    temperature  Float64
)
ENGINE = MergeTree
ORDER BY (station)
