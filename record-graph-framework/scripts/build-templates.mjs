#!/usr/bin/env node
/**
 * Build step: compile authored YAML templates into Graph_Template__mdt Custom
 * Metadata records (the JSON the Apex runtime reads).
 *
 *   templates/*.yaml  ->  force-app/main/default/customMetadata/Graph_Template.<dev_name>.md-meta.xml
 *
 * Each record's Graph_Json__c holds the template as JSON (including ${param}
 * placeholders and `includes`, which TemplateExpander resolves at runtime).
 *
 * Usage: node scripts/build-templates.mjs   (run from the project root)
 */
import { readFileSync, writeFileSync, readdirSync, mkdirSync, existsSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import yaml from 'js-yaml';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const templatesDir = join(root, 'templates');
const outDir = join(root, 'force-app', 'main', 'default', 'customMetadata');

if (!existsSync(outDir)) mkdirSync(outDir, { recursive: true });

const xmlEscape = (s) =>
  s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');

const files = readdirSync(templatesDir).filter((f) => f.endsWith('.yaml') || f.endsWith('.yml'));
if (files.length === 0) {
  console.error('No YAML templates found in', templatesDir);
  process.exit(1);
}

let count = 0;
for (const file of files) {
  const tpl = yaml.load(readFileSync(join(templatesDir, file), 'utf8'));
  if (!tpl || !tpl.id) {
    console.warn(`skip ${file}: no top-level "id"`);
    continue;
  }
  const developerName = String(tpl.id).replace(/-/g, '_');
  const label = tpl.label || tpl.id;
  const graphJson = JSON.stringify(tpl);

  const xml = `<?xml version="1.0" encoding="UTF-8"?>
<CustomMetadata xmlns="http://soap.sforce.com/2006/04/metadata" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:xsd="http://www.w3.org/2001/XMLSchema">
    <label>${xmlEscape(label)}</label>
    <protected>false</protected>
    <values>
        <field>Graph_Json__c</field>
        <value xsi:type="xsd:string">${xmlEscape(graphJson)}</value>
    </values>
</CustomMetadata>
`;
  const outPath = join(outDir, `Graph_Template.${developerName}.md-meta.xml`);
  writeFileSync(outPath, xml);
  console.log(`built ${file} -> Graph_Template.${developerName} (${graphJson.length} bytes)`);
  count++;
}
console.log(`\nDone: ${count} template(s) compiled to ${outDir}`);
