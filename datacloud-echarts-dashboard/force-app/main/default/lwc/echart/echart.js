import { LightningElement, api } from 'lwc';
import { loadScript } from 'lightning/platformResourceLoader';
import ECHARTS from '@salesforce/resourceUrl/echarts';

/**
 * Reusable, presentational ECharts wrapper.
 * Give it an ECharts `option` object and it renders a chart. It knows nothing
 * about queries or Data Cloud — that lives in the dashboard container.
 */
export default class Echart extends LightningElement {
    _option;
    _initialized = false;
    _libLoaded = false;
    chart;

    @api height = '320px';

    @api
    get option() {
        return this._option;
    }
    set option(value) {
        this._option = value;
        this.renderChart();
    }

    renderedCallback() {
        if (this._initialized) {
            return;
        }
        this._initialized = true;
        loadScript(this, ECHARTS)
            .then(() => {
                this._libLoaded = true;
                this.renderChart();
                // Keep the chart sized to its container.
                this._resizeHandler = () => this.chart && this.chart.resize();
                window.addEventListener('resize', this._resizeHandler);
            })
            .catch((error) => {
                // eslint-disable-next-line no-console
                console.error('Failed to load ECharts', error);
            });
    }

    disconnectedCallback() {
        if (this._resizeHandler) {
            window.removeEventListener('resize', this._resizeHandler);
        }
        if (this.chart) {
            this.chart.dispose();
            this.chart = undefined;
        }
    }

    renderChart() {
        if (!this._libLoaded || !this._option) {
            return;
        }
        const container = this.template.querySelector('.chart');
        if (!container) {
            return;
        }
        // eslint-disable-next-line no-undef
        if (!this.chart) {
            // eslint-disable-next-line no-undef
            this.chart = echarts.init(container);
        }
        this.chart.setOption(this._option, true);
        this.chart.resize();
    }

    get containerStyle() {
        return `width:100%;height:${this.height};`;
    }
}
