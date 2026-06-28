@isTest
private class DataCloudQueryControllerTest {

    @isTest
    static void mockReturnsKnownDataset() {
        Test.startTest();
        String jsonStr = DataCloudQueryController.runQuery('MOCK:sales_by_region');
        Test.stopTest();

        List<Object> rows = (List<Object>) JSON.deserializeUntyped(jsonStr);
        System.assertEquals(4, rows.size(), 'Expected four regions');
        Map<String, Object> first = (Map<String, Object>) rows[0];
        System.assertEquals('AMER', first.get('region'));
    }

    @isTest
    static void mockUnknownDatasetFallsBack() {
        String jsonStr = DataCloudQueryController.runQuery('MOCK:does_not_exist');
        List<Object> rows = (List<Object>) JSON.deserializeUntyped(jsonStr);
        System.assert(!rows.isEmpty(), 'Fallback dataset should not be empty');
    }

    @isTest
    static void blankQueryThrows() {
        try {
            DataCloudQueryController.runQuery('   ');
            System.assert(false, 'Expected an AuraHandledException');
        } catch (AuraHandledException e) {
            System.assert(true);
        }
    }

    @isTest
    static void normalizePositionalResponse() {
        String body = '{"data":[["AMER",10],["EMEA",20]],"metadata":{"region":{},"revenue":{}}}';
        String jsonStr = DataCloudQueryController.normalizeDataCloudResponse(body);
        List<Object> rows = (List<Object>) JSON.deserializeUntyped(jsonStr);
        System.assertEquals(2, rows.size());
        Map<String, Object> r0 = (Map<String, Object>) rows[0];
        System.assertEquals('AMER', r0.get('region'));
        System.assertEquals(10, r0.get('revenue'));
    }

    @isTest
    static void liveQueryUsesCallout() {
        Test.setMock(HttpCalloutMock.class, new DataCloudMock());
        Test.startTest();
        String jsonStr = DataCloudQueryController.runQuery('SELECT region, revenue FROM Sales__dlm');
        Test.stopTest();

        List<Object> rows = (List<Object>) JSON.deserializeUntyped(jsonStr);
        System.assertEquals(1, rows.size());
        Map<String, Object> r0 = (Map<String, Object>) rows[0];
        System.assertEquals('AMER', r0.get('region'));
    }

    @isTest
    static void liveQueryPropagatesHttpError() {
        Test.setMock(HttpCalloutMock.class, new DataCloudErrorMock());
        try {
            DataCloudQueryController.runQuery('SELECT 1');
            System.assert(false, 'Expected failure');
        } catch (AuraHandledException e) {
            System.assert(true);
        }
    }

    private class DataCloudMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setBody('{"data":[["AMER",42]],"metadata":{"region":{},"revenue":{}}}');
            return res;
        }
    }

    private class DataCloudErrorMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(500);
            res.setBody('{"error":"boom"}');
            return res;
        }
    }
}
