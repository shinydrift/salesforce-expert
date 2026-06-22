# Record Graph Framework — Design

A framework for an Agentforce agent to **create and edit multi-level graphs of
related Salesforce records** (e.g. Quote → QuoteLineItems, Opportunity →
OpportunityLineItems) reliably, from templates, in one transactional call.

## Goals

1. **Reliable generation / validation** — the agent never free-builds a record graph.
2. **Templating** — variations (bundles) are authored templates, not ad-hoc.
3. **Schema management** — one contract, generated from the org, never stale.
4. **Reading from DB** — read existing structures in the same shape we write.
5. **Editing existing structures** — diff the desired end-state against the DB.

## The one abstraction

Everything is a **record graph**: a list of nodes, each with a local `alias`, an
`op` (`create | update | delete | upsert`), an optional `id` (for existing
records), and a `parentAlias` + `parentField` linking it to its parent. The same
shape is used for **reads** and **writes**, so a read → edit → write round-trip is
symmetric.

```
node = { alias, objectApiName, op, id?, parentAlias?, parentField?, fields{} }
```

Children reference parents by **alias**, not Id — the engine resolves aliases to
real Ids at insert time and back-fills foreign keys. (This is the core problem the
framework solves; do **not** express parent links with YAML anchors — those are
intra-document only and can't span template files.)

## Two-tier schema (locked decision)

| Tier | Source | Used for | Size |
|------|--------|----------|------|
| **Base schema** | generated from `SObject` describe | validate the *resolved* graph before DML; bound editable fields; supply live picklist enums | broad |
| **Generation schema** | derived from a template | what the **LLM** generates against — only the typed parameter slots | tiny |

Containment: **generation surface ⊂ template ⊂ base schema.** The model picks a
`templateId` and fills a handful of slots; it never sees the wide object schema.
The base schema is the safety net behind it.

## Runtime flow

```
agent → templateId + params        (validated vs the tiny generation schema)
  └► TemplateExpander.expand(...)   → full record graph
       └► RecordGraphSync.sync(...)
            ├─ validate vs base schema (describe-derived)
            ├─ DIFF desired graph vs current DB state  (diff-based editing)
            │     existing-not-in-request → delete
            │     in-request with id      → update (changed fields only)
            │     in-request without id   → insert
            ├─ topo-sort (parents before children), resolve aliases → Ids
            └─ transactional DML (savepoint / all-or-none) → RecordGraphResult
```

## Editing model (locked decision): diff-based

The agent expresses the **desired end-state** of a structure; the engine loads the
current records, computes the create/update/delete set (child-collection
reconciliation), and applies the minimal change set. Optimistic locking via
`LastModifiedDate` guards against clobbering concurrent edits.

## Format boundary

- **YAML** — authoring surface for templates, plus a human-readable view for
  review/diff and "save this existing structure as a new template". Validated
  in-IDE against the base schema via the YAML language server
  (`# yaml-language-server: $schema=...`).
- **JSON** — the runtime/wire/DML format. Apex deserializes JSON with the native
  `JSON` class and **never parses YAML**.
- **Build steps** (outside Apex, in the tooling tier):
  1. `describe → base JSON Schema` — `scripts/build-schema.mjs` pulls field +
     picklist metadata and regenerates the per-object `$defs` so the schema stays
     in sync with the org (`node scripts/build-schema.mjs --target-org <alias>`).
     With no org it reads checked-in describe fixtures under `scripts/describe/`,
     so the build runs in CI. The object list is driven by the schema's own
     `node.objectApiName` enum — one source of truth.
  2. `YAML template → JSON → Custom Metadata Type record` — templates are authored
     in YAML in git, compiled to JSON, and published as `Quote_Template__mdt`
     (or Static Resource) so Apex reads JSON at runtime and admins can tweak
     bundles without a code deploy.

## Components in this folder

| File | Role |
|------|------|
| `schema/quote-graph.schema.json` | base graph contract (the JSON Schema) |
| `templates/starter-bundle.yaml` | a simple bundle template |
| `templates/enterprise-bundle.yaml` | a multi-level template using `includes:` |
| `classes/GraphNode` | one node DTO |
| `classes/RecordGraphRequest` | a graph + idempotency/source metadata |
| `classes/RecordGraphResult` | per-node outcome + `alias → Id` map |
| `classes/TemplateExpander` | template + params → record graph |
| `classes/RecordGraphSync` | the engine: validate → diff → topo-sort → DML |
| `classes/CreateQuoteFromTemplate` | Agentforce Invocable action (typed inputs) |
| `classes/RecordGraphSyncTest` | test starter |

## Status

**Implemented end-to-end.** Alias resolution, topo-sort, transactional execution,
describe-based `validate()`, picklist/type coercion, `TemplateExpander` loading from
`Graph_Template__mdt`, `includes:` merging, and the child-collection diff (with
`LastModifiedDate` optimistic locking) all work and are test-covered. Domain
reference resolution (default pricebook + `ProductCode` → `PricebookEntryId`/price)
runs in the engine before validation.

The runnable surface is `CreateOpportunityWithProducts` + the `opportunity-bundle`
template (Opportunity → OpportunityLineItem), verified live against a Developer
Edition org. `CreateQuoteFromTemplate` + the Quote templates remain as the
documented Quote example and require Quotes to be enabled in the target org.

DML is bulkified: `sync` applies the graph level-by-level, issuing one DML
statement per `(object, op)` bucket per level, so the statement count is
`O(levels × objects × ops)` rather than `O(nodes)` and a wide graph no longer
risks the 150-statement governor limit (covered by
`sync_bulkifiesDmlIndependentOfWidth`).

The `quote-graph.schema.json` `$defs` are now generated from describe by
`scripts/build-schema.mjs` (field types, live picklist enums, `maxLength`, and
required fields), wired into `node` via `objectApiName` conditionals, and covered
by a draft-07 smoke test (`scripts/schema-smoke.mjs`). Optimistic-lock coverage
now includes upserts.

Note on what the base schema validates: it describes the **resolved** graph (FKs
back-filled from `parentAlias`, `ProductCode` already resolved to a
`PricebookEntryId`, `${param}` placeholders substituted). Reference/FK fields are
deliberately omitted from `required` because the engine fills them. The raw YAML
templates are the *pre-resolution* authoring surface (placeholders, the synthetic
`ProductCode`, omitted FKs), so they are a looser surface than this schema — a
dedicated, template-derived generation schema for in-IDE template authoring is a
sensible follow-up.
