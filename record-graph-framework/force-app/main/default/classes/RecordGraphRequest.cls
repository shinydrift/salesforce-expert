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

    /** Deserialize from the JSON wire format. */
    public static RecordGraphRequest fromJson(String json) {
        return (RecordGraphRequest) JSON.deserialize(json, RecordGraphRequest.class);
    }
}
