# Drain Template Extraction

Drain is the algorithm that collapses thousands of repetitive log lines into a handful of structural templates. It is the foundation of pattern grouping -- without it, every unique log message would be its own group.

## The problem

These three log lines are structurally identical:

```
Connection to 10.0.0.1 timed out after 30s
Connection to 10.0.0.2 timed out after 45s
Connection to 10.0.0.3 timed out after 12s
```

They differ only in the IP address and timeout duration. A human sees "connection timeout" immediately. Drain teaches tailx to see the same thing.

## How it works

### 1. Tokenize

Split the message by whitespace into tokens.

```
["Connection", "to", "10.0.0.1", "timed", "out", "after", "30s"]
```

### 2. Classify tokens

Each token is classified as either a **literal** or a **wildcard** (`<*>`):

- **Contains any digit** -> wildcard. This catches IPs, ports, durations, counts, UUIDs, timestamps.
- **Quoted string** (starts and ends with `"`) -> wildcard.
- **Everything else** -> literal.

```
["Connection", "to", "<*>", "timed", "out", "after", "<*>"]
```

### 3. Match against existing clusters

Search existing clusters for one with:
- The same token count
- Similarity >= 0.5 (the sim_threshold)

Similarity is computed as the fraction of positions where both tokens match (both are wildcards, or both are the same literal):

```
similarity = matching_positions / total_positions
```

### 4. Merge or create

**If a match is found**: merge the new tokens into the existing cluster. Any position where the existing template has a literal but the new line has a different literal gets generalized to `<*>`.

**If no match is found**: create a new cluster with the classified tokens.

### 5. Hash the template

The final template tokens are hashed with FNV-1a to produce a `u64` template_hash. All events that map to the same template get the same hash.

```
"Connection to <*> timed out after <*>"  →  hash: 0x3a7f...
```

## Example walkthrough

**Line 1**: `Connection to 10.0.0.1 timed out after 30s`

Classified: `["Connection", "to", "<*>", "timed", "out", "after", "<*>"]`

No existing clusters. Create cluster #0.

**Line 2**: `Connection to 10.0.0.2 timed out after 45s`

Classified: `["Connection", "to", "<*>", "timed", "out", "after", "<*>"]`

Cluster #0 has 7 tokens, this has 7 tokens. Similarity = 7/7 = 1.0 >= 0.5. Match. All positions agree. Cluster #0 count becomes 2.

**Line 3**: `User logged in from 10.0.0.1 at 14:00`

Classified: `["User", "logged", "in", "from", "<*>", "at", "<*>"]`

Cluster #0 has 7 tokens, this has 7 tokens. But similarity: position 0 "Connection" vs "User" = mismatch, position 1 "to" vs "logged" = mismatch... similarity < 0.5. No match. Create cluster #1.

**Line 4**: `Error 500 on server web01`

Classified: `["Error", "<*>", "on", "server", "<*>"]`

Only 5 tokens. Cluster #0 has 7, cluster #1 has 7. Token count mismatch for both. Create cluster #2.

**Line 5**: `Error 404 on server web02`

Classified: `["Error", "<*>", "on", "server", "<*>"]`

Cluster #2 has 5 tokens, this has 5 tokens. Similarity = 5/5 = 1.0. Match. Cluster #2 count becomes 2.

## Configuration

The DrainTree is initialized with:

- **max_depth**: 4 (controls the depth of the classification tree -- in this implementation, used as a parameter but matching is linear across clusters)
- **sim_threshold**: 0.5 (minimum similarity to match an existing cluster)
- **max_clusters**: 4096 (hard limit on the number of distinct templates)

When the cluster limit is reached, new messages that don't match an existing cluster are still hashed (from their classified tokens) but don't create new clusters.

## Why these rules work

The "contains any digit -> wildcard" rule is surprisingly effective because most variable parts in log messages contain digits:

- IP addresses: `10.0.0.1`
- Ports: `5432`
- Durations: `30s`, `250ms`
- Counts: `42 items`
- HTTP status codes: `200`, `500`
- UUIDs: `550e8400-e29b-41d4-a716-446655440000`
- Timestamps: `14:23:01`
- PIDs: `[1234]`

The few variable tokens without digits (usernames, hostnames) may not get wildcarded, but they will either match literally (same user) or cause a new cluster (different user). Over time, if both forms appear, the merge step generalizes the position to `<*>`.

## Template hash

The hash function is FNV-1a over the concatenated template tokens (with space separators). This is a fast, well-distributed hash that produces a `u64` -- the `template_hash` stored on every event.

Events with the same `template_hash` are grouped together in the `GroupTable`. The hash is the primary grouping key for all downstream analysis.
