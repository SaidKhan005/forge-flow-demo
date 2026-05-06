# Firebase Auth Email Templates - Production1

Updated: 2026-05-05
Status: Copy-paste pack prepared. Apply only after the production1 Auth action
domain is live and Firebase allows sender/template updates.

## Scope

Use these templates for Firebase Auth in `forge-flow-production1` once:

- `https://auth.feflow.org/auth/action` returns the branded Forge & Flow action
  handler.
- Firebase Auth `notification.sendEmail.callbackUri` points to
  `https://auth.feflow.org/auth/action`.
- Sender domain `feflow.org` is verified or Firebase Console allows template
  updates.

Do not apply these to `forge-flow-staging` from this runbook. The active
automation named `Firebase Auth production1 domain watcher` watches the same
readiness gates and can apply them later through the API if the domain is ready.

## Manual Console Path

Firebase Console:

1. Open project `forge-flow-production1`.
2. Go to Authentication.
3. Go to Templates.
4. Open each template below.
5. Paste the subject and HTML body exactly.
6. Use sender name `Forge & Flow`.
7. Use sender local part `no-reply` after `feflow.org` is verified.
8. Send a fresh password reset email after saving to validate the live link.

Keep Firebase placeholders exactly as written, including percent signs.

## Password Reset

Subject:

```text
Reset your Forge & Flow password
```

HTML body:

```html
<div style="margin:0;padding:24px;background:#F8EDE6;color:#2C2C2C;font-family:Arial,Helvetica,sans-serif;line-height:1.55;"><div style="max-width:560px;margin:0 auto;background:#FFFFFF;border:1px solid #DDD6CC;border-radius:8px;padding:28px;"><div style="font-size:18px;font-weight:700;color:#9A5C2A;margin-bottom:18px;">Forge &amp; Flow</div><p style="margin:0 0 14px;">Hello,</p><p style="margin:0 0 14px;">We received a request to reset the password for <strong>%EMAIL%</strong>.</p><p style="margin:22px 0;"><a href="%LINK%" style="display:inline-block;background:#9A5C2A;color:#FFFFFF;text-decoration:none;font-weight:700;padding:12px 18px;border-radius:6px;">Reset password</a></p><p style="margin:0 0 14px;color:#5A524A;">If you did not ask for this, you can ignore this email. Your password will stay the same.</p><p style="margin:22px 0 0;color:#2C2C2C;">Forge &amp; Flow</p></div><p style="max-width:560px;margin:12px auto 0;color:#5A524A;font-size:12px;">This message was sent for %APP_NAME%.</p></div>
```

## Verify Email

Subject:

```text
Verify your Forge & Flow email
```

HTML body:

```html
<div style="margin:0;padding:24px;background:#F8EDE6;color:#2C2C2C;font-family:Arial,Helvetica,sans-serif;line-height:1.55;"><div style="max-width:560px;margin:0 auto;background:#FFFFFF;border:1px solid #DDD6CC;border-radius:8px;padding:28px;"><div style="font-size:18px;font-weight:700;color:#9A5C2A;margin-bottom:18px;">Forge &amp; Flow</div><p style="margin:0 0 14px;">Hello %DISPLAY_NAME%,</p><p style="margin:0 0 14px;">Please confirm this email address for your Forge &amp; Flow account.</p><p style="margin:22px 0;"><a href="%LINK%" style="display:inline-block;background:#9A5C2A;color:#FFFFFF;text-decoration:none;font-weight:700;padding:12px 18px;border-radius:6px;">Verify email</a></p><p style="margin:0 0 14px;color:#5A524A;">If you did not create or update a Forge &amp; Flow account, you can ignore this email.</p><p style="margin:22px 0 0;color:#2C2C2C;">Forge &amp; Flow</p></div><p style="max-width:560px;margin:12px auto 0;color:#5A524A;font-size:12px;">This message was sent for %APP_NAME%.</p></div>
```

## Email Change Or Recover Email

Subject:

```text
Your Forge & Flow sign-in email changed
```

HTML body:

```html
<div style="margin:0;padding:24px;background:#F8EDE6;color:#2C2C2C;font-family:Arial,Helvetica,sans-serif;line-height:1.55;"><div style="max-width:560px;margin:0 auto;background:#FFFFFF;border:1px solid #DDD6CC;border-radius:8px;padding:28px;"><div style="font-size:18px;font-weight:700;color:#9A5C2A;margin-bottom:18px;">Forge &amp; Flow</div><p style="margin:0 0 14px;">Hello %DISPLAY_NAME%,</p><p style="margin:0 0 14px;">The sign-in email for your Forge &amp; Flow account was changed to <strong>%NEW_EMAIL%</strong>.</p><p style="margin:0 0 14px;color:#5A524A;">If you made this change, no action is needed.</p><p style="margin:22px 0;"><a href="%LINK%" style="display:inline-block;background:#9A5C2A;color:#FFFFFF;text-decoration:none;font-weight:700;padding:12px 18px;border-radius:6px;">Restore previous email</a></p><p style="margin:0;color:#5A524A;">If you did not make this change, use the link above to secure your account.</p><p style="margin:22px 0 0;color:#2C2C2C;">Forge &amp; Flow</p></div><p style="max-width:560px;margin:12px auto 0;color:#5A524A;font-size:12px;">This message was sent for %APP_NAME%.</p></div>
```

## Multi-Factor Enrollment Notification

Subject:

```text
Two-step verification changed for Forge & Flow
```

HTML body:

```html
<div style="margin:0;padding:24px;background:#F8EDE6;color:#2C2C2C;font-family:Arial,Helvetica,sans-serif;line-height:1.55;"><div style="max-width:560px;margin:0 auto;background:#FFFFFF;border:1px solid #DDD6CC;border-radius:8px;padding:28px;"><div style="font-size:18px;font-weight:700;color:#9A5C2A;margin-bottom:18px;">Forge &amp; Flow</div><p style="margin:0 0 14px;">Hello %DISPLAY_NAME%,</p><p style="margin:0 0 14px;">Two-step verification was changed on your Forge &amp; Flow account.</p><p style="margin:0 0 14px;color:#5A524A;">Verification method: <strong>%SECOND_FACTOR%</strong></p><p style="margin:22px 0;"><a href="%LINK%" style="display:inline-block;background:#9A5C2A;color:#FFFFFF;text-decoration:none;font-weight:700;padding:12px 18px;border-radius:6px;">Review this change</a></p><p style="margin:0;color:#5A524A;">If you did not make this change, use the link above to protect your account.</p><p style="margin:22px 0 0;color:#2C2C2C;">Forge &amp; Flow</p></div><p style="max-width:560px;margin:12px auto 0;color:#5A524A;font-size:12px;">This message was sent for %APP_NAME%.</p></div>
```

## Validation

After saving templates:

- Send a password reset email to a test account.
- Confirm the link opens `https://auth.feflow.org/auth/action`.
- Confirm the page is branded and posts password reset confirmation through the
  production proxy, not Firebase Hosting.
- Confirm the email contains no recovery codes, secrets, tokens, or internal
  hostnames.
