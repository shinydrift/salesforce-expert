# record-graph-framework

A framework for an Agentforce agent to **create and edit multi-level graphs of
related Salesforce records** (Quote → QuoteLineItems, Opportunity →
OpportunityLineItems, …) reliably, from templates, in one transactional call.

See **[DESIGN.md](DESIGN.md)** for the full design. The engine is **implemented
end-to-end**: describe-based validation, template loading from Custom Metadata,
`includes:` merging, child-collection diff (with optimistic locking), picklist/type
coercion, and reference resolution (ProductCode → PricebookEntry) all work and are
covered by tests.

## Layout

```
schema/quote-graph.schema.json     base graph contract (JSON Schema; $defs generated)
schema/generation/<id>.schema.json per-template generation surface ({templateId,parameters})
templates/*.yaml                   authored bundle templates (enterprise uses includes:)
scripts/build-schema.mjs           SObject describe → schema/$defs (field/picklist constraints)
scripts/build-generation-schema.mjs  YAML templates → schema/generation/<id>.schema.json
scripts/describe/*.describe.json   checked-in describe fixtures (offline build / CI)
scripts/schema-smoke.mjs           draft-07 validation smoke test for the generated schema
scripts/generation-schema-smoke.mjs  draft-07 smoke test for the generation schemas
scripts/build-templates.mjs        YAML templates → Graph_Template__mdt CMDT records
force-app/main/default/
  objects/Graph_Template__mdt/      CMDT type that stores compiled template JSON
  customMetadata/Graph_Template.*   one CMDT record per template (generated)
  classes/
    GraphNode                       one node DTO (+ fromMap for untyped JSON)
    RecordGraphRequest              a graph + idempotency/source
    RecordGraphResult               per-node outcome + alias→Id map
    TemplateExpander                template + params → graph (CMDT load + includes)
    RecordGraphSync                 the engine (validate→resolve→diff→sort→DML)
    CreateOpportunityWithProducts   runnable Agentforce Invocable (Opportunity intent)
    CreateQuoteFromTemplate         Quote Invocable (needs Quotes enabled in the org)
    *Test                           unit + end-to-end tests
```

## The loop

```
agent → CreateOpportunityWithProducts(templateId, params)  # tiny, typed surface
      → TemplateExpander.expand()                           # CMDT load + ${param} + includes
      → RecordGraphSync.sync()                              # resolve→validate→diff→sort→DML
      → RecordGraphResult                                   # alias→Id, per-node status
```

`RecordGraphSync.sync()` runs, in order: resolve domain references (default the
pricebook, turn a synthetic `ProductCode` into a real `PricebookEntryId` + price) →
describe-based validation (fields exist + are writeable, picklist values are live,
required fields present) → child-collection diff (orphan children of an edited
parent are deleted; optimistic-lock guard via `LastModifiedDate`) → topo-sort
(parents first) → all-or-nothing DML inside a savepoint.

## Templates

Templates are authored in YAML (`templates/*.yaml`) and compiled to JSON stored on
the `Graph_Template__mdt` CMDT — Apex reads JSON, never YAML:

```sh
node scripts/build-templates.mjs    # regenerates customMetadata/Graph_Template.*.md-meta.xml
```

## Schema

The base contract `schema/quote-graph.schema.json` validates the **resolved** graph
(after alias/FK back-fill and reference resolution). Its per-object field and
picklist `$defs` are generated from SObject describe — never hand-edit them:

```sh
node scripts/build-schema.mjs                     # offline, from scripts/describe/*.json
node scripts/build-schema.mjs --target-org myOrg  # live describe; refreshes the fixtures
node scripts/schema-smoke.mjs                      # draft-07 smoke test (needs `npm install`)
```

The object list is the schema's own `node.objectApiName` enum, so adding an object
there and re-running is all it takes. Output is deterministic and idempotent for a
given describe input (field/`required` keys are sorted; picklist `enum`s preserve
the org's display order). Field/type/enum constraints apply on every op;
create-required fields are demanded only on `op: create` (edits and deletes touch
a subset). Apex runtime validation does **not** read this file — it validates
against live describe — so the schema serves authoring/LLM tooling, not the engine.

The checked-in `scripts/describe/*.describe.json` fixtures are a **curated subset**
of fields so the build runs offline / in CI. Because the generated defs use
`additionalProperties: false`, the offline schema only accepts the fixtured fields;
run `--target-org <alias>` to regenerate from a full describe (and refresh the
fixtures) before relying on the schema to validate arbitrary real-org fields.

`opportunity-bundle` is the runnable bundle (Opportunity + two priced lines).
`starter-bundle` / `enterprise-bundle` are the Quote examples; `enterprise-bundle`
demonstrates multi-level composition via `includes:`.

### Generation schema (the tiny tier the LLM targets)

The base schema validates the wide, **resolved** graph; the agent never builds
that. It picks a `templateId` and fills a handful of typed slots. Those slots are
the generation surface, derived per template from the YAML — one schema per
template, validating `{ templateId, parameters }`:

```sh
node scripts/build-generation-schema.mjs   # templates/*.yaml → schema/generation/<id>.schema.json
node scripts/generation-schema-smoke.mjs   # draft-07 smoke test (needs `npm install`)
```

`templateId` is a `const`, `parameters` is `additionalProperties:false` with one
typed slot per declared template parameter (`required` enforced, `default` carried
through). The template is the single source of truth, so the surface can't drift
from it, and `generation surface ⊂ template ⊂ base schema` holds.

## Deploy + test

```sh
cd record-graph-framework

# The CMDT type must exist before its records deploy (separate transaction).
sf project deploy start --source-dir force-app/main/default/objects
sf project deploy start --source-dir force-app/main/default/customMetadata
sf project deploy start --source-dir force-app/main/default/classes

# Run the tests (async — they span multiple classes).
sf apex run test \
  --class-names RecordGraphSyncTest \
  --class-names TemplateExpanderTest \
  --class-names CreateOpportunityWithProductsTest \
  --code-coverage --wait 10
```

`CreateOpportunityWithProductsTest` builds its own Product/PricebookEntry fixtures,
so it never depends on existing org data.

## Run it for real

```apex
CreateOpportunityWithProducts.Request r = new CreateOpportunityWithProducts.Request();
r.opportunityName = 'Acme Expansion';
r.closeDate = String.valueOf(Date.today().addDays(30));
r.quantity = 5;
RecordGraphResult ignored;
System.debug(CreateOpportunityWithProducts.run(
    new List<CreateOpportunityWithProducts.Request>{ r })[0]);
// → Opportunity + 2 OpportunityLineItems, pricebook defaulted, codes resolved.
```

## Platform notes (gotchas that bit us)

- **CMDT records** need `xmlns:xsd` declared on the `<CustomMetadata>` element, else
  the deploy fails with a bare `UNKNOWN_EXCEPTION`. The build script emits it.
- **`JSON.deserialize` can't target a `Map<String, Object>` field** ("Apex Type
  unsupported in JSON: Object"). Nodes are built from `JSON.deserializeUntyped`
  output via `GraphNode.fromMap`.
- **`OpportunityLineItem` needs a price on insert** — the reference resolver sets
  `UnitPrice` from the PricebookEntry. Updating only `Quantity` on an existing line
  holds `TotalPrice` and recomputes `UnitPrice` (standard OLI pricing behaviour).
- **Quotes** must be enabled in the org for `CreateQuoteFromTemplate`; where they
  aren't, use the Opportunity intent.
