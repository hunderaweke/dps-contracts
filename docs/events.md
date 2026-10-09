# DPS events on Redpanda

How DPS services publish and consume domain events. The source rules are:

- the event topology in "Project DPS: Architecture, Stack and Requirements"
- the "Same events" fidelity rule and the readiness gate in "Super App Backend Architecture: Phase One, Mock-First"
- the state changes and use cases in DPS-UCS-P1-001 v1.4, "Data Model, Use Cases and Scenarios", which set the event catalogue below

## The event message

Every event is a typed protobuf message, defined in the producing service's `events.proto`:

```proto
message OperationCompleted {
  option (dps.events.v1.event) = {type: "ledger.operation.completed.v1"};

  dps.events.v1.EventMetadata metadata = 1;
  Operation operation = 2;
}
```

1. **Field 1 is always `EventMetadata`**, defined in `dps/events/v1/metadata.proto`. It carries `event_id`, `event_type`, `aggregate_id`, `aggregate_version`, `occurred_at`, `producer`, `producer_impl`, `correlation_id`, `causation_id`, `actor` and `channel`.
2. **The `(dps.events.v1.event).type` option names the event** as `domain.entity.event.vN`. Read it through protoreflect; never hard-code event types in a service.
3. **`domain` is the producing service's namespace**, the same one its error codes use: `auth`, `onboarding`, `account`, `payment`, `tpi`, `ledger`, `fee`, `airtime`, `utility`, `airline`, `notification`, `adminops`, `fuel`, `lending`, `assistant`, `ticketing`, `dwh`. The event is a past-tense verb; multi-word segments are snake_case.
4. **No secrets in events.** That means no PINs, OTPs, tokens, card data, national IDs, full phone or account numbers (use `masked_*` fields), transcripts or rendered message text.
5. **Refunds are new Ledger `REFUND` operations** (`Operation.refund_of_operation_id`). The domain refund event (for example `airline.refund.completed.v1` or `ticketing.ticket.refunded.v1`) carries the refund ID, the original payment ID and the refund operation ID. A refund approved through maker-checker also carries the AdminOps `change_id`.

## Topics and records

| Item | Rule |
|---|---|
| Topic | One per domain: `<domain>.events`, where domain is the first segment of the event type. For example, `ledger.operation.completed.v1` is published on `ledger.events`. Every event type of the domain shares the topic. |
| Record key | `EventMetadata.aggregate_id`, so all events for one aggregate stay ordered on one partition, whatever their type. |
| Record value | The event message in Schema Registry wire format. |
| Headers | `x-dps-event-type` (the event type, so consumers route without decoding); `traceparent` and `tracestate` (OpenTelemetry, set by the kotel hook); `x-dps-impl: mock` or `real`. |
| Dead letters | `<domain>.events.dlq`, same key, value and headers, plus `x-dps-error` and `x-dps-consumer`. |
| Replication | RF3 in every shared environment. |
| Topic creation | Owned by the platform through GitOps. Auto-creation is for local compose only. |

## Schema Registry

- Redpanda's built-in Schema Registry, using `TopicRecordNameStrategy`: the subject is `<topic>-<message full name>`, for example `ledger.events-dps.ledger.v1.OperationCompleted`. `TopicNameStrategy` cannot hold several message types on one topic.
- Compatibility is `BACKWARD_TRANSITIVE` on every subject. `buf breaking` (FILE rules) on this repo is stricter, so a contract that passes here also passes the registry.
- Producers and consumers use franz-go's `pkg/sr` serde with the generated message type. A consumer that cannot decode a record sends it to the DLQ; it does not skip it. A consumer that does not handle an event type on its domain topic commits past it.
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
4. **Retries:** a bounded number with backoff. A poison message, meaning one that cannot decode or fails validation, goes straight to `<domain>.events.dlq`. Ops consoles replay the DLQ.

## Mocks

- Mocks publish the same topics and schemas as the real service.
- They set `producer_impl = PRODUCER_IMPL_MOCK` and the `x-dps-impl: mock` header.
- State moves between mocks only through these events. For example, the Ledger mock's `ledger.operation.completed.v1` is what the Account Management mock uses to update balances.

## Versioning

- Adding a field is backward compatible. Removing or renumbering one is not; reserve removed field numbers instead.
- **A breaking change creates a new package (`dps.ledger.v2`) and new `.v2` event types on the same domain topic.** The producer publishes both versions until every consumer has moved, then stops `.v1`.

## Topic catalogue

`audit.universal` and the Data Warehouse loader consume every domain topic. Other known consumers:

| Event type | Consumers |
|---|---|
| `ledger.operation.started.v1` | account-management.balance-projector |
| `ledger.operation.completed.v1` | account-management.balance-projector, notification.dispatcher, notification.receipt-generator, settlement.collector, reporting.cdc-sink, fraud.behaviour-profiler |
| `ledger.operation.aborted.v1` | account-management.balance-projector, notification.dispatcher, auth.policy-releaser |
| `ledger.operation.orphaned.v1` | adminops.manual-queue |
| `account.account.opened.v1`, `account.account.status_changed.v1` | notification.dispatcher (opened also reporting.cdc-sink) |
| `auth.session.started.v1`, `auth.device.registered.v1`, `auth.payment.decided.v1`, `auth.sign_in.failed.v1`, `auth.otp.failed.v1` | fraud.behaviour-profiler (device.registered also notification.dispatcher) |
| `notification.message.delivered.v1` | notification.inbox-writer |

**Notes on consumer names:**

- **Receipt generator:** the deck calls it `document.receipt-generator`. The mock-first doc gives receipts to Notification, so it is listed as `notification.receipt-generator`.
- **Fraud profiler:** fraud rules belong to AUTH, so `fraud.behaviour-profiler` runs inside the AUTH service.
- **`auth.policy-releaser` and `adminops.manual-queue`:** proposed names for the jobs that release limits on abort and work the 24-hour manual queue.

The events of each topic follow. The record key is the field named; a message comment may note an exception.

### `auth.events`

| Event type | Message | Record key |
|---|---|---|
| `auth.session.started.v1` | `dps.auth.v1.SessionStarted` | session_id |
| `auth.device.registered.v1` | `dps.auth.v1.DeviceRegistered` | device_id |
| `auth.payment.decided.v1` | `dps.auth.v1.PaymentDecided` | authorisation_id, or the request's idempotency key when nothing was authorised |
| `auth.otp.sent.v1` | `dps.auth.v1.OtpSent` | challenge_id |
| `auth.otp.verified.v1` | `dps.auth.v1.OtpVerified` | challenge_id |
| `auth.otp.failed.v1` | `dps.auth.v1.OtpFailed` | challenge_id |
| `auth.sign_in.failed.v1` | `dps.auth.v1.SignInFailed` | customer_id |
| `auth.session.revoked.v1` | `dps.auth.v1.SessionRevoked` | session_id |
| `auth.pin.changed.v1` | `dps.auth.v1.PinChanged` | subject_id |
| `auth.credential.locked.v1` | `dps.auth.v1.CredentialLocked` | subject_id |
| `auth.token_family.revoked.v1` | `dps.auth.v1.TokenFamilyRevoked` | family_id |
| `auth.payment.released.v1` | `dps.auth.v1.PaymentReleased` | authorisation_id |
| `auth.policy_bundle.activated.v1` | `dps.auth.v1.PolicyBundleActivated` | version |
| `auth.staff_role.granted.v1` | `dps.auth.v1.StaffRoleGranted` | subject_id |
| `auth.staff_role.revoked.v1` | `dps.auth.v1.StaffRoleRevoked` | subject_id |

### `onboarding.events`

| Event type | Message | Record key |
|---|---|---|
| `onboarding.application.started.v1` | `dps.onboarding.v1.ApplicationStarted` | application_id |
| `onboarding.application.consented.v1` | `dps.onboarding.v1.ApplicationConsented` | application_id |
| `onboarding.document.uploaded.v1` | `dps.onboarding.v1.DocumentUploaded` | application_id |
| `onboarding.kyc.passed.v1` | `dps.onboarding.v1.KycPassed` | application_id |
| `onboarding.kyc.flagged.v1` | `dps.onboarding.v1.KycFlagged` | application_id |
| `onboarding.application.returned.v1` | `dps.onboarding.v1.ApplicationReturned` | application_id |
| `onboarding.application.completed.v1` | `dps.onboarding.v1.ApplicationCompleted` | application_id |
| `onboarding.application.rejected.v1` | `dps.onboarding.v1.ApplicationRejected` | application_id |
| `onboarding.application.expired.v1` | `dps.onboarding.v1.ApplicationExpired` | application_id |
| `onboarding.application.blocked.v1` | `dps.onboarding.v1.ApplicationBlocked` | application_id, or the request's idempotency key when the block happened before an application was created |

### `account.events`

| Event type | Message | Record key |
|---|---|---|
| `account.account.opened.v1` | `dps.account.v1.AccountOpened` | account_id |
| `account.account.status_changed.v1` | `dps.account.v1.AccountStatusChanged` | account_id |
| `account.customer.created.v1` | `dps.account.v1.CustomerCreated` | customer_id |
| `account.customer.kyc_level_changed.v1` | `dps.account.v1.CustomerKycLevelChanged` | customer_id |
| `account.catalog.published.v1` | `dps.account.v1.CatalogPublished` | catalog_version |
| `account.contact_point.changed.v1` | `dps.account.v1.ContactPointChanged` | customer_id |

### `payment.events`

| Event type | Message | Record key |
|---|---|---|
| `payment.payment.initiated.v1` | `dps.payment.v1.PaymentInitiated` | payment_id |
| `payment.payment.completed.v1` | `dps.payment.v1.PaymentCompleted` | payment_id |
| `payment.payment.failed.v1` | `dps.payment.v1.PaymentFailed` | payment_id |
| `payment.payment.outcome_unknown.v1` | `dps.payment.v1.PaymentOutcomeUnknown` | payment_id |
| `payment.payment.reversed.v1` | `dps.payment.v1.PaymentReversed` | payment_id |
| `payment.beneficiary.added.v1` | `dps.payment.v1.BeneficiaryAdded` | beneficiary_id |
| `payment.beneficiary.deleted.v1` | `dps.payment.v1.BeneficiaryDeleted` | beneficiary_id |
| `payment.request_to_pay.created.v1` | `dps.payment.v1.RequestToPayCreated` | request_to_pay_id |
| `payment.request_to_pay.paid.v1` | `dps.payment.v1.RequestToPayPaid` | request_to_pay_id |
| `payment.request_to_pay.declined.v1` | `dps.payment.v1.RequestToPayDeclined` | request_to_pay_id |
| `payment.request_to_pay.expired.v1` | `dps.payment.v1.RequestToPayExpired` | request_to_pay_id |
| `payment.pre_authorization.held.v1` | `dps.payment.v1.PreAuthorizationHeld` | pre_authorization_id |
| `payment.pre_authorization.captured.v1` | `dps.payment.v1.PreAuthorizationCaptured` | pre_authorization_id |
| `payment.pre_authorization.released.v1` | `dps.payment.v1.PreAuthorizationReleased` | pre_authorization_id |
| `payment.pre_authorization.expired.v1` | `dps.payment.v1.PreAuthorizationExpired` | pre_authorization_id |
| `payment.qr_code.generated.v1` | `dps.payment.v1.QrCodeGenerated` | qr_id |
| `payment.qr_code.used.v1` | `dps.payment.v1.QrCodeUsed` | qr_id |
| `payment.qr_code.expired.v1` | `dps.payment.v1.QrCodeExpired` | qr_id |
| `payment.merchant.onboarded.v1` | `dps.payment.v1.MerchantOnboarded` | merchant_id |
| `payment.merchant.status_changed.v1` | `dps.payment.v1.MerchantStatusChanged` | merchant_id |

### `tpi.events`

| Event type | Message | Record key |
|---|---|---|
| `tpi.request.timed_out.v1` | `dps.tpi.v1.RequestTimedOut` | correlation_id |
| `tpi.status.resolved.v1` | `dps.tpi.v1.StatusResolved` | correlation_id |
| `tpi.webhook.rejected.v1` | `dps.tpi.v1.WebhookRejected` | rail_code and switch_event_id joined as "<rail_code>:<switch_event_id>" |

### `ledger.events`

| Event type | Message | Record key |
|---|---|---|
| `ledger.operation.started.v1` | `dps.ledger.v1.OperationStarted` | operation_id |
| `ledger.operation.completed.v1` | `dps.ledger.v1.OperationCompleted` | operation_id |
| `ledger.operation.aborted.v1` | `dps.ledger.v1.OperationAborted` | operation_id |
| `ledger.operation.orphaned.v1` | `dps.ledger.v1.OperationOrphaned` | operation_id |
| `ledger.operation.resolved.v1` | `dps.ledger.v1.OperationResolved` | operation_id |
| `ledger.operation.captured.v1` | `dps.ledger.v1.OperationCaptured` | operation_id |
| `ledger.recon_run.completed.v1` | `dps.ledger.v1.ReconRunCompleted` | recon_run_id |
| `ledger.recon_exception.raised.v1` | `dps.ledger.v1.ReconExceptionRaised` | exception_id |
| `ledger.settlement_batch.posted.v1` | `dps.ledger.v1.SettlementBatchPosted` | batch_id |
| `ledger.settlement_batch.failed.v1` | `dps.ledger.v1.SettlementBatchFailed` | batch_id |

### `fee.events`

| Event type | Message | Record key |
|---|---|---|
| `fee.quote.issued.v1` | `dps.fee.v1.QuoteIssued` | quote_id |
| `fee.rule_set.published.v1` | `dps.fee.v1.RuleSetPublished` | version |

### `airtime.events`

| Event type | Message | Record key |
|---|---|---|
| `airtime.order.placed.v1` | `dps.airtime.v1.OrderPlaced` | order_id |
| `airtime.order.completed.v1` | `dps.airtime.v1.OrderCompleted` | order_id |
| `airtime.order.failed.v1` | `dps.airtime.v1.OrderFailed` | order_id |
| `airtime.order.outcome_unknown.v1` | `dps.airtime.v1.OrderOutcomeUnknown` | order_id |

### `utility.events`

| Event type | Message | Record key |
|---|---|---|
| `utility.bill.inquired.v1` | `dps.utility.v1.BillInquired` | inquiry_id |
| `utility.bill_payment.completed.v1` | `dps.utility.v1.BillPaymentCompleted` | bill_payment_id |
| `utility.bill_payment.failed.v1` | `dps.utility.v1.BillPaymentFailed` | bill_payment_id |
| `utility.routing.updated.v1` | `dps.utility.v1.RoutingUpdated` | "<region>:<biller_code>" |

### `airline.events`

| Event type | Message | Record key |
|---|---|---|
| `airline.booking.held.v1` | `dps.airline.v1.BookingHeld` | booking_id |
| `airline.booking.ticketed.v1` | `dps.airline.v1.BookingTicketed` | booking_id |
| `airline.booking.cancelled.v1` | `dps.airline.v1.BookingCancelled` | booking_id |
| `airline.booking.ticketing_failed.v1` | `dps.airline.v1.BookingTicketingFailed` | booking_id |
| `airline.refund.requested.v1` | `dps.airline.v1.RefundRequested` | refund_id |
| `airline.refund.completed.v1` | `dps.airline.v1.RefundCompleted` | refund_id |
| `airline.refund.failed.v1` | `dps.airline.v1.RefundFailed` | refund_id |

### `notification.events`

| Event type | Message | Record key |
|---|---|---|
| `notification.message.delivered.v1` | `dps.notification.v1.MessageDelivered` | notification_id |
| `notification.message.failed.v1` | `dps.notification.v1.MessageFailed` | notification_id |
| `notification.message.read.v1` | `dps.notification.v1.MessageRead` | notification_id |
| `notification.preference.updated.v1` | `dps.notification.v1.PreferenceUpdated` | subject_id |

### `adminops.events`

| Event type | Message | Record key |
|---|---|---|
| `adminops.change.submitted.v1` | `dps.adminops.v1.ChangeSubmitted` | change_id |
| `adminops.change.approved.v1` | `dps.adminops.v1.ChangeApproved` | change_id |
| `adminops.change.rejected.v1` | `dps.adminops.v1.ChangeRejected` | change_id |
| `adminops.change.applied.v1` | `dps.adminops.v1.ChangeApplied` | change_id |
| `adminops.change.apply_failed.v1` | `dps.adminops.v1.ChangeApplyFailed` | change_id |
| `adminops.change.expired.v1` | `dps.adminops.v1.ChangeExpired` | change_id |
| `adminops.case.opened.v1` | `dps.adminops.v1.CaseOpened` | case_id |
| `adminops.case.assigned.v1` | `dps.adminops.v1.CaseAssigned` | case_id |
| `adminops.case.escalated.v1` | `dps.adminops.v1.CaseEscalated` | case_id |
| `adminops.case.closed.v1` | `dps.adminops.v1.CaseClosed` | case_id |
| `adminops.report_run.completed.v1` | `dps.adminops.v1.ReportRunCompleted` | report_run_id |

### `fuel.events`

| Event type | Message | Record key |
|---|---|---|
| `fuel.purchase.confirmed.v1` | `dps.fuel.v1.PurchaseConfirmed` | purchase_id |
| `fuel.purchase.expired.v1` | `dps.fuel.v1.PurchaseExpired` | purchase_id |

### `lending.events`

| Event type | Message | Record key |
|---|---|---|
| `lending.consent.granted.v1` | `dps.lending.v1.ConsentGranted` | consent_id |
| `lending.consent.revoked.v1` | `dps.lending.v1.ConsentRevoked` | consent_id |
| `lending.assessment.completed.v1` | `dps.lending.v1.AssessmentCompleted` | assessment_id |
| `lending.offer.presented.v1` | `dps.lending.v1.OfferPresented` | offer_id |
| `lending.offer.accepted.v1` | `dps.lending.v1.OfferAccepted` | offer_id |
| `lending.offer.expired.v1` | `dps.lending.v1.OfferExpired` | offer_id |
| `lending.loan.disbursed.v1` | `dps.lending.v1.LoanDisbursed` | loan_id |
| `lending.loan.disbursement_failed.v1` | `dps.lending.v1.LoanDisbursementFailed` | loan_id |
| `lending.loan.overdue.v1` | `dps.lending.v1.LoanOverdue` | loan_id |
| `lending.loan.closed.v1` | `dps.lending.v1.LoanClosed` | loan_id |
| `lending.repayment.received.v1` | `dps.lending.v1.RepaymentReceived` | repayment_id |

### `assistant.events`

| Event type | Message | Record key |
|---|---|---|
| `assistant.tool_call.executed.v1` | `dps.assistant.v1.ToolCallExecuted` | session_id |
| `assistant.tool_call.denied.v1` | `dps.assistant.v1.ToolCallDenied` | session_id |
| `assistant.article.published.v1` | `dps.assistant.v1.ArticlePublished` | article_id |

### `ticketing.events`

| Event type | Message | Record key |
|---|---|---|
| `ticketing.event.submitted.v1` | `dps.ticketing.v1.EventSubmitted` | event_id |
| `ticketing.event.published.v1` | `dps.ticketing.v1.EventPublished` | event_id |
| `ticketing.event.rejected.v1` | `dps.ticketing.v1.EventRejected` | event_id |
| `ticketing.ticket.issued.v1` | `dps.ticketing.v1.TicketIssued` | ticket_id |
| `ticketing.ticket.used.v1` | `dps.ticketing.v1.TicketUsed` | ticket_id |
| `ticketing.ticket.scan_rejected.v1` | `dps.ticketing.v1.TicketScanRejected` | ticket_id, or gate_id when the signature was invalid and no ticket is known |
| `ticketing.refund.requested.v1` | `dps.ticketing.v1.RefundRequested` | refund_id |
| `ticketing.refund.rejected.v1` | `dps.ticketing.v1.RefundRejected` | refund_id |
| `ticketing.ticket.refunded.v1` | `dps.ticketing.v1.TicketRefunded` | ticket_id |

### `dwh.events`

| Event type | Message | Record key |
|---|---|---|
| `dwh.backfill.completed.v1` | `dps.dwh.v1.BackfillCompleted` | load_run_id |
| `dwh.load_run.failed.v1` | `dps.dwh.v1.LoadRunFailed` | load_run_id |
