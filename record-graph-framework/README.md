# record-graph-framework

A framework for an Agentforce agent to **create and edit multi-level graphs of
related Salesforce records** (Quote → QuoteLineItems, Opportunity →
OpportunityLineItems, …) reliably, from templates, in one transactional call.

See **[DESIGN.md](DESIGN.md)** for the full design. This is a **skeleton** — the
core (alias resolution, topo-sort, transactional DML) works; schema validation,
the child-collection diff, picklist coercion, and template loading from Custom
Metadata are documented `TODO` stubs.

## Layout

```
schema/quote-graph.schema.json     base graph contract (JSON Schema)
templates/*.yaml                   authored bundle templates (enterprise uses includes:)
force-app/main/default/classes/
  GraphNode                        one node DTO
  RecordGraphRequest               a graph + idempotency/source
  RecordGraphResult                per-node outcome + alias→Id map
  TemplateExpander                 template + params → graph
  RecordGraphSync                  the engine
  CreateQuoteFromTemplate          Agentforce Invocable action
  RecordGraphSyncTest              starter tests
```

## The loop

```
agent → CreateQuoteFromTemplate(templateId, params)   # tiny, typed surface
      → TemplateExpander.expand()                      # → full record graph
      → RecordGraphSync.sync()                         # validate→diff→sort→DML
      → RecordGraphResult                              # alias→Id, per-node status
```

## Deploy + test

```sh
cd record-graph-framework
sf project deploy start
sf apex run test --class-names RecordGraphSyncTest --result-format human
```

The starter tests use Account → Contact (cheap standard objects) to exercise the
engine without Pricebook/Quote setup.

## Next steps to make it production-ready

1. **Describe → base schema**: a build script that emits `quote-graph.schema.json`
   `$defs` from `SObject` describe (fields, required, live picklist enums).
2. **Templates → CMDT**: compile each `templates/*.yaml` to JSON and publish as a
   `Quote_Template__mdt` record; implement `TemplateExpander.loadTemplateJson`.
3. **`includes:` merge** in `TemplateExpander` for multi-level bundles.
4. **Child-collection diff** in `RecordGraphSync.computeDiff` (+ optimistic locking).
5. **Picklist coercion** in `RecordGraphSync.coerce` via `Schema.describe`.
