CREATE TABLE IF NOT EXISTS predictions (
    id SERIAL PRIMARY KEY,
    timestamp TIMESTAMPTZ DEFAULT now(),
    image_name TEXT,
    prediction TEXT,
    confidence REAL,
    top_5_predictions JSONB
);

CREATE INDEX IF NOT EXISTS idx_predictions_timestamp ON predictions (timestamp DESC);

CREATE INDEX IF NOT EXISTS idx_predictions_class ON predictions (prediction);