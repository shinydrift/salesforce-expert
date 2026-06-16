/**
 * A desired record graph plus idempotency/audit metadata.
 *
 * Self-contained (carries clientRequestId/source itself rather than extending
 * BaseRequestWrapper) so this framework deploys independently of sf-apex-rest-case,
 * while following the same wrapper convention.
 */
public class RecordGraphRequest {
    /** Idempotency key — replays with the same id are de-duplicated. */
    public String clientRequestId;

    /** Originating system/agent, for audit. */
    public String source;

    /** Optional: the template this graph was expanded from. */
    public String templateId;

    /** The nodes of the graph (order does not matter; the engine topo-sorts). */
    public List<GraphNode> nodes;

    public RecordGraphRequest() {
        this.nodes = new List<GraphNode>();
    }

    /**
     * Deserialize from the JSON wire format. Parsed untyped because GraphNode.fields
     * is a Map<String, Object>, which JSON.deserialize into a typed graph cannot
     * target ("Apex Type unsupported in JSON: Object").
     */
    public static RecordGraphRequest fromJson(String jsonStr) {
        Map<String, Object> m = (Map<String, Object>) JSON.deserializeUntyped(jsonStr);
        RecordGraphRequest req = new RecordGraphRequest();
        req.clientRequestId = (String) m.get('clientRequestId');
        req.source = (String) m.get('source');
        req.templateId = (String) m.get('templateId');
        if (m.get('nodes') != null) {
            for (Object o : (List<Object>) m.get('nodes')) {
                req.nodes.add(GraphNode.fromMap((Map<String, Object>) o));
            }
        }
        return req;
    }
}
