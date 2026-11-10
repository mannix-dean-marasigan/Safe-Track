# SafeTrack security & operations notes

## Where each protection lives
| Requirement | Enforced by |
|---|---|
| Passwords hashed, session tokens, HTTPS | Supabase Auth (bcrypt, JWT; Supabase projects are HTTPS-only). Host the site on HTTPS (GitHub Pages is). |
| Who can see a contact list, location, profile, feedback | Row Level Security + `security definer` functions in `supabase_schema.sql` (server side, not the browser) |
| NFC card disabled | `profiles.nfc_active`, checked by `nfc_scan()` and `start_sos(... 'nfc')` on the server |
| Terms agreement | Required by the signup trigger (`handle_new_user`); version + time stored on the profile |
| Input limits | Length checks in the SQL functions + `esc()` on every value the page renders |
| Failed-login limits | Supabase rate-limits auth endpoints (Dashboard → Authentication → Rate Limits). The page also adds a client-side wait (15 s doubling to 5 min) as a convenience; it is not a security boundary. |
| Admin review of feedback | `profiles.is_admin` (set only in SQL: `update public.profiles set is_admin = true where email = '...';`) |

## Not done (needs your decision / a paid service)
* **Two-factor authentication:** Supabase supports TOTP MFA, but no 2FA screen is built yet.
* **Password rules:** the page requires 8+ characters with a letter and a number. Also raise "Minimum password length" in Supabase → Authentication.
* **Extra column-level encryption:** data is encrypted in transit (HTTPS) and at rest by Supabase. Application-level encryption of fields was not added.

## Backups
Free Supabase projects have no automatic backups (paid plans keep daily ones). To take your own:
1. Supabase → Project Settings → Database → copy the connection string.
2. `pg_dump "<connection string>" -Fc -f safetrack_backup.dump`
3. Keep the file somewhere private (encrypted drive or private storage), never in this public repo. Restore with `pg_restore`.
