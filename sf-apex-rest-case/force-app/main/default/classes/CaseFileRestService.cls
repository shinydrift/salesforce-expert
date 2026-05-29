@RestResource(urlMapping='/case-files/*')
global with sharing class CaseFileRestService {

    @HttpPost
    global static FileResponse uploadFile(FileRequestWrapper req) {
        if (req == null
            || String.isBlank(req.caseId)
            || String.isBlank(req.fileName)
            || String.isBlank(req.contentBase64)) {
            RestContext.response.statusCode = 400;
            return new FileResponse(null, null, 'caseId, fileName, and contentBase64 are required');
        }

        Blob fileBlob;
        try {
            fileBlob = EncodingUtil.base64Decode(req.contentBase64);
        } catch (Exception e) {
            RestContext.response.statusCode = 400;
            return new FileResponse(null, null, 'contentBase64 is not valid base64: ' + e.getMessage());
        }

        ContentVersion cv = mapToContentVersion(req, fileBlob);

        try {
            insert cv;
        } catch (DmlException e) {
            RestContext.response.statusCode = 500;
            return new FileResponse(null, null, e.getMessage());
        }

        ContentVersion inserted = [
            SELECT Id, ContentDocumentId
            FROM ContentVersion
            WHERE Id = :cv.Id
            LIMIT 1
        ];

        ensureLink(inserted.ContentDocumentId, req);

        RestContext.response.statusCode = 201;
        return new FileResponse(inserted.Id, inserted.ContentDocumentId, 'File uploaded');
    }

    private static ContentVersion mapToContentVersion(FileRequestWrapper req, Blob fileBlob) {
        ContentVersion cv = new ContentVersion();
        cv.Title                  = req.fileName;
        cv.PathOnClient           = req.fileName;
        cv.VersionData            = fileBlob;
        cv.FirstPublishLocationId = req.caseId;
        return cv;
    }

    private static void ensureLink(Id contentDocumentId, FileRequestWrapper req) {
        List<ContentDocumentLink> existing = [
            SELECT Id
            FROM ContentDocumentLink
            WHERE ContentDocumentId = :contentDocumentId AND LinkedEntityId = :req.caseId
            LIMIT 1
        ];
        if (!existing.isEmpty()) return;

        ContentDocumentLink link = new ContentDocumentLink();
        link.ContentDocumentId = contentDocumentId;
        link.LinkedEntityId    = req.caseId;
        link.ShareType         = String.isBlank(req.shareType) ? 'V' : req.shareType;
        link.Visibility        = String.isBlank(req.visibility) ? 'AllUsers' : req.visibility;
        insert link;
    }

    global class FileResponse {
        public String contentVersionId;
        public String contentDocumentId;
        public String message;

        public FileResponse(Id contentVersionId, Id contentDocumentId, String message) {
            this.contentVersionId = contentVersionId;
            this.contentDocumentId = contentDocumentId;
            this.message = message;
        }
    }
}
