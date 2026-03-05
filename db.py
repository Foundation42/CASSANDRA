"""
SQLite backend for WordNet Nucleus snapshots.

Replaces 30GB of JSON files with a normalized ~150-200MB database.
Anchors stored once per nucleus (50 × f32 = 200 bytes each).
Delta folded into observations to avoid extra joins.
"""

import sqlite3
import struct
import os
from pathlib import Path
from datetime import datetime, timezone

DB_PATH = Path(__file__).parent / 'nucleus.db'

SCHEMA = """
PRAGMA journal_mode=WAL;

CREATE TABLE IF NOT EXISTS nuclei (
    synset TEXT PRIMARY KEY,
    word   TEXT NOT NULL,
    anchor BLOB NOT NULL  -- 50 × f32 little-endian = 200 bytes
);

CREATE TABLE IF NOT EXISTS snapshots (
    id        INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp TEXT NOT NULL UNIQUE,  -- 'YYYYMMDD_HHMMSS'
    wall_time INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS observations (
    snapshot_id     INTEGER NOT NULL REFERENCES snapshots(id),
    synset          TEXT    NOT NULL REFERENCES nuclei(synset),
    update_count    INTEGER NOT NULL,
    exemplar_count  INTEGER NOT NULL,
    uncertainty     REAL    NOT NULL,
    delta           INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (snapshot_id, synset)
) WITHOUT ROWID;

CREATE TABLE IF NOT EXISTS positions (
    synset TEXT PRIMARY KEY,
    x      REAL NOT NULL,
    y      REAL NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_snapshots_walltime ON snapshots(wall_time);
"""


def pack_anchor(anchor_list):
    """Pack a list of 50 floats into a 200-byte little-endian blob."""
    return struct.pack('<50f', *anchor_list)


def unpack_anchor(blob):
    """Unpack a 200-byte blob into a list of 50 floats."""
    return list(struct.unpack('<50f', blob))


def parse_wall_time(timestamp):
    """Parse 'YYYYMMDD_HHMMSS' to Unix epoch seconds."""
    dt = datetime.strptime(timestamp, '%Y%m%d_%H%M%S').replace(tzinfo=timezone.utc)
    return int(dt.timestamp())


def get_connection(db_path=None):
    """Open a WAL-mode connection to the nucleus database."""
    path = str(db_path or DB_PATH)
    conn = sqlite3.connect(path)
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA synchronous=NORMAL")
    conn.execute("PRAGMA foreign_keys=ON")
    return conn


def ensure_schema(conn):
    """Create tables if they don't exist."""
    conn.executescript(SCHEMA)


def load_positions(conn):
    """Load all positions from the database."""
    rows = conn.execute("SELECT synset, x, y FROM positions").fetchall()
    return {synset: [x, y] for synset, x, y in rows}


def save_positions(conn, positions):
    """Write positions to the database (upsert)."""
    conn.executemany(
        "INSERT OR REPLACE INTO positions (synset, x, y) VALUES (?, ?, ?)",
        [(synset, pos[0], pos[1]) for synset, pos in positions.items()]
    )
    conn.commit()


def save_snapshot(conn, snapshot, delta, positions, timestamp):
    """Write a single snapshot + observations + positions to the database.

    Args:
        conn: SQLite connection
        snapshot: dict of synset -> {word, update_count, exemplar_count, uncertainty, anchor}
        delta: dict of synset -> hit_count
        positions: dict of synset -> [x, y]
        timestamp: 'YYYYMMDD_HHMMSS' string
    """
    wall_time = parse_wall_time(timestamp)

    # Upsert nuclei (anchor never changes, but word might be first seen)
    for synset, data in snapshot.items():
        conn.execute(
            "INSERT OR IGNORE INTO nuclei (synset, word, anchor) VALUES (?, ?, ?)",
            (synset, data['word'], pack_anchor(data['anchor']))
        )

    # Insert snapshot row
    conn.execute(
        "INSERT OR IGNORE INTO snapshots (timestamp, wall_time) VALUES (?, ?)",
        (timestamp, wall_time)
    )
    snap_id = conn.execute(
        "SELECT id FROM snapshots WHERE timestamp = ?", (timestamp,)
    ).fetchone()[0]

    # Insert observations
    rows = []
    for synset, data in snapshot.items():
        if data['update_count'] > 0:
            rows.append((
                snap_id,
                synset,
                data['update_count'],
                data['exemplar_count'],
                data['uncertainty'],
                delta.get(synset, 0),
            ))
    conn.executemany(
        "INSERT OR IGNORE INTO observations "
        "(snapshot_id, synset, update_count, exemplar_count, uncertainty, delta) "
        "VALUES (?, ?, ?, ?, ?, ?)",
        rows
    )

    # Upsert positions
    for synset, pos in positions.items():
        conn.execute(
            "INSERT OR REPLACE INTO positions (synset, x, y) VALUES (?, ?, ?)",
            (synset, pos[0], pos[1])
        )

    conn.commit()
