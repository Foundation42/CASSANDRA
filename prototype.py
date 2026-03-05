import nltk
from nltk.corpus import wordnet as wn
import numpy as np
from collections import defaultdict
import random
import os
import pickle
import json
from datetime import datetime, timezone

nltk.download('wordnet', quiet=True)
nltk.download('omw-1.4', quiet=True)

from nltk.stem import WordNetLemmatizer
_lemmatizer = WordNetLemmatizer()


def load_glove(path, embedding_dim=50):
    """Load GloVe vectors from file. Returns dict of word -> numpy array."""
    print(f"Loading GloVe vectors from {path}...")
    embeddings = {}
    with open(path, 'r', encoding='utf-8') as f:
        for line in f:
            parts = line.split()
            word = parts[0]
            vec = np.array(parts[1:], dtype=np.float32)
            if len(vec) == embedding_dim:
                embeddings[word] = vec / np.linalg.norm(vec)  # pre-normalize
    print(f"Loaded {len(embeddings)} GloVe vectors (dim={embedding_dim})")
    return embeddings


def synset_to_glove_key(synset):
    """Try to find a GloVe key for a WordNet synset.

    Strategy: try the first lemma name, lowercased, with underscores replaced.
    Multi-word expressions get averaged if individual words exist.
    """
    lemma = synset.lemma_names()[0].lower().replace('_', ' ')
    return lemma


class ConceptNucleus:
    def __init__(self, synset, anchor_embedding):
        self.synset = synset
        self.name = synset.name()
        self.anchor = anchor_embedding.copy()

        self.exemplars = []  # list of (embedding, context_text, count)
        self.uncertainty = 1.0
        self.update_count = 0

    def distance_to_anchor(self, embedding):
        return 1 - np.dot(self.anchor, embedding)  # cosine distance

    def distance_to_exemplars(self, embedding):
        if not self.exemplars:
            return float('inf')
        distances = [1 - np.dot(embedding, ex[0]) for ex in self.exemplars]
        return min(distances)

    def surprise(self, embedding):
        """Higher = more surprising/different from this concept"""
        d_anchor = self.distance_to_anchor(embedding)
        d_exemplars = self.distance_to_exemplars(embedding)
        return min(d_anchor, d_exemplars) / self.uncertainty

    def update(self, embedding, context_words, threshold=0.2):
        self.update_count += 1
        surprisal = self.surprise(embedding)

        if surprisal > threshold:
            self.exemplars.append((embedding.copy(), context_words, 1))
            self.uncertainty = min(2.0, self.uncertainty * 1.1)
            return surprisal, True
        else:
            self.uncertainty *= 0.95
            return surprisal, False

    def __repr__(self):
        return (
            f"<Nucleus {self.name} | exemplars: {len(self.exemplars)} "
            f"| uncertainty: {self.uncertainty:.2f}>"
        )


class WordNetNucleusModel:
    def __init__(self, glove_path, embedding_dim=50, pos_filter=['n'],
                 max_synsets=None):
        self.embedding_dim = embedding_dim
        self.glove = load_glove(glove_path, embedding_dim)
        self.nuclei = {}
        self.word_to_nuclei = defaultdict(list)  # word -> list of nucleus names

        self._init_nuclei(pos_filter, max_synsets)
        self._build_anchor_matrix()

    def _build_anchor_matrix(self):
        """Build a matrix of all anchor embeddings for vectorized search."""
        self._nucleus_names = list(self.nuclei.keys())
        self._anchor_matrix = np.array(
            [self.nuclei[name].anchor for name in self._nucleus_names]
        )  # shape: (N, dim)
        print(f"Built anchor matrix: {self._anchor_matrix.shape}")

    def _get_embedding(self, text):
        """Get embedding for a word or phrase. Averages tokens for phrases."""
        words = text.lower().split()
        vecs = [self.glove[w] for w in words if w in self.glove]
        if not vecs:
            return None
        avg = np.mean(vecs, axis=0)
        return avg / np.linalg.norm(avg)

    def _init_nuclei(self, pos_filter, max_synsets):
        """Create nuclei from WordNet synsets, anchored by GloVe vectors."""
        print("Creating nuclei from WordNet...")
        created = 0
        skipped = 0

        for synset in wn.all_synsets(pos=pos_filter[0]):
            if max_synsets and created >= max_synsets:
                break

            lemma_text = synset_to_glove_key(synset)
            embedding = self._get_embedding(lemma_text)

            if embedding is None:
                skipped += 1
                continue

            nucleus = ConceptNucleus(synset, embedding)
            self.nuclei[synset.name()] = nucleus

            # Index all lemma names for this synset
            for lemma_name in synset.lemma_names():
                key = lemma_name.lower().replace('_', ' ')
                self.word_to_nuclei[key].append(synset.name())

            created += 1

        print(f"Created {created} nuclei (skipped {skipped} without GloVe match)")

    def find_nuclei_for_word(self, word):
        """Find all nuclei associated with a word (handles polysemy).

        Tries the raw word first, then lemmatized forms (noun, verb, adj)
        so that plurals like 'prices' match 'price', etc.
        """
        key = word.lower().strip()
        names = self.word_to_nuclei.get(key, [])
        if not names:
            # Try lemmatized forms
            for pos in ('n', 'v', 'a'):
                lemma = _lemmatizer.lemmatize(key, pos=pos)
                if lemma != key:
                    names = self.word_to_nuclei.get(lemma, [])
                    if names:
                        break
        return [self.nuclei[n] for n in names if n in self.nuclei]

    def find_closest_nucleus(self, embedding, candidates=None):
        """Which nucleus is this embedding closest to?"""
        if candidates:
            # Small candidate list — just loop
            best_dist = float('inf')
            best_nucleus = None
            for nucleus in candidates:
                dist = nucleus.distance_to_anchor(embedding)
                if dist < best_dist:
                    best_dist = dist
                    best_nucleus = nucleus
            return best_nucleus, best_dist

        # Vectorized search over all anchors: cosine distance = 1 - dot product
        similarities = self._anchor_matrix @ embedding
        best_idx = np.argmax(similarities)
        best_name = self._nucleus_names[best_idx]
        best_dist = 1 - similarities[best_idx]
        return self.nuclei[best_name], float(best_dist)

    def process_observation(self, word, context_words):
        """Process a word occurrence in context.

        Creates a context embedding by averaging GloVe vectors of context words.
        Routes to the best-matching nucleus for this word.
        """
        context_embedding = self._get_embedding(' '.join(context_words))
        if context_embedding is None:
            return None

        # First, try to find nuclei specifically for this word (polysemy-aware)
        candidates = self.find_nuclei_for_word(word)

        if candidates:
            closest, dist = self.find_closest_nucleus(
                context_embedding, candidates
            )
        else:
            # Fall back to global search
            closest, dist = self.find_closest_nucleus(context_embedding)

        if closest:
            surprisal, stored = closest.update(context_embedding, context_words)
            return {
                'word': word,
                'nucleus': closest.name,
                'distance': dist,
                'surprise': surprisal,
                'stored_exemplar': stored,
                'context': context_words,
            }
        return None

    def get_stats(self):
        """Return model statistics."""
        total_exemplars = sum(len(n.exemplars) for n in self.nuclei.values())
        active_nuclei = sum(1 for n in self.nuclei.values() if n.update_count > 0)
        return {
            'total_nuclei': len(self.nuclei),
            'active_nuclei': active_nuclei,
            'total_exemplars': total_exemplars,
            'avg_uncertainty': float(
                np.mean([n.uncertainty for n in self.nuclei.values()])
            ),
        }

    def save(self, path):
        """Save model state to disk (nuclei states, not GloVe vectors)."""
        state = {}
        for name, nucleus in self.nuclei.items():
            state[name] = {
                'update_count': nucleus.update_count,
                'uncertainty': nucleus.uncertainty,
                'exemplars': [(e[0].tolist(), e[1], e[2]) for e in nucleus.exemplars],
            }
        with open(path, 'wb') as f:
            pickle.dump(state, f)
        print(f"Saved model state ({len(state)} nuclei) to {path}")

    def load(self, path):
        """Load model state from disk, restoring nucleus states."""
        with open(path, 'rb') as f:
            state = pickle.load(f)
        restored = 0
        for name, data in state.items():
            if name in self.nuclei:
                nucleus = self.nuclei[name]
                nucleus.update_count = data['update_count']
                nucleus.uncertainty = data['uncertainty']
                nucleus.exemplars = [
                    (np.array(e[0], dtype=np.float32), e[1], e[2])
                    for e in data['exemplars']
                ]
                restored += 1
        print(f"Restored state for {restored} nuclei from {path}")

    def snapshot(self):
        """Return a serializable snapshot of current nucleus states."""
        snap = {}
        for name, nucleus in self.nuclei.items():
            if nucleus.update_count > 0:
                snap[name] = {
                    'word': nucleus.synset.lemma_names()[0].replace('_', ' '),
                    'update_count': nucleus.update_count,
                    'exemplar_count': len(nucleus.exemplars),
                    'uncertainty': float(nucleus.uncertainty),
                    'anchor': nucleus.anchor.tolist(),
                }
        return snap


def test_drive():
    glove_path = os.path.join(os.path.dirname(__file__), 'data', 'glove.6B.50d.txt')
    model = WordNetNucleusModel(glove_path, embedding_dim=50)

    print("\n" + "=" * 60)
    print("TEST 1: Polysemy - 'bank' in different contexts")
    print("=" * 60)

    bank_nuclei = model.find_nuclei_for_word('bank')
    print(f"\nNuclei for 'bank': {[n.name for n in bank_nuclei]}")

    bank_contexts = [
        ("bank", ["river", "water", "shore", "mud", "flood"]),
        ("bank", ["money", "account", "deposit", "loan", "interest"]),
        ("bank", ["river", "fishing", "stream", "rocks", "current"]),
        ("bank", ["financial", "credit", "savings", "vault", "teller"]),
        ("bank", ["steep", "hill", "slope", "erosion", "cliff"]),
        ("bank", ["investment", "mortgage", "debt", "fund", "capital"]),
    ]

    for word, context in bank_contexts:
        result = model.process_observation(word, context)
        if result:
            marker = " *NEW*" if result['stored_exemplar'] else ""
            print(
                f"  '{word}' + {context[:3]}... -> {result['nucleus']} "
                f"(dist: {result['distance']:.3f}, "
                f"surprise: {result['surprise']:.3f}){marker}"
            )

    print("\n" + "=" * 60)
    print("TEST 2: Related words converging to similar nuclei")
    print("=" * 60)

    animal_contexts = [
        ("dog", ["pet", "bark", "tail", "walk", "fetch"]),
        ("cat", ["pet", "purr", "whiskers", "sleep", "mouse"]),
        ("dog", ["guard", "bite", "chain", "yard", "loyal"]),
        ("cat", ["stray", "alley", "night", "hunt", "climb"]),
        ("horse", ["ride", "saddle", "gallop", "stable", "race"]),
        ("bird", ["fly", "nest", "wing", "song", "tree"]),
    ]

    for word, context in animal_contexts:
        result = model.process_observation(word, context)
        if result:
            marker = " *NEW*" if result['stored_exemplar'] else ""
            print(
                f"  '{word}' + {context[:3]}... -> {result['nucleus']} "
                f"(dist: {result['distance']:.3f}, "
                f"surprise: {result['surprise']:.3f}){marker}"
            )

    print("\n" + "=" * 60)
    print("TEST 3: Surprising/unusual contexts")
    print("=" * 60)

    surprise_contexts = [
        # Normal usage
        ("mouse", ["computer", "click", "cursor", "screen", "pointer"]),
        # Surprising context for mouse
        ("mouse", ["cat", "cheese", "trap", "squeak", "hole"]),
        # Normal
        ("apple", ["fruit", "red", "tree", "eat", "sweet"]),
        # Surprising
        ("apple", ["computer", "phone", "software", "silicon", "steve"]),
        # Normal
        ("python", ["snake", "reptile", "coil", "venom", "jungle"]),
        # Surprising
        ("python", ["code", "programming", "script", "import", "function"]),
    ]

    for word, context in surprise_contexts:
        result = model.process_observation(word, context)
        if result:
            marker = " *NEW*" if result['stored_exemplar'] else ""
            print(
                f"  '{word}' + {context[:3]}... -> {result['nucleus']} "
                f"(dist: {result['distance']:.3f}, "
                f"surprise: {result['surprise']:.3f}){marker}"
            )

    print("\n" + "=" * 60)
    print("Model stats:", model.get_stats())
    print("=" * 60)

    # Show active nuclei
    print("\nActive nuclei with exemplars:")
    for n in model.nuclei.values():
        if n.exemplars:
            print(f"  {n}")


if __name__ == "__main__":
    test_drive()
