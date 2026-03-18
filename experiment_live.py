"""
Experiment: Fetch live RSS headlines, feed them into WordNet Nucleus model,
and compare against the CASSANDRA historical baseline.

Shows: what's new, what's shifting, and semantic drift detection.
"""

import os
import re
import copy
import duckdb
import feedparser
import numpy as np
from collections import defaultdict
from datetime import datetime

import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from sklearn.manifold import TSNE

from prototype import WordNetNucleusModel

# Reuse CASSANDRA's feed configs (subset for speed)
LIVE_FEEDS = [
    {
        "id": "gn_us_layoffs",
        "name": "Layoffs & Job Cuts (US)",
        "url": "https://news.google.com/rss/search?q=layoffs+OR+%22job+cuts%22+OR+%22workforce+reduction%22&hl=en-US&gl=US&ceid=US:en",
    },
    {
        "id": "gn_us_economy",
        "name": "Economic Outlook (US)",
        "url": "https://news.google.com/rss/search?q=recession+OR+%22economic+slowdown%22+OR+%22consumer+spending%22&hl=en-US&gl=US&ceid=US:en",
    },
    {
        "id": "gn_mideast_conflict",
        "name": "Middle East Conflict",
        "url": "https://news.google.com/rss/search?q=Iran+Israel+war+OR+%22Middle+East+conflict%22+OR+%22Strait+of+Hormuz%22&hl=en-US&gl=US&ceid=US:en",
    },
    {
        "id": "gn_iran_sanctions",
        "name": "Iran Sanctions & Trade",
        "url": "https://news.google.com/rss/search?q=Iran+sanctions+OR+%22Iran+oil%22+OR+%22Iran+trade%22&hl=en-US&gl=US&ceid=US:en",
    },
    {
        "id": "gn_oil_energy",
        "name": "Oil & Energy Markets",
        "url": "https://news.google.com/rss/search?q=oil+price+OR+%22crude+oil%22+OR+OPEC+OR+%22energy+crisis%22&hl=en-US&gl=US&ceid=US:en",
    },
    {
        "id": "gn_china_economy",
        "name": "China Economy",
        "url": "https://news.google.com/rss/search?q=China+economy+OR+%22Chinese+manufacturing%22+OR+%22China+exports%22&hl=en&gl=SG&ceid=SG:en",
    },
    {
        "id": "gn_geopolitical_risk",
        "name": "Geopolitical Risk",
        "url": "https://news.google.com/rss/search?q=%22geopolitical+risk%22+OR+%22trade+war%22+OR+%22military+escalation%22+OR+%22defense+spending%22&hl=en-US&gl=US&ceid=US:en",
    },
    {
        "id": "techcrunch",
        "name": "TechCrunch",
        "url": "https://techcrunch.com/feed/",
    },
]

STOPWORDS = {
    'the', 'and', 'for', 'that', 'this', 'with', 'from', 'are', 'was',
    'were', 'been', 'has', 'have', 'had', 'but', 'not', 'you', 'all',
    'can', 'her', 'his', 'its', 'our', 'their', 'they', 'she', 'him',
    'who', 'how', 'what', 'when', 'where', 'which', 'will', 'would',
    'could', 'should', 'may', 'might', 'more', 'also', 'than', 'then',
    'into', 'over', 'after', 'before', 'about', 'just', 'some', 'other',
    'com', 'www', 'http', 'https', 'said', 'says', 'year', 'new',
}


def fetch_live_headlines():
    """Fetch fresh headlines from RSS feeds."""
    headlines = []
    for feed_cfg in LIVE_FEEDS:
        print(f"  Fetching {feed_cfg['name']}...")
        try:
            parsed = feedparser.parse(feed_cfg['url'])
            for entry in parsed.entries:
                title = entry.get('title', '')
                # Strip outlet suffix (e.g. "- Reuters")
                title = re.sub(r'\s*[-|]\s*[\w\s]+$', '', title)
                if title:
                    headlines.append({
                        'text': title,
                        'feed': feed_cfg['id'],
                        'published': entry.get('published', ''),
                    })
        except Exception as e:
            print(f"    Error: {e}")

    print(f"\nFetched {len(headlines)} live headlines")
    return headlines


def tokenize(text):
    words = re.findall(r'[a-z]+', text.lower())
    return [w for w in words if len(w) > 2 and w not in STOPWORDS]


def load_cassandra_texts(db_path):
    """Load historical texts from CASSANDRA."""
    con = duckdb.connect(db_path, read_only=True)
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
    """Feed text snippets through the model. Returns results list."""
    results = []
    for text in texts:
        tokens = tokenize(text) if isinstance(text, str) else tokenize(text['text'])
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
                results.append(result)
    return results


def snapshot_model(model):
    """Take a snapshot of nucleus states for comparison."""
    snap = {}
    for name, nucleus in model.nuclei.items():
        snap[name] = {
            'update_count': nucleus.update_count,
            'exemplar_count': len(nucleus.exemplars),
            'uncertainty': nucleus.uncertainty,
        }
    return snap


def compare_snapshots(before, after, model):
    """Compare before/after snapshots to find what changed."""
    newly_activated = []
    growth = []
    uncertainty_shifts = []

    for name in after:
        b = before.get(name, {'update_count': 0, 'exemplar_count': 0, 'uncertainty': 1.0})
        a = after[name]

        delta_hits = a['update_count'] - b['update_count']
        delta_exemplars = a['exemplar_count'] - b['exemplar_count']
        delta_uncertainty = a['uncertainty'] - b['uncertainty']

        if delta_hits == 0:
            continue

        nucleus = model.nuclei[name]
        word = nucleus.synset.lemma_names()[0].replace('_', ' ')

        if b['update_count'] == 0 and a['update_count'] > 0:
            newly_activated.append((word, name, delta_hits, delta_exemplars))

        if delta_hits > 0:
            growth.append((word, name, delta_hits, delta_exemplars, delta_uncertainty))

        if abs(delta_uncertainty) > 0.01:
            uncertainty_shifts.append((word, name, delta_uncertainty, a['uncertainty']))

    return {
        'newly_activated': sorted(newly_activated, key=lambda x: x[2], reverse=True),
        'growth': sorted(growth, key=lambda x: x[2], reverse=True),
        'uncertainty_shifts': sorted(uncertainty_shifts, key=lambda x: abs(x[2]), reverse=True),
    }


def detect_semantic_drift(model, results):
    """Find words whose context embeddings are far from their WordNet anchor.

    These are candidates for meaning shift — the word is being used in ways
    WordNet didn't anticipate.
    """
    word_distances = defaultdict(list)

    for r in results:
        word_distances[r['word']].append({
            'nucleus': r['nucleus'],
            'distance': r['distance'],
            'surprise': r['surprise'],
            'context': r['context'],
        })

    drift_scores = []
    for word, observations in word_distances.items():
        if len(observations) < 2:
            continue
        avg_distance = np.mean([o['distance'] for o in observations])
        avg_surprise = np.mean([o['surprise'] for o in observations])
        max_surprise = max(o['surprise'] for o in observations)
        unique_nuclei = len(set(o['nucleus'] for o in observations))

        # Drift = high average distance from anchor + high surprise
        drift_score = avg_distance * avg_surprise * (1 + 0.1 * unique_nuclei)

        drift_scores.append({
            'word': word,
            'drift_score': drift_score,
            'avg_distance': avg_distance,
            'avg_surprise': avg_surprise,
            'max_surprise': max_surprise,
            'observations': len(observations),
            'unique_nuclei': unique_nuclei,
            'sample_contexts': observations[:3],
        })

    drift_scores.sort(key=lambda x: x['drift_score'], reverse=True)
    return drift_scores


def visualize_delta(model, before, after, live_results, output_path='concept_delta.png'):
    """Visualize the concept space highlighting what changed with live data."""

    # Find nuclei that changed
    changed = {}
    for name in after:
        b = before.get(name, {'update_count': 0})
        a = after[name]
        delta = a['update_count'] - b['update_count']
        if delta > 0:
            changed[name] = delta

    if len(changed) < 5:
        print("Not enough changed nuclei to visualize delta")
        return

    # Top changed nuclei
    top_changed = sorted(changed.items(), key=lambda x: x[1], reverse=True)[:50]
    top_names = {name for name, _ in top_changed}

    # Also include top historical nuclei for context
    historical_top = sorted(
        [(n, s['update_count']) for n, s in before.items() if s['update_count'] > 10],
        key=lambda x: x[1], reverse=True
    )[:30]
    historical_names = {name for name, _ in historical_top}

    all_names = top_names | historical_names
    nuclei_list = [model.nuclei[n] for n in all_names if n in model.nuclei]

    # Collect points
    points = []
    labels = []
    is_new = []  # was this nucleus newly activated by live data?
    heat = []    # how much did it change?

    for nucleus in nuclei_list:
        name = nucleus.name
        short = nucleus.synset.lemma_names()[0].replace('_', ' ')
        points.append(nucleus.anchor)
        labels.append(short)
        is_new.append(name in top_names and name not in historical_names)
        heat.append(changed.get(name, 0))

    points = np.array(points)

    # t-SNE
    perp = min(30, len(points) - 1)
    tsne = TSNE(n_components=2, perplexity=perp, random_state=42, max_iter=1000)
    coords = tsne.fit_transform(points)

    # Plot
    fig, ax = plt.subplots(figsize=(18, 14))
    fig.patch.set_facecolor('#0a0a0a')
    ax.set_facecolor('#0a0a0a')

    max_heat = max(heat) if max(heat) > 0 else 1

    for i, (x, y) in enumerate(coords):
        if heat[i] > 0:
            # Changed by live data — color by intensity
            intensity = heat[i] / max_heat
            color = plt.cm.hot(0.3 + 0.7 * intensity)
            size = 40 + 200 * intensity
            alpha = 0.9
            zorder = 3
        else:
            # Historical only — dim
            color = '#334455'
            size = 25
            alpha = 0.4
            zorder = 1

        marker = '*' if is_new[i] else 'o'
        ax.scatter(x, y, s=size, c=[color], alpha=alpha, marker=marker,
                   edgecolors='white' if heat[i] > 0 else 'none',
                   linewidth=0.5, zorder=zorder)

        # Label hot and new nuclei
        if heat[i] > max_heat * 0.15 or is_new[i]:
            fontsize = 7 + 3 * (heat[i] / max_heat)
            ax.annotate(
                labels[i], (x, y),
                fontsize=fontsize, color='white', alpha=0.9,
                ha='center', va='bottom',
                xytext=(0, 8), textcoords='offset points',
                fontweight='bold',
            )

    ax.set_title(
        f'WordNet Nucleus — Live Headlines Delta ({datetime.now().strftime("%Y-%m-%d %H:%M")})',
        fontsize=16, color='white', pad=20
    )
    for spine in ax.spines.values():
        spine.set_visible(False)
    ax.tick_params(colors='#333333')

    # Legend
    from matplotlib.lines import Line2D
    legend_elements = [
        Line2D([0], [0], marker='o', color='w', markerfacecolor='#ff4444',
               markersize=12, label='Hot (high live activity)', linestyle='None'),
        Line2D([0], [0], marker='*', color='w', markerfacecolor='#ff8800',
               markersize=14, label='Newly activated by live data', linestyle='None'),
        Line2D([0], [0], marker='o', color='w', markerfacecolor='#334455',
               markersize=8, label='Historical only (baseline)', linestyle='None'),
    ]
    ax.legend(handles=legend_elements, loc='upper right', fontsize=9,
              facecolor='#1a1a1a', edgecolor='#333', labelcolor='white')

    plt.tight_layout()
    plt.savefig(output_path, dpi=150, bbox_inches='tight',
                facecolor=fig.get_facecolor())
    plt.close()
    print(f"Saved delta visualization to {output_path}")


def main():
    glove_path = os.path.join(os.path.dirname(__file__), 'data', 'glove.6B.50d.txt')
    db_path = os.path.expanduser('~/dev/CASSANDRA/data/cassandra.duckdb')

    # 1. Build model and feed historical baseline
    print("=" * 60)
    print("PHASE 1: Loading historical baseline from CASSANDRA")
    print("=" * 60)
    model = WordNetNucleusModel(glove_path, embedding_dim=50)

    historical_texts = load_cassandra_texts(db_path)
    print(f"Feeding {len(historical_texts)} historical texts...")
    hist_results = feed_texts(model, historical_texts)
    print(f"Baseline: {len(hist_results)} observations processed")

    baseline_stats = model.get_stats()
    print(f"Baseline stats: {baseline_stats}")

    # 2. Snapshot before live data
    before = snapshot_model(model)

    # 3. Fetch and feed live headlines
    print("\n" + "=" * 60)
    print("PHASE 2: Fetching LIVE headlines")
    print("=" * 60)
    headlines = fetch_live_headlines()

    print(f"\nSample headlines:")
    for h in headlines[:5]:
        print(f"  [{h['feed']}] {h['text']}")

    print(f"\nFeeding {len(headlines)} live headlines into model...")
    live_results = feed_texts(model, [h['text'] for h in headlines])
    print(f"Live: {len(live_results)} observations processed")

    # 4. Snapshot after and compare
    after = snapshot_model(model)
    delta = compare_snapshots(before, after, model)

    print("\n" + "=" * 60)
    print("PHASE 3: WHAT CHANGED?")
    print("=" * 60)

    print(f"\nNewly activated nuclei (not seen in historical data):")
    print(f"{'Concept':<30} {'Hits':>5} {'New Exemplars':>13}")
    print("-" * 50)
    for word, name, hits, exemplars in delta['newly_activated'][:15]:
        print(f"  {word:<28} {hits:>5} {exemplars:>13}")

    print(f"\nMost active nuclei from live data:")
    print(f"{'Concept':<30} {'New Hits':>8} {'New Exemplars':>13} {'Uncert Shift':>12}")
    print("-" * 65)
    for word, name, hits, exemplars, du in delta['growth'][:20]:
        direction = "+" if du > 0 else ""
        print(f"  {word:<28} {hits:>8} {exemplars:>13} {direction}{du:>11.3f}")

    # 5. Semantic drift detection
    print("\n" + "=" * 60)
    print("PHASE 4: SEMANTIC DRIFT DETECTION")
    print("=" * 60)
    print("Words used in contexts far from their WordNet definitions:\n")

    drift = detect_semantic_drift(model, live_results)
    print(f"{'Word':<25} {'Drift':>6} {'Avg Dist':>8} {'Avg Surp':>8} "
          f"{'Max Surp':>8} {'Obs':>4} {'Nuclei':>6}")
    print("-" * 70)
    for d in drift[:20]:
        print(f"  {d['word']:<23} {d['drift_score']:>6.3f} {d['avg_distance']:>8.3f} "
              f"{d['avg_surprise']:>8.3f} {d['max_surprise']:>8.3f} "
              f"{d['observations']:>4} {d['unique_nuclei']:>6}")

    # Show interesting drift examples
    print("\nDrift examples (word used in unexpected ways):")
    for d in drift[:5]:
        print(f"\n  '{d['word']}' (drift: {d['drift_score']:.3f}):")
        for obs in d['sample_contexts']:
            ctx = ' '.join(obs['context'][:5])
            print(f"    -> {obs['nucleus']} [{ctx}...]")

    # 6. Visualize
    print("\n" + "=" * 60)
    print("PHASE 5: VISUALIZATION")
    print("=" * 60)
    output_path = os.path.join(os.path.dirname(__file__), 'concept_delta.png')
    visualize_delta(model, before, after, live_results, output_path)

    # Final stats
    final_stats = model.get_stats()
    print(f"\nFinal model stats: {final_stats}")
    print(f"Growth from live data:")
    print(f"  Active nuclei: {baseline_stats['active_nuclei']} -> {final_stats['active_nuclei']} "
          f"(+{final_stats['active_nuclei'] - baseline_stats['active_nuclei']})")
    print(f"  Exemplars: {baseline_stats['total_exemplars']} -> {final_stats['total_exemplars']} "
          f"(+{final_stats['total_exemplars'] - baseline_stats['total_exemplars']})")


if __name__ == '__main__':
    main()
