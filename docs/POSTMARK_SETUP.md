# Postmark: the one-off setup that switches the emails on

Everything that emails an owner is already built and waiting for
one token. Until it exists, each email is logged in the
`owner_emails` table as "skipped" and nothing is lost except the
message. About 30 minutes, once, plus Postmark's approval of the
account (usually the same day).

Why Postmark: it sends only transactional email, screens every
sender, and has the best inbox-placement and speed record of the
mainstream services, which is what the first email an owner ever
gets from us needs.

## What sends automatically once this is done

| Moment | Email |
|---|---|
| Free claim submitted | "We have your claim for X" |
| Payment lands (Verified) | "Payment received for X" |
| Claim approved | "X is Verified on nomadwise.io" or "You now manage X" |
| Claim rejected | "About your claim for X" (refund line for paid) |
| New page goes live | "X is live on nomadwise.io" with the link |
| Owner's edit put on the page | "Your changes to X are on the page" |
| Owner's edit sent back | "We sent your changes to X back" with your note |
| Claim form started, not finished | one nudge, next morning 09:00 UTC, once per address |
| Booking request on a Verified page | the request, to the owner's inbox |

Every one is copied (bcc) to hello@nomadwise.io, replies go to
hello@nomadwise.io, and each is signed Jonathan, Nomadwise.

## 1. Postmark account, sender domain (15 min)

1. https://postmarkapp.com, sign in to the existing account, or sign
   up with hello@nomadwise.io. A new account starts in test mode (100
   emails, only to your own domain) until Postmark approves it: fill
   in the approval request when asked. What we send: "transactional
   emails to business owners who claim or manage their listing on our
   directory nomadwise.io: confirmations, approvals, sign-in links,
   and booking requests from visitors". That is what they approve.
2. Sender Signatures, Add Domain: `nomadwise.io`. Postmark shows two
   DNS records (DKIM TXT and a Return-Path CNAME). Add them wherever
   nomadwise.io's DNS lives (registrar or Cloudflare). Nothing about
   the website changes. Verify both.
3. Servers: the default server is fine. Open it, note the
   **Message Streams**: `outbound` (transactional) must exist; it does
   by default.

## 2. The token into Supabase (5 min)

1. In the server, API Tokens: copy the Server API token.
2. Supabase, project `xclqfbuwrijpwtgbvrim`, Project Settings, Vault,
   Add new secret: name exactly `postmark_server_token`, secret the
   token. Save.

That is the switch. From the next email event on, `owner_emails`
shows `sent`.

## 3. Sign-in links through Postmark too (10 min)

The Owner account signs people in by emailing a link. Supabase's
built-in sender allows only a few an hour, so route it through
Postmark:

1. Supabase, Authentication, Emails (or Project Settings, Auth), SMTP
   Settings: Enable custom SMTP.
   Sender email `hello@nomadwise.io`, sender name `Nomadwise`,
   host `smtp.postmarkapp.com`, port `587`, username: the Server API
   token, password: the same token. Save.
2. Authentication, Rate limits: raise "emails sent" to 30 an hour.
3. Authentication, Email templates, Magic Link: paste the subject and
   the HTML body from docs/EMAIL_STYLE.md, so the sign-in email looks
   like the other owner emails.

## 4. Check it (5 min)

1. Open https://nomadmaps.io/?claim in a private window, claim any
   test space for free with your own email. Within a minute: "We have
   your claim" in your inbox and a copy at hello@.
2. Supabase, Table Editor, `owner_emails`: the row says `sent`.
   A `failed` row carries the reason in `error`.
3. Reject that test claim in the control centre (Owners tab): the
   rejection email arrives.
4. Open https://nomadmaps.io/owner, enter your email: the sign-in
   link arrives from hello@nomadwise.io.
5. Postmark, Activity, shows every message with its delivery time.

## If an email does not arrive

- `owner_emails` says `skipped`: the Vault secret is missing or
  misnamed (`postmark_server_token`, all lower case).
- `owner_emails` says `failed`: read `error`. An account still in
  test mode can only send to nomadwise.io addresses; an unverified
  domain is refused.
- `owner_emails` says `sent` but nothing arrived: Postmark, Activity,
  shows whether it was delivered, bounced or is waiting; check spam.
