#!/usr/bin/env node
/**
 * Smoke test for the per-template generation schemas. Three layers:
 *   1. payload validation — compile each generated schema with a real draft-07
 *      validator and assert it accepts well-formed { templateId, parameters }
 *      payloads and rejects the failure modes the schema exists to catch;
 *   2. no-drift — regenerate each schema from its template and assert it matches
 *      the checked-in file byte-for-byte (catches a stale commit);
 *   3. builder unit tests — drive generationSchemaFor with synthetic templates to
 *      cover the no-required path, default carry-through, and the malformed-input
 *      guards (which no real in-repo template should ever hit).
 *
 * Run after build-generation-schema.mjs:  node scripts/generation-schema-smoke.mjs
 */
import { readFileSync, readdirSync, existsSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import Ajv from 'ajv';
import addFormats from 'ajv-formats';
import yaml from 'js-yaml';
import { generationSchemaFor, serialize } from './build-generation-schema.mjs';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const genDir = join(root, 'schema', 'generation');
const templatesDir = join(root, 'templates');

const load = (id) => {
  const path = join(genDir, `${id}.schema.json`);
  if (!existsSync(path)) {
    throw new Error(`Missing ${path} — run: node scripts/build-generation-schema.mjs`);
  }
  return JSON.parse(readFileSync(path, 'utf8'));
};

const ajv = new Ajv({ allErrors: true, strict: false });
addFormats(ajv); // generation schemas can carry format: date/email/etc.

let failures = 0;
const pass = (name) => console.log(`  ✓ ${name}`);
const fail = (name, detail) => { failures++; console.error(`  ✗ ${name}${detail ? ': ' + detail : ''}`); };

// --- 1. payload validation --------------------------------------------------
// (schemaId, payload, expectedValid)
const cases = [
  // opportunity-bundle: name + closeDate(date) required, quantity optional (number).
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
  ['opportunity-bundle', 'non-date closeDate rejected (format: date)',
    { templateId: 'opportunity-bundle', parameters: { name: 'Acme', closeDate: 'banana' } }, false],
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

const validators = {};
for (const [id, name, payload, expected] of cases) {
  if (!validators[id]) validators[id] = ajv.compile(load(id));
  const validate = validators[id];
  const ok = validate(payload);
  if (ok === expected) pass(`[${id}] ${name}`);
  else fail(`[${id}] ${name}`, `expected valid=${expected}, got ${ok}` +
    (!ok ? '\n    ' + ajv.errorsText(validate.errors, { separator: '\n    ' }) : ''));
}

// Assert a default is actually carried through to the generated schema.
{
  const quantity = load('opportunity-bundle').properties.parameters.properties.quantity;
  if (quantity && quantity.default === 1) pass('[opportunity-bundle] optional default carried through');
  else fail('[opportunity-bundle] optional default carried through', `got default=${JSON.stringify(quantity && quantity.default)}`);
}

// --- 2. no-drift: regenerate from templates and compare to checked-in files --
for (const file of readdirSync(templatesDir).filter((f) => f.endsWith('.yaml') || f.endsWith('.yml')).sort()) {
  const tpl = yaml.load(readFileSync(join(templatesDir, file), 'utf8'));
  if (!tpl || !tpl.id) continue;
  const regenerated = serialize(generationSchemaFor(tpl, file));
  const onDisk = readFileSync(join(genDir, `${tpl.id}.schema.json`), 'utf8');
  if (regenerated === onDisk) pass(`[no-drift] ${tpl.id}.schema.json matches its template`);
  else fail(`[no-drift] ${tpl.id}.schema.json`, 'checked-in file is stale — run build-generation-schema.mjs');
}

// --- 3. builder unit tests (synthetic templates) ----------------------------
const expectThrow = (name, fn) => {
  try { fn(); fail(`[builder] ${name}`, 'expected a throw, got none'); }
  catch { pass(`[builder] ${name}`); }
};
const expectOk = (name, fn) => {
  try { fn(); pass(`[builder] ${name}`); }
  catch (e) { fail(`[builder] ${name}`, e.message); }
};

// No-required template: `parameters` is optional at the top level.
expectOk('no-required template → parameters optional + unknown slot still rejected', () => {
  const schema = generationSchemaFor(
    { id: 'np', label: 'NP', parameters: [{ name: 'opt', type: 'string', default: 'x' }] }, 'np.yaml');
  if (schema.required.includes('parameters')) throw new Error('parameters should not be top-level required');
  if (schema.properties.parameters.properties.opt.default !== 'x') throw new Error('default not carried on optional slot');
  const v = ajv.compile(schema);
  if (!v({ templateId: 'np' })) throw new Error('payload without parameters should be valid');
  if (v({ templateId: 'np', parameters: { bogus: 1 } })) throw new Error('unknown slot should be rejected');
});

// includes-only / no parameters block at all.
expectOk('template with no parameters block', () => {
  const schema = generationSchemaFor({ id: 'inc', includes: [{ template: 'x' }] }, 'inc.yaml');
  if (schema.required.includes('parameters')) throw new Error('parameters should be optional');
});

// default is dropped on a required slot (contradictory there).
expectOk('default dropped on required slot', () => {
  const schema = generationSchemaFor(
    { id: 'rq', parameters: [{ name: 'a', type: 'string', required: true, default: 'z' }] }, 'rq.yaml');
  if ('default' in schema.properties.parameters.properties.a) throw new Error('default should not appear on required slot');
});

// Malformed-template guards — each must throw, atomically aborting a real build.
expectThrow('missing param name throws', () =>
  generationSchemaFor({ id: 't', parameters: [{ type: 'string' }] }, 't.yaml'));
expectThrow('null param entry throws', () =>
  generationSchemaFor({ id: 't', parameters: [null] }, 't.yaml'));
expectThrow('duplicate param name throws', () =>
  generationSchemaFor({ id: 't', parameters: [{ name: 'x', type: 'string' }, { name: 'x', type: 'number' }] }, 't.yaml'));
expectThrow('unknown param type throws', () =>
  generationSchemaFor({ id: 't', parameters: [{ name: 'x', type: 'array' }] }, 't.yaml'));
expectThrow('default type mismatch throws', () =>
  generationSchemaFor({ id: 't', parameters: [{ name: 'x', type: 'number', default: 'nope' }] }, 't.yaml'));

if (failures) {
  console.error(`\n${failures} generation-schema smoke case(s) failed`);
  process.exit(1);
}
console.log('\nAll generation-schema smoke cases passed.');
