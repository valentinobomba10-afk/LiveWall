# LiveWall Community API

This is the Hostinger server side of Community. Videos are kept as files in `media/videos`; MySQL only stores users and wallpaper metadata.

## Deploy

1. In hPanel, create the database and user, then **change the password shown in the screenshot** before using it.
2. Open phpMyAdmin, select the new database, and run `schema.sql`.
3. Upload this `CommunityAPI` folder to `public_html/livewall-api/` using Hostinger File Manager. Keep `media/videos/` writable (normally folder permission `755`).
4. Copy `config.php.example` to `config.php`, enter the newly-created database details, and change `API_BASE_URL` to your real HTTPS address.
5. In LiveWall’s Community tab, enter that exact `api.php` address and register a test account.

## Updates

The in-app **Check for Updates** button uses `api.php?action=update`, so it works even though the GitHub repository is private. In `config.php`, set `LATEST_VERSION` and `UPDATE_DOWNLOAD_URL` whenever you publish a release. Keep the download URL private (for example, the private GitHub release URL shared only with collaborators).

New uploads are `pending` so strangers cannot publish content without approval. To publish one, in phpMyAdmin run:

```sql
UPDATE wallpapers SET status='approved', approved_at=NOW() WHERE id=123;
```

Or open `admin.php?token=YOUR_ADMIN_TOKEN` after setting `ADMIN_TOKEN` in `config.php`. It has the pending-upload and report moderation queues. It also notifies followers when an approved creator upload goes live.

Creator analytics are recorded whenever someone applies or downloads a community wallpaper. Do not change the schema with partial SQL; re-run the complete `schema.sql` on a fresh database, or add the new tables individually on an existing one.

Do not expose `config.php`, database passwords, or an open database port to the app.
