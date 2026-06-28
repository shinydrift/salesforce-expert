/**
 * DataCloudQueryController
 * ------------------------
 * The ONLY Apex in this dashboard. It is a thin, generic query runner: the LWC
 * owns every query string, every chart definition and all layout logic, while
 * this class just executes a query and hands rows back as JSON.
 *
 * Two modes:
 *   - DUMMY  : queries prefixed with "MOCK:" return generated sample rows, so the
 *              dashboard renders end-to-end before Data Cloud is wired up.
 *   - LIVE   : any other query is sent to the Data Cloud (Data 360) Query API via
 *              a Named Credential callout and the result rows are returned.
 *
 * To go live you change the query strings in the LWC (drop the "MOCK:" prefix)
 * and create a `Data_Cloud` Named Credential pointing at your Data Cloud query
 * endpoint. No change to this class is required to add new charts.
 */
public with sharing class DataCloudQueryController {

    @TestVisible
    private static final String MOCK_PREFIX = 'MOCK:';

    /**
     * Generic entry point called by the LWC.
     * @param query  Either "MOCK:<datasetKey>" for sample data, or a Data Cloud
     *               SQL string for live data.
     * @return       JSON array of row objects, e.g. [{"region":"AMER","revenue":42}]
     */
    @AuraEnabled(cacheable=true)
    public static String runQuery(String query) {
        if (String.isBlank(query)) {
            throw new AuraHandledException('A query string is required.');
        }
        try {
            if (query.startsWith(MOCK_PREFIX)) {
                return mockResult(query.substring(MOCK_PREFIX.length()).trim());
            }
            return liveResult(query);
        } catch (Exception e) {
            // Surface a clean message to the LWC rather than a raw stack trace.
            throw new AuraHandledException('Query failed: ' + e.getMessage());
        }
    }

    // ---------------------------------------------------------------------
    // LIVE: Data Cloud (Data 360) Query API via Named Credential callout.
    // ---------------------------------------------------------------------
    private static String liveResult(String sql) {
        HttpRequest req = new HttpRequest();
        // Create a Named Credential named "Data_Cloud" pointing at your Data
        // Cloud query host; this callout works against the v2 Query API.
        req.setEndpoint('callout:Data_Cloud/api/v2/query');
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/json');
        req.setBody(JSON.serialize(new Map<String, Object>{ 'sql' => sql }));
        req.setTimeout(120000);

        HttpResponse res = new Http().send(req);
        if (res.getStatusCode() < 200 || res.getStatusCode() >= 300) {
            throw new CalloutException(
                'Data Cloud returned HTTP ' + res.getStatusCode() + ': ' + res.getBody()
            );
        }
        // Normalise the Data Cloud response (data + metadata arrays) into a plain
        // array of row objects keyed by column name, which is what the LWC expects.
        return normalizeDataCloudResponse(res.getBody());
    }

    /**
     * The Data Cloud Query API returns { "data": [[...],[...]], "metadata": {...} }
     * with positional rows. Convert it to [{col: value, ...}, ...].
     */
    @TestVisible
    private static String normalizeDataCloudResponse(String body) {
        Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(body);
        List<Object> data = (List<Object>) parsed.get('data');
        if (data == null) {
            // Some responses are already an array of objects — pass through.
            return body;
        }
        // Derive ordered column names from the metadata block when present.
        List<String> columns = new List<String>();
        Object metaObj = parsed.get('metadata');
        if (metaObj instanceof Map<String, Object>) {
            for (String col : ((Map<String, Object>) metaObj).keySet()) {
                columns.add(col);
            }
        }
        List<Map<String, Object>> rows = new List<Map<String, Object>>();
        for (Object rowObj : data) {
            List<Object> cells = (List<Object>) rowObj;
            Map<String, Object> row = new Map<String, Object>();
            for (Integer i = 0; i < cells.size(); i++) {
                String key = (i < columns.size()) ? columns[i] : ('col' + i);
                row.put(key, cells[i]);
            }
            rows.add(row);
        }
        return JSON.serialize(rows);
    }

    // ---------------------------------------------------------------------
    // DUMMY: self-contained sample data so the dashboard works on any org.
    // Replace these by switching the LWC query strings to real SQL.
    // ---------------------------------------------------------------------
    @TestVisible
    private static String mockResult(String dataset) {
        List<Map<String, Object>> rows = new List<Map<String, Object>>();
        if (dataset == 'sales_by_region') {
            rows.add(new Map<String, Object>{ 'region' => 'AMER', 'revenue' => 4280000 });
            rows.add(new Map<String, Object>{ 'region' => 'EMEA', 'revenue' => 3115000 });
            rows.add(new Map<String, Object>{ 'region' => 'APAC', 'revenue' => 2460000 });
            rows.add(new Map<String, Object>{ 'region' => 'LATAM', 'revenue' => 980000 });
        } else if (dataset == 'monthly_revenue') {
            rows.add(new Map<String, Object>{ 'month' => 'Jan', 'revenue' => 720000 });
            rows.add(new Map<String, Object>{ 'month' => 'Feb', 'revenue' => 810000 });
            rows.add(new Map<String, Object>{ 'month' => 'Mar', 'revenue' => 905000 });
            rows.add(new Map<String, Object>{ 'month' => 'Apr', 'revenue' => 870000 });
            rows.add(new Map<String, Object>{ 'month' => 'May', 'revenue' => 1015000 });
            rows.add(new Map<String, Object>{ 'month' => 'Jun', 'revenue' => 1180000 });
        } else if (dataset == 'channel_mix') {
            rows.add(new Map<String, Object>{ 'channel' => 'Direct', 'orders' => 540 });
            rows.add(new Map<String, Object>{ 'channel' => 'Partner', 'orders' => 320 });
            rows.add(new Map<String, Object>{ 'channel' => 'Online', 'orders' => 760 });
            rows.add(new Map<String, Object>{ 'channel' => 'Retail', 'orders' => 410 });
        } else {
            // Unknown dataset key — return a small generic series.
            rows.add(new Map<String, Object>{ 'label' => 'A', 'value' => 30 });
            rows.add(new Map<String, Object>{ 'label' => 'B', 'value' => 70 });
        }
        return JSON.serialize(rows);
    }
}
