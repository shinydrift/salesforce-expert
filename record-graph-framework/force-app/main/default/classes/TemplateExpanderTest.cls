/**
 * Tests for template loading (from Graph_Template__mdt), placeholder resolution,
 * and multi-level `includes` merging. None of these touch the database beyond the
 * CMDT read, so they run regardless of which SObjects are enabled in the org.
 */
@IsTest
private class TemplateExpanderTest {

    @IsTest
    static void expand_loadsTemplateAndResolvesParams() {
        Map<String, Object> params = new Map<String, Object>{
            'name' => 'Acme Expansion',
            'closeDate' => '2026-12-31',
            'quantity' => 3
        };

        RecordGraphRequest req = TemplateExpander.expand('opportunity-bundle', params);

        System.assertEquals('opportunity-bundle', req.templateId);
        System.assertEquals(3, req.nodes.size(), 'opp + 2 lines');

        Map<String, GraphNode> byAlias = new Map<String, GraphNode>();
        for (GraphNode n : req.nodes) {
            byAlias.put(n.alias, n);
        }
        System.assertEquals('Acme Expansion', byAlias.get('opp').fields.get('Name'));
        System.assertEquals('2026-12-31', byAlias.get('opp').fields.get('CloseDate'));
        // ${quantity|1} resolved to the supplied value (as a string post-substitution).
        System.assertEquals('3', String.valueOf(byAlias.get('line_generator').fields.get('Quantity')));
        // ProductCode is left for the engine to resolve to a PricebookEntryId.
        System.assertEquals('GC104', byAlias.get('line_generator').fields.get('ProductCode'));
    }

    @IsTest
    static void expand_mergesIncludedSubTemplate() {
        Map<String, Object> params = new Map<String, Object>{
            'opportunityId' => '006000000000001',
            'quantity' => 5,
            'discount' => 10
        };

        RecordGraphRequest req = TemplateExpander.expand('enterprise-bundle', params);

        Set<String> aliases = new Set<String>();
        for (GraphNode n : req.nodes) {
            aliases.add(n.alias);
        }
        // Enterprise's own lines plus the included starter bundle's nodes, sharing the
        // single "quote" root anchor (no duplicate quote node).
        System.assert(aliases.contains('quote'), aliases + '');
        System.assert(aliases.contains('line_core'), 'included starter line present');
        System.assert(aliases.contains('line_support'), 'included starter line present');
        System.assert(aliases.contains('line_premium'), 'enterprise line present');
        System.assert(aliases.contains('line_onboarding'), 'enterprise line present');
        System.assertEquals(5, req.nodes.size(), 'one shared quote + four lines');

        Map<String, GraphNode> byAlias = new Map<String, GraphNode>();
        for (GraphNode n : req.nodes) {
            byAlias.put(n.alias, n);
        }
        // The included starter quote received the opportunityId passed through `with`.
        System.assertEquals('006000000000001', byAlias.get('quote').fields.get('OpportunityId'));
    }

    @IsTest
    static void expand_unknownTemplate_throws() {
        try {
            TemplateExpander.expand('does-not-exist', new Map<String, Object>());
            System.assert(false, 'expected a TemplateException');
        } catch (TemplateExpander.TemplateException e) {
            System.assert(e.getMessage().contains('does_not_exist'), e.getMessage());
        }
    }

    @IsTest
    static void expand_missingRequiredParam_throws() {
        try {
            // starter-bundle requires opportunityId and supplies no default.
            TemplateExpander.expand('starter-bundle', new Map<String, Object>());
            System.assert(false, 'expected a missing-parameter failure');
        } catch (TemplateExpander.TemplateException e) {
            System.assert(e.getMessage().contains('opportunityId'), e.getMessage());
        }
    }
}
