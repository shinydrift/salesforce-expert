#!/usr/bin/env node
/**
 * Smoke test for the per-template generation schemas: compile each with a real
 * draft-07 validator and assert it accepts a well-formed generation payload
 * ({ templateId, parameters }) and rejects the failure modes the schema exists to
 * catch — wrong templateId, missing required slot, unknown slot, wrong slot type.
 *
 * Run after build-generation-schema.mjs:  node scripts/generation-schema-smoke.mjs
 */
import { readFileSync, existsSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import Ajv from 'ajv';
import addFormats from 'ajv-formats';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const genDir = join(root, 'schema', 'generation');

const load = (id) => {
  const path = join(genDir, `${id}.schema.json`);
  if (!existsSync(path)) {
    throw new Error(`Missing ${path} — run: node scripts/build-generation-schema.mjs`);
  }
  return JSON.parse(readFileSync(path, 'utf8'));
};

const ajv = new Ajv({ allErrors: true, strict: false });
addFormats(ajv);

// (schemaId, payload, expectedValid)
const cases = [
  // opportunity-bundle: name + closeDate required, quantity optional (number).
  ['opportunity-bundle', 'valid full payload',
    { templateId: 'opportunity-bundle', parameters: { name: 'Acme Q3', closeDate: '2026-09-30', quantity: 5 } }, true],
  ['opportunity-bundle', 'valid without optional quantity',
    { templateId: 'opportunity-bundle', parameters: { name: 'Acme Q3', closeDate: '2026-09-30' } }, true],
  ['opportunity-bundle', 'wrong templateId rejected',
    { templateId: 'starter-bundle', parameters: { name: 'Acme', closeDate: '2026-09-30' } }, false],
  ['opportunity-bundle', 'missing required slot rejected',
    { templateId: 'opportunity-bundle', parameters: { name: 'Acme' } }, false],
  ['opportunity-bundle', 'unknown slot rejected',
    { templateId: 'opportunity-bundle', parameters: { name: 'Acme', closeDate: '2026-09-30', bogus: 'x' } }, false],
  ['opportunity-bundle', 'wrong slot type rejected',
    { templateId: 'opportunity-bundle', parameters: { name: 'Acme', closeDate: '2026-09-30', quantity: 'five' } }, false],
  ['opportunity-bundle', 'missing parameters object rejected',
    { templateId: 'opportunity-bundle' }, false],
  ['opportunity-bundle', 'unknown top-level key rejected',
    { templateId: 'opportunity-bundle', parameters: { name: 'A', closeDate: '2026-09-30' }, extra: 1 }, false],

  // starter-bundle: opportunityId required, quantity optional.
  ['starter-bundle', 'valid payload',
    { templateId: 'starter-bundle', parameters: { opportunityId: '0060000000000001', quantity: 3 } }, true],
  ['starter-bundle', 'missing required opportunityId rejected',
    { templateId: 'starter-bundle', parameters: { quantity: 3 } }, false],

  // enterprise-bundle: opportunityId required, quantity + discount optional.
  ['enterprise-bundle', 'valid payload',
    { templateId: 'enterprise-bundle', parameters: { opportunityId: '0060000000000001', quantity: 20, discount: 5 } }, true],
  ['enterprise-bundle', 'valid with only required slot',
    { templateId: 'enterprise-bundle', parameters: { opportunityId: '0060000000000001' } }, true],
  ['enterprise-bundle', 'discount wrong type rejected',
    { templateId: 'enterprise-bundle', parameters: { opportunityId: '0060000000000001', discount: 'lots' } }, false],
];

let failures = 0;
const validators = {};
for (const [id, name, payload, expected] of cases) {
  if (!validators[id]) validators[id] = ajv.compile(load(id));
  const validate = validators[id];
  const ok = validate(payload);
  if (ok === expected) {
    console.log(`  ✓ [${id}] ${name}`);
  } else {
    failures++;
    console.error(`  ✗ [${id}] ${name}: expected valid=${expected}, got ${ok}`);
    if (!ok) console.error('    ' + ajv.errorsText(validate.errors, { separator: '\n    ' }));
  }
}

if (failures) {
  console.error(`\n${failures} generation-schema smoke case(s) failed`);
  process.exit(1);
}
console.log('\nAll generation-schema smoke cases passed.');
