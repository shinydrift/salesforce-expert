import { LightningElement, track } from 'lwc';
import runQuery from '@salesforce/apex/DataCloudQueryController.runQuery';
import { WIDGETS } from './dashboardConfig';

/**
 * Dashboard container. Owns the organization + display logic: it walks the
 * widget config, asks Apex to run each query, builds the ECharts option and
 * renders a responsive grid of <c-echart> tiles.
 */
export default class DataCloudDashboard extends LightningElement {
    @track tiles = [];
    loading = true;

    connectedCallback() {
        this.loadAll();
    }

    async loadAll() {
        this.loading = true;
        const tiles = await Promise.all(WIDGETS.map((w) => this.loadWidget(w)));
        this.tiles = tiles;
        this.loading = false;
    }

    async loadWidget(widget) {
        const base = {
            id: widget.id,
            title: widget.title,
            sizeClass: this.sizeClass(widget.size),
            option: undefined,
            error: undefined
        };
        try {
            const json = await runQuery({ query: widget.query });
            const rows = JSON.parse(json || '[]');
            return { ...base, option: widget.build(rows) };
        } catch (e) {
            return { ...base, error: this.readError(e) };
        }
    }

    handleRefresh() {
        this.loadAll();
    }

    sizeClass(size) {
        // SLDS responsive column: full width on small screens, `size`/12 on desktop.
        const span = size || 12;
        return `slds-col slds-size_1-of-1 slds-large-size_${span}-of-12`;
    }

    readError(e) {
        return (e && e.body && e.body.message) || (e && e.message) || 'Unknown error';
    }
}
