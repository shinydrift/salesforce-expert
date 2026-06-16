/**
 * Expands a template (+ caller-supplied params) into a concrete RecordGraphRequest.
 *
 * Templates are AUTHORED in YAML (see /templates) but at runtime are stored as
 * JSON on the Custom Metadata Type Graph_Template__mdt (field Graph_Json__c) — Apex
 * reads JSON, never YAML. This class:
 *   1. loads the template JSON for `templateId` from the CMDT,
 *   2. resolves ${param} / ${param|default} placeholders against `params`,
 *   3. resolves `includes:` by recursively expanding + merging sub-templates,
 *   4. returns a RecordGraphRequest ready for RecordGraphSync.
 */
public with sharing class TemplateExpander {

    public class TemplateException extends Exception {}

    /**
     * @param templateId  the template's `id` (e.g. "opportunity-bundle"); maps to a
     *                     Graph_Template__mdt DeveloperName (hyphens -> underscores).
     * @param params      caller-supplied parameter values (slot name -> value).
     */
    public static RecordGraphRequest expand(String templateId, Map<String, Object> params) {
        if (String.isBlank(templateId)) {
            throw new TemplateException('templateId is required');
        }
        String graphJson = loadTemplateJson(templateId);
        graphJson = resolvePlaceholders(graphJson, params);

        // Parse untyped: GraphNode.fields is a Map<String, Object>, which
        // JSON.deserialize can't target, so build nodes from the untyped view.
        Map<String, Object> tpl = (Map<String, Object>) JSON.deserializeUntyped(graphJson);

        RecordGraphRequest req = new RecordGraphRequest();
        req.templateId = templateId;
        req.nodes = new List<GraphNode>();
        if (tpl.get('nodes') != null) {
            for (Object o : (List<Object>) tpl.get('nodes')) {
                req.nodes.add(GraphNode.fromMap((Map<String, Object>) o));
            }
        }

        // Resolve includes: each included template is expanded with its own params
        // (the `with` block, already placeholder-resolved against the outer params),
        // then its nodes are merged in — remapping the included root onto `rootAlias`
        // so the outer template's nodes can attach to it.
        if (tpl.get('includes') != null) {
            for (Object incObj : (List<Object>) tpl.get('includes')) {
                Map<String, Object> inc = (Map<String, Object>) incObj;
                String childTemplate = (String) inc.get('template');
                Map<String, Object> childParams = inc.get('with') == null
                    ? new Map<String, Object>()
                    : (Map<String, Object>) inc.get('with');
                String rootAlias = (String) inc.get('rootAlias');

                RecordGraphRequest childReq = expand(childTemplate, childParams);
                mergeIncluded(req, childReq, rootAlias);
            }
        }
        return req;
    }

    /** Loads the stored JSON graph for a template from Graph_Template__mdt. */
    private static String loadTemplateJson(String templateId) {
        String developerName = templateId.replace('-', '_');
        List<Graph_Template__mdt> rows = [
            SELECT Graph_Json__c
            FROM Graph_Template__mdt
            WHERE DeveloperName = :developerName
            LIMIT 1
        ];
        if (rows.isEmpty() || String.isBlank(rows[0].Graph_Json__c)) {
            throw new TemplateException('no Graph_Template__mdt named "' + developerName +
                                        '" (for templateId "' + templateId + '")');
        }
        return rows[0].Graph_Json__c;
    }

    /**
     * Merge an included graph into the parent. If `rootAlias` is given, the included
     * graph's root node (the one with no parentAlias) is renamed to `rootAlias`, and
     * any of its children pointing at the old alias are rebound — so the parent
     * template's nodes can reference the included structure by `rootAlias`.
     */
    private static void mergeIncluded(RecordGraphRequest parent, RecordGraphRequest child, String rootAlias) {
        if (String.isNotBlank(rootAlias)) {
            String oldRoot = null;
            for (GraphNode n : child.nodes) {
                if (String.isBlank(n.parentAlias)) {
                    oldRoot = n.alias;
                    break;
                }
            }
            if (oldRoot != null && oldRoot != rootAlias) {
                for (GraphNode n : child.nodes) {
                    if (n.alias == oldRoot) {
                        n.alias = rootAlias;
                    }
                    if (n.parentAlias == oldRoot) {
                        n.parentAlias = rootAlias;
                    }
                }
            }
        }
        Set<String> existing = new Set<String>();
        for (GraphNode n : parent.nodes) {
            existing.add(n.alias);
        }
        for (GraphNode n : child.nodes) {
            // Skip an included root that the parent already declares (shared anchor).
            if (existing.contains(n.alias)) {
                continue;
            }
            parent.nodes.add(n);
            existing.add(n.alias);
        }
    }

    /**
     * Replaces ${name} and ${name|default} tokens with values from `params`.
     */
    @TestVisible
    private static String resolvePlaceholders(String json, Map<String, Object> params) {
        if (json == null) {
            return null;
        }
        Map<String, Object> p = (params == null) ? new Map<String, Object>() : params;
        Pattern token = Pattern.compile('\\$\\{([a-zA-Z_][a-zA-Z0-9_]*)(?:\\|([^}]*))?\\}');
        Matcher m = token.matcher(json);
        String out = '';
        Integer last = 0;
        while (m.find()) {
            out += json.substring(last, m.start());
            String name = m.group(1);
            String fallback = m.group(2);
            Object value = p.containsKey(name) ? p.get(name) : fallback;
            if (value == null) {
                throw new TemplateException('Missing required parameter: ' + name);
            }
            out += String.valueOf(value);
            last = m.end();
        }
        out += json.substring(last);
        return out;
    }
}
