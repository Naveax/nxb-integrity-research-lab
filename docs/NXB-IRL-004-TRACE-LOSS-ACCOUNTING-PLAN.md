# Trace-Loss Accounting Implementation Plan

1. Define a strict JSON Schema for loss, drop and circular-overwrite evidence.
2. Add a semantic validator for provenance, state consistency and conservative classification.
3. Add a PowerShell collector that records declared circular capacity, ETL length, utilization ratio and native counters when available.
4. Integrate accounting into the WPR stop/finalization path without changing teardown guarantees.
5. Add valid and adversarial fixtures plus PowerShell 7 and Windows PowerShell 5.1 tests.
6. Extend repository smoke validation and exact-head Windows validation.
7. Inspect native evidence and close out only after all mandatory gates pass.
