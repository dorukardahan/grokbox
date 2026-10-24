# Google Cloud setup (your own OAuth client for Drive)

Why your own client: rclone's built-in client is shared by every rclone user, rate-limited, and may be
retired. Your own client has its own quota, and the Drive API is free. This takes about 10 minutes and is
done once. Everything below is in https://console.cloud.google.com/ , signed in with the Google account whose
Drive will hold the backups. Google renames menus now and then; the names below match the "Google Auth Platform" UI.

Billing is not required: the Google Drive API is free to use, and creating a project, enabling the API and an
OAuth client work without attaching a billing account (if Google ever asks for one in your region, that is the only exception).

## 1. Create a project
1. Project picker (top bar) -> **New project**. Name: e.g. `grokbox-backup`. Location: no organization is fine. **Create**, then select it.

## 2. Enable the Google Drive API
1. **APIs & Services -> Library** -> search **Google Drive API** -> **Enable**.

## 3. Google Auth Platform: Branding
1. **Google Auth Platform** (or APIs & Services -> OAuth consent screen) -> **Get started** / **Branding**.
2. **App name**: e.g. `Grok Box backup`. **User support email**: your own address.
3. **App home page** and **Application privacy policy link**: both
   the GitHub URL of this repo (the clone URL in README.md, without `.git`); for the policy link you can use its `blob/main/PRIVACY.md` page.
   (If you forked the repo, use your fork's URLs.)
4. **Developer contact information**: your email. Save.

## 4. Audience
1. **Audience** -> User type **External**. Save.
2. **Publish app -> Confirm** so that **Publishing status = In production**.
   **Do not leave it in "Testing"**: in Testing mode refresh tokens expire after 7 days and your backups
   silently stop. You do not need to add test users once it is in production.

## 5. Data access (scopes)
1. **Data Access -> Add or remove scopes** -> add only
   `https://www.googleapis.com/auth/drive.file` ("See, edit, create, and delete only the specific Google Drive files you use with this app"). Save.
2. `drive.file` is a **non-sensitive** scope, so no Google verification is needed for personal use. During
   consent you may still see an "unverified app" / "Google hasn't verified this app" screen: click
   **Advanced -> Go to <app name> (unsafe)**; it is your own app.

## 6. Create the OAuth client
1. **Clients -> Create client** (or APIs & Services -> Credentials -> Create credentials -> OAuth client ID).
2. Application type **Desktop app**. Name e.g. `grokbox-rclone`. **Create**.
3. **Download JSON** (Google shows the client secret only at creation; later you can still download a new secret, but keep this file).
4. Put the file on the box as `/workspace/grokbox/secrets/gdrive-oauth-client.json` (`chmod 600`).
5. **Keep a copy of the JSON outside the box** (password manager attachment, encrypted notes) next to your restic
   password. You need it to reconnect after a disaster (see ../REBUILD.md).

## 7. Authorise
On the box: `./auth-gdrive.sh`. It prints `http://127.0.0.1:53682/auth?state=...`; open it in the box's browser, sign
in, **Allow**. Done: remote `gdrive`, folder `GrokBox/restic` (both configurable in `config.env`).

## Notes
- With `drive.file`, Grok Box can only see files and folders it created with this client, not the rest of your Drive.
- Revoke any time: https://myaccount.google.com/permissions . Delete the project to destroy the client.
- A different client later (or rclone's default client) cannot see this folder: see `migrate-client.md`.
