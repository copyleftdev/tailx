# Intent Queries

Intent queries let you describe what you are looking for in natural language, as a positional argument. If the argument is not an existing file path, tailx treats it as an intent query and translates it into filter predicates.

## How it works

```bash
tailx "errors related to payments" app.log
```

tailx tokenizes the query, strips filler words, maps keywords to filters, and applies basic stemming.

The above becomes: severity >= error AND message contains "payment" (stemmed from "payments").

## Examples

### Severity keywords

```bash
tailx "errors related to payments" app.log
# → severity >= error, message contains "payment"

tailx "warnings from nginx" app.log
# → severity >= warn, service = "nginx"

tailx "5xx from nginx" app.log
# → severity >= error, service = "nginx"

tailx "4xx errors" app.log
# → severity >= warn (4xx maps to warn)
```

The following words are recognized as severity keywords: `error`/`errors` (maps to error), `warning`/`warnings` (maps to warn), `fatal`/`critical` (maps to fatal), `5xx` (maps to error), `4xx` (maps to warn).

### Service targeting with "from"

```bash
tailx "5xx from nginx" app.log
# → severity >= error, service = "nginx"

tailx "errors from payments" app.log
# → severity >= error, service = "payments"
```

The word `from` followed by a non-filler word creates a service filter.

You can also use the `service:` prefix:

```bash
tailx "timeouts service:payments" app.log
# → message contains "timeout", service = "payments"
```

### Implicit error detection

```bash
tailx "why are payments failing" app.log
```

Even without explicit severity keywords, certain words imply errors: `fail`, `crash`, `down`, `broken`, `bug`. When detected, tailx automatically adds a severity >= error filter.

The above becomes: severity >= error AND message contains "payment" AND message contains "failing".

### Simple keyword search

```bash
tailx "timeout" app.log
# → message contains "timeout"

tailx "connection refused" app.log
# → message contains "connection" AND message contains "refused"
```

Any word that is not a filler word, severity keyword, or service pattern becomes a message substring filter.

## Filler words

The following words are stripped from queries before processing:

> the, a, an, is, are, was, were, in, on, at, to, for, of, with, and, or, but, not, related, about, why, what, how, when, where, show, me, find, get, all, any, some, that, this, those, requests, logs, events, messages

This means `"show me all timeout errors"` reduces to: severity >= error, message contains "timeout".

## Basic stemming

Trailing `s` is removed from keywords longer than 3 characters. This handles simple plurals:

- `payments` -> `payment`
- `errors` -> recognized as severity keyword (not stemmed as a message filter)
- `timeouts` -> `timeout`

## File vs. query detection

tailx checks whether a positional argument is an existing file path. If the file exists, it is opened as a log source. If the file does not exist, it is treated as an intent query.

```bash
tailx app.log                    # file exists → open as source
tailx "timeout errors" app.log   # "timeout errors" doesn't exist → intent query
tailx timeout app.log            # "timeout" doesn't exist → intent query
```
