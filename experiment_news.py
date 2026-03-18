"""
Experiment: Feed CASSANDRA news headlines into the WordNet Nucleus model
and visualize the resulting concept space.
"""

import os
import re
import duckdb
import numpy as np
from collections import Counter
from prototype import WordNetNucleusModel

# -- Visualization imports (deferred to avoid issues on headless systems) --
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from sklearn.manifold import TSNE


def load_news_texts(db_path):
    """Load headlines and summaries from CASSANDRA."""
    con = duckdb.connect(db_path, read_only=True)

    # Get event headlines + summaries
    events = con.sql("""
        SELECT canonical_headline, summary, event_type
        FROM events
        WHERE canonical_headline IS NOT NULL
    """).fetchall()

    # Get raw source titles
    sources = con.sql("""
        SELECT title FROM event_sources
        WHERE title IS NOT NULL
    """).fetchall()

    con.close()

    texts = []
    for headline, summary, etype in events:
        texts.append(headline)
        if summary:
            texts.append(summary)
    for (title,) in sources:
        texts.append(title)

    print(f"Loaded {len(texts)} text snippets from CASSANDRA")
    return texts


STOPWORDS = {
    'the', 'and', 'for', 'that', 'this', 'with', 'from', 'are', 'was',
    'were', 'been', 'has', 'have', 'had', 'but', 'not', 'you', 'all',
    'can', 'her', 'his', 'its', 'our', 'their', 'they', 'she', 'him',
    'who', 'how', 'what', 'when', 'where', 'which', 'will', 'would',
    'could', 'should', 'may', 'might', 'more', 'also', 'than', 'then',
    'into', 'over', 'after', 'before', 'about', 'just', 'some', 'other',
    'com', 'www', 'http', 'https', 'said', 'says', 'year', 'new',
}


def tokenize_simple(text):
    """Basic tokenization: lowercase, split on non-alpha, filter stopwords."""
    words = re.findall(r'[a-z]+', text.lower())
    return [w for w in words if len(w) > 2 and w not in STOPWORDS]


def feed_corpus(model, texts, window_size=5):
    """Feed texts through the model using a sliding context window."""
    results = []
    total_obs = 0
    skipped = 0

    for ti, text in enumerate(texts):
        if ti % 500 == 0:
            print(f"  Processing text {ti}/{len(texts)}...")
        tokens = tokenize_simple(text)
        if len(tokens) < 3:
            continue

        for i, word in enumerate(tokens):
            # Context = surrounding words (excluding target)
            start = max(0, i - window_size)
            end = min(len(tokens), i + window_size + 1)
            context = [tokens[j] for j in range(start, end) if j != i]

            if not context:
                continue

            result = model.process_observation(word, context)
            total_obs += 1

            if result:
                results.append(result)
            else:
                skipped += 1

    print(f"\nProcessed {total_obs} observations, {len(results)} routed, "
          f"{skipped} skipped (no embedding)")
    return results


def visualize_concept_space(model, results, output_path='concept_space.png'):
    """Visualize active nuclei and their exemplars using t-SNE."""

    # Collect active nuclei (those that got observations)
    active = {r['nucleus'] for r in results}
    active_nuclei = [model.nuclei[name] for name in active if name in model.nuclei]

    # Filter to nuclei with enough activity to be interesting
    interesting = [n for n in active_nuclei if n.update_count >= 3]
    interesting.sort(key=lambda n: n.update_count, reverse=True)
    top_n = interesting[:60]  # top 60 most active

    if len(top_n) < 5:
        print("Not enough active nuclei to visualize")
        return

    print(f"\nVisualizing {len(top_n)} most active nuclei...")

    # Gather all points: anchors + exemplars
    points = []
    labels = []
    point_types = []  # 'anchor' or 'exemplar'
    sizes = []

    for nucleus in top_n:
        short_name = nucleus.synset.lemma_names()[0].replace('_', ' ')

        # Add anchor point
        points.append(nucleus.anchor)
        labels.append(short_name)
        point_types.append('anchor')
        sizes.append(max(20, min(200, nucleus.update_count * 3)))

        # Add exemplar points
        for emb, ctx, count in nucleus.exemplars:
            points.append(emb)
            labels.append(f"{short_name}*")
            point_types.append('exemplar')
            sizes.append(10)

    points = np.array(points)

    # t-SNE projection
    perplexity = min(30, len(points) - 1)
    tsne = TSNE(n_components=2, perplexity=perplexity, random_state=42,
                max_iter=1000)
    coords = tsne.fit_transform(points)

    # Plot
    fig, ax = plt.subplots(figsize=(18, 14))
    fig.patch.set_facecolor('#0a0a0a')
    ax.set_facecolor('#0a0a0a')

    # Plot exemplars first (behind anchors)
    for i, (x, y) in enumerate(coords):
        if point_types[i] == 'exemplar':
            ax.scatter(x, y, s=sizes[i], c='#ff6b6b', alpha=0.4,
                       edgecolors='none', zorder=1)

    # Plot anchors
    anchor_colors = plt.cm.Set2(np.linspace(0, 1, len(top_n)))
    anchor_idx = 0
    for i, (x, y) in enumerate(coords):
        if point_types[i] == 'anchor':
            nucleus = top_n[anchor_idx]
            color = anchor_colors[anchor_idx % len(anchor_colors)]
            ax.scatter(x, y, s=sizes[i], c=[color], alpha=0.9,
                       edgecolors='white', linewidth=0.5, zorder=2)

            # Label — only label top nuclei to avoid clutter
            if nucleus.update_count >= 5:
                ax.annotate(
                    labels[i], (x, y),
                    fontsize=7, color='white', alpha=0.9,
                    ha='center', va='bottom',
                    xytext=(0, 6), textcoords='offset points',
                    fontweight='bold',
                )
            anchor_idx += 1

    # Draw lines from exemplars to their anchors
    anchor_idx = 0
    exemplar_offset = 0
    for nucleus in top_n:
        ai = anchor_idx
        for ei in range(len(nucleus.exemplars)):
            idx = len(top_n) + exemplar_offset + ei
            if idx < len(coords):
                ax.plot(
                    [coords[ai][0], coords[idx][0]],
                    [coords[ai][1], coords[idx][1]],
                    color='#ff6b6b', alpha=0.15, linewidth=0.5, zorder=0,
                )
        exemplar_offset += len(nucleus.exemplars)
        anchor_idx += 1

    ax.set_title('WordNet Nucleus Concept Space — CASSANDRA News Feed',
                 fontsize=16, color='white', pad=20)
    ax.tick_params(colors='#333333')
    for spine in ax.spines.values():
        spine.set_visible(False)

    # Legend
    from matplotlib.lines import Line2D
    legend_elements = [
        Line2D([0], [0], marker='o', color='w', markerfacecolor='#66c2a5',
               markersize=10, label='Anchor (synset)', linestyle='None'),
        Line2D([0], [0], marker='o', color='w', markerfacecolor='#ff6b6b',
               markersize=6, label='Exemplar (surprising context)',
               linestyle='None'),
    ]
    ax.legend(handles=legend_elements, loc='upper right', fontsize=9,
              facecolor='#1a1a1a', edgecolor='#333', labelcolor='white')

    plt.tight_layout()
    plt.savefig(output_path, dpi=150, bbox_inches='tight',
                facecolor=fig.get_facecolor())
    plt.close()
    print(f"Saved visualization to {output_path}")


def print_report(model, results):
    """Print a summary of what the model learned."""
    # Most active nuclei
    active = [(n.name, n.update_count, len(n.exemplars), n.uncertainty)
              for n in model.nuclei.values() if n.update_count > 0]
    active.sort(key=lambda x: x[1], reverse=True)

    print("\n" + "=" * 60)
    print("TOP 20 MOST ACTIVATED NUCLEI")
    print("=" * 60)
    print(f"{'Synset':<35} {'Hits':>5} {'Exemplars':>9} {'Uncert':>7}")
    print("-" * 60)
    for name, count, exemplars, unc in active[:20]:
        synset_word = name.split('.')[0].replace('_', ' ')
        print(f"{synset_word:<35} {count:>5} {exemplars:>9} {unc:>7.3f}")

    # Surprise distribution
    surprises = [r['surprise'] for r in results]
    stored = [r for r in results if r['stored_exemplar']]
    print(f"\n{'Surprise statistics':}")
    print(f"  Mean surprise: {np.mean(surprises):.4f}")
    print(f"  Median surprise: {np.median(surprises):.4f}")
    print(f"  Max surprise: {np.max(surprises):.4f}")
    print(f"  Exemplars stored: {len(stored)} / {len(results)} "
          f"({100*len(stored)/len(results):.1f}%)")

    # Most surprising observations
    stored.sort(key=lambda r: r['surprise'], reverse=True)
    print(f"\nTOP 10 MOST SURPRISING OBSERVATIONS:")
    print("-" * 60)
    for r in stored[:10]:
        ctx = ' '.join(r['context'][:4])
        print(f"  '{r['word']}' [{ctx}...] -> {r['nucleus']} "
              f"(surprise: {r['surprise']:.3f})")

    # Which words triggered the most different nuclei?
    word_nuclei = {}
    for r in results:
        word_nuclei.setdefault(r['word'], set()).add(r['nucleus'])
    polysemous = [(w, len(ns), ns) for w, ns in word_nuclei.items() if len(ns) > 1]
    polysemous.sort(key=lambda x: x[1], reverse=True)

    print(f"\nTOP 10 MOST POLYSEMOUS WORDS (routed to multiple nuclei):")
    print("-" * 60)
    for word, count, nuclei in polysemous[:10]:
        nlist = ', '.join(sorted(nuclei)[:4])
        if len(nuclei) > 4:
            nlist += f' +{len(nuclei)-4} more'
        print(f"  '{word}' -> {count} nuclei: {nlist}")


def main():
    glove_path = os.path.join(os.path.dirname(__file__), 'data', 'glove.6B.50d.txt')
    db_path = os.path.expanduser('~/dev/CASSANDRA/data/cassandra.duckdb')

    # Build model
    model = WordNetNucleusModel(glove_path, embedding_dim=50)

    # Load and feed news
    texts = load_news_texts(db_path)
    results = feed_corpus(model, texts)

    # Report
    print_report(model, results)

    # Visualize
    output_path = os.path.join(os.path.dirname(__file__), 'concept_space.png')
    visualize_concept_space(model, results, output_path)

    print(f"\nFinal model stats: {model.get_stats()}")


if __name__ == '__main__':
    main()
