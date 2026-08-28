# Keyspace Notifications — Architecture & Design

This document describes the internal architecture of the keyspace/subkey notification
support in `redis` and `redis-clustering`: the components, the threading and consistency
models behind each client, the edge cases each design decision exists to handle, and the
trade-offs those decisions carry. The end-user contract lives in
[user-guide.md](user-guide.md); this document explains *why the
implementation looks the way it does*.

## 1. The three constraints that shaped everything

Every non-obvious decision below traces back to one of these facts about the transport
and the driver stack. They are worth internalizing before reading further.

**1. Pub/sub is fire-and-forget.** The server pushes a notification to whoever is
subscribed *at that instant* and forgets it. There is no backlog, no replay, no
acknowledgment of delivery. Consequence: no client-side design can guarantee zero loss
across a reconnect or a topology change. The achievable guarantee is **stream recovery
plus observability** — re-establish the subscriptions automatically, and make every gap
visible (`on_reconnect`, error handlers) so the application can reconcile. Designs are
judged by how small and how observable they make the gaps, never by pretending the gaps
don't exist.

**2. In redis-rb's subscription model, only the listener thread can read.** A
subscribed connection runs one read loop (`SubscribedClient`). Other threads
*may write* onto the socket, but every reply — including the acknowledgment of *their
own* `PSUBSCRIBE`/`PUNSUBSCRIBE` — is read by the listener thread and surfaces through
the `on.psubscribe`/`on.punsubscribe` callbacks. Consequence: "wait for the server to
acknowledge" always means "wait on shared state that the listener thread's callbacks
update", and code running *on* the listener thread (i.e. inside a notification handler)
can never wait for an acknowledgment at all — it would be waiting for itself.

The connection object itself is **not safe under concurrent read/write/teardown**: on a
connection error (or close) the driver disconnects it in place, and with hiredis that
is a native use-after-free, not a rescuable exception. `SubscribedClient` therefore
serializes reads, writes and close under one monitor, reading in short (50ms) slices so
a cross-thread write waits at most one slice — with an explicit writer-priority wait
between slices, because mutex handoff is scheduler-dependent (MRI 3.2 lets the reader
barge indefinitely otherwise). The `*_with_timeout` forms slice the same way while
preserving the caller's overall deadline.

**3. Cluster notifications are node-local.** Each cluster node emits events only for
keys it owns; events are not forwarded on the cluster bus. `redis-cluster-client`
routes `SUBSCRIBE`/`PSUBSCRIBE` to a *single* node (`PubSub#_call`), so naive pub/sub
against a cluster silently delivers ~1/N of the events. Consequence: correct cluster
support requires a subscription on **every primary**, and surviving topology changes —
for which the server provides no unsubscribe signal — becomes the client's problem.

## 2. Component map

```
lib/redis/keyspace_notifications.rb              namespace, ParseError, Redis#keyspace_notifications
lib/redis/keyspace_notifications/channels.rb     channel/pattern builders (pure functions)
lib/redis/keyspace_notifications/parser.rb       wire-format parser (pure functions)
lib/redis/keyspace_notifications/notification.rb deep-frozen value object
lib/redis/keyspace_notifications/manager.rb      standalone manager (1 connection, 1 thread)

cluster/lib/redis/cluster/keyspace_notifications.rb               cluster manager (fan-out)
cluster/lib/redis/cluster/keyspace_notifications/node_listener.rb per-primary sidecar
```

Layering — the cluster manager is built *out of* the standalone manager, not beside it:

```
                    ┌────────────────────────────────────────────┐
                    │  Channels / Parser / Notification (pure)   │
                    └────────────────────────────────────────────┘
                          ▲                            ▲
        ┌─────────────────┴─────┐      ┌───────────────┴───────────────────────┐
        │  Standalone Manager   │      │  Cluster::KeyspaceNotifications        │
        │  1 connection         │      │   ├ NodeListener (primary 1)           │
        │  1 listener thread    │◄─────│   │   └ Standalone Manager (sidecar)   │
        │  ack-then-commit      │reused│   ├ NodeListener (primary N)           │
        └───────────────────────┘ as   │   ├ SizedQueue → dispatcher thread     │
                                per-node│   └ refresher thread                   │
                                engine  └────────────────────────────────────────┘
```

Reusing the standalone manager as the per-node engine means every per-node concern —
auto-reconnect with backoff, registry replay, ack-time convergence, torn-connection
tolerance — is implemented and tested exactly once. The cluster layer adds only what is
genuinely cluster-shaped: fan-out, topology reconciliation, and cross-node dispatch.

## 3. The shared core: pure functions and one frozen object

### 3.1 Channels — builders

Six builders (`keyspace`, `keyevent`, `subkeyspace`, `subkeyevent`, `subkeyspaceitem`,
`subkeyspaceevent`) return BINARY-encoded channel strings; `glob_escape` makes a literal
key safe inside a psubscribe pattern (with the replacement built in BINARY, since a key
may combine glob metacharacters with high bytes). `subkeyspaceitem` rejects keys
containing `\n` up front — the server never emits that family for such keys, so a
subscription would be silently dead; failing at build time converts a silent no-op into
an immediate `ArgumentError`.

### 3.2 Parser — binary-safe by construction

Keys and subkeys may contain arbitrary bytes, *including every structural delimiter the
wire formats use* (`:`, `|`, `,`, `\n`). The parser therefore never splits a key or
subkey by delimiter:

- Subkey lists are **length-prefixed** (`<len>:<bytes>[,<len>:<bytes>...]`) and read
  strictly by length — content bytes are inert. Lengths are validated as digits, and
  bounds-checked against the remaining buffer *before* slicing, so malformed input
  always surfaces as the documented `ParseError` (never `RangeError`).
- Where a delimiter is structural, only the **first occurrence** is significant, and
  only on the side the grammar guarantees is delimiter-free (events never contain `|`;
  `subkeyspaceitem` keys never contain `\n` — see above).
- Non-notification channels return `nil` (not an error): the parser is also a public
  utility, usable inside a plain `psubscribe` block against mixed traffic.
- An **empty event name** is malformed (Redis never emits one — it means garbage was
  published on a notification channel) and raises `ParseError` rather than producing a
  contract-violating `Notification`. Empty *keys* stay parseable — `""` is a valid
  Redis key — as are empty subkeys.
- `ParseError` carries the raw channel and payload, so an error handler can log or
  quarantine the exact bytes.

An empty subkey is `0:`; an *absent* list is malformed. Duplicates and order are
preserved — the server's semantics, passed through.

### 3.3 Notification — deep-frozen value object

Every string field (`db` in its `"*"` form, `event`, `key`, `channel`, `payload`,
`pattern`, each subkey) is defensively copied and frozen; the object and subkey array
are frozen too. This is not stylistic: in the cluster manager, notifications are
**created on node reader threads, buffered in a queue, and consumed on the dispatcher
thread** — deep immutability is what makes that hand-off safe without any locking, and
what makes value equality (`==`/`hash`) reliable for deduplication in user code.
The copy is taken from the caller's argument (never mutated in place), so parsing
never freezes strings the caller still owns.

**Trade-off (BINARY encoding, whole layer):** keys/subkeys come back BINARY-encoded, so
comparing them against UTF-8 literals requires an `.b` on one side. Documented; the
alternative (guessing an encoding) corrupts genuinely binary keys, which is worse than
a documented comparison rule.

**Trade-off (opaque events):** events are plain strings, never an enum — new server
events flow through old client versions untouched. The cost is no compile-time typo
protection on event names; the benefit is zero forced-upgrade coupling to the server's
event vocabulary.

## 4. Standalone manager

### 4.1 Threading model

Two kinds of threads touch a manager:

| Thread | Count | Runs | Blocks on |
|---|---|---|---|
| Caller threads | any | `subscribe`, `unsubscribe`, `close`, readers | ack confirmation (condition variable, bounded 5s) |
| Listener thread | 0 or 1 | `run_listener`: the `psubscribe` read loop, ack callbacks, `dispatch`, reconnect backoff | socket read; backoff wait |

All shared state is guarded by **one `Monitor` + one condition variable**. The Monitor
(reentrant) matters because ack callbacks and in-handler API calls both run on the
listener thread while it may already hold the lock. Writes to the socket happen from
caller threads (constraint 2 allows it); every acknowledgment is observed only via the
listener's `on.psubscribe`/`on.punsubscribe` callbacks, which update `@confirmed` and
broadcast the condition variable. Waiting callers loop on the shared state with a
deadline; they also re-issue their command **at most once per listener session**
(`reissue_unconfirmed` keyed on `@session_seq`, marked only when the write went out) to
cover the window where the command was written into a session that died before acking —
re-subscribing an already-subscribed pattern is harmless (the server just re-acks). Once
per session, not per wakeup: every duplicate adds a pending acknowledgment the final-ack
gate (`@pending_acks`) must drain, so a time-based retry under a delayed listener would
keep pushing confirmation behind fresh duplicates of itself until the wait timed out.

### 4.2 State model

| Field | Meaning | Written by |
|---|---|---|
| `@handlers` | **Intent**: pattern → `Registration` (the registry; what a replay restores) | callers, listener (rollbacks) |
| `@confirmed` | **Server truth**: patterns the *current session* has acked; the value is a monotonic confirmation *generation*. Presence answers "is it subscribed?"; a re-subscribing caller's wait instead compares the generation against its install-time snapshot, so a kept-but-stale entry keeps `patterns`/`subscribed?` truthful without satisfying the replacing call | listener only |
| `@pending_acks` | pattern → wire-ordered queue of the psubscribe commands whose ack is unconsumed (each entry: the issuing blocking batch's seq, nil for batch-less writes). Acks arrive in command order, so each shifts the oldest entry — the queue names exactly which command an ack answers. A non-final ack (queue still non-empty) answers an *earlier* command than the pattern's newest and resolves nothing pattern-wide (no confirmation, no marker retirement, no revert) but still credits its own batch's retirement. Cleared with `@confirmed` at session end | writers (push at every psubscribe write), listener (shift per ack) |
| `@removing` | pattern → the exact `Registration` an in-flight unsubscribe targets | unsubscribing callers |
| `@unvalidated` | pattern → `{entry:, batch:, seq:}` for in-handler subscribes not yet acked (`seq` = issue order; map position lies once a later call re-marks a pattern). Retired when the marker's OWN command's ack token is consumed (like `@inflight_waits`). **Dies with its session**: a stale marker would win the next session's rejection attribution over the replay itself and evict a valid pattern — cross-session poison is the probing replay's to identify | listener thread |
| `@inflight_waits` | issue seq → a blocking subscribe's patterns still awaiting *their own command's* acks, until its wait exits or the last of them is consumed (credited per issued command via the `@pending_acks` tokens, not via pattern-wide confirmation). A wait is an attribution candidate only through live tokens of its own commands on the *current* session | subscribing callers, listener (per-ack credit) |
| `@opening_pending` + `@opening_seq` | the session-opening batch's unacked patterns and its position on the issue-seq axis: represents the opening replay in rejection attribution, so its rejection cannot be pinned on a command issued later. Dies with its session | listener |
| `@probe_inflight` + `@probe_replay` | probing-replay bookkeeping: when a rejection was unattributable (the batch replay itself was rejected), the next session replays one pattern per command, so the rejection lands on exactly the poisoned pattern. Dies with its session | listener |
| `@establishing` | gate refusing all writes between opening-ack tracking and the opening's first ack: nothing may precede the opening command on the wire, or `@pending_acks` order would invert against reply order | listener |
| `@rejected_wait` | the issue seq a session-killing rejection was attributed to: only the *named* waiter raises it (gated raising) — innocent waiters ride the bounce and confirm on the replay | listener |
| `@resume_reconnecting` | set when the listener died with registrations on the books: the next start is a restart after a lossy gap and runs as a reconnect (`on_reconnect` fires) | listener, unsubscribe paths |
| `@listener_error` + `@listener_error_epoch` | last session-killing error, with a counter for temporal attribution (the epoch snapshot is taken in the same lock hold that issues the command, so a waiter cannot miss its own rejection) | listener |
| `@reconnect_now`, `@closing`, `@closed` | control signals for the backoff wait and lifecycle | callers |

The separation of `@handlers` (intent) from `@confirmed` (per-session server truth) is
the backbone: `@confirmed` is cleared whenever a session ends — server-side
subscriptions die with the connection, so the client's belief must die with them — while
`@handlers` survives and drives the replay. `patterns` exposes confirmations;
`registered_patterns` exposes intent. Reconciliation logic (the cluster catch-up) must
compare against intent, because intent is what a replay will restore.

**Registration identity.** Registry values are fresh `Registration` objects per
(re-)subscription, and every ownership check compares with `equal?`, never by pattern
string. Pattern strings are ABA-vulnerable: between "capture the registration" and "act
on it", the same pattern may have been unsubscribed and re-subscribed — a *different*
subscription that happens to share a name. Object identity distinguishes "the
registration I captured" from "a same-named successor" everywhere: rollbacks refuse to
touch successors, unsubscribes refuse to delete them, ack invariants know which
registration an ack answers. The `failed` flag marks a registration dead-for-good (its
own subscribe rolled back, or an unsubscribe targeting it completed) so that a
*concurrent* failed subscribe's rollback can never resurrect it as "the previous
registration". A timed-out unsubscribe deliberately does **not** mark: there the
registration legitimately lives on and the caller retries.

**Advantages:** the entire race matrix (see §4.6) reduces to `equal?` checks; no
generation counters, no CAS loops.
**Disadvantages:** discipline — every code path must thread the captured registration
through, and a comparison by pattern string anywhere reintroduces the ABA bug (one such
bug survived until TruffleRuby's scheduler exposed it; see §4.4).

### 4.3 Consistency model: ack-then-commit

The standalone manager's contract is strong: **when `subscribe` returns, the server is
delivering and nothing after the return is missed; when it raises, no trace remains.
When `unsubscribe` returns, nothing more is delivered; when it raises, the pattern is
still fully subscribed and the call can simply be retried.**

*Subscribe* = register → write → wait → (on failure) rollback:

1. The handler is registered **before** the command is written — matching messages can
   arrive ahead of our processing of the ack, and dispatch must find the handler.
   The pre-write registration is exactly what the rollback must be able to undo.
   Installing also **snapshots the pattern's confirmation generation**: a
   (re-)subscribe demands a *fresh* acknowledgment — its wait accepts only a
   generation newer than the snapshot — because a confirmation earned by the replaced
   registration would otherwise satisfy this call's wait, reporting success for a
   command the server may still reject (e.g. permissions revoked since), with no
   waiter left to roll the poisoned registration back. The stale entry itself is
   deliberately **kept**, not deleted: the server-side subscription genuinely persists
   across a same-session replacement, so `patterns`/`subscribed?` keep reporting it
   and a failed call's rollback leaves no observable dent (deleting made a timed-out
   re-subscribe under-report the still-subscribed pattern until its late ack healed
   it). The snapshot alone is not enough when several commands for the same pattern
   are on the wire (two callers re-subscribing concurrently): the earlier command's
   ack would mint the fresh generation and satisfy the later call's wait before its
   own command is answered. Every psubscribe write therefore records one expected ack
   per pattern (`@pending_acks`), and only the **final** ack — the one draining the
   queue — mints a generation, retires validation markers, or triggers the
   unregistered-pattern revert. The queues are only truthful if they match wire
   order, which two rules guarantee: every write is sequenced and issued under the
   same lock hold, and nothing may precede the **session-opening command** on a new
   session's socket (the `@establishing` gate refuses writes until the opening's
   first ack — the subscription client becomes visible to writers a beat before the
   opening write actually reaches the socket).
2. `wait_for_confirmation` waits until every pattern is either confirmed or **no longer
   this call's** (its registration was replaced/removed by a concurrent operation — then
   it resolves to *that* operation's outcome; timing out on it would tear down the
   batch's innocent siblings).
3. On any raise, `rollback_registration` restores each pattern's previous registration
   exactly — unless that previous registration is itself `failed`, or a concurrent
   subscribe already replaced ours. Patterns the server *did* confirm before the
   failure are actively reverted (`punsubscribe`), and any ack that lands even later is
   caught by the ack-time invariant below.

*Unsubscribe* = mark → write → wait → delete:

1. The exact owned registrations are captured and marked in `@removing` **before** the
   write; the registry entry is **not** deleted yet — in-flight notifications received
   before the server's ack still belong to their handler, and a raise must leave the
   pattern subscribed.
2. The write is always the captured targets, never a blanket `PUNSUBSCRIBE` — a blanket
   would also drop patterns a concurrent subscribe added after the capture.
3. After the ack, deletion is conditional (`equal?` — don't delete a successor), the
   owned registration is marked `failed`, and a final sweep reverts any target a
   reconnect replay re-confirmed in the gap.
4. On timeout, the `@removing` marks are cleared **atomically with the raise** (inside
   the same locked section): after the raise the registration stays and the caller
   retries, so a late ack must see no mark and re-establish the subscription — clearing
   the marks in a separate step would open a window where the ack slips through with
   stale ownership and leaves the pattern deaf.

**The two ack-time invariants.** All block-less writes (caller commands, replays,
reverts, re-issues) can interleave arbitrarily on the wire. Convergence is owned by two
rules evaluated on every ack, on the listener thread:

- **psubscribe ack for a pattern nobody is registered for** → revert it
  (`punsubscribe`). Covers: rolled-back subscribes whose ack arrived late, replays
  racing unsubscribes.
- **punsubscribe ack whose pattern still has a live registration that is *not* the
  removal's target** → re-establish it (`psubscribe`). Covers: an unsubscribe aimed at
  an older, since-replaced registration whose write crossed the replacement's write on
  the wire.

Because these rules run on the only thread that observes server state transitions, and
they always steer *server state toward the registry*, any finite interleaving of writes
converges. This is the design's central invariant: **the registry is authoritative; acks
are audited against it, never trusted blindly.**

**Advantages:** the strongest guarantees a fire-and-forget transport admits; callers
never need to poll or double-check; failed calls are safely retryable.
**Disadvantages:** `subscribe`/`unsubscribe` block (bounded at 5s worst case against a
sick server); the implementation carries a genuine concurrency matrix (mitigated by the
identity discipline and by hammer tests, §7). This trade was made deliberately: for a
notifications API, "returned but not actually subscribed" is a silent-data-loss bug in
the application, which is the worst failure mode available.

### 4.4 Background actions: the reconnect loop

`run_listener` is a session loop:

```
loop:
  listen(patterns)                 # blocks in the psubscribe read loop
  ── clean exit ──────────────────  everything unsubscribed (count 0) or close
  │  recheck registry: replay any registration that is NOT an in-flight
  │  removal's own target; break only if truly empty
  ── error exit ──────────────────  translate → attribute → record → report
  clear @confirmed (session truth died), broadcast waiters
  consult reconnect schedule → interruptible backoff → replay registry
```

- **Reconnect schedule.** `reconnect_attempts` uses the same semantics as
  `Redis.new` (an Integer count of immediate retries, or an array of sleep durations,
  validated at construction — finite, non-negative reals only, because a bad value
  would otherwise surface as an exception on the listener thread after the first
  connection loss, killing the reconnect machinery instead of the caller);
  the default ladder is `[0.5, 1, 2, 4, 8, 16, 30, 30, 30, 30]` (~2 minutes). The
  manager is the schedule's **sole owner**: the connection it duplicates from the
  source client is built with `reconnect_attempts: 0` at the transport (likewise for
  the cluster sidecars), because a copied transport ladder would run *inside* every
  connect attempt — a source configured with `[30]` would stack a 30s pause under
  each manager step, and even a manager schedule of `[]` (reconnection disabled)
  would still retry at the transport. The
  budget **resets after every healthy session** (one confirmed ack), so only a
  persistent outage exhausts it — a flaky network that reconnects successfully each
  time never runs out. An empty array disables reconnection. An exhausted schedule
  leaves a dead listener with intact intent: the next `subscribe` restarts it **with
  the complete registry**, not just the new patterns — restarting with only the new
  ones would silently kill earlier subscriptions — and the restart **runs as a
  reconnect** (`on_reconnect` announces the gap the death opened). The same revival
  applies when an unsubscribe race leaves live registrations behind an exited
  listener (a timed-out removal, or a replacement that landed after the listener's
  clean-exit recheck).
- **Interruptible backoff.** The backoff waits on the shared condition variable, not
  `sleep`: `close` broadcasts to cut it short (a 30s sleep would outlive close's bounded
  joins), and a `subscribe` issued while the listener is parked sets `@reconnect_now`
  and broadcasts — the caller's 5s confirmation window must not be spent waiting out a
  30s backoff slot.
- **Replay and `on_reconnect`.** After reconnecting, the listener re-subscribes
  `@handlers.keys` and fires `on_reconnect` only once **every replayed pattern is
  confirmed or no longer registered** — an ack for an unregistered pattern is reverted
  and must not count as "live". Applications use the hook to reconcile the loss gap
  (constraint 1).
- **The clean-termination recheck** deserves its own paragraph, because it hides the
  subtlest race in the file. The read loop exits when the subscription count reaches 0 —
  which happens on the *punsubscribe ack*, while the unsubscribing caller's registry
  deletion happens *after* that ack wakes it. So at loop exit, the registry legitimately
  still contains the just-removed registration. Worse, a subscription that replaced (or
  arrived alongside) the final unsubscribe has its registration present but its ack
  never read (the loop already exited). The recheck therefore replays every
  registration **except one that is `equal?` to an in-flight removal's own target**:
  the removal's target must be skipped (replaying it would resubscribe what was just
  removed), while a *replacement under the same pattern* is a different registration
  and must be replayed — its waiter may already have returned on the replaced entry's
  stale confirmation, leaving this recheck as the only actor that can revive it. An
  earlier version compared by pattern (`@handlers.keys - @removing.keys`) and killed
  legitimate replacements; only TruffleRuby's scheduler ever interleaved the three
  threads tightly enough to expose it.
- **Session-killing `CommandError`** (e.g. an ACL-forbidden pattern): retrying cannot
  fix it, so the rejection must be *attributed* to exactly one command and resolved
  there. Subscriber-mode replies arrive **in command order**, so the rejected command
  is the **oldest outstanding one** — every candidate kind is sequenced on one
  wire-order axis (`@issue_seq`) and the oldest wins:
  - **In-handler batch** (`@unvalidated` marker): nobody waited, nobody can roll it
    back — evict exactly that batch. Age is an explicit sequence, not map order
    (re-marking keeps the original Hash position). Markers die with their session.
  - **Blocking subscribe**: candidacy only through live `@pending_acks` tokens of its
    *own* commands on the current session (a wait whose command died with an older
    session must not absorb this session's rejection; the opening command's credit
    token is the opening's, not the wait's). When named, `@rejected_wait` records the
    seq and **only that waiter raises** the rejection — gated raising. An unnamed
    waiter rides the bounce and confirms on the replay; raising to every waiter
    sharing the session rolled back valid registrations (and misled the cluster
    manager's per-pattern calls into evicting healthy patterns).
  - **The opening replay itself, or nothing attributable**: the batch names no
    culprit, so the next session is a **probing replay** — one pattern per command
    (opening carries the first; the rest go out on its first ack, tracked in
    `@probe_inflight`). The rejection then lands on a single-pattern probe: evict
    exactly that pattern (naming any wait awaiting it), re-arm probing for the
    remainder. Bounded, convergent, never drops a valid registration — and the only
    way a *long-registered* pattern whose permissions were revoked later can be
    identified (there is no marker or waiter left to blame).

  Temporal attribution is separate: `@listener_error_epoch` increments when the error
  is recorded (atomically with the attribution, in one lock hold), each wait snapshots
  the epoch **in the same hold that issues its command**, and only an error newer than
  the snapshot implicates the wait — a stale rejection from a killed session cannot
  reject a valid subscribe issued during the reconnect window, and a waiter cannot
  miss its own rejection to a scheduling gap.

### 4.5 In-handler operations (the one-shot pattern)

Calls made from inside a notification handler run on the listener thread — the only
thread that can read acknowledgments (constraint 2) — so they **cannot wait** and take
non-blocking paths:

- *In-handler `subscribe`*: registers, writes, records the registration in
  `@unvalidated` (tagged with a batch token — the call's own `installed` map, a free
  identity), returns. The ack validates and clears the marker; a session rejection
  removes the oldest batch (§4.4). The marker is only recorded if the registration is
  still the live one — a stale marker would match no future ack and be retained forever.
- *In-handler `unsubscribe`*: writes, then **commits the removal immediately** — no
  further notifications reach the handler either way, because dispatch resolves the
  handler from the live registry and drops unregistered patterns. Its `@unvalidated`
  purge and `failed`-marking mirror the blocking path; a replay racing the removal is
  reverted by the ack-time invariant.
- *In-handler `close`*: the join is guarded (`thread.equal?(Thread.current)`) — close
  from a handler skips self-join and relies on the force-close of the connection to
  terminate the loop.

**Trade-off:** in-handler subscribes lose the ack-then-commit guarantee (there is
nobody to give it to) and degrade to at-least-recorded intent plus the convergence
machinery. That is inherent to constraint 2, not a choice.

### 4.6 Edge case catalog (standalone)

| Edge case | Handling |
|---|---|
| Notification arrives before its subscribe's ack is processed | Handler registered before the command is written |
| Subscribe fails after the server confirmed some patterns | Rollback actively reverts confirmed patterns; later acks caught by invariant 1 |
| Concurrent subscribe replaces a registration mid-unsubscribe | `equal?` ownership everywhere; invariant 2 re-establishes the replacement the unsubscribe killed on the wire |
| Reconnect replay races an unsubscribe | Post-ack sweep + invariant 1 revert |
| Stale `CommandError` from a killed session vs a fresh valid subscribe | Error epochs: only errors newer than the wait's entry snapshot implicate it |
| Failed subscribe's rollback resurrects a removed registration | `failed` flag: dead registrations are never restored as "previous" |
| Block-less write races connection teardown | `write_to_session` maps `SubscriptionError`/connection errors/the driver's nil-receiver `NoMethodError` on `write` to "session gone"; registry replay owns convergence |
| `close` during a 30s reconnect backoff | Backoff waits on the condition variable; close broadcasts |
| `subscribe` while the listener is parked in backoff | `@reconnect_now` + broadcast: reconnect now instead of eating the caller's 5s window |
| `close` called from inside a handler | Self-join guard; force-close terminates the loop |
| Unsubscribe-all racing a subscribe (loop exits on count 0 without reading the new ack) | Clean-termination recheck (registration-exact) + restart-once in `wait_for_confirmation` |
| ACL-rejected pattern subscribed in-handler | Oldest-batch attribution drops exactly the poisoned batch |
| Long-registered pattern rejected on the reconnect replay (permissions revoked since) | The batch replay names no culprit → the next session is a probing replay (one pattern per command) and exactly the poisoned pattern is evicted; survivors keep flowing |
| Listener dead (schedule exhausted), then a new subscribe | Restart with the **complete** registry, run as a reconnect (`on_reconnect` announces the gap) |
| Unsubscribe timeout (or a replacement landing after the listener's clean-exit recheck) leaves live registrations behind an exited listener | `restart_dead_listener` revives it as a reconnect — otherwise the survivors would sit deaf until an unrelated subscribe |
| Write racing a new session's establishment | The `@establishing` gate refuses it (treated as "session not ready"), so nothing precedes the opening command on the wire and ack-queue order stays truthful |
| In-handler subscribe unsubscribed before its ack | Unvalidated marker purged (identity-checked) at removal |
| Re-subscribe of a confirmed pattern racing a server rejection | Install snapshots the confirmation generation and the wait demands a NEWER one, so the rejection raises instead of the call reporting success on the replaced registration's confirmation |
| Re-subscribe of a confirmed pattern fails (timeout) on a live session | The stale confirmation was kept, not deleted, at install: the rollback restores the previous registration and `patterns`/`subscribed?` never stopped reporting the still-subscribed, still-delivering pattern |
| Two concurrent re-subscribes of one pattern, the later command rejected | Confirmation is gated on `@pending_acks` draining to zero: the earlier command's ack cannot satisfy the later call's wait, so the rejection raises to that caller and its registration rolls back |
| Overlapping in-handler batches on one pattern | Batch age by sequence number, not map position — the rejection is attributed to the oldest *issued* batch even when a later call re-marked a shared pattern |
| Blocking subscribe rejected while an in-handler subscribe is in flight | All candidates share one wire-order axis: when the blocking command is oldest, attribution *names* it (`@rejected_wait`) and only its waiter raises and rolls back — the in-handler batch survives for the replay |
| In-handler rejected pattern re-subscribed by a blocking call before the error is read | Attribution marks every registration of the dropped batch `failed` — including already-replaced ones — so no later rollback can restore the rejected entry as "the previous registration"; the blocking call's own command is rejected (and named) one replay later |
| Blocking batch acked but its caller not yet resumed when a rejection arrives | Fully-acknowledged batches retire from `@inflight_waits` at ack time (on the listener thread), credited per issued command via the `@pending_acks` tokens — command-order proves an acked batch is not the rejected command, so it must not mask attribution of a younger poisoned in-handler batch, and the credit applies even when the ack is gated by an overlapping younger command; the opening replay's acks likewise credit the waits whose lost commands they re-issue |
| Error handler inspects `patterns`/`subscribed?` during the callback | Confirmations are cleared (and waiters broadcast) *before* the error reaches user code — the callback never observes the dead session as live, and a reactive refresh triggered from it sees truthful listener health |
| Command written into a session that dies before acking | Waiters re-issue unconfirmed patterns once per listener session (idempotent; bounded so retries don't stack pending acks behind the final-ack gate) |
| Handler raises / message unparseable / error handler itself raises | Reported to the error handler (or `warn`); the listener never dies from traffic; a broken error handler is swallowed |

## 5. Cluster manager

### 5.1 Why in-gem fan-out (alternatives considered)

Constraint 3 makes naive cluster pub/sub silently lossy. Alternatives evaluated:

- **`command_routings` (redis-cluster-client 0.17.0, issue #534)** — lets clients
  override routing policies per command, and an `:all_primaries` policy for
  `PSUBSCRIBE` looks like exactly this feature. Investigated against the pinned
  version: the routing table **does not reach `PubSub#_call`** (byte-identical to
  0.16.7), and the router's fan-out primitives are one-shot calls on pooled
  connections — structurally wrong for a subscription, which needs a *held* dedicated
  connection per node. An upstream PubSub fix may land eventually; this design neither
  depends on it nor conflicts with it.
- **Documenting the trap and doing nothing** — rejected: "silently receives 1/N of
  events" is the kind of bug that ships to production and is discovered by an
  inconsistency audit months later.

The inherited `Redis::Cluster#subscribe` is deliberately left untouched (no heuristic
"looks like a notification channel" guard): the manager is the correct path, and the
trap is documented.

### 5.2 Architecture and thread inventory

```
                          caller threads
                    subscribe / unsubscribe / refresh / close
                               │ (registry under @lock; fan-out outside it)
   ┌───────────────────────────┼────────────────────────────────┐
   │ NodeListener (primary 1)  │            ...                 │ NodeListener (primary N)
   │  sidecar Redis + core     │                                │
   │  Manager + reader thread ─┼──► SizedQueue ──► dispatcher ──┼──► user handlers (serial)
   └───────────────────────────┘        ▲            thread     │
                                        │                       │
                            refresher thread ◄── request_refresh (reactive, deferred, manual)
```

| Thread | Count | Role | Blocks on |
|---|---|---|---|
| Node reader (core manager listener) | N (one per primary) | read socket, parse, enqueue | socket read; **full queue** (backpressure) |
| Dispatcher | 1 | pop queue, resolve handler from live registry, invoke | empty queue |
| Refresher | 1 | topology reconciliation with backoff retry | condition variable |
| Caller threads | any | registry updates + best-effort fan-out | per-node ack (via core manager), bounded |

Each `NodeListener` owns a dedicated standalone `Redis` connection ("sidecar") wrapped
in a core `Manager` whose single handler for every pattern is an **enqueue-only proc**:
reader threads never run user code. Per-node connection loss to the *same address* is
healed by the core manager's own reconnect machinery, for free; only genuine topology
changes (node gone, demoted, replaced) need the cluster layer's refresh.

### 5.3 Consistency model: desired-state — deliberately the opposite of §4.3

The cluster registry is updated **first**, then the fan-out runs best-effort per node.
`unsubscribe` removes tracking before any node has acknowledged; `subscribe` registers
before any node has confirmed. This inverts the standalone ack-then-commit on purpose:

With N nodes, **partial failure is the normal case**, not the exception. If the
registry committed only after all N acks (ack-then-commit), one sick node would hold
the truth hostage: an unsubscribe that failed on 1 of N nodes would keep the pattern
registered, and the next refresh would *re-subscribe it on the N−1 nodes that had
already correctly dropped it* — a converging system turned oscillating. With
registry-first, every healthy node is correct immediately, and the one failed node is
reported to the error handler and converged by the next refresh, whose per-node
`catch_up` subscribes everything registered and unsubscribes everything not (comparing
against the core manager's **registered intent**, not its confirmations — a failed
unsubscribe followed by a connection drop leaves the obsolete pattern
registered-but-unconfirmed, and the reconnect replay would resurrect it if
reconciliation couldn't see it).

The registry is thus a **desired state**, and refresh is the convergence engine — the
same shape as a Kubernetes controller loop, chosen for the same reason.

**Advantages:** healthy nodes never wait for sick ones; unsubscribes cannot oscillate;
the failure surface is per-node and observable (`error_handler` receives
`(error, node_key)`).
**Disadvantages:** the caller guarantee is weaker than standalone — `subscribe`
returning means "registered and fanned out best-effort", not "every primary confirmed".
Applications needing per-node certainty watch the error handler. This asymmetry between
the two managers is documented rather than papered over, because papering over it would
mean giving the cluster API a guarantee it cannot keep.

Two post-fan-out checks close the remaining races: if a concurrent unsubscribe removed
one of our patterns mid-fan-out (our node subscriptions may have been undone after the
fact), or if **no listeners existed at all** (a previously failed refresh left none —
and with zero connections there is no error signal to drive reactive recovery), the
refresher is asked to reconcile. Finally, a close racing the call is detected after the
fan-out and raised — returning success on a closed manager would leave the caller
believing a subscription exists.

**The one failure exempt from best-effort: server rejections.** A `CommandError`
(e.g. ACL `NOPERM` on the channel) is deterministic — the pattern can never subscribe,
on this node or any other — so treating it as a per-node hiccup would leave a poison in
the registry: every future catch-up batch containing it would fail on **every**
primary, the refresh would delete those healthy listeners as "failed nodes", and the
refresher would loop forever, silencing valid patterns too. The fan-out therefore
subscribes **one pattern per per-node call**: under the core manager's gated
attribution, a `CommandError` raised there names exactly its own pattern (a session
bounce caused by another pattern's poison no longer surfaces to innocent calls), so
the culprit is identified directly — no second probing pass that would race the
reactive refresh's prune-and-rebuild of the very listener it probes. Rejected patterns
are **evicted from the registry** (unconditionally — the server rejects by name, so a
concurrently re-registered handler is just as poisoned), each rejection is reported,
and a blocking `subscribe` whose patterns were evicted **raises** — restoring the
standalone contract exactly where best-effort is the wrong model. Other per-node
failures during the same fan-out are still collected and reported per node after the
loop, never silently dropped; nodes that accepted an evicted pattern converge via the
refresher (no longer registered → unsubscribed as an extra). Rejections with no caller
to raise to — in-handler subscribes, or a node's *reconnect replay* being refused after
permissions changed — surface through the error handler and reconcile via refresh: the
node's own manager evicts the pattern locally (probing replay, §4.4), the rejection
report triggers a refresh, and the refresh's catch-up re-runs the per-pattern
identification (`evict_rejected`) to converge the canonical registry too.

### 5.4 Dispatch pipeline and parallel processing

**N readers → one bounded queue → one dispatcher.** Design properties:

- **Handlers need no thread-safety.** All user code runs serially on the dispatcher.
  This was chosen over a handler thread-pool because notification handlers
  overwhelmingly mutate shared application state (caches, maps); making every user
  synchronize would export the library's concurrency to its users. The cost is a
  throughput ceiling of one core for handler execution — acceptable because handlers
  are documented to be fast, and heavy work belongs on the application's own executor.
- **Ordering:** per-node order is preserved end-to-end (one reader per node, FIFO
  queue, serial dispatch). Cross-node order is unspecified — it is already unspecified
  at the source (independent nodes), so the queue honestly reflects the transport
  rather than pretending to a global order that doesn't exist.
- **Dispatch-time handler resolution.** Queue items carry only the (frozen)
  notification; the handler is looked up from the live registry *at dispatch time*, by
  the notification's matched pattern. Buffered events therefore honor unsubscribes and
  handler replacements that completed while they sat in the queue — an unsubscribed
  pattern's buffered backlog is dropped, never delivered to a stale handler. (The
  standalone manager gets the same property from its live-registry lookup in
  `dispatch`.)
- **Backpressure chain, end to end:** slow handler → queue fills → node readers block
  in `push` → sockets go unread → the *server's* pub/sub output buffer for those
  connections grows → the server's `client-output-buffer-limit pubsub` eventually kills
  the connection → that surfaces as a connection error → reactive refresh rebuilds the
  listener. Client memory stays bounded by `queue_size`; the overflow valve is
  deliberately the server's, which operators already size for pub/sub. The alternative
  (unbounded client queue) trades a visible, self-healing connection reset for an
  invisible OOM — the wrong trade.
- **Why one shared queue instead of per-node queues:** a single consumer draining
  multiple queues must poll or juggle condition variables across them; a shared
  `SizedQueue` gives blocking pop, a single bound, and cross-node fairness (a chatty
  node cannot starve others of *queue capacity* beyond the shared bound — it blocks
  itself). Per-node bounds would isolate a slow node's backpressure but triple the
  moving parts for a marginal gain the server-side buffer limits already provide.

### 5.5 Background actions: the refresher thread

**Why refresh gets its own thread** — the deadlock that forbids doing it on the
dispatcher: a refresh blocks on per-node subscription acks; those acks are read by node
reader threads; under backpressure the readers are blocked pushing into the full queue;
the queue drains only while the dispatcher runs. A dispatcher that performs the refresh
therefore waits on acks that can only flow while it keeps dispatching — deadlock until
the ack timeouts fire. Hence:

- **Dispatcher-thread deferral, uniformly.** All three ack-blocking entry points
  (`subscribe`, `unsubscribe`, `refresh`) detect being called on the dispatcher thread
  (i.e. from inside a handler) and defer to the refresher (`request_refresh`), which
  reconciles from the already-updated registry. One rule, three call sites, no
  special-case matrix.
- **Reactive triggers: connection failures and server rejections.** Connection loss
  implies topology work. A `CommandError` reported from a node thread is a rejected
  reconnect replay (user handlers run on the dispatcher, never on node threads) and
  implies *registry* work: the node's own manager evicted the pattern locally, and
  without a refresh the canonical registry would keep reporting a pattern no node is
  subscribed to, with no signal left to converge on. Parse errors trigger nothing —
  the listener stays healthy, and refreshing on them would let anyone publishing
  garbage on a watched channel drive cluster-wide re-subscription load.
- **Failure retry with backoff.** A failed reactive refresh reschedules itself
  (0.5s → 30s exponential): the triggering signal was already consumed, and a
  partially-rebuilt node may have **no listener thread left to emit a new one** — without
  the retry loop, a refresh that failed at the wrong moment would strand the manager
  with no recovery path. The backoff wait doubles as an interruptible sleep (a new
  `request_refresh` or `close` broadcast cuts it short).
- **The refresh algorithm** (serialized by `@refresh_lock`, which also excludes
  `close`):
  1. Enumerate primaries via the public `CLUSTER NODES` — **membership, not slot
     coverage**: `CLUSTER SLOTS` cannot show a scale-out primary that owns no slots
     yet, and the slots later moved onto it emit no error signal, so a
     slots-enumerated manager would silently miss it until an unrelated refresh.
     Membership lists zero-slot primaries, letting `refresh` attach the listener
     *before* the first migrated key. Nodes are filtered to healthy masters
     (`fail?`-suspected kept — their slots are still assigned; confirmed-`fail`,
     `noaddr`, handshaking dropped), then the view itself is validated before any
     reconciliation, always by *keeping the current listeners and raising* so the
     refresher's backoff retries:
     - a **dropped master still owning slots** is a mid-failover view (the promoted
       replica hasn't claimed the slots yet) — reconciling would succeed with N−1
       listeners and stop the reactive retries, silently missing the promotion;
     - **no slot-owning primary at all** (mid-reset, or a degraded node's view) —
       tearing every listener down would destroy the very connections whose errors
       drive reactive recovery;
     - **concealed endpoints** (empty announced IPs) fail loudly unless
       `fixed_hostname` supplies the dial target, and distinct primaries collapsing
       onto one dial target fail loudly too: one sidecar cannot listen to two nodes,
       and silently covering 1/N is the exact bug this manager exists to prevent.
  2. Under `@lock`: prune listeners for vanished/demoted nodes and any listener that
     fails `healthy?` (closed core manager, or expected-subscribed-but-isn't — covers
     exhausted reconnect budgets). Close the pruned ones outside the lock, **in
     parallel** (after a cluster-wide blip every listener is mid-reconnect, and a
     serial prune would hold the refresh lock for O(nodes) while `close` waits on it);
     failure-path listeners are likewise detached in the loop and closed together
     afterwards.
  3. Per primary, *outside* `@lock` (acks take seconds against a sick node; dispatch
     and the API must stay responsive): create a missing listener — **committed to
     `@listeners` before its catch-up**, so a racing subscribe's fan-out covers it too
     (both paths idempotent) — then `catch_up` against a registry snapshot, **looping
     until a pass ran against an unchanged registry** (bounded at 5; churn during a
     refresh is rare, so the bound is a livelock guard). If the bound exhausts with the
     registry still churning, schedule another refresh rather than silently accepting a
     possibly-stale node — the concurrent operations that kept changing the registry
     saw it already updated and requested no refresh themselves.
  4. A `CommandError` from a catch-up (which batches the node's whole registry) is
     resolved by per-pattern identification and registry eviction (`evict_rejected`;
     the refresh lock serializes it against prune-and-rebuild races) — it is a server
     rejection, not a node failure, and the connection is healthy; only an
     unattributable batch failure (every pattern succeeds individually) falls through
     to the per-node failure handling. Rejection reports discovered this way are
     **deferred until the refresh lock is released**: the error handler is user code
     that may call `close` or `refresh`, which acquire the same non-reentrant lock —
     invoked while held, that raises `ThreadError`, is swallowed by the report guard,
     and a requested close would be silently dropped. Node-level reports (the core
     managers reporting their own errors from reader threads) are deliberately *not*
     routed through a deferral pipeline: they never hold the refresh lock, so the
     failure mode there is different — a blocking error handler parks its reader,
     which stalls (bounded by the ack timeouts, then converges) rather than drops an
     in-flight refresh. Making every report asynchronous to also absorb that would
     cost a dedicated reporter thread and at-close delivery semantics for a bounded
     corner case; the documented contract instead requires error handlers to be fast
     and non-blocking, reacting asynchronously (`Thread.new { manager.close }`).
  5. Per-node failures collect into `KeyspaceNotificationsRefreshError#errors`
     (`"host:port" => exception`); the failed node's listener is removed so the next
     refresh rebuilds it from scratch.
- **No proactive polling.** Scale-out (a brand-new primary) produces no error signal —
  there is no connection to it to fail — so it requires a manual `refresh`, and this is
  documented. Polling `CLUSTER NODES` on a timer was rejected: it turns every idle
  manager into cluster-wide background load, and the polling interval becomes an
  unfixable loss-window knob (any interval is both too long for correctness and too
  short for load). Reactive + manual keeps the quiet path silent.

### 5.6 Sidecar connection derivation

Sidecars must connect to arbitrary discovered primaries with the *same effective
configuration* the cluster client uses:

- Start from the cluster client's options; strip cluster-only keys
  (`nodes`, `replica`, `replica_affinity`, `fixed_hostname`, `concurrency`,
  `connect_with_original_config`, `max_startup_sample`, `slow_command_timeout`,
  `command_routings`) and **seed addressing** (`url`, `path`, sentinel keys). `:path`
  is seed addressing too: standalone configs prefer a Unix socket over host/port, so a
  leaked `path` from a `{path: ...}` seed would silently point *every* sidecar at the
  seed socket — N subscriptions to one node.
- Credentials/TLS embedded in the first `nodes` entry are reused when no top-level
  equivalents exist (the node list is often the only place they live). The URL parsing
  is an **exact mirror of redis-cluster-client's `parse_node_url`** — including its
  form-style decoding where `+` becomes a space. Diverging toward stricter URI
  semantics locally would make sidecars fail against clusters that connect fine today;
  a semantics change belongs upstream where both sides inherit it together. (This
  coupling is one reason the gemspec pins redis-cluster-client exactly; re-audit on
  every bump.)
- `fixed_hostname` (single-endpoint TLS setups) replaces the announced IP as the dial
  target, matching the cluster client's own behavior.

### 5.7 Lifecycle edges

- **Constructor**: dispatcher and refresher spawn first, then the initial `refresh`
  runs; if it raises, the constructor `close`s before re-raising — the caller gets an
  exception, never an unreferenced object with two live threads and half a fleet of
  connections.
- **Close ordering**: the closed flag is raised (and the refresher woken) **before**
  waiting on `@refresh_lock` — an in-flight refresh holds that lock across ack-blocking
  per-node catch-ups (tens of seconds on a big cluster) and checks the flag at every
  node boundary, so it aborts promptly instead of making close sit out the full
  reconciliation. Teardown itself stays serialized under `@refresh_lock` (otherwise a
  refresh past its closed-checks could recreate subscribed listeners on a torn-down
  manager, leaking threads). Then: **close the queue before the listeners** — readers
  blocked pushing into a full queue are stuck in Ruby, not in Redis I/O, so closing
  their connections cannot unblock them, but `ClosedQueueError` from the closed queue
  does (the enqueue proc rescues it and drops) → close the listeners **in parallel**
  (each teardown joins that node's threads; they are independent, and serial closes
  would make close O(nodes)) → bounded joins with self-join guards on *both* threads
  (close may be invoked from a handler, i.e. the dispatcher, or from an error handler
  fired by a failed reactive refresh, i.e. the refresher). Queue items surviving close
  are dropped, not dispatched: the caller may have torn down handler dependencies the
  moment `close` returned.

### 5.8 Edge case catalog (cluster)

| Edge case | Handling |
|---|---|
| **Failover** (master ↔ replica swap) | Usual path: the old master's connection dies → reactive refresh prunes it (no longer a healthy master in `CLUSTER NODES`) and subscribes the promoted node; a mid-failover view (dropped master still owning slots) is rejected and retried rather than reconciled against. |
| **Demotion without disconnection** (manual `CLUSTER FAILOVER`) | No error signal; the demoted node, now a replica, re-emits every replicated write — its shard's events arrive **twice** until a refresh observes the settled topology and prunes it. Documented: handlers must tolerate duplicates. |
| **Resharding** (slots migrate between existing primaries) | **Transparent by construction**: all-primaries fan-out makes the slot→node mapping irrelevant — events arrive from whichever node owns the key now. Only node-*set* changes need refresh. |
| **Scale-out** (new primary) | No error signal exists (nothing was connected to it) → manual `refresh`, documented — and because enumeration is membership-based, refreshing *before* the reshard attaches the listener ahead of the first migrated key. |
| Node connection lost, same address | Healed by that node's core manager (backoff + replay + `catch_up` on the next refresh); no cluster-level action. |
| Node's reconnect budget exhausted | `healthy?(expect_subscribed)` fails → pruned and rebuilt by the next refresh. |
| Degraded topology view (no slot-owning primary; or a failed master still owning slots mid-failover) | Keep existing listeners (they carry the recovery signal), raise; refresher backoff retries until the view settles. |
| Server conceals node endpoints | Loud failure unless `fixed_hostname` provides the dial target — never silently subscribe to `":<port>"`. |
| Concealed primaries sharing a port under `fixed_hostname` | Distinct primaries collapsing onto one dial target → loud refresh failure instead of one listener silently covering 1/N. |
| Server-rejected pattern (e.g. ACL `NOPERM`) | Identified per-pattern, evicted from the registry, reported; a blocking `subscribe` raises. A rejection is not a node failure: refresh converges over the cleaned registry (listeners whose sessions the rejection bounced are transiently rebuilt, never destroyed in a loop) (§5.3). |
| Subscribe when zero listeners exist (a previous refresh failed completely) | Post-fan-out check requests a refresh — with no connections there is no error signal, so this is the only recovery trigger. |
| Subscribe/unsubscribe/refresh from inside a handler | Deferred to the refresher (deadlock analysis, §5.5). |
| Registry churn during a node's catch-up | Convergence loop (re-run until a pass saw an unchanged registry); if the bound exhausts, schedule another refresh — never accept a stale node silently. |
| Concurrent subscribe during refresh's listener creation | Listener committed to the map before catch-up; both the racing fan-out and the catch-up cover it (idempotent). |
| Unsubscribe fan-out crossing a concurrent re-subscribe | Post-fan-out registry check requests reconciliation. |
| `unsubscribe()` with an empty registry | Early return — an empty target list would mean "everything" at the node level and wipe patterns a concurrent subscribe just installed. |
| Failed per-node unsubscribe, then that node's connection drops | Catch-up compares against the core manager's **registered intent** (`registered_patterns`), so the obsolete registration is removed even though its confirmation vanished with the session. |
| Slow handler under high event rate | Bounded queue → reader backpressure → server output-buffer limit is the overflow valve → connection reset self-heals via reactive refresh (§5.4). |
| `close` racing `subscribe` | Post-fan-out closed-check raises instead of reporting success on a dead manager. |
| `close` from a handler or from a refresh-failure error handler | Self-join guards on dispatcher and refresher. |
| Constructor fails mid-initial-refresh | `close` before re-raise; no leaked threads/connections. |

## 6. Delivery guarantees (summary)

| Property | Standalone | Cluster |
|---|---|---|
| `subscribe` returned ⇒ server(s) delivering | Yes (acked) | Best-effort per node; failures reported, converged by refresh |
| `subscribe` raised ⇒ no trace | Yes (rollback + revert) | Server rejections raise and evict the pattern; other per-node failures are best-effort (§5.3) |
| `unsubscribe` returned ⇒ no further delivery | Yes | Yes for the dispatcher (dispatch-time registry lookup drops buffered/late events); node-level convergence via refresh |
| Events during a reconnect/topology gap | **Lost** (transport property). Observable via `on_reconnect` | **Lost**. Observable via `on_reconnect(node_key)` (fired when a node's own replay re-established its subscriptions, or when a refresh attached a listener the manager didn't have — a rebuild, a promoted replica under a new address, a scale-out primary) and the error handler; per-node gaps only |
| Ordering | Single connection: server order | Per-node preserved; cross-node unspecified |
| Handler thread-safety required | No (single listener thread) | No (single dispatcher thread) |
| Duplicate delivery | One per matching *pattern* (server semantics) | Same; plus a key migrating mid-event-stream can emit from two nodes across the migration boundary, and a primary demoted without disconnection re-emits replicated writes until a refresh prunes it |

## 7. How the edge cases are verified

Two testing policies carry most of the weight:

- **Real events only.** Manager tests never publish synthetic messages onto
  notification channels; every notification in the suites is emitted by the server in
  response to a real command (`SET`, `DEL`, `HSET`, expirations). This keeps tests
  honest about wire formats, `notify-keyspace-events` flag requirements (subkey flags
  require their data-type flag, e.g. `KEASTIV`), and timing. Because the transport is
  fire-and-forget, tests that cross a reconnect/convergence boundary use *retry probes*
  (keep SETting until one arrives) rather than asserting on a single event that may
  legitimately fall into a gap, and settlement is asserted three-layered: registry ==
  confirmed == server `PUBSUB NUMPAT`, with a full state dump on failure.
- **TruffleRuby as the race detector.** Its scheduler interleaves threads that MRI's
  GVL never separates; four latent races (the nil-write teardown window, in-flight
  command settlement, gap-loss probes, the registration-exact recheck of §4.4) were
  exposed only there. The concurrency hammer test and its state-dump diagnostics stay
  in the suite as a permanent tripwire. MRI 3.2 plays the same role for scheduler
  *fairness* (its mutex barging exposed the writer-starvation the sliced reads guard
  against). Where `close`'s legitimate worst case is a stack of bounded joins, tests
  assert **behavior** (reader threads terminated, state closed) rather than tight
  wall-clock bounds — a wall-clock threshold there cannot separate "loaded but
  correct" from "broken".

The cluster suite additionally proves the fan-out (events from all primaries, where
single-node routing would deliver ~1/3), failover recovery (tolerating the demotion
duplicate window by requiring exact-once delivery only after convergence), transparent
resharding, the degraded-view guards, backpressure close, and empty-listener recovery,
against a real Docker cluster whose test orchestrator gates on range-exact
`CLUSTER SLOTS` *and* `CLUSTER SHARDS` agreement plus exact canonical membership across
every node (zero-slot or handshaking extras are invisible to both range views, and the
manager's membership-based enumeration would see them).

## 8. Out of scope, and why

- **`notify-keyspace-events` configuration API** — docs only. `CONFIG SET` is commonly
  restricted on managed Redis; a convenience API that fails on the platforms where
  most users run would be a trap. Tests set the flags themselves.
- **`Redis::Distributed`** — its `psubscribe` raises `NotImplementedError`; the pure
  parser/builders remain usable manually. Client-side sharding has no topology
  discovery to hang a manager on.
- **Blocking `publish` to notification channels** — the HLD's "reject or discourage"
  is satisfied by documentation; guarding the hot `publish` path with channel-name
  inspection taxes every publish for a mistake almost nobody makes, and the manager
  exposes no publish surface at all.
