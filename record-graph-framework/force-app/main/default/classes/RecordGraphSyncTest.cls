/**
 * Starter tests for the engine. Uses Account -> Contact (cheap standard objects
 * with simple required fields) to exercise alias resolution, parent-FK back-fill,
 * topo-sort, and transactional insert without Pricebook/Quote setup. Swap in
 * Quote -> QuoteLineItem once a Pricebook fixture is in place.
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
}
