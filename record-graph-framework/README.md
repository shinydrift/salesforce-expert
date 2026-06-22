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
templates/*.yaml                   authored bundle templates (enterprise uses includes:)
scripts/build-schema.mjs           SObject describe → schema/$defs (field/picklist constraints)
scripts/describe/*.describe.json   checked-in describe fixtures (offline build / CI)
scripts/schema-smoke.mjs           draft-07 validation smoke test for the generated schema
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
there and re-running is all it takes. Output is deterministic and idempotent.
Apex runtime validation does **not** read this file — it validates against live
describe — so the schema serves authoring/LLM tooling, not the engine.

`opportunity-bundle` is the runnable bundle (Opportunity + two priced lines).
`starter-bundle` / `enterprise-bundle` are the Quote examples; `enterprise-bundle`
demonstrates multi-level composition via `includes:`.

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
