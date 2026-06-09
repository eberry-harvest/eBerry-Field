-- V21_00 — Fix #3: BOL storage bucket + RLS policies
-- Note: storage.buckets row was created via direct DML, not via this migration
-- (storage.buckets is owned by the supabase_storage_admin role and cannot be
-- inserted into from a plain DDL migration in all environments). This file
-- captures the policies so the bucket configuration is reproducible.

-- Create bucket (idempotent)
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('bol-documents','bol-documents', false, 33554432,
        ARRAY['image/jpeg','image/png','image/gif','image/webp','application/pdf'])
on conflict (id) do update set
  public = excluded.public,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "bol_anon_insert" on storage.objects;
drop policy if exists "bol_anon_select" on storage.objects;
drop policy if exists "bol_anon_update" on storage.objects;

create policy "bol_anon_insert" on storage.objects
  for insert to anon, authenticated
  with check (bucket_id = 'bol-documents');

create policy "bol_anon_select" on storage.objects
  for select to anon, authenticated
  using (bucket_id = 'bol-documents');

create policy "bol_anon_update" on storage.objects
  for update to anon, authenticated
  using (bucket_id = 'bol-documents');
