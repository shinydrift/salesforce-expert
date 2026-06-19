/**
 * Tests for the engine. The create/alias/topo-sort/rollback cases use Account ->
 * Contact (cheap standard objects). Describe-validation, coercion, child-collection
 * diff, and optimistic locking are exercised here too; the full Opportunity ->
 * OpportunityLineItem path (pricebook + ProductCode resolution) lives in
 * CreateOpportunityWithProductsTest.
 */
@IsTest
private class RecordGraphSyncTest {

    private static GraphNode node(String alias, String obj, String op,
                                  String parentAlias, String parentField, Map<String, Object> fields) {
        GraphNode n = new GraphNode();
        n.alias = alias;
        n.objectApiName = obj;
        n.op = op;
        n.parentAlias = parentAlias;
        n.parentField = parentField;
        n.fields = (fields == null) ? new Map<String, Object>() : fields;
        return n;
    }

    @IsTest
    static void sync_createsParentAndChildren_inOneTransaction() {
        RecordGraphRequest req = new RecordGraphRequest();
        req.nodes.add(node('acct', 'Account', 'create', null, null,
            new Map<String, Object>{ 'Name' => 'Acme Corp' }));
        // Children deliberately listed before/around the parent — engine topo-sorts.
        req.nodes.add(node('c1', 'Contact', 'create', 'acct', 'AccountId',
            new Map<String, Object>{ 'LastName' => 'Doe' }));
        req.nodes.add(node('c2', 'Contact', 'create', 'acct', 'AccountId',
            new Map<String, Object>{ 'LastName' => 'Roe' }));

        Test.startTest();
        RecordGraphResult result = new RecordGraphSync().sync(req);
        Test.stopTest();

        System.assert(result.success, result.message);
        System.assertEquals(3, result.aliasToId.size(), 'all three nodes persisted');

        Id acctId = result.aliasToId.get('acct');
        List<Contact> kids = [SELECT Id FROM Contact WHERE AccountId = :acctId];
        System.assertEquals(2, kids.size(), 'both contacts linked to the account');
    }

    @IsTest
    static void sync_emptyRequest_failsCleanly() {
        RecordGraphResult result = new RecordGraphSync().sync(new RecordGraphRequest());
        System.assert(!result.success);
        System.assertEquals('Request had no nodes', result.message);
    }

    @IsTest
    static void sync_missingParentAlias_rollsBack() {
        RecordGraphRequest req = new RecordGraphRequest();
        req.nodes.add(node('c1', 'Contact', 'create', 'ghost', 'AccountId',
            new Map<String, Object>{ 'LastName' => 'Orphan' }));

        Test.startTest();
        RecordGraphResult result = new RecordGraphSync().sync(req);
        Test.stopTest();

        System.assert(!result.success, 'unresolved parent should fail');
        System.assert(result.message.contains('ghost'), result.message);
    }

    @IsTest
    static void topoSort_ordersParentsBeforeChildren() {
        List<GraphNode> nodes = new List<GraphNode>{
            node('child', 'Contact', 'create', 'parent', 'AccountId', null),
            node('parent', 'Account', 'create', null, null, null)
        };
        List<GraphNode> ordered = new RecordGraphSync().topoSort(nodes);
        System.assertEquals('parent', ordered[0].alias, 'parent comes first');
        System.assertEquals('child', ordered[1].alias);
    }

    @IsTest
    static void resolvePlaceholders_substitutesValuesAndDefaults() {
        String json = '{"a":"${opportunityId}","b":"${quantity|1}"}';
        Map<String, Object> params = new Map<String, Object>{ 'opportunityId' => '006XXSENTINEL' };
        String resolved = TemplateExpander.resolvePlaceholders(json, params);
        System.assert(resolved.contains('006XXSENTINEL'), 'param substituted');
        System.assert(resolved.contains('"b":"1"'), 'default applied when param absent');
    }

    @IsTest
    static void fromJson_parsesWireFormat() {
        String wire = '{"clientRequestId":"r1","source":"unit",' +
            '"nodes":[{"alias":"acct","objectApiName":"Account","op":"create",' +
            '"fields":{"Name":"Wire Co"}},' +
            '{"alias":"c","objectApiName":"Contact","op":"create","parentAlias":"acct",' +
            '"parentField":"AccountId","id":"003000000000001","fields":{"LastName":"Wired"}}]}';
        RecordGraphRequest req = RecordGraphRequest.fromJson(wire);

        System.assertEquals('r1', req.clientRequestId);
        System.assertEquals('unit', req.source);
        System.assertEquals(2, req.nodes.size());
        System.assertEquals('Wire Co', req.nodes[0].fields.get('Name'));
        // `id` in the wire format maps to recordId.
        System.assertEquals('003000000000001', req.nodes[1].recordId);
        System.assertEquals('acct', req.nodes[1].parentAlias);
    }

    // --- validation -----------------------------------------------------------

    @IsTest
    static void validate_rejectsUnknownField() {
        RecordGraphRequest req = new RecordGraphRequest();
        req.nodes.add(node('a', 'Account', 'create', null, null,
            new Map<String, Object>{ 'Name' => 'X', 'NotARealField__c' => 'y' }));
        List<String> errors = new RecordGraphSync().validate(req);
        System.assert(!errors.isEmpty(), 'should flag unknown field');
        System.assert(String.join(errors, ';').contains('unknown field'), String.join(errors, ';'));
    }

    @IsTest
    static void validate_rejectsBadPicklistValue() {
        RecordGraphRequest req = new RecordGraphRequest();
        req.nodes.add(node('a', 'Account', 'create', null, null,
            new Map<String, Object>{ 'Name' => 'X', 'Industry' => 'NotAnIndustry' }));
        List<String> errors = new RecordGraphSync().validate(req);
        System.assert(String.join(errors, ';').contains('picklist'), String.join(errors, ';'));
    }

    @IsTest
    static void validate_rejectsMissingRequiredField() {
        RecordGraphRequest req = new RecordGraphRequest();
        // Contact with no LastName (a required field).
        req.nodes.add(node('c', 'Contact', 'create', null, null,
            new Map<String, Object>{ 'FirstName' => 'NoLast' }));
        List<String> errors = new RecordGraphSync().validate(req);
        System.assert(String.join(errors, ';').contains('LastName'), String.join(errors, ';'));
    }

    @IsTest
    static void validate_unknownObject_isReported() {
        RecordGraphRequest req = new RecordGraphRequest();
        req.nodes.add(node('x', 'NotAnSObject__x', 'create', null, null,
            new Map<String, Object>{ 'Name' => 'X' }));
        List<String> errors = new RecordGraphSync().validate(req);
        System.assert(String.join(errors, ';').contains('unknown objectApiName'), String.join(errors, ';'));
    }

    // --- coercion -------------------------------------------------------------

    @IsTest
    static void coerce_convertsStringsToTypedValues() {
        RecordGraphSync engine = new RecordGraphSync();
        Object num = engine.coerce('Opportunity', 'Amount', '1500.50');
        System.assert(num instanceof Decimal, 'currency coerced to Decimal');
        System.assertEquals(1500.50, (Decimal) num);

        Object dt = engine.coerce('Opportunity', 'CloseDate', '2026-12-31');
        System.assert(dt instanceof Date, 'date string coerced to Date');
        System.assertEquals(Date.newInstance(2026, 12, 31), (Date) dt);
    }

    // --- child-collection diff ------------------------------------------------

    @IsTest
    static void computeDiff_deletesOrphanChildren() {
        Account a = new Account(Name = 'Acme');
        insert a;
        Contact keep = new Contact(LastName = 'Keep', AccountId = a.Id);
        Contact orphan = new Contact(LastName = 'Orphan', AccountId = a.Id);
        insert new List<Contact>{ keep, orphan };

        // Desired end-state: same account, keep one child, add a new one, drop "orphan".
        RecordGraphRequest req = new RecordGraphRequest();
        GraphNode acct = node('acct', 'Account', 'update', null, null,
            new Map<String, Object>{ 'Name' => 'Acme' });
        acct.recordId = a.Id;
        req.nodes.add(acct);

        GraphNode keptNode = node('keep', 'Contact', 'update', 'acct', 'AccountId',
            new Map<String, Object>{ 'LastName' => 'Keep' });
        keptNode.recordId = keep.Id;
        req.nodes.add(keptNode);

        req.nodes.add(node('fresh', 'Contact', 'create', 'acct', 'AccountId',
            new Map<String, Object>{ 'LastName' => 'Fresh' }));

        Test.startTest();
        RecordGraphResult result = new RecordGraphSync().sync(req);
        Test.stopTest();

        System.assert(result.success, result.message);
        Map<Id, Contact> remaining = new Map<Id, Contact>(
            [SELECT Id, LastName FROM Contact WHERE AccountId = :a.Id]);
        System.assertEquals(2, remaining.size(), 'orphan deleted, keep + fresh remain');
        Set<String> names = new Set<String>();
        for (Contact c : remaining.values()) {
            names.add(c.LastName);
        }
        System.assert(!names.contains('Orphan'), 'orphan child was reconciled away');
        System.assert(names.contains('Keep') && names.contains('Fresh'), names + '');
    }

    // --- optimistic locking ---------------------------------------------------

    @IsTest
    static void optimisticLock_rejectsStaleUpdate() {
        Account a = new Account(Name = 'Acme');
        insert a;

        RecordGraphRequest req = new RecordGraphRequest();
        GraphNode n = node('acct', 'Account', 'update', null, null,
            new Map<String, Object>{ 'Name' => 'Renamed' });
        n.recordId = a.Id;
        n.expectedLastModified = '2000-01-01T00:00:00Z'; // deliberately stale
        req.nodes.add(n);

        Test.startTest();
        RecordGraphResult result = new RecordGraphSync().sync(req);
        Test.stopTest();

        System.assert(!result.success, 'stale update should be rejected');
        System.assert(result.message.contains('optimistic lock'), result.message);
        System.assertEquals('Acme', [SELECT Name FROM Account WHERE Id = :a.Id].Name,
            'record left unchanged');
    }

    @IsTest
    static void optimisticLock_allowsCurrentLastModified() {
        // Happy path: the client passes back the record's *current* LastModifiedDate,
        // including sub-second millis (exactly how a serialized SF Datetime looks). The
        // lock must accept this and let the update through — the bug this guards against
        // was an exact-equality compare that falsely rejected every non-stale update.
        Account a = new Account(Name = 'Acme');
        insert a;
        Datetime lm = [SELECT LastModifiedDate FROM Account WHERE Id = :a.Id].LastModifiedDate;
        // ISO-8601 with millis + 'Z', the value a client would round-trip unchanged.
        String isoWithMillis = lm.formatGmt('yyyy-MM-dd\'T\'HH:mm:ss.SSS\'Z\'');

        RecordGraphRequest req = new RecordGraphRequest();
        GraphNode n = node('acct', 'Account', 'update', null, null,
            new Map<String, Object>{ 'Name' => 'Renamed' });
        n.recordId = a.Id;
        n.expectedLastModified = isoWithMillis;
        req.nodes.add(n);

        Test.startTest();
        RecordGraphResult result = new RecordGraphSync().sync(req);
        Test.stopTest();

        System.assert(result.success, 'current LastModifiedDate should pass the lock: ' + result.message);
        System.assertEquals('Renamed', [SELECT Name FROM Account WHERE Id = :a.Id].Name,
            'update should have been applied');
    }
}
