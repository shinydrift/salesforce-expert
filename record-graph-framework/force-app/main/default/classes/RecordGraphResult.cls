/**
 * Outcome of a graph sync: overall status, the resolved alias -> Id map (so the
 * caller/agent can report what it created), and per-node detail.
 */
public class RecordGraphResult {
    public Boolean success;
    public String message;

    /** alias -> real record Id for every node that ended up persisted. */
    public Map<String, Id> aliasToId;

    /** Per-node outcome, in execution order. */
    public List<NodeResult> nodeResults;

    public RecordGraphResult() {
        this.success = false;
        this.aliasToId = new Map<String, Id>();
        this.nodeResults = new List<NodeResult>();
    }

    public void record(String alias, String objectApiName, String op, Id recordId, Boolean ok, String error) {
        NodeResult nr = new NodeResult();
        nr.alias = alias;
        nr.objectApiName = objectApiName;
        nr.op = op;
        nr.recordId = recordId;
        nr.success = ok;
        nr.error = error;
        this.nodeResults.add(nr);
        if (ok && recordId != null) {
            this.aliasToId.put(alias, recordId);
        }
    }

    public class NodeResult {
        public String alias;
        public String objectApiName;
        /** The op actually applied (the diff may turn a create into an update, etc.). */
        public String op;
        public Id recordId;
        public Boolean success;
        public String error;
    }
}
