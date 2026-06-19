/**
 * End-to-end test of the runnable invocable: template (CMDT) -> expand -> engine ->
 * Opportunity + OpportunityLineItems, including ProductCode -> PricebookEntryId
 * resolution against the standard pricebook. Builds its own Product/PricebookEntry
 * fixtures so it never depends on existing org data.
 */
@IsTest
private class CreateOpportunityWithProductsTest {

    @TestSetup
    static void seedProducts() {
        Id standardPb = Test.getStandardPricebookId();
        Product2 gen = new Product2(Name = 'GenWatt Diesel 200kW', ProductCode = 'GC104', IsActive = true);
        Product2 sla = new Product2(Name = 'SLA: Silver', ProductCode = 'SL9040', IsActive = true);
        insert new List<Product2>{ gen, sla };
        insert new List<PricebookEntry>{
            new PricebookEntry(Pricebook2Id = standardPb, Product2Id = gen.Id, UnitPrice = 2000, IsActive = true),
            new PricebookEntry(Pricebook2Id = standardPb, Product2Id = sla.Id, UnitPrice = 20000, IsActive = true)
        };
    }

    @IsTest
    static void run_createsOpportunityWithTwoLines() {
        CreateOpportunityWithProducts.Request r = new CreateOpportunityWithProducts.Request();
        r.opportunityName = 'Framework Test Opp';
        r.closeDate = '2026-12-31';
        r.quantity = 4;

        Test.startTest();
        List<CreateOpportunityWithProducts.Response> resps =
            CreateOpportunityWithProducts.run(new List<CreateOpportunityWithProducts.Request>{ r });
        Test.stopTest();

        CreateOpportunityWithProducts.Response resp = resps[0];
        System.assert(resp.success, resp.message);
        System.assertNotEquals(null, resp.opportunityId, 'opportunity created');
        System.assertEquals(2, resp.lineCount, 'two product lines created');

        Opportunity opp = [
            SELECT Id, Name, StageName, Pricebook2Id,
                   (SELECT Id, Quantity, PricebookEntryId, Product2.ProductCode FROM OpportunityLineItems)
            FROM Opportunity WHERE Id = :resp.opportunityId
        ];
        System.assertEquals('Framework Test Opp', opp.Name);
        System.assertEquals(Test.getStandardPricebookId(), opp.Pricebook2Id, 'pricebook defaulted');
        System.assertEquals(2, opp.OpportunityLineItems.size());

        Map<String, Decimal> qtyByCode = new Map<String, Decimal>();
        for (OpportunityLineItem oli : opp.OpportunityLineItems) {
            qtyByCode.put(oli.Product2.ProductCode, oli.Quantity);
        }
        System.assertEquals(4, qtyByCode.get('GC104'), 'quantity param flowed through');
        System.assertEquals(1, qtyByCode.get('SL9040'), 'fixed quantity from template');
    }

    @IsTest
    static void run_unknownProductCode_failsCleanly() {
        // A template whose product code has no PricebookEntry should roll back with a
        // clear message rather than throwing. Drive the engine directly with a bad code.
        RecordGraphRequest req = new RecordGraphRequest();
        GraphNode opp = new GraphNode();
        opp.alias = 'opp';
        opp.objectApiName = 'Opportunity';
        opp.op = 'create';
        opp.fields = new Map<String, Object>{
            'Name' => 'Bad', 'StageName' => 'Prospecting', 'CloseDate' => '2026-12-31'
        };
        GraphNode line = new GraphNode();
        line.alias = 'line';
        line.objectApiName = 'OpportunityLineItem';
        line.op = 'create';
        line.parentAlias = 'opp';
        line.parentField = 'OpportunityId';
        line.fields = new Map<String, Object>{ 'ProductCode' => 'NOPE999', 'Quantity' => 1 };
        req.nodes.add(opp);
        req.nodes.add(line);

        Test.startTest();
        RecordGraphResult result = new RecordGraphSync().sync(req);
        Test.stopTest();

        System.assert(!result.success, 'should fail');
        System.assert(result.message.contains('NOPE999'), result.message);
        System.assertEquals(0, [SELECT COUNT() FROM Opportunity WHERE Name = 'Bad'],
            'nothing persisted on rollback');
    }
}
