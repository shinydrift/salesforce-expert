/**
 * dashboardConfig.js
 * ------------------
 * This is where you define the dashboard. Each widget owns:
 *   - query : the string handed to Apex. Use "MOCK:<key>" for sample data, or a
 *             real Data Cloud SQL string once your Named Credential is set up.
 *   - size  : SLDS grid width out of 12 (e.g. 6 = half width).
 *   - build : maps the rows returned by Apex into an Apache ECharts `option`.
 *
 * Add a chart = add an entry here. No Apex or other LWC changes required.
 *
 * To go live, replace each `query` with real SQL, e.g.:
 *   query: 'SELECT Region__c region, SUM(Amount__c) revenue ' +
 *          'FROM Sales__dlm GROUP BY Region__c'
 * and drop the MOCK widgets you no longer need.
 */

const palette = ['#1b96ff', '#9050e9', '#06a59a', '#fe9339', '#e5469a', '#3296ed'];

export const WIDGETS = [
    {
        id: 'sales-by-region',
        title: 'Revenue by Region',
        query: 'MOCK:sales_by_region',
        size: 6,
        build: (rows) => ({
            color: palette,
            tooltip: { trigger: 'axis' },
            grid: { left: 60, right: 20, top: 20, bottom: 30 },
            xAxis: { type: 'category', data: rows.map((r) => r.region) },
            yAxis: { type: 'value' },
            series: [
                {
                    type: 'bar',
                    data: rows.map((r) => r.revenue),
                    itemStyle: { borderRadius: [4, 4, 0, 0] }
                }
            ]
        })
    },
    {
        id: 'channel-mix',
        title: 'Orders by Channel',
        query: 'MOCK:channel_mix',
        size: 6,
        build: (rows) => ({
            color: palette,
            tooltip: { trigger: 'item' },
            legend: { bottom: 0 },
            series: [
                {
                    type: 'pie',
                    radius: ['40%', '70%'],
                    data: rows.map((r) => ({ name: r.channel, value: r.orders }))
                }
            ]
        })
    },
    {
        id: 'monthly-revenue',
        title: 'Monthly Revenue Trend',
        query: 'MOCK:monthly_revenue',
        size: 12,
        build: (rows) => ({
            color: palette,
            tooltip: { trigger: 'axis' },
            grid: { left: 60, right: 20, top: 20, bottom: 30 },
            xAxis: { type: 'category', boundaryGap: false, data: rows.map((r) => r.month) },
            yAxis: { type: 'value' },
            series: [
                {
                    type: 'line',
                    smooth: true,
                    areaStyle: { opacity: 0.15 },
                    data: rows.map((r) => r.revenue)
                }
            ]
        })
    }
];
