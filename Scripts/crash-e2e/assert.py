"""Checks the batch the fake ingest received. Every assertion names the thing it would catch."""
import json, sys

batch = json.load(open(sys.argv[1]))
expected_exception = sys.argv[2]
failures = []


def check(ok, message):
    if not ok:
        failures.append(message)


check(batch.get("contract_version") == 1, "batch is not contract_version 1")
check(len(batch.get("reports", [])) == 1, "expected exactly one report in the batch")
report = batch["reports"][0]

check(report.get("kind") == "fatal" and report.get("is_fatal") is True,
      "a signal must arrive as a fatal, not as a nonfatal")
# Attribution: without these the report lands in the panel detached from the run that produced it.
check(report.get("session_id") == "harness-session", "the crash did not carry its session")
check(report.get("custom_keys", {}).get("build_flavor") == "harness", "custom keys were lost")
check([b.get("name") for b in report.get("breadcrumbs", [])] == ["Checkout"],
      "the breadcrumb trail did not survive the crash")
check(all("value" not in b for b in report.get("breadcrumbs", [])),
      "a breadcrumb carried a value — breadcrumbs bypass the kill switch and must stay names only")

signal = report.get("signal") or {}
check(signal.get("mach_exception") == expected_exception,
      f"expected {expected_exception}, got {signal.get('mach_exception')}")

crashed = [t for t in report.get("threads", []) if t.get("crashed")]
check(len(crashed) == 1, f"expected exactly one crashed thread, got {len(crashed)}")
if crashed:
    check(len(crashed[0].get("frames", [])) >= 2, "the frame walk did not climb past the pc")
    check(all("frames_truncated" in t for t in report["threads"]),
          "a thread omitted frames_truncated — a cut stack must not read as a short one")
check(len(report.get("images", [])) > 0, "no binary images: every frame would be unsymbolicatable")
# The handler owns this one; the sidecar cannot know it.
check(isinstance((report.get("state") or {}).get("uptime_ms"), int), "uptime_ms is missing")

for failure in failures:
    print(f"  FAIL {failure}")
sys.exit(1 if failures else 0)
