@RestResource(urlMapping='/cases/*')
global with sharing class CaseRestService {

    @HttpPost
    global static CaseResponse createCase(CaseRequestWrapper req) {
        if (req == null || String.isBlank(req.subject)) {
            RestContext.response.statusCode = 400;
            return new CaseResponse(null, null, 'subject is required');
        }

        Case c = mapToCase(req);

        try {
            insert c;
        } catch (DmlException e) {
            RestContext.response.statusCode = 500;
            return new CaseResponse(null, null, e.getMessage());
        }

        Case inserted = [
            SELECT Id, CaseNumber
            FROM Case
            WHERE Id = :c.Id
            LIMIT 1
        ];

        RestContext.response.statusCode = 201;
        return new CaseResponse(inserted.Id, inserted.CaseNumber, 'Case created');
    }

    private static Case mapToCase(CaseRequestWrapper req) {
        Case c = new Case();
        c.Subject         = req.subject;
        c.Description     = req.description;
        c.Status          = req.status;
        c.Priority        = req.priority;
        c.Origin          = req.origin;
        c.Type            = req.type;
        c.Reason          = req.reason;
        c.SuppliedName    = req.suppliedName;
        c.SuppliedEmail   = req.suppliedEmail;
        c.SuppliedPhone   = req.suppliedPhone;
        c.SuppliedCompany = req.suppliedCompany;
        if (String.isNotBlank(req.accountId)) c.AccountId = req.accountId;
        if (String.isNotBlank(req.contactId)) c.ContactId = req.contactId;
        return c;
    }

    global class CaseResponse {
        public String caseId;
        public String caseNumber;
        public String message;

        public CaseResponse(Id caseId, String caseNumber, String message) {
            this.caseId = caseId;
            this.caseNumber = caseNumber;
            this.message = message;
        }
    }
}
