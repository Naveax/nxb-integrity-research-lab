# NXB-IRL-004 Storage Block A+B

Block A is closed by `docs/NXB-IRL-004-STORAGE-SUMMARY-ADAPTER-VALIDATION.md`.

Block B must produce one exact-head native Windows pipeline that:

1. validates the storage profile/evidence/bridge/summary layers;
2. refuses to auto-cancel an existing WPR session;
3. runs a bounded owned-file workload;
4. captures WPR ETL;
5. produces xperf dumper and header inventory locally;
6. normalizes supported storage events;
7. creates a schema-valid storage summary;
8. writes SHA-256 provenance and a bounded review ZIP;
9. excludes raw ETL, full xperf dumper and raw path-heavy normalized CSV from the review ZIP;
10. leaves timing units, queue/service-time semantics, representative throughput/IOPS and trace completeness unclaimed.

The runtime result, not this plan, is the authority for Block B completion.
