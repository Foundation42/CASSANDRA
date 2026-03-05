#!/usr/bin/env python3
"""
Hourly runner for WordNet Nucleus — ingest only.

Each run:
  1. Loads (or creates) model state
  2. Fetches fresh RSS headlines
  3. Feeds them through the model
  4. Saves snapshot to SQLite + computes positions for new nuclei

Run via systemd timer or cron.
"""

import os
import re
import numpy as np
import feedparser
from datetime import datetime, timezone
from pathlib import Path

from sklearn.manifold import TSNE

from prototype import WordNetNucleusModel
from db import (
    get_connection, ensure_schema,
    save_snapshot as db_save_snapshot,
    load_positions as db_load_positions,
    save_positions as db_save_positions,
)

BASE_DIR = Path(__file__).parent
GLOVE_PATH = BASE_DIR / 'data' / 'glove.6B.50d.txt'
DB_PATH = Path.home() / 'dev' / 'CASSANDRA' / 'data' / 'cassandra.duckdb'
MODEL_STATE_PATH = BASE_DIR / 'model_state.pkl'

STOPWORDS = {
    'the', 'and', 'for', 'that', 'this', 'with', 'from', 'are', 'was',
    'were', 'been', 'has', 'have', 'had', 'but', 'not', 'you', 'all',
    'can', 'her', 'his', 'its', 'our', 'their', 'they', 'she', 'him',
    'who', 'how', 'what', 'when', 'where', 'which', 'will', 'would',
    'could', 'should', 'may', 'might', 'more', 'also', 'than', 'then',
    'into', 'over', 'after', 'before', 'about', 'just', 'some', 'other',
    'com', 'www', 'http', 'https', 'said', 'says', 'year', 'new',
}

FEEDS = [
    ("Layoffs (US)", "https://news.google.com/rss/search?q=layoffs+OR+%22job+cuts%22+OR+%22workforce+reduction%22&hl=en-US&gl=US&ceid=US:en"),
    ("Economy (US)", "https://news.google.com/rss/search?q=recession+OR+%22economic+slowdown%22+OR+%22consumer+spending%22&hl=en-US&gl=US&ceid=US:en"),
    ("Middle East", "https://news.google.com/rss/search?q=Iran+Israel+war+OR+%22Middle+East+conflict%22+OR+%22Strait+of+Hormuz%22&hl=en-US&gl=US&ceid=US:en"),
    ("Iran Sanctions", "https://news.google.com/rss/search?q=Iran+sanctions+OR+%22Iran+oil%22+OR+%22Iran+trade%22&hl=en-US&gl=US&ceid=US:en"),
    ("Oil & Energy", "https://news.google.com/rss/search?q=oil+price+OR+%22crude+oil%22+OR+OPEC+OR+%22energy+crisis%22&hl=en-US&gl=US&ceid=US:en"),
    ("China Economy", "https://news.google.com/rss/search?q=China+economy+OR+%22Chinese+manufacturing%22+OR+%22China+exports%22&hl=en&gl=SG&ceid=SG:en"),
    ("Geopolitical", "https://news.google.com/rss/search?q=%22geopolitical+risk%22+OR+%22trade+war%22+OR+%22military+escalation%22+OR+%22defense+spending%22&hl=en-US&gl=US&ceid=US:en"),
    ("TechCrunch", "https://techcrunch.com/feed/"),
]


def tokenize(text):
    words = re.findall(r'[a-z]+', text.lower())
    return [w for w in words if len(w) > 2 and w not in STOPWORDS]


def fetch_headlines():
    headlines = []
    for name, url in FEEDS:
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


def load_cassandra_texts():
    """Load historical baseline from CASSANDRA."""
    import duckdb
    con = duckdb.connect(str(DB_PATH), read_only=True)
    events = con.sql("""
        SELECT canonical_headline, summary FROM events
        WHERE canonical_headline IS NOT NULL
    """).fetchall()
    sources = con.sql("SELECT title FROM event_sources WHERE title IS NOT NULL").fetchall()
    con.close()
    texts = []
    for headline, summary in events:
        texts.append(headline)
        if summary:
            texts.append(summary)
    for (title,) in sources:
        texts.append(title)
    return texts


def feed_texts(model, texts, window_size=5):
    """Feed texts through model. Returns per-nucleus delta counts."""
    delta = {}  # nucleus_name -> hit count this batch
    for text in texts:
        tokens = tokenize(text)
        if len(tokens) < 3:
            continue
        for i, word in enumerate(tokens):
            start = max(0, i - window_size)
            end = min(len(tokens), i + window_size + 1)
            context = [tokens[j] for j in range(start, end) if j != i]
            if not context:
                continue
            result = model.process_observation(word, context)
            if result:
                delta[result['nucleus']] = delta.get(result['nucleus'], 0) + 1
    return delta


def compute_positions(model, top_n=200):
    """Compute stable t-SNE positions for the most active nuclei.

    Uses anchor embeddings (which never change) so positions are deterministic
    for a given set of nuclei + random seed.
    """
    # Pick the most active nuclei
    active = [(name, n.update_count) for name, n in model.nuclei.items()
              if n.update_count > 0]
    active.sort(key=lambda x: x[1], reverse=True)
    selected = [name for name, _ in active[:top_n]]

    if len(selected) < 10:
        print(f"Only {len(selected)} active nuclei, need at least 10 for layout")
        return {}

    embeddings = np.array([model.nuclei[n].anchor for n in selected])

    perp = min(30, len(selected) - 1)
    tsne = TSNE(n_components=2, perplexity=perp, random_state=42, max_iter=2000)
    coords = tsne.fit_transform(embeddings)

    positions = {}
    for i, name in enumerate(selected):
        positions[name] = [float(coords[i][0]), float(coords[i][1])]

    return positions


def load_or_compute_positions(model, conn):
    """Load positions from SQLite, add any new active nuclei."""
    positions = db_load_positions(conn)

    if not positions:
        print("Computing initial positions (first run)...")
        positions = compute_positions(model, top_n=200)
        db_save_positions(conn, positions)
        return positions

    # Add positions for any new active nuclei not yet positioned
    active = [(name, n.update_count) for name, n in model.nuclei.items()
              if n.update_count > 5 and name not in positions]
    if active:
        for name, _ in active:
            anchor = model.nuclei[name].anchor
            best_dist = float('inf')
            best_pos = [0.0, 0.0]
            for pname, pos in positions.items():
                if pname in model.nuclei:
                    d = 1 - np.dot(anchor, model.nuclei[pname].anchor)
                    if d < best_dist:
                        best_dist = d
                        best_pos = pos
            jitter = np.random.RandomState(hash(name) % 2**31).randn(2) * 0.3
            positions[name] = [best_pos[0] + jitter[0], best_pos[1] + jitter[1]]
        db_save_positions(conn, positions)
    return positions


def main():
    timestamp = datetime.now(timezone.utc).strftime('%Y%m%d_%H%M%S')
    print(f"\n{'='*60}")
    print(f"WordNet Nucleus — Hourly Run: {timestamp}")
    print(f"{'='*60}")

    # 1. Build/load model
    model = WordNetNucleusModel(str(GLOVE_PATH), embedding_dim=50)

    if MODEL_STATE_PATH.exists():
        print("Loading existing model state...")
        model.load(str(MODEL_STATE_PATH))
    else:
        print("First run — loading CASSANDRA historical baseline...")
        hist_texts = load_cassandra_texts()
        print(f"  Feeding {len(hist_texts)} historical texts...")
        feed_texts(model, hist_texts)
        print(f"  Baseline stats: {model.get_stats()}")

    # 2. Fetch and feed live headlines
    print("\nFetching live headlines...")
    headlines = fetch_headlines()
    print(f"  Got {len(headlines)} headlines")

    delta = feed_texts(model, headlines)
    total_delta = sum(delta.values())
    print(f"  Processed {total_delta} observations, {len(delta)} nuclei hit")

    # 3. Save model state
    model.save(str(MODEL_STATE_PATH))

    # 4. Build snapshot + positions, write to SQLite
    snapshot = model.snapshot()
    db_conn = get_connection()
    ensure_schema(db_conn)
    positions = load_or_compute_positions(model, db_conn)
    db_save_snapshot(db_conn, snapshot, delta, positions, timestamp)
    db_conn.close()
    print(f"  SQLite snapshot saved")

    # 5. Summary
    top_hot = sorted(delta.items(), key=lambda x: x[1], reverse=True)[:10]
    print(f"\nTop 10 hottest nuclei this run:")
    for name, count in top_hot:
        word = model.nuclei[name].synset.lemma_names()[0].replace('_', ' ')
        print(f"  {word:<30} {count:>5} hits")

    print(f"\nDone!")


if __name__ == '__main__':
    main()
