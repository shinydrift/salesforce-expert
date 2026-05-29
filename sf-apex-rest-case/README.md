# sf-apex-rest-case-file

Salesforce Apex REST scaffold: two endpoints backed by split wrapper DTOs that share a common base.

- `POST /services/apexrest/cases/` — creates a `Case` from `CaseRequestWrapper`.
- `POST /services/apexrest/case-files/` — uploads a file (base64 in JSON) as a `ContentVersion` linked to a `Case` via `FirstPublishLocationId`, with an explicit `ContentDocumentLink` fallback.

## Wrappers

```
BaseRequestWrapper      (virtual)  clientRequestId, source
  ├─ CaseRequestWrapper            subject, description, status, priority, origin, type, reason,
  │                                suppliedName/Email/Phone/Company, accountId, contactId
  └─ FileRequestWrapper            caseId, fileName, contentBase64, contentType, shareType, visibility
```

Mapping from wrapper → SObject fields lives inside each REST class (`mapToCase`, `mapToContentVersion`) — keep request DTOs free of platform types.

## Practical limits

Practical max file size via this base64-in-JSON endpoint is **~4 MB binary** (sync Apex 6 MB heap + 6 MB HTTP request cap, base64 inflates ~33%). For larger payloads use async Apex, a raw-binary body variant, or skip Apex REST and hit standard REST `ContentVersion` multipart directly.

## Sample requests

Create a case:

```json
POST /services/apexrest/cases/
{
  "req": {
    "subject": "Printer on fire",
    "priority": "High",
    "origin": "Web",
    "suppliedEmail": "jane@example.com"
  }
}
```

Upload a file to that case:

```json
POST /services/apexrest/case-files/
{
  "req": {
    "caseId": "500xx0000000001",
    "fileName": "incident.pdf",
    "contentBase64": "<base64-encoded bytes>",
    "contentType": "application/pdf"
  }
}
```

## Deploy + run tests

```sh
sf project deploy start
sf apex run test --class-names CaseRestServiceTest --result-format human
```

## Files

- `force-app/main/default/classes/BaseRequestWrapper.cls`
- `force-app/main/default/classes/CaseRequestWrapper.cls`
- `force-app/main/default/classes/FileRequestWrapper.cls`
- `force-app/main/default/classes/CaseRestService.cls`
- `force-app/main/default/classes/CaseFileRestService.cls`
- `force-app/main/default/classes/CaseRestServiceTest.cls`
