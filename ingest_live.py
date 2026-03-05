#!/usr/bin/env python3
"""
Continuous RSS ingest for WordNet Nucleus.

Round-robins through feeds, drip-feeding headlines in small batches so the
viewer sees gradual changes rather than big jumps.

Flow:
  1. Fetch one feed (e.g. 80 headlines)
  2. Chunk into batches of --batch-size (default 10)
  3. For each batch: feed model → save snapshot → sleep --interval seconds
  4. Move to next feed, repeat

With 8 feeds averaging ~80 headlines each, batch=10, interval=6:
  ~8 batches per feed × 6s = ~48s per feed, full cycle ~6 min.

Usage:
    python ingest_live.py                        # defaults
    python ingest_live.py --interval 3 --batch 5 # faster for testing
"""

import argparse
import os
import re
import signal
import time
from datetime import datetime, timezone

import feedparser

from hourly import (
    FEEDS, GLOVE_PATH, MODEL_STATE_PATH,
    feed_texts, load_or_compute_positions, load_recency, update_recency,
)
from db import get_connection, ensure_schema, save_snapshot as db_save_snapshot
from prototype import WordNetNucleusModel

shutting_down = False


def handle_signal(signum, frame):
    global shutting_down
    print(f"\nCaught signal {signum}, finishing current cycle...")
    shutting_down = True


def fetch_one_feed(name, url):
    """Fetch headlines from a single RSS feed."""
    headlines = []
    try:
        parsed = feedparser.parse(url)
        for entry in parsed.entries:
            title = entry.get('title', '')
            title = re.sub(r'\s*[-|]\s*[\w\s]+$', '', title)
            if title:
                headlines.append(title)
    except Exception as e:
        print(f"  Feed error ({name}): {e}")
    return headlines


def save_cycle(model, recency, delta):
    """Save model state, snapshot, delta, and positions. Returns timestamp."""
    timestamp = datetime.now(timezone.utc).strftime('%Y%m%d_%H%M%S')

    # Recency
    recency = update_recency(recency, delta)

    # Model state
    tmp_model = str(MODEL_STATE_PATH) + '.tmp'
    model.save(tmp_model)
    os.rename(tmp_model, MODEL_STATE_PATH)

    # Snapshot + positions
    snapshot = model.snapshot()
    positions = load_or_compute_positions(model)

    # Write to SQLite
    db_conn = get_connection()
    ensure_schema(db_conn)
    db_save_snapshot(db_conn, snapshot, delta, positions, timestamp)
    db_conn.close()

    return recency, timestamp


def main():
    parser = argparse.ArgumentParser(description="Continuous drip-feed RSS ingest")
    parser.add_argument("--interval", type=int, default=6,
                        help="Seconds between batches (default: 6)")
    parser.add_argument("--batch", type=int, default=10,
                        help="Headlines per batch (default: 10)")
    args = parser.parse_args()

    signal.signal(signal.SIGINT, handle_signal)
    signal.signal(signal.SIGTERM, handle_signal)

    # Load model once
    print("Loading model...")
    model = WordNetNucleusModel(str(GLOVE_PATH), embedding_dim=50)
    if MODEL_STATE_PATH.exists():
        model.load(str(MODEL_STATE_PATH))
        print(f"  Loaded existing state: {model.get_stats()}")
    else:
        print("  No existing model state — starting fresh from RSS only")

    recency = load_recency()
    n_feeds = len(FEEDS)
    print(f"Live ingest: {n_feeds} feeds, batch={args.batch}, interval={args.interval}s. Ctrl-C to stop.\n")

    feed_idx = 0

    while not shutting_down:
        name, url = FEEDS[feed_idx]
        print(f"--- [{feed_idx+1}/{n_feeds}] {name} ---")

        headlines = fetch_one_feed(name, url)
        print(f"  {len(headlines)} headlines, {(len(headlines) + args.batch - 1) // args.batch} batches")

        # Drip-feed in small batches
        for i in range(0, max(len(headlines), 1), args.batch):
            if shutting_down:
                break
            batch = headlines[i:i + args.batch]
            if not batch:
                break

            delta = feed_texts(model, batch)
            total = sum(delta.values())

            if delta:
                recency, ts = save_cycle(model, recency, delta)

                top = sorted(delta.items(), key=lambda x: x[1], reverse=True)[:3]
                names = ', '.join(f"{n}({c})" for n, c in top)
                print(f"  [{ts}] batch {i//args.batch+1}: {total} obs, {len(delta)} nuclei — {names}")
            else:
                print(f"  batch {i//args.batch+1}: (no observations)")

            # Sleep between batches
            for _ in range(args.interval):
                if shutting_down:
                    break
                time.sleep(1)

        if not headlines:
            print("  (no headlines, sleeping)")
            for _ in range(args.interval):
                if shutting_down:
                    break
                time.sleep(1)

        # Next feed
        feed_idx = (feed_idx + 1) % n_feeds

    # Graceful shutdown
    print("Saving model state before exit...")
    tmp_model = str(MODEL_STATE_PATH) + '.tmp'
    model.save(tmp_model)
    os.rename(tmp_model, MODEL_STATE_PATH)
    print("Done.")


if __name__ == '__main__':
    main()
