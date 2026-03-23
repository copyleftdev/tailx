# MCP & Agent Integration

tailx is designed to be a tool for AI agents. The `--json` output provides structured triage data that an LLM can reason over directly, without parsing raw log text.

The key insight: **the AI does not parse logs**. tailx parses logs. The AI reasons over structured triage output.

## Subprocess integration

The simplest integration is calling tailx as a subprocess and reading the last line of output.

### Python example

```python
import subprocess
import json

result = subprocess.run(
    ["tailx", "--json", "-s", "-n", "--last", "5m", "/var/log/syslog"],
    capture_output=True,
    text=True
)

# The last line is always the triage_summary
lines = result.stdout.strip().split("\n")
triage = json.loads(lines[-1])

print(f"Events: {triage['stats']['events']}")
print(f"Groups: {triage['stats']['groups']}")
print(f"Top issue: {triage['top_groups'][0]['exemplar']}")
```

### Shell example

```bash
# Get triage summary as JSON
TRIAGE=$(tailx --json -s -n --last 5m /var/log/syslog | tail -1)

# Extract top group with jq
echo "$TRIAGE" | jq -r '.top_groups[0].exemplar'
```

## MCP tool definition

tailx can be exposed as an MCP (Model Context Protocol) tool. Here is a tool definition:

```json
{
  "name": "tailx_triage",
  "description": "Analyze log files for patterns, anomalies, and root causes. Returns structured triage with event groups ranked by severity/frequency, anomaly alerts, causal hypotheses, and request traces. Use this when investigating system issues, outages, or performance problems.",
  "input_schema": {
    "type": "object",
    "properties": {
      "files": {
        "type": "array",
        "items": { "type": "string" },
        "description": "Log file paths to analyze (e.g., [\"/var/log/syslog\"])"
      },
      "time_window": {
        "type": "string",
        "description": "How far back to look (e.g., \"5m\", \"1h\", \"30s\")"
      },
      "severity": {
        "type": "string",
        "enum": ["trace", "debug", "info", "warn", "error", "fatal"],
        "description": "Minimum severity to include in event output"
      },
      "grep": {
        "type": "string",
        "description": "Filter events by message substring"
      },
      "service": {
        "type": "string",
        "description": "Filter events by service name"
      }
    },
    "required": ["files"]
  }
}
```

### MCP tool implementation

```python
def tailx_triage(files, time_window=None, severity=None, grep=None, service=None):
    cmd = ["tailx", "--json", "-s", "-n"]

    if time_window:
        cmd.extend(["--last", time_window])
    if severity:
        cmd.extend(["--severity", severity])
    if grep:
        cmd.extend(["--grep", grep])
    if service:
        cmd.extend(["--service", service])

    cmd.extend(files)

    result = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
    lines = result.stdout.strip().split("\n")

    # Return just the triage summary for the AI to reason over
    return json.loads(lines[-1])
```

## What the AI receives

When an agent calls `tailx_triage(files=["/var/log/syslog"], time_window="5m")`, it receives a structured object like:

```json
{
  "type": "triage_summary",
  "stats": {
    "events": 847,
    "groups": 12,
    "templates": 8,
    "drops": 0,
    "events_per_sec": 4231.0,
    "elapsed_ms": 200
  },
  "top_groups": [
    {
      "exemplar": "Connection refused to <*>",
      "count": 34,
      "severity": "ERROR",
      "trend": "rising",
      "service": "payments"
    }
  ],
  "anomalies": [
    {
      "kind": "rate_spike",
      "score": 0.823,
      "observed": 450.0,
      "expected": 120.3,
      "deviation": 4.2,
      "fire_count": 3
    }
  ],
  "hypotheses": [
    {
      "causes": [
        {"label": "DB latency spike", "strength": 0.742, "lag_ms": 5000}
      ],
      "confidence": 0.742
    }
  ],
  "traces": []
}
```

The AI can now reason: "The top pattern group is rising connection refused errors from the payments service (34 occurrences). There's a rate spike anomaly. The correlation engine suggests a DB latency spike 5 seconds earlier as a likely cause."

## Design rationale

Why not have the AI read raw logs?

1. **Volume**: 24,000 lines of syslog would consume an entire context window. The triage summary is a few hundred tokens.
2. **Signal-to-noise**: 60% of the syslog was USB adapter cycling noise. The AI would waste tokens on irrelevant repetition.
3. **Speed**: tailx processes 69,000 events/sec. The pipeline runs in seconds, not minutes.
4. **Determinism**: statistical analysis (z-scores, CUSUM, EWMA) is reproducible. LLM pattern matching is not.
5. **Cost**: one subprocess call is effectively free. Feeding 24,000 lines to an LLM costs tokens and time.

The AI's job is to interpret the structured triage, suggest fixes, and communicate findings to humans -- not to count log lines.
