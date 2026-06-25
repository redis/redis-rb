# Redis Query Engine Support in redis-rb

A guide to how redis-rb exposes the **Redis Query Engine** (RediSearch, the `FT.*` command family):
the layers it is built from, the abstractions available for schemas, indexes, queries, aggregations
and hybrid search, and — most importantly — **when to reach for an abstraction and when to just call
the `ft_*` command directly**.

If you read only one thing: there are **two supported ways** to use the Query Engine and they
interoperate freely. The thin `ft_*` methods are the floor (always available, always current); the
`Schema` / `Query` / `Index` / `AggregateRequest` / hybrid builder classes sit on top to make the
common cases readable. Pick per call site — you are never locked into one.

---

## 1. Where it lives

The Query Engine is a Redis **module** (in core since Redis 8), so it lives under the modules tree
alongside JSON, not in the per-category command files:

```
lib/redis/commands/modules/search.rb                # loader + Redis::Commands::Search namespace
lib/redis/commands/modules/search/
  miscellaneous.rb     # the ft_* command methods (the floor)
  schema.rb            # Schema, SchemaDefinition, VectorFieldDefinition
  field.rb             # Field + TextField/NumericField/TagField/GeoField/GeoShapeField/VectorField
  query.rb             # Query builder + Predicate types
  index_definition.rb  # IndexDefinition, IndexType
  index.rb             # Index (the high-level object)
  aggregation.rb       # AggregateRequest, Reducers, Asc/Desc, Cursor
  hybrid.rb            # HybridSearchQuery, HybridVsimQuery, CombineResultsMethod, ...
  result.rb            # SearchResult, Document, AggregateResult + ResultParser (reply reshaping)
```

`Redis::Commands::Search` is `included` into the umbrella `Redis::Commands` module
(`lib/redis/commands.rb`), exactly like every other category, so all `ft_*` methods are available on
any `Redis` (and, by inheritance, `Redis::Cluster`) instance. See
[adding-commands.md](adding-commands.md) for the general command-DSL conventions this module follows.

---

## 2. The layers

```
            ┌─────────────────────────────────────────────────────────────┐
  Layer 3   │ Index                  high-level object: holds a schema +    │
            │  (index.rb)            prefix, exposes #add/#search/#aggregate│
            └───────────────┬─────────────────────────────────────────────┘
                            │ delegates to
            ┌───────────────▼─────────────────────────────────────────────┐
  Layer 2   │ Builders / value objects                                     │
            │  Schema, Field*      → SCHEMA args for FT.CREATE              │
            │  Query, Predicate*   → query string + option args            │
            │  IndexDefinition     → ON HASH|JSON, PREFIX, FILTER, ...      │
            │  AggregateRequest    → GROUPBY/REDUCE/SORTBY/APPLY/... args   │
            │  Hybrid*             → SEARCH/VSIM/COMBINE args               │
            └───────────────┬─────────────────────────────────────────────┘
                            │ produce arrays consumed by
            ┌───────────────▼─────────────────────────────────────────────┐
  Layer 1   │ ft_* commands (miscellaneous.rb)                             │
            │  ft_create, ft_search, ft_aggregate, ft_info, ft_dropindex,  │
            │  ft_aliasadd, ft_sugadd, ft_spellcheck, ...                  │
            │  each builds [:"FT.X", ...] and calls send_command           │
            └───────────────┬─────────────────────────────────────────────┘
                            │ reply passed through
            ┌───────────────▼─────────────────────────────────────────────┐
  Layer 0   │ ResultParser (result.rb)                                     │
            │  reshapes RESP2 arrays / RESP3 maps into SearchResult,       │
            │  Document, AggregateResult, or plain Hashes                  │
            └─────────────────────────────────────────────────────────────┘
```

Each layer is usable on its own. You can call `ft_search` with a hand-built query string and get a
fully reshaped `SearchResult` back without ever touching `Query` or `Index`. The higher layers only
ever **produce arguments** for the lower ones — they never bypass `send_command`, so error
translation, the per-connection monitor lock, and pipeline/`multi` support apply uniformly.

### Layer 1 — the `ft_*` commands (the floor)

Plain methods in `miscellaneous.rb`, one per `FT.*` command, each building a command array and
calling `send_command` (gaining `Redis::*` error translation and pipeline support):

```ruby
def ft_search(index_name, query, **options)
  args = [index_name, query]
  args << "NOCONTENT" if options[:no_content]
  # ... translate keyword options to FT.SEARCH tokens ...
  send_command(["FT.SEARCH"] + args.flatten.compact) do |reply|
    ResultParser.search(reply, with_scores: !!options[:with_scores], ...)
  end
end
```

Coverage includes: index lifecycle (`ft_create`, `ft_alter`, `ft_dropindex`, `ft_info`), search and
aggregation (`ft_search`, `ft_aggregate`, `ft_cursor_read`/`ft_cursor_del`, `ft_explain`,
`ft_profile`), suggestions (`ft_sugadd`/`ft_sugget`/`ft_suglen`/`ft_sugdel`), dictionaries
(`ft_dictadd`/`ft_dictdel`/`ft_dictdump`), synonyms (`ft_synupdate`/`ft_syndump`), aliases
(`ft_aliasadd`/`ft_aliasupdate`/`ft_aliasdel`), tag values (`ft_tagvals`), spellcheck
(`ft_spellcheck`), config (`ft_config_get`/`ft_config_set`), and hybrid search (`ft_hybrid_search`).

### Layer 0 — reply reshaping (`ResultParser`)

`result.rb` turns raw replies into Ruby objects, normalising **both** RESP2 (flat arrays) and RESP3
(native maps) to the same result so the public API is identical regardless of protocol:

- `ft_search` → **`SearchResult`** (`total`, Enumerable over **`Document`**s; each `Document` exposes
  `id`, `["field"]`, `attributes`, `score`, `payload`).
- `ft_aggregate` / `ft_cursor_read` → **`AggregateResult`** (Enumerable over row Hashes, plus
  `cursor`).
- `ft_info` / `ft_config_get` → `Hash`; `ft_syndump` → `{ term => [group_ids] }`; `ft_spellcheck` →
  `{ term => [{ "suggestion" => ..., "score" => ... }] }`.

This mirrors the RESP2/RESP3 reshaping lambdas used elsewhere in the gem (see the module note in
[migration-resp3.md](migration-resp3.md)). RESP3 is the default protocol; the RESP2 branches exist
for `protocol: 2` connections.

### Layer 2 — builders

Value objects that hold intent and emit argument arrays. They have no I/O and are independently
unit-testable (see `test/modules/search_offline_test.rb`).

**Schema / Field** — describe the index fields and render the `SCHEMA ...` clause:

```ruby
schema = Redis::Commands::Search::Schema.build do
  text_field :title, weight: 5.0, sortable: true
  numeric_field :price, sortable: true
  tag_field :category, separator: ","
  geo_field :location
  vector_field :embedding, "HNSW", type: "FLOAT32", dim: 384, distance_metric: "COSINE"
end
schema.to_args
# => ["SCHEMA", "title", "TEXT", "WEIGHT", "5.0", "SORTABLE", "price", "NUMERIC", "SORTABLE", ...]
```

`SchemaDefinition` is the block DSL; each `*_field` helper builds the matching `Field` subclass
(`TextField`, `NumericField`, `TagField`, `GeoField`, `GeoShapeField`, `VectorField`). Field classes
validate inputs early (e.g. `TextField` rejects unknown phonetic matchers; `VectorField` rejects
`sortable`/`no_index` and unknown algorithms) and own their `to_args`.

**Query** — builds the query string and the per-search option flags via a fluent/predicate API:

```ruby
query = Redis::Commands::Search::Query.build do
  and_ do
    tag(:category).eq("electronics")
    text(:title).match("phone*")
    numeric(:price).between(100, 800)
  end
end
query.paging(0, 10).sort_by(:price, :desc).return(:title, :price).with_scores
query.to_redis_args
# => ["(@category:{electronics} @title:phone* @price:[100 800])", "WITHSCORES", "SORTBY", ...]
```

Predicates (`TagEqualityPredicate`, `TextMatchPredicate`, `RangePredicate`) compose through
`PredicateCollection` so nested `and_`/`or_` blocks render correctly-parenthesised query strings.
`return_field(field, decode_field: true)` additionally drives JSON-decoding of that field in the
reshaped `Document` (consumed via `options[:decode_fields]`).

**IndexDefinition** — the `ON HASH|JSON`, `PREFIX`, `FILTER`, `LANGUAGE`, `SCORE`, `PAYLOAD` clause
for `FT.CREATE`. Use `IndexType::HASH` / `IndexType::JSON`:

```ruby
definition = Redis::Commands::Search::IndexDefinition.new(
  prefix: ["bicycle:"], index_type: Redis::Commands::Search::IndexType::JSON
)
```

**AggregateRequest** — the aggregation pipeline, with `Reducers` (`count`, `sum`, `avg`,
`count_distinct`, `quantile`, …) and `Asc`/`Desc` sort helpers:

```ruby
req = Redis::Commands::Search::AggregateRequest.new("*")
  .group_by("@category", Redis::Commands::Search::Reducers.count.as("n"))
  .sort_by(Redis::Commands::Search::Desc.new("@n"))
  .limit(0, 10)
r.ft_aggregate("idx", req)   # => AggregateResult of row Hashes
```

**Hybrid** — `HybridSearchQuery` (text leg) + `HybridVsimQuery` (vector leg) combine into a
`HybridQuery`; `CombineResultsMethod.rrf`/`.linear` choose fusion, `HybridPostProcessingConfig` adds a
post-fusion pipeline, and `HybridCursorQuery` paginates. These feed `ft_hybrid_search`.

### Layer 3 — the `Index` object

`Index` bundles a schema, optional key prefix and a `Redis` handle, and is the most ergonomic entry
point for HASH/JSON document workflows:

```ruby
index = r.create_index("idx:products", schema, prefix: "product")  # runs FT.CREATE, returns Index
index.add("p1", title: "Phone", price: 699)                        # HSET product:p1 ...
result = index.search(query)                                       # FT.SEARCH, SearchResult back
result.total                # => 1
result.first.id             # => "p1"  (the prefix is stripped back off)
result.first["price"]       # => "699"
index.info; index.drop; index.aggregate(req)                       # FT.INFO / FT.DROPINDEX / ...
```

`Index` adds genuine value over the raw commands: it remembers the prefix (so document ids round-trip
to the logical id you used in `#add`), validates field values against the schema, and accepts a
`Query` object, a query string, or a block.

---

## 3. Abstractions vs. raw `ft_*` — benefits and drawbacks

Both styles produce the same wire commands and the same reshaped results. The choice is about
**readability, safety and discoverability** versus **directness and control**.

### Benefits of the abstractions

- **Readability & intent.** `numeric(:price).between(100, 800)` and `text(:title).match("phone*")`
  read as the query they encode; a hand-written `"@price:[100 800] @title:phone*"` does not, and gets
  worse as `and_`/`or_` nesting and parenthesisation grow.
- **Correct-by-construction argument order.** `FT.CREATE`/`FT.SEARCH` are positional and order-
  sensitive (e.g. `LOAD` must precede `DIALECT`; field option tokens have a required order). The
  builders encode that ordering once, in one place, instead of at every call site.
- **Early validation.** Field classes reject invalid options before a round-trip (unknown vector
  algorithm, vector field marked `sortable`, bad phonetic matcher), turning server errors into clear
  `ArgumentError`s at build time.
- **Prefix & id round-tripping.** `Index` keeps document ids symmetric with `#add`, stripping the key
  prefix off results so callers work in their own id space.
- **Composability & testability.** Builders are pure value objects: assemble them incrementally,
  reuse them, and assert on `#to_args`/`#to_redis_args` in unit tests with no server.
- **A smoother RESP3 story.** Because results always come back as `SearchResult`/`Document`/
  `AggregateResult`, calling code is insulated from RESP2-vs-RESP3 reply-shape differences.

### Drawbacks of the abstractions

- **Another API to learn**, partly parallel to the Redis command reference — two mental models
  (`Query#sort_by` vs the `SORTBY` token).
- **Coverage lag.** New `FT.*` flags or whole query-syntax features (vector operators, modifiers,
  brand-new clauses) may not have a builder method yet; the builder can become the limiting factor.
- **Leaky abstraction for advanced syntax.** Vector/KNN clauses, complex modifiers and the full query
  grammar are still expressed as raw strings even inside `Query`, so the abstraction does not cover
  everything and you end up mixing styles.
- **Indirection when debugging.** Reproducing a failure in `redis-cli` means mentally rendering the
  builder to tokens (or printing `to_redis_args` first).
- **Light behavioural assumptions.** Niceties like prefix stripping and field decoding are
  conveniences that occasionally need to be understood (e.g. when an id legitimately contains the
  prefix string).

### Benefits of calling `ft_*` directly

- **One-to-one with the docs.** What you pass is what the Redis command reference documents; the
  newest flags work the day the server supports them, no gem change required.
- **Full grammar, no ceiling.** Any query string, any option, any future clause — nothing to wait
  for.
- **Less indirection.** Easiest to copy to/from `redis-cli` and to reason about on the wire.
- **Still ergonomic on the way back.** You keep the reshaped `SearchResult`/`AggregateResult` even
  with a hand-built request — the floor and the reshaping layer are independent.

### Drawbacks of calling `ft_*` directly

- **Order-sensitive, stringly-typed arguments** are easy to get subtly wrong, with errors surfacing
  only at the server.
- **No early validation**; mistakes cost a round-trip and a less obvious message.
- **Repetition.** Common query/aggregation shapes get rebuilt by hand at every call site.
- **Manual prefix/id bookkeeping** when you would otherwise let `Index` handle it.

### Rule of thumb

- **Use `Index` + `Schema` + `Query` + `AggregateRequest`** for the bread-and-butter: defining
  indexes, structured filters/sorts/paging, and standard aggregations — especially in application code
  where readability and validation pay off.
- **Drop to `ft_*` with a raw string** for advanced/edge query syntax (vector KNN, brand-new flags),
  for one-off scripts, or when you want an exact mirror of a documented command. You still get
  reshaped results.
- **Mix freely.** `index.search("(*)=>[KNN 2 @embedding $v]", params: { v: blob }, dialect: 2)` uses
  the `Index` convenience with a raw vector query — a common and recommended combination.

---

## 4. Cross-cutting notes

- **Protocol.** All parsers handle RESP2 and RESP3. RESP3 is the default; the RESP2 paths cover
  `protocol: 2` connections.
- **Default dialect (DIALECT 2).** Queries default to query **dialect 2**
  (`Redis::Commands::Search::DEFAULT_DIALECT`, in `search/dialect.rb`). The server's own built-in
  default is dialect 1; dialect 2 is the recommended baseline because it supports modern query syntax
  (vector/KNN and geoshape predicates). The default is applied on **every** path — `Query` and
  `AggregateRequest` emit `DIALECT 2`, and the raw `ft_search` / `ft_aggregate` (string form) append
  it when no dialect is given. Override per query with `Query#dialect(n)`,
  `AggregateRequest#dialect(n)` (or `AggregateRequest.new(dialect: n)`), or the `dialect:` option to
  `ft_search` / `ft_aggregate` — e.g. vector and geoshape examples pass `dialect: 2`/`dialect: 3`
  explicitly. **Exception: `FT.HYBRID`** rejects a per-command `DIALECT` token (the server errors
  with "DIALECT is not supported in FT.HYBRID"), so `ft_hybrid_search` never appends it; the dialect
  for hybrid queries is governed by the server's `search-default-dialect` config
  (`ft_config_set("DEFAULT_DIALECT", n)`).
- **db 0 only.** The Query Engine creates indexes on logical database 0; create indexes there.
- **Distributed & cluster.** `FT.*` commands are index-scoped, not key-shardable. They are **not**
  available on `Redis::Distributed` (calling them raises `NoMethodError`). `Redis::Cluster` inherits
  them via the `Commands` mixin, but the module test suite exercises standalone only.
- **Pipelines/transactions.** Because every `ft_*` method goes through `send_command`, the commands
  work inside `pipelined`/`multi` blocks (each call returns a `Future`); the reshaping block runs when
  the batch resolves.

## 5. Testing

The shared suite lives in `test/lint/search.rb` (`Lint::Search`) and runs against a module-capable
server via `test/modules/commands_on_search_test.rb` (`Helper::Modules` + `require_module("search")`).
Server-free builder/parser tests live in `test/modules/search_offline_test.rb`. Run with:

```sh
bundle exec rake test:modules TEST=test/modules/commands_on_search_test.rb   # live (needs FT.*)
bundle exec ruby -Ilib -Itest test/modules/search_offline_test.rb            # offline builders/parsers
```

See [adding-commands.md](adding-commands.md) for how to add a new `ft_*` command and the lint-module
testing pattern.
