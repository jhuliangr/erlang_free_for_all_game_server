-- Leaderboard entries table
-- Records player session performance for the global leaderboard.
-- This migration runs automatically on server startup via leaderboard_repo:create_table/0.

CREATE TABLE IF NOT EXISTS leaderboard_entries (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    player_name TEXT NOT NULL,
    kills INTEGER NOT NULL DEFAULT 0,
    deaths INTEGER NOT NULL DEFAULT 0,
    max_level INTEGER NOT NULL DEFAULT 1,
    score INTEGER NOT NULL DEFAULT 0,
    played_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_leaderboard_score
    ON leaderboard_entries(score DESC);

CREATE INDEX IF NOT EXISTS idx_leaderboard_played_at
    ON leaderboard_entries(played_at DESC);
