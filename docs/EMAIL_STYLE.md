# The owner emails: how they look

Since migration 83 every owner email (and the booking request) is
sent twice over in one message: a plain-text version for old phones
and strict spam filters, and an HTML version in the house style
built by `owner_email_html()`: the site's grey background, a white
card, the nomadwise wordmark in red with FOR SPACES beside it, the
text at 16px, links in red, one red button where the email has
somewhere to send the reader, the signature in grey under it, and a
one-line footer.

The words are the ones in migration 81; nothing is rewritten. The
button per email:

| Email | Button |
|---|---|
| We have your claim | See how Verified works (nomadmaps.io/spaces) |
| Payment received | Open my Owner account |
| Approved (Verified or free) | Open my Owner account |
| Rejected | none; the email asks them to reply |
| Page is live | See my page |
| Changes on the page | See my page (or the Owner account when the page has no address yet) |
| Changes sent back | Open my Owner account |
| Finish your claim | Finish my claim |
| Booking request | none |
| Test from the control centre | Open the Owner account |

## The sign-in email (Supabase, once)

Supabase sends the sign-in link itself, so it needs the same dress
pasted into its template. Supabase, Authentication, Email templates,
**Magic Link**.

Subject:

```
Your sign-in link for nomadwise.io
```

Body (Message):

```html
<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Nomadwise</title></head>
<body style="margin:0;padding:0;background:#F7F8F9;">
<div style="display:none;max-height:0;max-width:0;overflow:hidden;opacity:0;mso-hide:all;font-size:1px;line-height:1px;color:#F7F8F9;">Your link to manage your listing on Nomadwise. It works once, for the next hour.&#847; &zwnj;&nbsp;&#847; &zwnj;&nbsp;&#847; &zwnj;&nbsp;&#847; &zwnj;&nbsp;&#847; &zwnj;&nbsp;&#847; &zwnj;&nbsp;&#847; &zwnj;&nbsp;&#847; &zwnj;&nbsp;</div>
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="background:#F7F8F9;"><tr><td align="center" style="padding:28px 16px;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="max-width:560px;">
<tr><td style="padding:0 6px 14px;font-family:-apple-system,BlinkMacSystemFont,Segoe UI,Helvetica,Arial,sans-serif;"><span style="font-size:22px;font-weight:800;color:#E0442E;letter-spacing:-0.3px;">nomadwise</span> <span style="font-size:12px;font-weight:700;color:#5C6773;letter-spacing:1.2px;margin-left:4px;">FOR SPACES</span></td></tr>
<tr><td style="background:#ffffff;border:1px solid rgba(20,32,50,0.10);border-radius:16px;padding:30px 30px 26px;font-family:-apple-system,BlinkMacSystemFont,Segoe UI,Helvetica,Arial,sans-serif;">
<p style="margin:0 0 16px;font-size:16px;line-height:1.6;color:#142032;">Hi,</p>
<p style="margin:0 0 16px;font-size:16px;line-height:1.6;color:#142032;">Here is your link to manage your listing on Nomadwise. It works once and for the next hour.</p>
<table role="presentation" cellpadding="0" cellspacing="0" border="0" style="margin:10px 0 26px;"><tr><td style="background:#E0442E;border-radius:10px;"><a href="{{ .ConfirmationURL }}" style="display:inline-block;padding:13px 22px;font-size:15px;font-weight:700;color:#ffffff;text-decoration:none;">Sign in to my Owner account</a></td></tr></table>
<p style="margin:0 0 16px;font-size:14px;line-height:1.6;color:#5C6773;">If the button does not work, copy this address into your browser:<br><a href="{{ .ConfirmationURL }}" style="color:#E0442E;word-break:break-all;">{{ .ConfirmationURL }}</a></p>
<p style="margin:0 0 16px;font-size:14px;line-height:1.6;color:#5C6773;">If you did not ask for this link, you can ignore this email; nothing happens without it.</p>
<p style="margin:0;font-size:14px;line-height:1.6;color:#5C6773;">Jonathan<br>Nomadwise, <a href="https://www.nomadwise.io" style="color:#E0442E;">nomadwise.io</a></p>
</td></tr>
<tr><td style="padding:16px 6px 0;font-family:-apple-system,BlinkMacSystemFont,Segoe UI,Helvetica,Arial,sans-serif;font-size:12px;line-height:1.6;color:#96A0AC;">Nomadwise, work from anywhere. Reply to this email and a person answers. <a href="https://www.nomadwise.io" style="color:#96A0AC;">nomadwise.io</a> &middot; <a href="https://nomadmaps.io/owner" style="color:#96A0AC;">Owner account</a></td></tr>
</table></td></tr></table></body></html>
```

Save. The next sign-in link looks like the rest.

Mail apps turn any written web address into a link, so body text
says "Nomadwise", never "nomadwise.io" (a reader tapping it would land
on the homepage instead of signing in). The only links are the
button, the fallback address and the signature.

## Changing the words

The text lives in the trigger functions (migration 81, re-created in
83). To change a sentence, a new migration re-creates that one
function with the new text; the HTML dress needs no change.
