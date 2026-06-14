/**
 * Expands a template (+ caller-supplied params) into a concrete RecordGraphRequest.
 *
 * Templates are AUTHORED in YAML (see /templates) but at runtime are stored as
 * JSON on a Custom Metadata Type (e.g. Quote_Template__mdt.Graph_Json__c) — Apex
 * reads JSON, never YAML. This class:
 *   1. loads the template JSON for `templateId`,
 *   2. resolves ${param} / ${param|default} placeholders against `params`,
 *   3. resolves `includes:` by merging sub-templates (multi-level bundles),
 *   4. returns a RecordGraphRequest ready for RecordGraphSync.
 *
 * Step 1, 3, and 4's include-merge are documented stubs (TODO) — they need the
 * CMDT to exist in your org. Step 2 (placeholder resolution) is implemented so the
 * shape is testable.
 */
public with sharing class TemplateExpander {

    public class TemplateException extends Exception {}

    /**
     * @param templateId  the template's `id` (matches a CMDT DeveloperName).
     * @param params      caller-supplied parameter values (slot name -> value).
     */
    public static RecordGraphRequest expand(String templateId, Map<String, Object> params) {
        if (String.isBlank(templateId)) {
            throw new TemplateException('templateId is required');
        }
        String graphJson = loadTemplateJson(templateId);          // TODO: CMDT/Static Resource
        graphJson = resolvePlaceholders(graphJson, params);       // implemented below
        RecordGraphRequest req = RecordGraphRequest.fromJson(graphJson);
        req.templateId = templateId;
        // TODO: resolve req's `includes` by recursively expanding sub-templates and
        // merging their nodes (remap aliases, rebind parentAlias to rootAlias).
        return req;
    }

    /**
     * Loads the stored JSON graph for a template.
     * TODO: replace with a query against Quote_Template__mdt (or a Static Resource).
     */
    private static String loadTemplateJson(String templateId) {
        // Example shape of what the CMDT row's Graph_Json__c holds:
        //   { "nodes": [ { "alias": "quote", "objectApiName": "Quote", ... } ] }
        throw new TemplateException(
            'loadTemplateJson is a stub — wire up Quote_Template__mdt for "' + templateId + '"'
        );
    }

    /**
     * Replaces ${name} and ${name|default} tokens with values from `params`.
     * Operates on the JSON text BEFORE parse for placeholders that stand alone as a
     * value; for typed substitution into non-string fields, prefer resolving on the
     * parsed object model (left as a refinement).
     */
    @TestVisible
    private static String resolvePlaceholders(String json, Map<String, Object> params) {
        if (json == null) {
            return null;
        }
        Map<String, Object> p = (params == null) ? new Map<String, Object>() : params;
        Pattern token = Pattern.compile('\\$\\{([a-zA-Z_][a-zA-Z0-9_]*)(?:\\|([^}]*))?\\}');
        Matcher m = token.matcher(json);
        StringBuilder out = new StringBuilder();
        Integer last = 0;
        while (m.find()) {
            out.append(json.substring(last, m.start()));
            String name = m.group(1);
            String fallback = m.group(2);
            Object value = p.containsKey(name) ? p.get(name) : fallback;
            if (value == null) {
                throw new TemplateException('Missing required parameter: ' + name);
            }
            out.append(String.valueOf(value));
            last = m.end();
        }
        out.append(json.substring(last));
        return out.toString();
    }
}
