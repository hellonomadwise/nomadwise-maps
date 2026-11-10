-- ============================================================
-- Migration 306: changes reach GitHub without a zip
-- ============================================================
-- Jonathan, 10 Nov 2026: "how can we make it so that each time there
-- is a new zip, that I dont need to download it, and manually add it to
-- github".
--
-- Claude's workspace cannot push to GitHub and cannot reach Supabase
-- over the network, but it can run SQL here through the Supabase
-- connector. So a change travels as a row: the patch (git format-patch,
-- gzipped, base64) is put in code_changes, the database starts the
-- "Apply changes" workflow (apply_changes.yml), which applies the
-- patch, commits it to main and starts the build. Nobody uploads
-- anything. See docs/AUTO_APPLY.md.
--
-- Who can queue a change: only whoever can run SQL as the database's
-- owner (the Supabase dashboard, the connector, or anything holding a
-- service key, since apply_migration() runs SQL too). The workflow
-- refuses a patch that touches .github/ (workflow files are still
-- uploaded by hand) and one whose checksum does not match.
-- Off switch: disable the "Apply changes" workflow in GitHub.
-- ============================================================

create table if not exists public.code_changes (
  id          bigint generated always as identity primary key,
  created_at  timestamptz not null default now(),
  message     text not null,
  base_sha    text,
  patch       text not null default '',
  sha256      text,
  status      text not null default 'draft'
              check (status in ('draft', 'pending', 'applied', 'failed', 'cancelled')),
  applied_at  timestamptz,
  applied_sha text,
  error       text,
  run_url     text
);

alter table public.code_changes enable row level security;
revoke all on table public.code_changes from public, anon, authenticated, service_role;
-- the workflow reads the queue and writes back only what happened
grant select on table public.code_changes to service_role;
grant update (status, applied_at, applied_sha, error, run_url)
  on table public.code_changes to service_role;

-- Start the workflow (also used to try again).
create or replace function public.code_changes_run()
returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare
  tok text;
  req bigint;
begin
  select decrypted_secret into tok
    from vault.decrypted_secrets where name = 'github_actions_token' limit 1;
  if coalesce(tok, '') = '' then
    raise exception 'No github_actions_token in the Vault.';
  end if;
  select net.http_post(
    url := 'https://api.github.com/repos/hellonomadwise/nomadwise-maps'
           '/actions/workflows/apply_changes.yml/dispatches',
    body := '{"ref":"main"}'::jsonb,
    headers := jsonb_build_object(
      'Authorization', 'Bearer ' || tok,
      'Accept', 'application/vnd.github+json',
      'Content-Type', 'application/json',
      'User-Agent', 'nomadmaps-db',
      'X-GitHub-Api-Version', '2022-11-28')) into req;
  return req;
end $$;

-- A change in parts (a long patch is sent in pieces): begin, append,
-- commit. Commit checks the checksum, queues it and starts the workflow.
create or replace function public.code_change_begin(p_message text, p_base_sha text default null)
returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare
  new_id bigint;
begin
  if coalesce(btrim(p_message), '') = '' then
    raise exception 'Say what the change is.';
  end if;
  insert into public.code_changes (message, base_sha)
  values (btrim(p_message), nullif(btrim(p_base_sha), ''))
  returning id into new_id;
  return new_id;
end $$;

create or replace function public.code_change_append(p_id bigint, p_chunk text)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  n integer;
begin
  update public.code_changes
     set patch = patch || regexp_replace(coalesce(p_chunk, ''), '\s', '', 'g')
   where id = p_id and status = 'draft'
  returning length(patch) into n;
  if n is null then
    raise exception 'Change % is not open for more parts.', p_id;
  end if;
  return n;
end $$;

create or replace function public.code_change_commit(p_id bigint, p_sha256 text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  c    public.code_changes%rowtype;
  got  text;
  req  bigint;
begin
  select * into c from public.code_changes where id = p_id for update;
  if not found or c.status <> 'draft' then
    raise exception 'Change % is not open.', p_id;
  end if;
  begin
    got := encode(sha256(decode(c.patch, 'base64')), 'hex');
  exception when others then
    raise exception 'Change % is not valid base64 (% characters).', p_id, length(c.patch);
  end;
  if got <> lower(btrim(coalesce(p_sha256, ''))) then
    raise exception 'Change % arrived damaged: checksum % is not % (% characters). Send it again.',
      p_id, left(got, 12), left(coalesce(p_sha256, ''), 12), length(c.patch);
  end if;
  update public.code_changes set status = 'pending', sha256 = got where id = p_id;
  req := public.code_changes_run();
  return jsonb_build_object('id', p_id, 'characters', length(c.patch), 'started', req);
end $$;

-- In one go, for a short patch.
create or replace function public.code_change_add(
  p_message text, p_base_sha text, p_patch text, p_sha256 text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  new_id bigint;
begin
  new_id := public.code_change_begin(p_message, p_base_sha);
  perform public.code_change_append(new_id, p_patch);
  return public.code_change_commit(new_id, p_sha256);
end $$;

revoke all on function public.code_changes_run() from public, anon, authenticated, service_role;
revoke all on function public.code_change_begin(text, text) from public, anon, authenticated, service_role;
revoke all on function public.code_change_append(bigint, text) from public, anon, authenticated, service_role;
revoke all on function public.code_change_commit(bigint, text) from public, anon, authenticated, service_role;
revoke all on function public.code_change_add(text, text, text, text) from public, anon, authenticated, service_role;

notify pgrst, 'reload schema';
