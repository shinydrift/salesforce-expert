/**
 * Agentforce-facing Invocable action. This is the LLM's *generation surface*: a
 * narrow, typed input (a templateId + a few slots) — the model never sees the wide
 * object schema. Internally it expands the template and hands the graph to the
 * engine.
 *
 * Add one Invocable per business intent (Create Opportunity With Products, etc.);
 * they all share TemplateExpander + RecordGraphSync underneath.
 */
public with sharing class CreateQuoteFromTemplate {

    public class Request {
        @InvocableVariable(required=true label='Template Id'
            description='Which bundle template to use, e.g. starter-bundle')
        public String templateId;

        @InvocableVariable(required=true label='Opportunity Id'
            description='The Opportunity the quote belongs to')
        public String opportunityId;

        @InvocableVariable(label='Quantity'
            description='Quantity for the primary line (template default applies if blank)')
        public Decimal quantity;

        @InvocableVariable(label='Discount Percent')
        public Decimal discount;

        @InvocableVariable(label='Client Request Id'
            description='Idempotency key to de-duplicate retries')
        public String clientRequestId;
    }

    public class Response {
        @InvocableVariable public Boolean success;
        @InvocableVariable public String quoteId;
        @InvocableVariable public String message;
    }

    @InvocableMethod(
        label='Create Quote From Template'
        description='Creates a Quote and its lines from a named bundle template.')
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
            Map<String, Object> params = new Map<String, Object>{
                'opportunityId' => r.opportunityId
            };
            if (r.quantity != null) params.put('quantity', r.quantity);
            if (r.discount != null) params.put('discount', r.discount);

            RecordGraphRequest graph = TemplateExpander.expand(r.templateId, params);
            graph.clientRequestId = r.clientRequestId;
            graph.source = 'CreateQuoteFromTemplate';

            RecordGraphResult result = new RecordGraphSync().sync(graph);
            resp.success = result.success;
            resp.quoteId = (result.aliasToId != null) ? String.valueOf(result.aliasToId.get('quote')) : null;
            resp.message = result.message;
        } catch (Exception e) {
            resp.success = false;
            resp.message = e.getMessage();
        }
        return resp;
    }
}
