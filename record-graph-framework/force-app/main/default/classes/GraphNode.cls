/**
 * One node in a record graph: a single SObject to create/update/delete, plus its
 * link to a parent node via a local alias. Children reference parents by `alias`
 * (resolved to real Ids at DML time), never by Id directly.
 *
 * Kept free of platform types (mirrors the BaseRequestWrapper convention in
 * sf-apex-rest-case) so it deserializes cleanly from the JSON wire format.
 */
public class GraphNode {
    /** Local id, unique within the graph. Parents are referenced by this. */
    public String alias;

    /** SObject API name, e.g. 'Quote', 'QuoteLineItem'. */
    public String objectApiName;

    /** 'create' | 'update' | 'delete' | 'upsert'. */
    public String op;

    /** Salesforce record Id — set for update/delete, optional for upsert. */
    public String recordId;

    /** alias of the parent node within this same graph (null for roots). */
    public String parentAlias;

    /** FK field on this object that points at the parent, e.g. 'QuoteId'. */
    public String parentField;

    /** Field API name -> value. Constrained per-object by the base schema. */
    public Map<String, Object> fields;

    /**
     * Optional optimistic-lock guard for `update` ops: the LastModifiedDate the
     * caller last saw (ISO-8601). If the live record differs, the sync is rejected.
     */
    public String expectedLastModified;

    public GraphNode() {
        this.fields = new Map<String, Object>();
    }

    /**
     * Build a node from an untyped JSON map. We hand-map (rather than
     * JSON.deserialize into GraphNode.class) because `fields` is a
     * Map<String, Object>, which JSON.deserialize cannot target — it throws
     * "Apex Type unsupported in JSON: Object". JSON.deserializeUntyped, by
     * contrast, produces exactly the Map<String, Object> shape `fields` needs.
     * Accepts either `id` (schema/wire) or `recordId` for the record Id.
     */
    public static GraphNode fromMap(Map<String, Object> m) {
        GraphNode n = new GraphNode();
        n.alias = (String) m.get('alias');
        n.objectApiName = (String) m.get('objectApiName');
        n.op = (String) m.get('op');
        if (m.get('id') != null) {
            n.recordId = String.valueOf(m.get('id'));
        }
        if (m.get('recordId') != null) {
            n.recordId = String.valueOf(m.get('recordId'));
        }
        n.parentAlias = (String) m.get('parentAlias');
        n.parentField = (String) m.get('parentField');
        if (m.get('expectedLastModified') != null) {
            n.expectedLastModified = String.valueOf(m.get('expectedLastModified'));
        }
        if (m.get('fields') != null) {
            n.fields = (Map<String, Object>) m.get('fields');
        }
        return n;
    }
}
