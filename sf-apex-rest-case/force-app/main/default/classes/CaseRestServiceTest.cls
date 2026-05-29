@IsTest
private class CaseRestServiceTest {

    private static RestRequest buildRequest(String uri, String body) {
        RestRequest req = new RestRequest();
        req.requestUri = uri;
        req.httpMethod = 'POST';
        req.requestBody = Blob.valueOf(body);
        RestContext.request = req;
        RestContext.response = new RestResponse();
        return req;
    }

    @IsTest
    static void createCase_happyPath_returnsIdAndCaseNumber() {
        CaseRequestWrapper w = new CaseRequestWrapper();
        w.subject       = 'Printer on fire';
        w.description   = 'Smoke coming from tray 2';
        w.status        = 'New';
        w.priority      = 'High';
        w.origin        = 'Web';
        w.suppliedName  = 'Jane Doe';
        w.suppliedEmail = 'jane@example.com';

        buildRequest('/services/apexrest/cases/', JSON.serialize(w));

        Test.startTest();
        CaseRestService.CaseResponse resp = CaseRestService.createCase(w);
        Test.stopTest();

        System.assertNotEquals(null, resp.caseId, 'caseId should be set');
        System.assertNotEquals(null, resp.caseNumber, 'caseNumber should be set');
        System.assertEquals(201, RestContext.response.statusCode);

        Case c = [SELECT Subject, Priority, SuppliedEmail FROM Case WHERE Id = :resp.caseId];
        System.assertEquals('Printer on fire', c.Subject);
        System.assertEquals('High', c.Priority);
        System.assertEquals('jane@example.com', c.SuppliedEmail);
    }

    @IsTest
    static void createCase_missingSubject_returns400() {
        CaseRequestWrapper w = new CaseRequestWrapper();
        w.description = 'no subject here';

        buildRequest('/services/apexrest/cases/', JSON.serialize(w));

        CaseRestService.CaseResponse resp = CaseRestService.createCase(w);

        System.assertEquals(null, resp.caseId);
        System.assertEquals(400, RestContext.response.statusCode);
    }

    @IsTest
    static void uploadFile_happyPath_attachesContentVersionToCase() {
        Case parent = new Case(Subject = 'Parent for file');
        insert parent;

        FileRequestWrapper w = new FileRequestWrapper();
        w.caseId        = parent.Id;
        w.fileName      = 'hello.txt';
        w.contentBase64 = EncodingUtil.base64Encode(Blob.valueOf('hello world'));
        w.contentType   = 'text/plain';

        buildRequest('/services/apexrest/case-files/', JSON.serialize(w));

        Test.startTest();
        CaseFileRestService.FileResponse resp = CaseFileRestService.uploadFile(w);
        Test.stopTest();

        System.assertNotEquals(null, resp.contentVersionId, 'contentVersionId should be set');
        System.assertNotEquals(null, resp.contentDocumentId, 'contentDocumentId should be set');
        System.assertEquals(201, RestContext.response.statusCode);

        Integer linkCount = [
            SELECT COUNT()
            FROM ContentDocumentLink
            WHERE LinkedEntityId = :parent.Id AND ContentDocumentId = :resp.contentDocumentId
        ];
        System.assertEquals(1, linkCount, 'expected one ContentDocumentLink to the case');
    }

    @IsTest
    static void uploadFile_missingFields_returns400() {
        FileRequestWrapper w = new FileRequestWrapper();
        w.fileName = 'orphan.txt';

        buildRequest('/services/apexrest/case-files/', JSON.serialize(w));

        CaseFileRestService.FileResponse resp = CaseFileRestService.uploadFile(w);

        System.assertEquals(null, resp.contentVersionId);
        System.assertEquals(400, RestContext.response.statusCode);
    }
}
