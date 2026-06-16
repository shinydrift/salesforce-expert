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

    public GraphNode() {
        this.fields = new Map<String, Object>();
    }
}
