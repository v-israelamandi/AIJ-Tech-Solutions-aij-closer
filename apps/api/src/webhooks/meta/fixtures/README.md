# fixtures

Recorded Meta webhook payloads, used by every test in this directory and by the
repository integration test in `apps/api/src/db/`.

Provenance: **not captured from live traffic** — there is no Meta app on this
account yet. Each file is a complete payload in the shape Meta documents for
that event, with every field a real delivery carries (WABA id, `messaging_product`,
`metadata.display_phone_number`, the contact's `profile.name`, Meta's `wamid.…`
and `mid` forms, conversation/pricing blocks on statuses), pointed at the demo
tenant's channels:

| Field | Value |
| --- | --- |
| WhatsApp `metadata.phone_number_id` | `109876543210987` — `supabase/seed/` channel `…0101` |
| Instagram `entry[].id` | `17841400000000001` — `supabase/seed/` channel `…0102` |
| Buyer `wa_id` / IGSID | `2348031234567`, `7012384591267503`, … |

`apps/api/src/webhooks/meta/test-support/index.ts` loads them as **bytes**: the
signature tests sign exactly what is in these files, which is the point of
keeping them as files rather than as objects in a test.

| File | Covers |
| --- | --- |
| `whatsapp-text.json` | A normal WhatsApp text message → one `text` event, display name captured. |
| `whatsapp-voice-note.json` | `type: "audio"` with `voice: true` → stored as `voice`. |
| `whatsapp-image-with-caption.json` | `type: "image"` with a caption → stored as `image`, caption kept as content. |
| `whatsapp-status-callback.json` | `statuses[]` (delivered + read) → ignored, no rows. |
| `whatsapp-other-message-type.json` | A buyer `location` message → ignored, no rows. |
| `whatsapp-unknown-event.json` | A `message_template_status_update` change → ignored, no rows. |
| `whatsapp-unknown-phone-number.json` | A `phone_number_id` no tenant owns → acknowledged, no rows. |
| `instagram-text.json` | A normal Instagram DM → one `text` event, routed by `entry[].id`. |
| `instagram-image-attachment.json` | An `image` attachment → stored as `image`. |
| `instagram-read-callback.json` | A `read` receipt → ignored, no rows. |
| `instagram-echo.json` | `is_echo: true` (our own send mirrored back) → ignored, no rows. |
