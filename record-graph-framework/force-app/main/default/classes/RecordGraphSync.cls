/**
 * The engine. Takes a desired RecordGraphRequest and reconciles it into the org:
 *
 *   validate (vs base schema) → diff (vs current DB state) → topo-sort →
 *   resolve aliases to Ids → transactional DML → RecordGraphResult
 *
 * IMPLEMENTED: alias resolution, topo-sort (parents before children), per-op DML,
 * and all-or-nothing execution inside a savepoint.
 * STUBBED (marked TODO): schema validation, picklist coercion, and the
 * child-collection diff — these need the describe-generated schema wired up.
 */
public with sharing class RecordGraphSync {

    public class GraphException extends Exception {}

    public RecordGraphResult sync(RecordGraphRequest req) {
        RecordGraphResult result = new RecordGraphResult();

        if (req == null || req.nodes == null || req.nodes.isEmpty()) {
            result.message = 'Request had no nodes';
            return result;
        }

        // 1. Validate the desired graph against the base (describe-derived) schema.
        List<String> errors = validate(req);
        if (!errors.isEmpty()) {
            result.message = 'Validation failed: ' + String.join(errors, '; ');
            return result;
        }

        // 2. Diff the desired end-state against current DB state (diff-based editing).
        //    Returns nodes tagged with the op actually required (create/update/delete).
        List<GraphNode> reconciled = computeDiff(req);

        // 3. Order so parents are processed before children.
        List<GraphNode> ordered = topoSort(reconciled);

        // 4. Resolve + apply inside a savepoint — all-or-nothing.
        Savepoint sp = Database.setSavepoint();
        Map<String, Id> aliasToId = new Map<String, Id>();
        try {
            for (GraphNode node : ordered) {
                applyNode(node, aliasToId, result);
            }
            result.success = true;
            result.message = 'Graph synced: ' + result.aliasToId.size() + ' record(s) persisted';
        } catch (Exception e) {
            Database.rollback(sp);
            result.success = false;
            result.aliasToId = new Map<String, Id>();
            result.message = 'Rolled back: ' + e.getMessage();
        }
        return result;
    }

    // --- core: apply one node -------------------------------------------------

    private void applyNode(GraphNode node, Map<String, Id> aliasToId, RecordGraphResult result) {
        String op = String.isBlank(node.op) ? 'create' : node.op.toLowerCase();

        if (op == 'delete') {
            if (String.isBlank(node.recordId)) {
                throw new GraphException('delete node "' + node.alias + '" has no recordId');
            }
            Database.delete((Id) node.recordId, true);
            result.record(node.alias, node.objectApiName, op, (Id) node.recordId, true, null);
            return;
        }

        SObject record = buildSObject(node, aliasToId);

        if (op == 'create') {
            Database.insert(record, true);
        } else if (op == 'update') {
            if (record.Id == null) {
                throw new GraphException('update node "' + node.alias + '" has no recordId');
            }
            Database.update(record, true);
        } else if (op == 'upsert') {
            Database.upsert(record, true);
        } else {
            throw new GraphException('unknown op "' + node.op + '" on node "' + node.alias + '"');
        }
        result.record(node.alias, node.objectApiName, op, record.Id, true, null);
    }

    /** Build an SObject from a node, back-filling the parent FK from the alias map. */
    private SObject buildSObject(GraphNode node, Map<String, Id> aliasToId) {
        SObjectType t = ((SObject) Type.forName(node.objectApiName).newInstance()).getSObjectType();
        SObject record = t.newSObject();

        if (String.isNotBlank(node.recordId)) {
            record.put('Id', (Id) node.recordId);
        }
        // Resolve the parent link: child's FK = the parent's freshly-inserted Id.
        if (String.isNotBlank(node.parentAlias)) {
            Id parentId = aliasToId.get(node.parentAlias);
            if (parentId == null) {
                throw new GraphException(
                    'node "' + node.alias + '" references unresolved parent "' + node.parentAlias + '"'
                );
            }
            record.put(node.parentField, parentId);
        }
        if (node.fields != null) {
            for (String f : node.fields.keySet()) {
                record.put(f, coerce(node.objectApiName, f, node.fields.get(f)));
            }
        }
        return record;
    }

    // --- topo-sort: parents before children -----------------------------------

    @TestVisible
    private List<GraphNode> topoSort(List<GraphNode> nodes) {
        Map<String, GraphNode> byAlias = new Map<String, GraphNode>();
        for (GraphNode n : nodes) {
            if (byAlias.containsKey(n.alias)) {
                throw new GraphException('duplicate alias "' + n.alias + '"');
            }
            byAlias.put(n.alias, n);
        }

        List<GraphNode> ordered = new List<GraphNode>();
        Set<String> placed = new Set<String>();
        Set<String> visiting = new Set<String>();
        for (GraphNode n : nodes) {
            visit(n, byAlias, placed, visiting, ordered);
        }
        return ordered;
    }

    private void visit(GraphNode n, Map<String, GraphNode> byAlias,
                       Set<String> placed, Set<String> visiting, List<GraphNode> ordered) {
        if (placed.contains(n.alias)) {
            return;
        }
        if (visiting.contains(n.alias)) {
            throw new GraphException('cycle detected at alias "' + n.alias + '"');
        }
        visiting.add(n.alias);
        if (String.isNotBlank(n.parentAlias)) {
            GraphNode parent = byAlias.get(n.parentAlias);
            if (parent == null) {
                throw new GraphException(
                    'node "' + n.alias + '" references missing parent alias "' + n.parentAlias + '"'
                );
            }
            visit(parent, byAlias, placed, visiting, ordered);
        }
        visiting.remove(n.alias);
        placed.add(n.alias);
        ordered.add(n);
    }

    // --- stubs that need the describe-generated schema / CMDT -----------------

    /**
     * Validate the resolved graph against the base schema (field existence, required
     * fields, picklist values). TODO: load the describe-generated JSON Schema and
     * validate against it, or perform per-field Schema.describe checks here.
     */
    @TestVisible
    private List<String> validate(RecordGraphRequest req) {
        List<String> errors = new List<String>();
        for (GraphNode n : req.nodes) {
            if (String.isBlank(n.alias)) {
                errors.add('a node is missing alias');
            }
            if (String.isBlank(n.objectApiName)) {
                errors.add('node "' + n.alias + '" missing objectApiName');
            } else if (Type.forName(n.objectApiName) == null) {
                errors.add('node "' + n.alias + '" has unknown objectApiName "' + n.objectApiName + '"');
            }
        }
        return errors;
    }

    /**
     * Diff the desired graph against current DB state and return op-tagged nodes.
     * For now this honours the op the caller supplied. TODO: implement child-
     * collection reconciliation — load existing children of each parent, then:
     *   existing not in request  -> delete
     *   in request with recordId -> update (changed fields only)
     *   in request without id    -> insert
     * plus optimistic locking via LastModifiedDate.
     */
    @TestVisible
    private List<GraphNode> computeDiff(RecordGraphRequest req) {
        return req.nodes;
    }

    /**
     * Coerce a raw JSON value to the field's type (e.g. picklist case, Decimal).
     * TODO: use Schema.describe to map picklist labels/values and numeric types.
     */
    private Object coerce(String objectApiName, String fieldApiName, Object value) {
        return value;
    }
}
