# CASSANDRA

A live map of what the internet is talking about.

The system continuously reads news feeds, groups the words it finds into clusters of related concepts, and plots them on an interactive 2D map. Topics that are trending glow brighter; topics the internet has moved on from fade out. Related concepts drift closer together, giving you a weather-radar view of the news cycle at a glance.

## Architecture

```
RSS feeds ──► hourly.py (ingest) ──► nucleus.db (SQLite)
                                         │
                                         ▼
                                   viewer (Zig + Raylib)
```

- **`hourly.py`** — Fetches RSS headlines, tokenizes them, updates the nucleus model, writes snapshots and positions to SQLite.
- **`prototype.py`** — Core model: `ConceptNucleus`, `WordNetNucleusModel`, GloVe embedding loader.
- **`db.py`** — SQLite helpers (schema, snapshot storage, position I/O).
- **`viewer/`** — Real-time interactive viewer built with Zig and Raylib.
- **`render.py`** — Batch matplotlib renderer (reads saved JSON, outputs frames).
- **`make_movie.py`** — Stitches `frames/` into an MP4 via ffmpeg.

## Prerequisites

- Python 3.11+
- [Zig](https://ziglang.org/download/) (0.13+)
- [Raylib](https://www.raylib.com/) (system library)
- GloVe embeddings (see below)

### GloVe embeddings

```bash
mkdir -p data
curl -Lo data/glove.6B.zip https://nlp.stanford.edu/data/glove.6B.zip
unzip data/glove.6B.zip glove.6B.50d.txt -d data/
rm data/glove.6B.zip
```

### Python dependencies

```bash
python -m venv .venv
source .venv/bin/activate
pip install numpy scipy scikit-learn feedparser nltk matplotlib pillow
```

## Running

### 1. Ingest (hourly)

```bash
python hourly.py
```

This fetches current headlines, updates the model, and writes to `nucleus.db`. Set up a cron job or systemd timer to run it every hour:

```
0 * * * * cd /path/to/wordnets && .venv/bin/python hourly.py >> hourly.log 2>&1
```

### 2. Viewer

```bash
cd viewer
zig build run
```

The viewer reads from `nucleus.db` in real time. It polls for new snapshots on a background thread, so you can leave it running while `hourly.py` adds data.

### 3. Overlays (ships & planes)

The viewer has live overlays toggled with keyboard shortcuts:

| Key | Overlay | Source |
|-----|---------|--------|
| `S` | Ships (AIS) | Digitraffic (Finland) by default |
| `A` | Aircraft (ADS-B) | OpenSky Network |

For **global ship coverage**, set an [aisstream.io](https://aisstream.io) API key:

```bash
export AISSTREAM_API_KEY=your_key_here
```

Without it, ship data is limited to the Finnish coast via the free Digitraffic API.

### 4. Batch rendering (optional)

```bash
python render.py          # renders frames to frames/
python make_movie.py      # stitches into concept_timelapse.mp4
```

## Viewer controls

### General

| Key | Action |
|-----|--------|
| `F` / `F11` | Toggle fullscreen |
| `Home` | Reset camera (fit to screen) |
| `Esc` | Close search / clear selection |
| `P` | Toggle performance stats |

### Search

| Key | Action |
|-----|--------|
| `/` | Open search bar |
| `Esc` | Close search bar |

### Navigation & display

| Key | Action |
|-----|--------|
| `G` | Toggle physics simulation |
| `M` | Toggle geographic mode (pins concepts to map coordinates) |
| `;` / `'` | Decrease / increase geo spring strength |
| `N` | Toggle navmesh visualisation |
| `E` | Toggle edge rendering |
| `1`–`8` | Toggle visibility of colour clusters |

### Timeline

| Key | Action |
|-----|--------|
| `Space` | Play / pause timeline |
| `[` / `]` | Decrease / increase playback speed |
| `Left` / `Right` | Step backward / forward |
| `End` | Snap to live |

### Visual effects

| Key | Action |
|-----|--------|
| `T` | Toggle motion trails |
| `B` | Toggle bloom |

### Overlays

| Key | Action |
|-----|--------|
| `S` | Toggle ships (AIS) |
| `A` | Toggle aircraft (ADS-B) |

## License

See [LICENSE](LICENSE).
