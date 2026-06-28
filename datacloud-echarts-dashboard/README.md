# Data Cloud ECharts Dashboard

A lightweight, open-source dashboard for Salesforce Data Cloud (Data 360) data,
rendered with [Apache ECharts](https://echarts.apache.org/) (Apache-2.0) inside a
Lightning Web Component.

Design goals: **minimal Apex**, with all queries, chart definitions and layout
logic living in LWC.

## Architecture

```
dataCloudDashboard (LWC container)
  ├── dashboardConfig.js   ← queries + chart builders + grid sizing  (edit this)
  ├── renders a grid of …
  └── echart (LWC)         ← reusable Apache ECharts wrapper
            │
            ▼  Apex @AuraEnabled(cacheable=true)
   DataCloudQueryController.runQuery(query)   ← the ONLY Apex
            │
            ├── "MOCK:<key>"  → sample rows (works on any org, no Data Cloud)
            └── <Data Cloud SQL> → Data 360 Query API via `Data_Cloud` Named Credential
```

Add a chart = add one entry to `dashboardConfig.js`. No Apex changes needed.

## What's deployed

| Component | Type | Purpose |
|-----------|------|---------|
| `DataCloudQueryController` | Apex | Generic query runner (mock + live) |
| `DataCloudQueryControllerTest` | Apex | 6 tests, 100% pass |
| `echarts` | Static Resource | Apache ECharts 5.5.1 min build |
| `echart` | LWC | Reusable chart wrapper |
| `dataCloudDashboard` | LWC | Container + config + layout |
| `Data_Cloud_Dashboard` | FlexiPage + Tab | App page so you can open it |

## Open it

App Launcher → search **Data Cloud Dashboard**, or:
`/lightning/n/Data_Cloud_Dashboard`

It ships with three dummy widgets (bar / pie / line) backed by `MOCK:` data.

## Going live with real Data Cloud data

1. **Create a Named Credential** called `Data_Cloud` pointing at your Data Cloud
   query endpoint (Data 360 v2 Query API), with auth configured.
2. **Edit `dashboardConfig.js`** — replace each `query` string, dropping the
   `MOCK:` prefix, with real Data Cloud SQL, e.g.:

   ```js
   query: 'SELECT Region__c region, SUM(Amount__c) revenue ' +
          'FROM Sales__dlm GROUP BY Region__c'
   ```

   Make sure the column aliases match the keys your `build(rows)` mapper reads
   (`r.region`, `r.revenue`, …).
3. Deploy. No Apex change required.

> Note: the live path is a generic "run this SQL" method with queries defined
> client-side. It is read-only and runs under the user's Data Cloud permissions,
> but for a hardened production deployment consider switching to named/whitelisted
> queries server-side.

## Deploy

```bash
sf project deploy start --target-org <alias> \
  --test-level RunSpecifiedTests --tests DataCloudQueryControllerTest
```
