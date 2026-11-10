# Changes reach GitHub by themselves

Jonathan, 10 Nov 2026: "how can we make it so that each time there is a
new zip, that I dont need to download it, and manually add it to github".

## Why it was a zip

Claude works in a cloud workspace that may read this repository but not
push to it, and that cannot reach Supabase over the network. The one
door it has is the Supabase connector, which runs SQL.

## How it works now

1. Claude commits in its workspace as before.
2. `scripts/queue_change.sh` turns the commits not yet on GitHub into
   a patch (`git format-patch`, gzipped, base64) with a checksum.
3. Claude puts it in the table `public.code_changes` through the
   connector: `select public.code_change_add(message, base, patch,
   sha256)`, or `code_change_begin` / `code_change_append` /
   `code_change_commit` for a long one. The checksum is checked there,
   so a patch damaged on the way is refused at once.
4. The database starts the workflow **Apply changes**
   (`.github/workflows/apply_changes.yml`), which runs
   `scripts/apply_changes.py`: applies each waiting patch with
   `git am`, pushes to main and starts **Build Nomadwise Maps**.
5. The row says what happened (`status`, `applied_sha`, `error`,
   `run_url`), and the founders' phones get a ping: "Changes are in,
   building now" or "A change did not go in".

Claude then checks the row and syncs its workspace
(`git fetch && git reset --hard origin/main`).

## What it will not do

- Change anything under `.github/`. A workflow is not allowed to
  rewrite workflows, so those files are still uploaded by hand
  (Add file > Upload files, inside `.github/workflows`).
- Apply a patch that does not fit the code as it is now. The row is
  marked failed with the reason and later rows wait.

## Who can queue a change

Whoever can run SQL as the database's owner: the Supabase dashboard,
the Supabase connector Claude uses, and anything that holds a service
key (the migration runner can run SQL too). Before this, that access
reached the data; now it also reaches the code, and through the code
the secrets the workflows use. Keep service keys where they are today
and do not hand them out.

## Turning it off

GitHub > Actions > Apply changes > ... > **Disable workflow**. Queued
rows then wait; zips work as before.

## If something looks stuck

- `select id, message, status, error, run_url from code_changes order by id desc limit 5;`
- `select public.code_changes_run();` starts the workflow again.
- A row to drop: `update code_changes set status = 'cancelled' where id = N;`
