# dps-contracts

Shared Protobuf contracts for Project DPS, the Oromia Bank Digital Banking Services Platform. The design docs call this the *service-contracts repository*.

This repo holds `.proto` files only. Each service generates its own code from a tagged release, and its mock (`cmd/mock`) and real service (`cmd/server`) build from the same tag. That is how a mock can be swapped for the real service without callers noticing.

Source documents:

- **Project DPS: Architecture, Stack and Requirements** (deck): https://claude.ai/artifact/GaG9sfBPz1uTebQ5vXxaRw
- **Super App Backend Architecture: Phase One, Mock-First**: https://claude.ai/artifact/6zLFNSgnRXvw2ENZhbEToP

## What is here

| Package | Service ID | gRPC services | Events |
|---|---|---|---|
| `dps.common.v1` | n/a | none | n/a |
| `dps.events.v1` | n/a | none | `EventMetadata`, `(dps.events.v1.event)` option |
| `dps.ledger.v1` | LED | `LedgerService` | `ledger.operation.*.v1` |
| `dps.account.v1` | ACC | `AccountService` | `account.account.*.v1` |
| `dps.auth.v1` | AUTH | `AuthService`, `PolicyService` (limits and fraud rules) | `auth.*.v1` |
| `dps.fee.v1` | FEE | `FeeService` | none |
| `dps.notification.v1` | NOT | `NotificationService` | `notification.message.*.v1` |
| `dps.audit.v1` | AUD | `AuditService` (read only) | none |

`dps.common.v1` holds `Money`, `RequestContext`, `Actor`, `Channel`, `ErrorDetail` and pagination.

ADM and the rest of the 18 Phase One services follow on the same pattern.

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
5. **Events are typed protobuf on Redpanda.** One message per topic; the topic is the event type. They go through the transactional outbox and are keyed by aggregate ID. See [docs/events.md](docs/events.md).
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
- A breaking change needs a new version package (`v2`), and for events new `.v2` topics. It runs alongside `v1` until every caller has moved.
- Release by tagging (`vX.Y.Z`). Services pin the tag in their `buf.gen.yaml`.

Tools: `buf` (brew or `go tool`).
