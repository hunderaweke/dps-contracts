# DPS events on Redpanda

How DPS services publish and consume domain events. The source rules are:

- the event topology in "Project DPS: Architecture, Stack and Requirements"
- the "Same events" fidelity rule and the readiness gate in "Super App Backend Architecture: Phase One, Mock-First"

## The event message

Every event is a typed protobuf message, defined in the producing service's `events.proto`:

```proto
message OperationCompleted {
  option (dps.events.v1.event) = {type: "ledger.operation.completed.v1"};

  dps.events.v1.EventMetadata metadata = 1;
  Operation operation = 2;
}
```

1. **Field 1 is always `EventMetadata`**, defined in `dps/events/v1/metadata.proto`. It carries `event_id`, `event_type`, `aggregate_id`, `aggregate_version`, `occurred_at`, `producer`, `producer_impl`, `correlation_id`, `causation_id` and `actor`.
2. **The `(dps.events.v1.event).type` option names the event** as `domain.entity.event.vN`. Read it through protoreflect; never hard-code topic names in a service.
3. **No secrets in events.** That means no PINs, OTPs, tokens, card data or rendered message text.

## Topics and records

| Item | Rule |
|---|---|
| Topic | Equals the event type, for example `ledger.operation.completed.v1`. One message type per topic. |
| Record key | `EventMetadata.aggregate_id`, so all events for one aggregate stay ordered on one partition. |
| Record value | The event message in Schema Registry wire format. |
| Headers | `traceparent` and `tracestate` (OpenTelemetry, set by the kotel hook); `x-dps-impl: mock` or `real`. |
| Dead letters | `<topic>.dlq`, same key and value, plus headers `x-dps-error` and `x-dps-consumer`. |
| Replication | RF3 in every shared environment. |
| Topic creation | Owned by the platform through GitOps. Auto-creation is for local compose only. |

## Schema Registry

- Redpanda's built-in Schema Registry, using `TopicNameStrategy`: the subject is `<topic>-value`.
- Compatibility is `BACKWARD_TRANSITIVE` on every subject. `buf breaking` (FILE rules) on this repo is stricter, so a contract that passes here also passes the registry.
- Producers and consumers use franz-go's `pkg/sr` serde with the generated message type. A consumer that cannot decode a record sends it to the DLQ; it does not skip it.
- Schemas are registered from a tagged release of this repo by CI, not by services at runtime. *The registration job is not built yet.*
- Readiness gate: before a real service replaces its mock, the events it publishes must pass the registry checks against the schemas the mock publishes.

## Producing: transactional outbox

1. In the same database transaction as the state change, insert the encoded event into the service's `outbox` table. Its columns are `event_id`, `topic`, `key`, `value`, `headers` and `created_at`.
2. A relay publishes unsent rows in `created_at` order per key, then marks them sent.
3. Never publish directly from a request handler. A crash between commit and publish would lose the event.
4. `event_id` is generated when the row is written. A retried publish therefore sends the same `event_id`.
5. `aggregate_version` is incremented in the same transaction as the aggregate it describes.

## Consuming

1. **Consumer group:** `<service>.<job>`, for example `account-management.balance-projector`. One job per group.
2. **Delivery is at least once.** Commit offsets after handling, and make every handler idempotent on `event_id`. Use one of:
   - `INSERT ... ON CONFLICT DO NOTHING`
   - a processed-events table
   - a deterministic Temporal workflow ID
3. **Ordering:** use `aggregate_version` to drop stale or duplicate updates. Don't rely on arrival order across partitions.
4. **Retries:** a bounded number with backoff. A poison message, meaning one that cannot decode or fails validation, goes straight to `<topic>.dlq`. Ops consoles replay the DLQ.

## Mocks

- Mocks publish the same topics and schemas as the real service.
- They set `producer_impl = PRODUCER_IMPL_MOCK` and the `x-dps-impl: mock` header.
- State moves between mocks only through these events. For example, the Ledger mock's `ledger.operation.completed.v1` is what the Account Management mock uses to update balances.

## Versioning

- Adding a field is backward compatible. Removing or renumbering one is not; reserve removed field numbers instead.
- **A breaking change creates a new package (`dps.ledger.v2`) and new topics (`.v2`).** The producer publishes both versions until every consumer has moved, then stops `.v1`.

## Topic catalogue

| Topic | Message | Key | Producer | Known consumers |
|---|---|---|---|---|
| `ledger.operation.started.v1` | `dps.ledger.v1.OperationStarted` | operation_id | ledger | account-management.balance-projector, audit.universal |
| `ledger.operation.completed.v1` | `dps.ledger.v1.OperationCompleted` | operation_id | ledger | account-management.balance-projector, notification.dispatcher, notification.receipt-generator, audit.universal, settlement.collector, reporting.cdc-sink, fraud.behaviour-profiler |
| `ledger.operation.aborted.v1` | `dps.ledger.v1.OperationAborted` | operation_id | ledger | account-management.balance-projector, notification.dispatcher, auth.policy-releaser, audit.universal |
| `ledger.operation.orphaned.v1` | `dps.ledger.v1.OperationOrphaned` | operation_id | ledger | admin.manual-queue, audit.universal |
| `account.account.opened.v1` | `dps.account.v1.AccountOpened` | account_id | account-management | notification.dispatcher, audit.universal, reporting.cdc-sink |
| `account.account.status_changed.v1` | `dps.account.v1.AccountStatusChanged` | account_id | account-management | notification.dispatcher, audit.universal |
| `auth.session.started.v1` | `dps.auth.v1.SessionStarted` | session_id | auth | fraud.behaviour-profiler, audit.universal |
| `auth.device.registered.v1` | `dps.auth.v1.DeviceRegistered` | device_id | auth | notification.dispatcher, fraud.behaviour-profiler, audit.universal |
| `auth.payment.decided.v1` | `dps.auth.v1.PaymentDecided` | authorisation_id | auth | fraud.behaviour-profiler, audit.universal |
| `notification.message.delivered.v1` | `dps.notification.v1.MessageDelivered` | notification_id | notification | notification.inbox-writer, audit.universal |
| `notification.message.failed.v1` | `dps.notification.v1.MessageFailed` | notification_id | notification | audit.universal |

**Notes on consumer names:**

- **Receipt generator:** the deck calls it `document.receipt-generator`. The mock-first doc gives receipts to Notification, so it is listed as `notification.receipt-generator`.
- **Fraud profiler:** fraud rules belong to AUTH, so `fraud.behaviour-profiler` runs inside the AUTH service.
- **`auth.policy-releaser` and `admin.manual-queue`:** the deck doesn't name these. They are proposed names for the jobs that release limits on abort and work the 24-hour manual queue.

Other services that already appear in the deck's producer list will add their topics here as their contracts land: `transfer.*`, `utility.*`, `airtime.*`, `qr.*`, `onboarding.*`, `fuel.*`, `event.*`, `airline.*` and `loan.*`.
