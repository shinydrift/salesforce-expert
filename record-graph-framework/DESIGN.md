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
  1. `describe → base JSON Schema` — a script pulls field + picklist metadata so
     the schema stays in sync with the org.
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

This is a **skeleton**. Alias resolution, topo-sort, and transactional execution
are implemented; `validate()`, picklist coercion, `TemplateExpander` loading, and
the child-collection diff are documented stubs marked `TODO` — they need the
describe-generated schema and the CMDT storage to be wired up for your org.
