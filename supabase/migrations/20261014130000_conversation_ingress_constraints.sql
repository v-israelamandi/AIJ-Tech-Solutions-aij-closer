-- 20261014130000_conversation_ingress_constraints.sql
--
-- AIJ Closer — two small consequences of the webhook ingress (PR 4).
--
-- 1. One open conversation per contact, enforced by the database.
--    The ingress finds the open `conversations` row for a contact and creates
--    one when there is none. A find-or-create written that way is only correct
--    if the database refuses a second open row: Meta retries a webhook, and two
--    redeliveries racing would otherwise each create a conversation, leaving one
--    of them with no message (an orphan). This partial unique index — the same
--    "unique when set" pattern as messages.meta_message_id — closes that race so
--    the ingest can use `on conflict do nothing` and re-read, instead of hoping.
--    Closed threads are excluded, so the next enquiry after a closed thread
--    opens a new conversation as before.
--
-- 2. offers.status now has a shared counterpart. PR 2 flagged that the CHECK
--    accepted proposed|accepted|rejected with no matching enum in @aij/shared;
--    offerStatusSchema (packages/shared/src/offer.ts) is now that enum, so the
--    comment that said otherwise is stale.

begin;

create unique index conversations_one_open_per_contact_key
  on public.conversations (tenant_id, contact_id)
  where status <> 'closed';

comment on index public.conversations_one_open_per_contact_key is
  'At most one non-closed conversation per (tenant_id, contact_id): makes the webhook ingress'' find-or-create safe against Meta redelivering the same message twice at once.';

comment on column public.offers.status is
  'proposed | accepted | rejected. Mirrors offerStatusSchema in @aij/shared.';

commit;
