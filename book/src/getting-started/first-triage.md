# Your First Triage

This walkthrough uses real data from a Linux workstation's `/var/log/syslog` -- 23,907 lines of actual system logs. No synthetic data, no cherry-picked examples.

## The command

```bash
tailx -s -n /var/log/syslog
```

- `-s` (`--from-start`): read from the beginning of the file
- `-n` (`--no-follow`): read to EOF and stop (don't tail)

## What happened

In 2.7 seconds, tailx processed all 23,907 events:

```
tailx: 23907 events, 118 groups, 51 templates, 0 drops
```

That is 69,000 events per second on a single core, with full parsing, template extraction, grouping, anomaly detection, and correlation.

## The pattern summary

The pattern summary ranked 118 groups by severity, frequency, and trend. The top groups told the story immediately:

```
──────────────────────────────────────────────────────────────
 Pattern Summary  23907 events  118 groups  51 templates  8860 ev/s  2.7s
──────────────────────────────────────────────────────────────
  ⚠ [NetworkManager] <*> <*> carrier <*> ...  (x4812) ↑ rising
  ● [avahi-daemon] Registering new address record ...  (x3891) → stable
  ● [wsdd] <*> traffic on <*>  (x2744) → stable
  ● [dbus-daemon] <*> activation request ...  (x2103) → stable
  ⚠ [kernel] usb <*> USB disconnect ...  (x1847) ↑ rising
  ...
──────────────────────────────────────────────────────────────
```

## The root cause

Look at the top groups. They form a cascade:

1. **USB ethernet adapter cycling** -- the kernel reports USB connect/disconnect events (`usb <*> USB disconnect`). A USB ethernet adapter is flapping.

2. **NetworkManager reacts** -- every USB event triggers NetworkManager to reconfigure the network interface. Carrier up, carrier down, DHCP restart. This is the largest single group: 4,812 events.

3. **Avahi re-announces** -- when the network interface changes state, Avahi (mDNS/DNS-SD) re-registers address records. 3,891 events.

4. **wsdd follows** -- Web Services Discovery (wsdd) detects the network change and re-announces on the new interface. 2,744 events.

5. **dbus mediates** -- all of the above communicate over D-Bus, generating activation requests. 2,103 events.

One USB adapter cycling caused approximately 60% of all log volume, cascading through four services: NetworkManager, Avahi, wsdd, and dbus.

## The "aha" moment

Without tailx, you would read 23,907 lines. Manually. You would notice the NetworkManager lines are frequent. You might eventually connect them to the USB events. After 30 minutes, you might piece together the cascade.

With tailx: one command, 2.7 seconds, and the ranked pattern summary shows you the cascade directly. The highest-count groups are all related. The USB adapter is the root cause. The fix is either replacing the adapter or disabling auto-management for that interface.

## Getting the JSON triage

For programmatic access to the same analysis:

```bash
tailx --json -s -n /var/log/syslog | tail -1
```

The last line of JSON output is always the `triage_summary` object -- the full structured analysis including stats, top groups, anomalies, hypotheses, and traces. See [JSON Output](../ai/json-output.md) for the full schema.
