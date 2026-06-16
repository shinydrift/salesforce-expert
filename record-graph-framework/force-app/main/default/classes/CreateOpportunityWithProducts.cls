/**
 * Agentforce-facing Invocable action — the runnable sibling of CreateQuoteFromTemplate
 * for orgs without Quotes enabled. It exposes a narrow, typed surface (a templateId
 * + a few slots); internally it expands the template and hands the graph to the engine.
 *
 * This is the "one Invocable per business intent" pattern: Create Opportunity With
 * Products. It shares TemplateExpander + RecordGraphSync with every other intent.
 */
public with sharing class CreateOpportunityWithProducts {

    public class Request {
        @InvocableVariable(label='Template Id'
            description='Which bundle template to use (default: opportunity-bundle).')
        public String templateId;

        @InvocableVariable(required=true label='Opportunity Name')
        public String opportunityName;

        @InvocableVariable(required=true label='Close Date'
            description='Opportunity close date, ISO yyyy-MM-dd.')
        public String closeDate;

        @InvocableVariable(label='Quantity'
            description='Quantity for the primary line (template default applies if blank).')
        public Decimal quantity;

        @InvocableVariable(label='Client Request Id'
            description='Idempotency key to de-duplicate retries.')
        public String clientRequestId;
    }

    public class Response {
        @InvocableVariable public Boolean success;
        @InvocableVariable public String opportunityId;
        @InvocableVariable public Integer lineCount;
        @InvocableVariable public String message;
    }

    @InvocableMethod(
        label='Create Opportunity With Products'
        description='Creates an Opportunity and its product lines from a named bundle template.')
    public static List<Response> run(List<Request> requests) {
        List<Response> responses = new List<Response>();
        for (Request r : requests) {
            responses.add(handle(r));
        }
        return responses;
    }

    private static Response handle(Request r) {
        Response resp = new Response();
        try {
            String templateId = String.isBlank(r.templateId) ? 'opportunity-bundle' : r.templateId;
            Map<String, Object> params = new Map<String, Object>{
                'name' => r.opportunityName,
                'closeDate' => r.closeDate
            };
            if (r.quantity != null) {
                params.put('quantity', r.quantity);
            }

            RecordGraphRequest graph = TemplateExpander.expand(templateId, params);
            graph.clientRequestId = r.clientRequestId;
            graph.source = 'CreateOpportunityWithProducts';

            RecordGraphResult result = new RecordGraphSync().sync(graph);
            resp.success = result.success;
            Id oppId = result.aliasToId.get('opp');
            resp.opportunityId = (oppId == null) ? null : String.valueOf(oppId);
            resp.lineCount = countLines(result);
            resp.message = result.message;
        } catch (Exception e) {
            resp.success = false;
            resp.message = e.getMessage();
        }
        return resp;
    }

    private static Integer countLines(RecordGraphResult result) {
        Integer n = 0;
        for (RecordGraphResult.NodeResult nr : result.nodeResults) {
            if (nr.objectApiName == 'OpportunityLineItem' && nr.success) {
                n++;
            }
        }
        return n;
    }
}
