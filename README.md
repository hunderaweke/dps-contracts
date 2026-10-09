# dps-contracts

Shared Protobuf contracts for Project DPS, the Oromia Bank Digital Banking Services Platform. The design docs call this the *service-contracts repository*.

This repo holds `.proto` files only. Each service generates its own code from a tagged release, and its mock (`cmd/mock`) and real service (`cmd/server`) build from the same tag. That is how a mock can be swapped for the real service without callers noticing.

Source documents:

- **Project DPS: Architecture, Stack and Requirements** (deck): https://claude.ai/artifact/GaG9sfBPz1uTebQ5vXxaRw
- **Super App Backend Architecture: Phase One, Mock-First**: https://claude.ai/artifact/6zLFNSgnRXvw2ENZhbEToP

## What is here

| Package | Owner (database) | gRPC services | Events (topic `<domain>.events`) |
|---|---|---|---|
| `dps.common.v1` | n/a | none | n/a |
| `dps.events.v1` | n/a | none | `EventMetadata`, `(dps.events.v1.event)` option |
| `dps.auth.v1` | AUTH (`dps_auth`) | `AuthService`, `PolicyService` (limits and fraud rules) | `auth.*.v1` (15) |
| `dps.onboarding.v1` | ONB (`dps_onboarding`) | not yet | `onboarding.*.v1` (10) |
| `dps.account.v1` | ACC (`dps_account`) | `AccountService` | `account.*.v1` (6) |
| `dps.payment.v1` | RTP (`dps_payment`) | not yet | `payment.*.v1` (20) |
| `dps.tpi.v1` | TPI (`dps_tpi`) | not yet | `tpi.*.v1` (3) |
| `dps.ledger.v1` | LED (`dps_ledger`) | `LedgerService` | `ledger.*.v1` (10) |
| `dps.fee.v1` | FEE (`dps_fee`) | `FeeService` | `fee.*.v1` (2) |
| `dps.airtime.v1` | AIR (`dps_airtime`) | not yet | `airtime.*.v1` (4) |
| `dps.utility.v1` | UTL (`dps_utility`) | not yet | `utility.*.v1` (4) |
| `dps.airline.v1` | ETA (`dps_airline`) | not yet | `airline.*.v1` (7) |
| `dps.notification.v1` | NOT (`dps_notification`) | `NotificationService` | `notification.*.v1` (4) |
| `dps.adminops.v1` | ADM (`dps_adminops`) | not yet | `adminops.*.v1` (11) |
| `dps.fuel.v1` | FUEL (`dps_fuel`) | not yet | `fuel.*.v1` (2) |
| `dps.lending.v1` | MILKII (`dps_lending`) | not yet | `lending.*.v1` (11) |
| `dps.assistant.v1` | ORO (`dps_assistant`) | not yet | `assistant.*.v1` (3) |
| `dps.ticketing.v1` | EVT (`dps_ticketing`) | not yet | `ticketing.*.v1` (9) |
| `dps.dwh.v1` | DWH (`dps_dwh`) | not yet | `dwh.*.v1` (2) |
| `dps.audit.v1` | AUD (`dps_audit`) | `AuditService` (read only) | none |

`dps.common.v1` holds `Money`, `RequestContext`, `Actor`, `Channel`, `ErrorDetail` and pagination.

Packages marked "not yet" hold the entities and events only; their gRPC services follow on the same pattern. The event catalogue comes from DPS-UCS-P1-001 v1.4 and is listed in [docs/events.md](docs/events.md#topic-catalogue).

## Generating code in your service

1. Copy `templates/buf.gen.service.yaml` to your service root as `buf.gen.yaml`, then edit its three marked lines: the module path, the tag and the packages you need.
2. Add the generators as Go tools, once:
   ```sh
   go get -tool github.com/bufbuild/buf/cmd/buf \
     google.golang.org/protobuf/cmd/protoc-gen-go \
     google.golang.org/grpc/cmd/protoc-gen-go-grpc
   ```
3. Generate:
   ```sh
   go tool buf generate
   ```
   This is the same as the `proto` target in the service starter. Code lands in `pkg/dpsapi/gen/dps/<pkg>/v1`. Never edit it by hand.
4. To take a newer contract, bump `tag:` and regenerate.

## Rules these contracts encode

1. **One money path.** Every money flow calls `LedgerService.StartOperation`, then `CompleteOperation` or `AbortOperation`. An unknown rail outcome stays `STARTED` until a status query resolves it. Refunds are new `REFUND` operations.
2. **Controls before money.** `StartOperation` carries `Controls`: a `policy_authorisation_id` from `PolicyService.AuthorisePayment`, which covers limits and fraud rules, and an unexpired `fee_quote_id` from `FeeService.QuoteFee`. Limit usage is released automatically when the operation is aborted.
3. **Idempotency.** Every mutating request has an `idempotency_key`, checked in Valkey and then a database unique key. The same key with the same request returns the first result. The same key with a different request returns `ALREADY_EXISTS`.
4. **Money is integer minor units.** `Money.amount_minor` is santim for ETB. Never use floats.
5. **Events are typed protobuf on Redpanda.** One topic per domain, `<domain>.events`; the `x-dps-event-type` header names the event. They go through the transactional outbox and are keyed by aggregate ID. See [docs/events.md](docs/events.md).
6. **Who may call whom.** Only Ledger and Account Management call the CBS. Only Third-Party Integration calls EthSwitch. Core services never call composed services.
7. **Mocks are indistinguishable.** A mock honours the full contract: the same errors, idempotency, events and identity. It marks itself with `x-dps-impl: mock` gRPC metadata and `producer_impl = MOCK` on events.

## Errors

Every non-OK gRPC status carries one `dps.common.v1.ErrorDetail` in its details: `code`, `message_key`, `retryable` and `correlation_id`. Use the gRPC code that matches:

| gRPC code | When |
|---|---|
| `INVALID_ARGUMENT` | Bad input |
| `FAILED_PRECONDITION` | Wrong state, an expired quote or missing controls |
| `ALREADY_EXISTS` | Idempotency key reused with a different request |
| `NOT_FOUND` | Unknown ID |
| `PERMISSION_DENIED` | Caller not allowed |
| `UNAVAILABLE` | A downstream failure; `retryable = true`, so retry with the same idempotency key |

## Changing a contract

```sh
make check   # format, lint, build, and breaking against the latest tag
```

- Never change a field number or reuse a removed one; mark removed fields `reserved`.
- A breaking change needs a new version package (`v2`), and for events new `.v2` event types on the same domain topic. It runs alongside `v1` until every caller has moved.
- Release by tagging (`vX.Y.Z`). Services pin the tag in their `buf.gen.yaml`.

Tools: `buf` (brew or `go tool`).
