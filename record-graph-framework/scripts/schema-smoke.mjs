#!/usr/bin/env node
/**
 * Smoke test for the generated base schema: compile it with a real JSON Schema
 * validator (draft-07) and assert it accepts a valid *resolved* graph and rejects
 * the failure modes the generated `$defs` exist to catch (unknown field, dead
 * picklist value, missing required field, wrong type).
 *
 * Run after `build-schema.mjs`:  node scripts/schema-smoke.mjs
 */
import { readFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import Ajv from 'ajv';
import addFormats from 'ajv-formats';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const schema = JSON.parse(readFileSync(join(root, 'schema', 'quote-graph.schema.json'), 'utf8'));

const ajv = new Ajv({ allErrors: true, strict: false });
addFormats(ajv);
const validate = ajv.compile(schema);

// A resolved graph (FKs back-filled, ProductCode already resolved away).
const validGraph = {
  nodes: [
    { alias: 'opp', objectApiName: 'Opportunity', op: 'create',
      fields: { Name: 'Acme Expansion', StageName: 'Prospecting', CloseDate: '2026-07-22' } },
    { alias: 'line1', objectApiName: 'OpportunityLineItem', op: 'create',
      parentAlias: 'opp', parentField: 'OpportunityId',
      fields: { PricebookEntryId: '01u000000000001AAA', Quantity: 5, UnitPrice: 100 } },
  ],
};

const cases = [
  ['valid resolved graph', validGraph, true],
  ['unknown field rejected', {
    nodes: [{ alias: 'q', objectApiName: 'Quote', op: 'create',
      fields: { Name: 'Q', Bogus__c: 'x' } }],
  }, false],
  ['dead picklist value rejected', {
    nodes: [{ alias: 'q', objectApiName: 'Quote', op: 'create',
      fields: { Name: 'Q', Status: 'Retired' } }],
  }, false],
  ['missing required field rejected', {
    nodes: [{ alias: 'opp', objectApiName: 'Opportunity', op: 'create',
      fields: { Name: 'A', StageName: 'Prospecting' } }],
  }, false],
  ['wrong type rejected', {
    nodes: [{ alias: 'l', objectApiName: 'OpportunityLineItem', op: 'create',
      fields: { Quantity: 'five' } }],
  }, false],
  ['update without id rejected', {
    nodes: [{ alias: 'q', objectApiName: 'Quote', op: 'update', fields: { Name: 'Q' } }],
  }, false],
];

let failures = 0;
for (const [name, graph, expected] of cases) {
  const ok = validate(graph);
  if (ok === expected) {
    console.log(`  ✓ ${name}`);
  } else {
    failures++;
    console.error(`  ✗ ${name}: expected valid=${expected}, got ${ok}`);
    if (!ok) console.error('    ' + ajv.errorsText(validate.errors, { separator: '\n    ' }));
  }
}

if (failures) {
  console.error(`\n${failures} smoke case(s) failed`);
  process.exit(1);
}
console.log('\nAll schema smoke cases passed.');
