/**
 * The engine. Takes a desired RecordGraphRequest and reconciles it into the org:
 *
 *   resolve domain refs → validate (vs describe) → diff (vs current DB state) →
 *   topo-sort → resolve aliases to Ids → transactional DML → RecordGraphResult
 *
 * All of these are now implemented:
 *  - resolveReferences: defaults a Pricebook on Opportunity/Quote nodes and turns a
 *    synthetic `ProductCode` on line-item nodes into a real `PricebookEntryId`.
 *  - validate: describe-driven — object exists, every field exists and is writeable
 *    for the node's op, picklist values are live values, required fields are present.
 *  - computeDiff: child-collection reconciliation for existing parents (orphan
 *    children are deleted) plus optimistic locking via LastModifiedDate.
 *  - coerce: describe-driven type coercion (Decimal/Date/Datetime/Boolean/picklist).
 *  - topo-sort + savepoint DML: parents before children, all-or-nothing.
 */
public with sharing class RecordGraphSync {

    public class GraphException extends Exception {}

    // --- domain reference-resolution configuration ----------------------------
    // The engine itself is object-agnostic. The ONE place it knows about a specific
    // domain is here: the pricebook/ProductCode convention used by Opportunity and
    // Quote line items. To support another priced object (or a different business-key
    // reference), extend this config rather than editing resolveReferences() inline —
    // add the host object to PRICEBOOK_HOST_OBJECTS. A future generalisation would
    // make this a pluggable ReferenceResolver interface; until a second convention
    // exists, a single declared config block keeps the seam visible and contained.

    /** Objects whose line items are priced from a Pricebook2 (host carries Pricebook2Id). */
    @TestVisible
    private static final Set<String> PRICEBOOK_HOST_OBJECTS =
        new Set<String>{ 'Opportunity', 'Quote' };

    /** Synthetic field the engine resolves to PricebookEntryId then strips before DML. */
    @TestVisible
    private static final String PRODUCT_CODE_FIELD = 'ProductCode';

    private final DescribeCache describes = new DescribeCache();

    public RecordGraphResult sync(RecordGraphRequest req) {
        RecordGraphResult result = new RecordGraphResult();

        if (req == null || req.nodes == null || req.nodes.isEmpty()) {
            result.message = 'Request had no nodes';
            return result;
        }

        Savepoint sp = Database.setSavepoint();
        Map<String, Id> aliasToId = new Map<String, Id>();
        try {
            // a. Resolve domain references (pricebook default, ProductCode -> PricebookEntryId).
            resolveReferences(req);

            // b. Validate the resolved graph against describe metadata.
            List<String> errors = validate(req);
            if (!errors.isEmpty()) {
                // Nothing has been written yet — return a clean validation failure.
                result.success = false;
                result.message = 'Validation failed: ' + String.join(errors, '; ');
                return result;
            }

            // c. Diff the desired end-state against current DB state (adds orphan deletes,
            //    enforces optimistic locks).
            List<GraphNode> reconciled = computeDiff(req);

            // d. Order so parents are processed before children, then split into
            //    breadth levels (a node's level is its parent's + 1).
            List<List<GraphNode>> levels = groupByLevel(topoSort(reconciled));

            // e. Resolve + apply level-by-level — all-or-nothing. Each level issues
            //    one DML per (object, op) bucket, so the statement count is
            //    O(levels x objects x ops) rather than O(nodes). Every node's parent
            //    sits at a strictly lower level, so its Id is already resolved.
            for (List<GraphNode> level : levels) {
                applyLevel(level, aliasToId, result);
            }
            result.success = true;
            result.message = 'Graph synced: ' + result.aliasToId.size() + ' record(s) persisted';
        } catch (Exception e) {
            Database.rollback(sp);
            result.success = false;
            // Everything is undone — don't report rolled-back nodes as persisted.
            result.aliasToId = new Map<String, Id>();
            result.nodeResults.clear();
            result.message = 'Rolled back: ' + e.getMessage();
        }
        return result;
    }

    // --- core: apply one breadth level ----------------------------------------

    /**
     * Split a topo-ordered list into breadth levels. A node's level is its parent's
     * level + 1 (roots and orphan-delete nodes are level 0). Because each node has at
     * most one parent (single parentAlias), levels are unambiguous, and iterating the
     * already parent-before-child ordering means a parent's level is known before its
     * children are reached.
     */
    private List<List<GraphNode>> groupByLevel(List<GraphNode> ordered) {
        Map<String, Integer> levelByAlias = new Map<String, Integer>();
        List<List<GraphNode>> levels = new List<List<GraphNode>>();
        for (GraphNode n : ordered) {
            Integer lvl = 0;
            if (String.isNotBlank(n.parentAlias) && levelByAlias.containsKey(n.parentAlias)) {
                lvl = levelByAlias.get(n.parentAlias) + 1;
            }
            levelByAlias.put(n.alias, lvl);
            while (levels.size() <= lvl) {
                levels.add(new List<GraphNode>());
            }
            levels.get(lvl).add(n);
        }
        return levels;
    }

    /**
     * Apply one level: bucket its nodes by (objectApiName, op) and issue a single bulk
     * DML per bucket. All parent Ids are already resolved (parents live at lower levels),
     * so bucket order never affects FK back-filling.
     *
     * Within a level the buckets run in a fixed op order — delete, then update, upsert,
     * create — so a record that frees a unique key (or is otherwise removed/changed) is
     * processed before any create that might reuse it. Siblings at the same level have no
     * FK dependency on each other, so this ordering is the only intra-level concern.
     * Among buckets sharing an op (different objects), first-appearance order is kept.
     */
    private static final List<String> OP_ORDER =
        new List<String>{ 'delete', 'update', 'upsert', 'create' };

    private void applyLevel(List<GraphNode> level, Map<String, Id> aliasToId, RecordGraphResult result) {
        Map<String, List<GraphNode>> byBucket = new Map<String, List<GraphNode>>();
        List<String> bucketOrder = new List<String>();
        for (GraphNode n : level) {
            String op = String.isBlank(n.op) ? 'create' : n.op.toLowerCase();
            if (!OP_ORDER.contains(op)) {
                throw new GraphException('unknown op "' + n.op + '" on node "' + n.alias + '"');
            }
            String key = n.objectApiName + '|' + op;
            if (!byBucket.containsKey(key)) {
                byBucket.put(key, new List<GraphNode>());
                bucketOrder.add(key);
            }
            byBucket.get(key).add(n);
        }
        // Run buckets grouped by op priority; first-appearance order breaks ties.
        for (String op : OP_ORDER) {
            for (String key : bucketOrder) {
                if (key.substringAfterLast('|') == op) {
                    applyBucket(op, byBucket.get(key), aliasToId, result);
                }
            }
        }
    }

    /** Apply one (object, op) bucket of nodes with a single bulk DML statement. */
    private void applyBucket(String op, List<GraphNode> nodes,
                             Map<String, Id> aliasToId, RecordGraphResult result) {
        if (op == 'delete') {
            List<Id> ids = new List<Id>();
            for (GraphNode n : nodes) {
                if (String.isBlank(n.recordId)) {
                    throw new GraphException('delete node "' + n.alias + '" has no recordId');
                }
                ids.add((Id) n.recordId);
            }
            Database.delete(ids, true);
            for (GraphNode n : nodes) {
                result.record(n.alias, n.objectApiName, op, (Id) n.recordId, true, null);
            }
            return;
        }

        // SObject list stays index-parallel to `nodes` so freshly-assigned Ids map back.
        List<SObject> records = new List<SObject>();
        for (GraphNode n : nodes) {
            SObject record = buildSObject(n, aliasToId, op);
            if (op == 'update' && record.Id == null) {
                throw new GraphException('update node "' + n.alias + '" has no recordId');
            }
            records.add(record);
        }

        if (op == 'create') {
            Database.insert(records, true);
        } else if (op == 'update') {
            Database.update(records, true);
        } else if (op == 'upsert') {
            // Id-based bulk upsert; allOrNone throws on any failure, which the
            // surrounding savepoint/try-catch turns into a rollback.
            Database.upsert(records, true);
        }

        for (Integer i = 0; i < nodes.size(); i++) {
            GraphNode n = nodes[i];
            Id rid = records[i].Id;
            // Make this node's freshly-resolved Id available to later children whose
            // parentAlias points at it (buildSObject reads this map to back-fill the FK).
            aliasToId.put(n.alias, rid);
            result.record(n.alias, n.objectApiName, op, rid, true, null);
        }
    }

    /** Build an SObject from a node, back-filling the parent FK from the alias map. */
    private SObject buildSObject(GraphNode node, Map<String, Id> aliasToId, String op) {
        SObjectType t = describes.sObjectType(node.objectApiName);
        SObject record = t.newSObject();

        if (String.isNotBlank(node.recordId)) {
            record.put('Id', (Id) node.recordId);
        }
        // Resolve the parent link: child's FK = the parent's freshly-inserted Id.
        // Only on insert/upsert — parent FKs (e.g. OpportunityId) are not editable on
        // an existing child, and an update doesn't re-parent it.
        if (String.isNotBlank(node.parentAlias) && op != 'update') {
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
                record.put(describes.fieldName(node.objectApiName, f),
                           coerce(node.objectApiName, f, node.fields.get(f)));
            }
        }
        return record;
    }

    // --- reference resolution: pricebook default + ProductCode -> PricebookEntry ---

    /**
     * Resolves domain references that templates express by business key rather than
     * Id, mutating the request in place:
     *   1. Opportunity/Quote nodes without a Pricebook2Id get the standard pricebook.
     *   2. Line-item nodes carrying a synthetic `ProductCode` get a real
     *      `PricebookEntryId` (looked up against their parent's pricebook), and the
     *      synthetic field is removed so describe-validation only sees real fields.
     * No-op for graphs that use neither convention.
     */
    @TestVisible
    private void resolveReferences(RecordGraphRequest req) {
        Map<String, GraphNode> byAlias = aliasMap(req.nodes);

        // 1. Collect line-item nodes that need a PricebookEntry lookup.
        List<GraphNode> productNodes = new List<GraphNode>();
        for (GraphNode n : req.nodes) {
            if (n.fields != null && n.fields.containsKey(PRODUCT_CODE_FIELD)) {
                productNodes.add(n);
            }
        }

        Boolean needsStandardPricebook = false;
        for (GraphNode n : req.nodes) {
            // n.fields may be null (a host node with no explicit fields) — guard like
            // the ProductCode collection above and treat it as lacking a pricebook.
            if (isPricebookHost(n.objectApiName)
                && (n.fields == null || !n.fields.containsKey('Pricebook2Id'))) {
                needsStandardPricebook = true;
            }
        }
        if (productNodes.isEmpty() && !needsStandardPricebook) {
            return;
        }

        Id standardPricebookId = standardPricebookId();

        // 2. Default the pricebook on every host node that lacks one.
        for (GraphNode n : req.nodes) {
            if (isPricebookHost(n.objectApiName)
                && (n.fields == null || !n.fields.containsKey('Pricebook2Id'))) {
                if (n.fields == null) {
                    n.fields = new Map<String, Object>();
                }
                n.fields.put('Pricebook2Id', standardPricebookId);
            }
        }
        if (productNodes.isEmpty()) {
            return;
        }

        // 3. Work out which pricebook each product node resolves against (its parent's).
        Set<String> codes = new Set<String>();
        Set<Id> pricebookIds = new Set<Id>();
        Map<GraphNode, Id> nodePricebook = new Map<GraphNode, Id>();
        for (GraphNode n : productNodes) {
            Id pbId = pricebookForLine(n, byAlias, standardPricebookId);
            nodePricebook.put(n, pbId);
            pricebookIds.add(pbId);
            codes.add(String.valueOf(n.fields.get(PRODUCT_CODE_FIELD)));
        }

        // 4. One query to resolve (pricebook, productCode) -> PricebookEntry (id + price).
        Map<String, PricebookEntry> entryByKey = new Map<String, PricebookEntry>();
        for (PricebookEntry pbe : [
            SELECT Id, UnitPrice, Pricebook2Id, Product2.ProductCode
            FROM PricebookEntry
            WHERE IsActive = true
              AND Pricebook2Id IN :pricebookIds
              AND Product2.ProductCode IN :codes
        ]) {
            entryByKey.put(pbe.Pricebook2Id + '|' + pbe.Product2.ProductCode, pbe);
        }

        // 5. Rewrite each product node: drop ProductCode, set PricebookEntryId, and
        //    default UnitPrice from the entry (line items require a price on insert).
        for (GraphNode n : productNodes) {
            String code = String.valueOf(n.fields.get(PRODUCT_CODE_FIELD));
            Id pbId = nodePricebook.get(n);
            PricebookEntry entry = entryByKey.get(pbId + '|' + code);
            if (entry == null) {
                throw new GraphException(
                    'no active PricebookEntry for ProductCode "' + code +
                    '" in pricebook ' + pbId + ' (node "' + n.alias + '")'
                );
            }
            n.fields.remove(PRODUCT_CODE_FIELD);
            n.fields.put('PricebookEntryId', entry.Id);
            if (!n.fields.containsKey('UnitPrice') && !n.fields.containsKey('TotalPrice')) {
                n.fields.put('UnitPrice', entry.UnitPrice);
            }
        }
    }

    private Id pricebookForLine(GraphNode line, Map<String, GraphNode> byAlias, Id fallback) {
        if (String.isNotBlank(line.parentAlias)) {
            GraphNode parent = byAlias.get(line.parentAlias);
            if (parent != null && parent.fields != null && parent.fields.get('Pricebook2Id') != null) {
                return (Id) parent.fields.get('Pricebook2Id');
            }
        }
        return fallback;
    }

    private Boolean isPricebookHost(String objectApiName) {
        return PRICEBOOK_HOST_OBJECTS.contains(objectApiName);
    }

    private Id standardPricebookId() {
        // In a test context no standard pricebook is "deployed"; Test provides one.
        if (Test.isRunningTest()) {
            return Test.getStandardPricebookId();
        }
        List<Pricebook2> pbs = [SELECT Id FROM Pricebook2 WHERE IsStandard = true LIMIT 1];
        if (pbs.isEmpty()) {
            throw new GraphException('no standard Pricebook2 found in this org');
        }
        return pbs[0].Id;
    }

    // --- validation: describe-driven ------------------------------------------

    /**
     * Validate the resolved graph against describe metadata: object exists, every
     * supplied field exists and is writeable for the node's op, picklist values are
     * real values, and required fields are present for create.
     */
    @TestVisible
    private List<String> validate(RecordGraphRequest req) {
        List<String> errors = new List<String>();
        for (GraphNode n : req.nodes) {
            String op = String.isBlank(n.op) ? 'create' : n.op.toLowerCase();

            if (String.isBlank(n.alias)) {
                errors.add('a node is missing alias');
            }
            if (String.isBlank(n.objectApiName)) {
                errors.add('node "' + n.alias + '" missing objectApiName');
                continue;
            }
            SObjectType sot = describes.sObjectType(n.objectApiName);
            if (sot == null) {
                errors.add('node "' + n.alias + '" has unknown objectApiName "' + n.objectApiName + '"');
                continue;
            }
            if (op == 'delete' || op == 'update') {
                if (String.isBlank(n.recordId)) {
                    errors.add('node "' + n.alias + '" op "' + op + '" requires a recordId');
                }
            }
            if (op == 'delete') {
                continue; // no field checks for deletes
            }

            Map<String, Schema.SObjectField> fieldMap = describes.fieldMap(n.objectApiName);
            Boolean isCreate = (op == 'create');

            // Supplied fields: existence + writeability + picklist value.
            if (n.fields != null) {
                for (String f : n.fields.keySet()) {
                    Schema.SObjectField token = fieldMap.get(f.toLowerCase());
                    if (token == null) {
                        errors.add('node "' + n.alias + '" has unknown field "' + f + '" on ' + n.objectApiName);
                        continue;
                    }
                    Schema.DescribeFieldResult dfr = token.getDescribe();
                    Boolean writeable = isCreate ? dfr.isCreateable() : dfr.isUpdateable();
                    if (!writeable) {
                        errors.add('node "' + n.alias + '" field "' + f + '" is not ' +
                                   (isCreate ? 'createable' : 'updateable'));
                        continue;
                    }
                    String picklistError = checkPicklist(dfr, f, n.fields.get(f), n.alias);
                    if (picklistError != null) {
                        errors.add(picklistError);
                    }
                }
            }

            // Required fields (create only): every createable, non-nillable, non-defaulted
            // field must be supplied directly or satisfied by the parent FK.
            if (isCreate) {
                for (String reqField : describes.requiredCreateFields(n.objectApiName)) {
                    Boolean supplied = n.fields != null && containsKeyCI(n.fields, reqField);
                    Boolean isParentFk = String.isNotBlank(n.parentField)
                        && n.parentField.equalsIgnoreCase(reqField);
                    if (!supplied && !isParentFk) {
                        errors.add('node "' + n.alias + '" missing required field "' + reqField +
                                   '" on ' + n.objectApiName);
                    }
                }
            }
        }
        return errors;
    }

    private String checkPicklist(Schema.DescribeFieldResult dfr, String fieldName, Object value, String alias) {
        if (value == null) {
            return null;
        }
        Schema.DisplayType dt = dfr.getType();
        if (dt != Schema.DisplayType.Picklist && dt != Schema.DisplayType.MultiPicklist) {
            return null;
        }
        Set<String> valid = new Set<String>();
        for (Schema.PicklistEntry pe : dfr.getPicklistValues()) {
            if (pe.isActive()) {
                valid.add(pe.getValue().toLowerCase());
                valid.add(pe.getLabel().toLowerCase());
            }
        }
        if (!valid.contains(String.valueOf(value).toLowerCase())) {
            return 'node "' + alias + '" field "' + fieldName + '" value "' + value +
                   '" is not a valid picklist value';
        }
        return null;
    }

    // --- diff: child-collection reconciliation + optimistic locking ------------

    /**
     * Diff the desired graph against current DB state and return op-tagged nodes:
     *   - For every existing parent (recordId set) whose children are declared in the
     *     request, any current child of that (parent, object, FK) NOT named in the
     *     request is appended as a delete node (child-collection reconciliation).
     *   - For every update (or upsert that targets an existing record) node carrying
     *     expectedLastModified, the live LastModifiedDate is compared and a stale write
     *     is rejected (optimistic lock).
     */
    @TestVisible
    private List<GraphNode> computeDiff(RecordGraphRequest req) {
        List<GraphNode> out = new List<GraphNode>(req.nodes);
        Map<String, GraphNode> byAlias = aliasMap(req.nodes);

        // Optimistic locking on updates and upserts that target an existing record.
        enforceOptimisticLocks(req.nodes);

        // Group requested children by (object, fk) so each child collection is
        // reconciled with ONE bulk query (per object/FK) rather than one per parent.
        Map<String, Schema.SObjectType> groupType = new Map<String, Schema.SObjectType>();
        Map<String, String> groupFk = new Map<String, String>();
        Map<String, Set<Id>> groupParentIds = new Map<String, Set<Id>>();
        // Per (object, fk, parentId): the child Ids the request wants to keep.
        Map<String, Set<Id>> keepByParent = new Map<String, Set<Id>>();

        for (GraphNode n : req.nodes) {
            if (String.isBlank(n.parentAlias)) {
                continue;
            }
            GraphNode parent = byAlias.get(n.parentAlias);
            if (parent == null || String.isBlank(parent.recordId)) {
                continue; // only reconcile children of *existing* parents
            }
            Id parentId = (Id) parent.recordId;
            String groupKey = n.objectApiName + '|' + n.parentField;
            groupType.put(groupKey, describes.sObjectType(n.objectApiName));
            groupFk.put(groupKey, n.parentField);
            if (!groupParentIds.containsKey(groupKey)) {
                groupParentIds.put(groupKey, new Set<Id>());
            }
            groupParentIds.get(groupKey).add(parentId);

            String parentKey = groupKey + '|' + parentId;
            if (!keepByParent.containsKey(parentKey)) {
                keepByParent.put(parentKey, new Set<Id>());
            }
            if (String.isNotBlank(n.recordId)) {
                keepByParent.get(parentKey).add((Id) n.recordId);
            }
        }

        // One bulk query per (object, fk): anything under a reconciled parent that the
        // request doesn't name is an orphan -> delete.
        for (String groupKey : groupType.keySet()) {
            String objName = groupType.get(groupKey).getDescribe().getName();
            // Validate the FK against describe BEFORE interpolating it into SOQL — it
            // is caller-supplied (node.parentField) and must never be concatenated raw.
            Schema.SObjectField fkToken =
                describes.fieldMap(objName).get(groupFk.get(groupKey).toLowerCase());
            if (fkToken == null) {
                throw new GraphException(
                    'parentField "' + groupFk.get(groupKey) + '" is not a field on ' + objName
                );
            }
            String fkName = fkToken.getDescribe().getName();
            Set<Id> parentIds = groupParentIds.get(groupKey);
            String soql = 'SELECT Id, ' + fkName + ' FROM ' + objName +
                          ' WHERE ' + fkName + ' IN :parentIds';
            for (SObject existing : Database.query(soql)) {
                Id childId = (Id) existing.get('Id');
                Id parentId = (Id) existing.get(fkName);
                Set<Id> keep = keepByParent.get(groupKey + '|' + parentId);
                if (keep == null || !keep.contains(childId)) {
                    GraphNode del = new GraphNode();
                    del.alias = '_orphan_' + childId;
                    del.objectApiName = objName;
                    del.op = 'delete';
                    del.recordId = String.valueOf(childId);
                    out.add(del);
                }
            }
        }
        return out;
    }

    private void enforceOptimisticLocks(List<GraphNode> nodes) {
        Map<Id, GraphNode> guarded = new Map<Id, GraphNode>();
        Map<Schema.SObjectType, Set<Id>> idsByType = new Map<Schema.SObjectType, Set<Id>>();
        for (GraphNode n : nodes) {
            String op = String.isBlank(n.op) ? 'create' : n.op.toLowerCase();
            // Updates always target an existing record; an upsert does too whenever it
            // carries a recordId (a recordId-less upsert is a create — nothing to lock).
            if ((op == 'update' || op == 'upsert')
                && String.isNotBlank(n.recordId) && String.isNotBlank(n.expectedLastModified)) {
                Id rid = (Id) n.recordId;
                guarded.put(rid, n);
                Schema.SObjectType sot = describes.sObjectType(n.objectApiName);
                if (!idsByType.containsKey(sot)) {
                    idsByType.put(sot, new Set<Id>());
                }
                idsByType.get(sot).add(rid);
            }
        }
        for (Schema.SObjectType sot : idsByType.keySet()) {
            String objName = sot.getDescribe().getName();
            Set<Id> ids = idsByType.get(sot);
            for (SObject row : Database.query(
                'SELECT Id, LastModifiedDate FROM ' + objName + ' WHERE Id IN :ids')) {
                GraphNode n = guarded.get((Id) row.get('Id'));
                Datetime live = (Datetime) row.get('LastModifiedDate');
                // Compare at second precision in GMT. The client round-trips an ISO
                // string (e.g. '2026-06-16T10:30:45.123Z'); the live value carries
                // sub-second millis. Exact Datetime equality would falsely reject every
                // valid update (and parsing the '.123' fraction would throw), so both
                // sides are normalised to a canonical 'yyyy-MM-ddTHH:mm:ss' GMT key.
                if (secondKey(live) != secondKey(parseExpected(n.expectedLastModified))) {
                    throw new GraphException(
                        'optimistic lock failed for node "' + n.alias +
                        '": record ' + row.get('Id') + ' was modified concurrently'
                    );
                }
            }
        }
    }

    /** Second-precision GMT key for optimistic-lock comparison. */
    private String secondKey(Datetime dt) {
        return dt.formatGmt('yyyy-MM-dd\'T\'HH:mm:ss');
    }

    /**
     * Parse a client-supplied LastModifiedDate. Accepts ISO-8601 with optional
     * sub-second fraction and trailing 'Z' (GMT) — '2026-06-16T10:30:45.123Z',
     * '2026-06-16T10:30:45Z', or a plain '2026-06-16 10:30:45'. Sub-seconds are
     * stripped (we compare at second precision) and the value is read as GMT, which
     * is how a serialized Salesforce Datetime presents the 'Z'.
     */
    @TestVisible
    private Datetime parseExpected(String iso) {
        String s = iso.trim().replace('T', ' ').replace('Z', '').trim();
        Integer dot = s.indexOf('.');
        if (dot != -1) {
            s = s.substring(0, dot);
        }
        return Datetime.valueOfGmt(s);
    }

    // --- coercion: describe-driven type mapping --------------------------------

    /**
     * Coerce a raw JSON value to the field's Apex type so SObject.put() accepts it
     * (JSON numbers arrive as Integer/Double, dates as String, etc.).
     */
    @TestVisible
    private Object coerce(String objectApiName, String fieldApiName, Object value) {
        if (value == null) {
            return null;
        }
        Schema.SObjectField token = describes.fieldMap(objectApiName).get(fieldApiName.toLowerCase());
        if (token == null) {
            return value;
        }
        Schema.DisplayType dt = token.getDescribe().getType();
        String s = String.valueOf(value);
        try {
            if (dt == Schema.DisplayType.Currency || dt == Schema.DisplayType.Double
                || dt == Schema.DisplayType.Percent) {
                return Decimal.valueOf(s);
            } else if (dt == Schema.DisplayType.Integer) {
                return Integer.valueOf(s);
            } else if (dt == Schema.DisplayType.Boolean) {
                return Boolean.valueOf(s);
            } else if (dt == Schema.DisplayType.Date) {
                return Date.valueOf(s.length() == 10 ? s + ' 00:00:00' : s);
            } else if (dt == Schema.DisplayType.Datetime) {
                return Datetime.valueOf(s.replace('T', ' ').replace('Z', ''));
            }
        } catch (Exception e) {
            throw new GraphException('cannot coerce field "' + fieldApiName + '" value "' + s +
                                     '" to ' + dt + ' on ' + objectApiName);
        }
        return value; // strings, references, ids, picklists pass through
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

    // --- helpers ---------------------------------------------------------------

    private Map<String, GraphNode> aliasMap(List<GraphNode> nodes) {
        Map<String, GraphNode> byAlias = new Map<String, GraphNode>();
        for (GraphNode n : nodes) {
            byAlias.put(n.alias, n);
        }
        return byAlias;
    }

    private static Boolean containsKeyCI(Map<String, Object> m, String key) {
        for (String k : m.keySet()) {
            if (k.equalsIgnoreCase(key)) {
                return true;
            }
        }
        return false;
    }

    /** Small describe cache so a graph touching the same object describes it once. */
    private class DescribeCache {
        private final Map<String, Schema.SObjectType> typeByName = new Map<String, Schema.SObjectType>();
        private final Map<String, Map<String, Schema.SObjectField>> fieldsByName =
            new Map<String, Map<String, Schema.SObjectField>>();

        Schema.SObjectType sObjectType(String objectApiName) {
            String key = objectApiName.toLowerCase();
            if (!typeByName.containsKey(key)) {
                typeByName.put(key, Schema.getGlobalDescribe().get(key));
            }
            return typeByName.get(key);
        }

        Map<String, Schema.SObjectField> fieldMap(String objectApiName) {
            String key = objectApiName.toLowerCase();
            if (!fieldsByName.containsKey(key)) {
                fieldsByName.put(key, sObjectType(objectApiName).getDescribe().fields.getMap());
            }
            return fieldsByName.get(key);
        }

        /** Real, case-correct field API name for put(). */
        String fieldName(String objectApiName, String fieldApiName) {
            Schema.SObjectField token = fieldMap(objectApiName).get(fieldApiName.toLowerCase());
            return token == null ? fieldApiName : token.getDescribe().getName();
        }

        List<String> requiredCreateFields(String objectApiName) {
            List<String> required = new List<String>();
            for (Schema.SObjectField token : fieldMap(objectApiName).values()) {
                Schema.DescribeFieldResult d = token.getDescribe();
                if (d.isCreateable() && !d.isNillable() && !d.isDefaultedOnCreate()) {
                    required.add(d.getName());
                }
            }
            return required;
        }
    }
}
