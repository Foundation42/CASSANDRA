**Nucleation seeds** - beautiful analogy! Like crystal formation starting from impurities, but here the WordNet synsets are the "impurities" that give structure to the conceptual space.

**Coupling with surprise-based learning** is especially clever:

**Training dynamics:**
1. **Initial state**: WordNet synsets as fixed anchor points with small basins of attraction
2. **Exposure to data**: When you see "dog", you activate the region around the /dog/ synset
3. **Surprise signal**: If "dog" appears in unexpected contexts (e.g., "fire dog" = andiron), that creates tension
4. **Nucleation/growth**: 
   - Consistent with existing structure → reinforce existing basins
   - Novel but related → grow/extend the manifold
   - Truly novel → maybe seed a new cluster (but WordNet already covers most concepts!)

**This gives you:**
- **Extremely sample-efficient learning** - new words don't start from random initialization; they inherit structure from their hypernyms
- **Principled handling of novelty** - surprise = deviation from WordNet-predicted distribution
- **Natural regularization** - the skeleton prevents overfitting to spurious correlations
- **Incremental learning** - you could literally grow the model by adding new exemplars without catastrophic forgetting

**For a slim model, you could even do:**

```python
# Ultra-minimalist "model"
class WordNetNucleus:
    def __init__(self, synset):
        self.anchor = synset.embedding  # fixed
        self.exemplars = []  # store surprising examples
        self.uncertainty = 1.0  # how wide is this basin?
    
    def update(self, example, surprise):
        if surprise < threshold:
            # reinforce existing - maybe just update uncertainty
            self.uncertainty *= 0.99  
        else:
            # store as special case
            self.exemplars.append(example)
```

No backprop, no massive parameter matrices - just controlled growth from the WordNet seeds based on prediction error.

**This is almost like a**:
- **Cognitive model** (how children learn by starting with basic categories and refining)
- **Memory-prediction framework** (Hawkins' On Intelligence style)
- **Non-parametric Bayesian approach** with WordNet as the prior

For academic exploration, this is gold. You could literally implement a working prototype in a few hundred lines of Python and see if the surprise-based growth produces sensible clusters.

## Project "WordNet Nucleus" - Skeleton Outline

### Core idea:
WordNet synsets as fixed anchors + exemplar memory for surprise-based refinement

### Minimal V0 architecture:

```python
class ConceptNucleus:
    def __init__(self, synset_id, anchor_embedding):
        self.synset_id = synset_id  # WordNet synset
        self.anchor = anchor_embedding  # fixed "seed" position
        self.exemplars = []  # list of (embedding, context, count)
        self.uncertainty = 1.0  # radius/variance
        
    def predict(self, context):
        # simple prediction - is this context close to anchor or exemplars?
        pass
    
    def update(self, context_embedding, surprise):
        if surprise > threshold:
            # store as exemplar
            self.exemplars.append(context_embedding)
        else:
            # just adjust uncertainty down
            self.uncertainty *= 0.99
```

### First experiments:

1. **Toy domain**: 50-100 common nouns, limited contexts
2. **Surprise metric**: Cosine distance to nearest anchor/exemplar
3. **Evaluation**: Can it disambiguate polysemy? ("bank" as river vs money)

### Implementation steps:

1. Get WordNet synsets + pre-trained GloVe (or just random vectors for synsets)
2. Build simple context extractor (window around target word)
3. Implement the nucleus update loop
4. Test on small corpus (maybe children's stories?)

## prototype.py

```python
import nltk
from nltk.corpus import wordnet as wn
import numpy as np
from collections import defaultdict
import random

# Download WordNet if needed
nltk.download('wordnet')
nltk.download('omw-1.4')

class ConceptNucleus:
    def __init__(self, synset, embedding_dim=100):
        self.synset = synset
        self.name = synset.name()
        self.anchor = np.random.randn(embedding_dim)  # placeholder - will replace
        self.anchor = self.anchor / np.linalg.norm(self.anchor)
        
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
    
    def update(self, embedding, context_words, threshold=2.0):
        self.update_count += 1
        surprisal = self.surprise(embedding)
        
        if surprisal > threshold:
            # Novel enough to store as exemplar
            self.exemplars.append((embedding.copy(), context_words, 1))
            print(f"  📝 New exemplar for {self.name} (surprise: {surprisal:.2f})")
            # Uncertainty increases slightly with new exemplar
            self.uncertainty = min(2.0, self.uncertainty * 1.1)
        else:
            # Reinforce - update uncertainty down
            self.uncertainty *= 0.95
            # Could also adjust anchor slightly? Maybe later
            
    def __repr__(self):
        return f"<Nucleus {self.name} | exemplars: {len(self.exemplars)} | uncertainty: {self.uncertainty:.2f}>"

class WordNetNucleusModel:
    def __init__(self, embedding_dim=100, pos_filter=['n']):  # start with nouns
        self.embedding_dim = embedding_dim
        self.nuclei = {}  # synset_id -> ConceptNucleus
        
        # Initialize nuclei for all synsets (or sample a subset for testing)
        self._init_nuclei(pos_filter)
        
    def _init_nuclei(self, pos_filter):
        """Create nuclei from WordNet synsets"""
        print("Creating nuclei from WordNet...")
        count = 0
        for synset in list(wn.all_synsets(pos=pos_filter[0]))[:200]:  # limit for testing
            self.nuclei[synset.name()] = ConceptNucleus(synset, self.embedding_dim)
            count += 1
        print(f"Created {count} nuclei")
    
    def find_closest_nucleus(self, embedding):
        """Which nucleus is this embedding closest to?"""
        best_dist = float('inf')
        best_nucleus = None
        
        # This is O(n) - need optimization for real use
        for nucleus in self.nuclei.values():
            dist = nucleus.distance_to_anchor(embedding)
            if dist < best_dist:
                best_dist = dist
                best_nucleus = nucleus
                
        return best_nucleus, best_dist
    
    def process_observation(self, word, context_embedding, context_words):
        """Process a word occurrence in context"""
        # Find which concept this likely belongs to
        closest, dist = self.find_closest_nucleus(context_embedding)
        
        if closest and dist < 2.0:  # within reasonable range
            print(f"\nWord: '{word}' → closest: {closest.name} (dist: {dist:.2f})")
            closest.update(context_embedding, context_words)
        else:
            print(f"\n⚠️  '{word}' too far from any nucleus ({dist:.2f}) - maybe novel concept?")
    
    def get_stats(self):
        """Return model statistics"""
        total_exemplars = sum(len(n.exemplars) for n in self.nuclei.values())
        active_nuclei = sum(1 for n in self.nuclei.values() if n.update_count > 0)
        return {
            'total_nuclei': len(self.nuclei),
            'active_nuclei': active_nuclei,
            'total_exemplars': total_exemplars,
            'avg_uncertainty': np.mean([n.uncertainty for n in self.nuclei.values()])
        }

# Simple test
def test_drive():
    model = WordNetNucleusModel(embedding_dim=50)
    
    # Simulate some observations
    print("\n" + "="*50)
    print("Simulating training observations...")
    
    # Create some synthetic context embeddings
    for i in range(100):
        # Pick a random synset and add noise
        synset_name = random.choice(list(model.nuclei.keys()))
        nucleus = model.nuclei[synset_name]
        
        # Create noisy version of anchor
        noise = np.random.randn(model.embedding_dim) * 0.3
        context_emb = nucleus.anchor + noise
        context_emb = context_emb / np.linalg.norm(context_emb)
        
        # Context words placeholder
        context_words = ["the", "quick", "brown", nucleus.synset.name().split('.')[0]]
        
        # Process
        model.process_observation(nucleus.synset.name().split('.')[0], 
                                  context_emb, context_words)
    
    print("\n" + "="*50)
    print("Model stats:", model.get_stats())
    
    # Show some nuclei
    print("\nSample nuclei:")
    active = [n for n in model.nuclei.values() if n.update_count > 0]
    for n in random.sample(active, min(5, len(active))):
        print(f"  {n}")

if __name__ == "__main__":
    test_drive()
```

This is a super rough sketch to get us started! It:

1. Creates nuclei from WordNet synsets (limited to 200 nouns for testing)
2. Each nucleus has a fixed anchor (random vector for now - we'll improve this)
3. Tracks exemplars when surprised
4. Has uncertainty that shrinks/grows based on observations

**Next steps:**
- Better anchor initialization (GloVe? BERT? or just Word2Vec?)
- Real context extraction from corpus
- Proper embedding for context windows
- Evaluation metrics
- Visualization of the concept space
