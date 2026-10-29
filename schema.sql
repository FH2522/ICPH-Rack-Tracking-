-- ICPH Rack Tracker - Supabase/PostgreSQL schema
-- Run once in Supabase SQL Editor using an administrator account.
-- IMPORTANT: this script expects Supabase Auth, and uses row-level security.
create extension if not exists pgcrypto;

create table if not exists public.staff_roles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  role text not null check (role in ('viewer','editor','admin')),
  created_at timestamptz not null default now()
);
create table if not exists public.projects (
  id uuid primary key default gen_random_uuid(),
  code text not null default '',
  name text not null unique,
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);
create table if not exists public.trailers (
  id uuid primary key default gen_random_uuid(),
  trailer_no text not null unique,
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);
create table if not exists public.racks (
  number integer primary key check (number between 1 and 40),
  status text not null default 'available' check (status in ('available','occupied','out')),
  location text not null default 'Factory - ICPH',
  project_id uuid references public.projects(id),
  trailer_id uuid references public.trailers(id),
  block text not null default '',
  floor text not null default '',
  zone text not null default '',
  notes text not null default '',
  photos jsonb not null default '[]'::jsonb check (jsonb_typeof(photos) = 'array'),
  status_since timestamptz not null default now(),
  loaded_at timestamptz,
  dispatched_at timestamptz,
  unloaded_at timestamptz,
  available_at timestamptz default now(),
  last_delivery_id uuid,
  updated_at timestamptz not null default now()
);
create table if not exists public.deliveries (
  id uuid primary key default gen_random_uuid(),
  rack_number integer not null references public.racks(number),
  project_id uuid references public.projects(id),
  trailer_id uuid references public.trailers(id),
  block text not null default '',floor text not null default '',zone text not null default '',
  notes text not null default '',
  photos jsonb not null default '[]'::jsonb,
  site_location text not null default '',
  departed_at timestamptz not null,
  unloaded_at timestamptz,
  returned_at timestamptz,
  created_at timestamptz not null default now()
);
create table if not exists public.rack_events (
  id uuid primary key default gen_random_uuid(),
  rack_number integer not null references public.racks(number),
  event_type text not null check (event_type in ('load','update','dispatch','unload','return')),
  occurred_at timestamptz not null,
  created_at timestamptz not null default now(),
  project_id uuid references public.projects(id),
  trailer_id uuid references public.trailers(id),
  delivery_id uuid,
  payload jsonb not null default '{}'::jsonb,
  changed_by uuid default auth.uid()
);
create table if not exists public.event_corrections (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.rack_events(id) on delete cascade,
  old_at timestamptz not null,new_at timestamptz not null,
  reason text not null,
  changed_by uuid default auth.uid(),
  changed_at timestamptz not null default now()
);
create index if not exists rack_events_rack_time on public.rack_events(rack_number,occurred_at desc);
create index if not exists deliveries_departed on public.deliveries(departed_at desc);
create index if not exists deliveries_project on public.deliveries(project_id);

-- Initialise exactly 40 racks; re-running does not overwrite rack records.
insert into public.racks(number)
select generate_series(1,40)
on conflict (number) do nothing;

insert into public.projects(code,name) values
 ('10108','Bedok N8C14'),('10124','New Maitri School'),('10061','Project L'),
 ('','CCK 2'),('','QT C33'),('','YISHUN N5C9'),('','YISHUN N8C16-17'),('','Tampines N2C24')
on conflict (name) do nothing;

-- Authentication helpers are SECURITY DEFINER so staff can inspect their own membership.
create or replace function public.is_staff() returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.staff_roles where user_id = (select auth.uid()));
$$;
create or replace function public.can_edit() returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.staff_roles where user_id = (select auth.uid()) and role in ('editor','admin'));
$$;

alter table public.staff_roles enable row level security;
alter table public.projects enable row level security;
alter table public.trailers enable row level security;
alter table public.racks enable row level security;
alter table public.deliveries enable row level security;
alter table public.rack_events enable row level security;
alter table public.event_corrections enable row level security;

create policy "Read own staff role" on public.staff_roles for select to authenticated using (user_id=auth.uid());
create policy "Staff view projects" on public.projects for select to authenticated using (public.is_staff());
create policy "Editors create projects" on public.projects for insert to authenticated with check (public.can_edit());
create policy "Editors edit projects" on public.projects for update to authenticated using (public.can_edit()) with check (public.can_edit());
create policy "Staff view trailers" on public.trailers for select to authenticated using (public.is_staff());
create policy "Editors create trailers" on public.trailers for insert to authenticated with check (public.can_edit());
create policy "Editors edit trailers" on public.trailers for update to authenticated using (public.can_edit()) with check (public.can_edit());
create policy "Staff view racks" on public.racks for select to authenticated using (public.is_staff());
create policy "Staff view deliveries" on public.deliveries for select to authenticated using (public.is_staff());
create policy "Staff view events" on public.rack_events for select to authenticated using (public.is_staff());
create policy "Staff view corrections" on public.event_corrections for select to authenticated using (public.is_staff());

-- Writes to racks, deliveries and audit events are ONLY through this atomic RPC.
create or replace function public.transition_rack(
  p_no integer,p_action text,p_at timestamptz default now(),p_data jsonb default '{}'::jsonb
) returns void language plpgsql security definer set search_path = '' as $$
declare
  r public.racks%rowtype;
  d public.deliveries%rowtype;
  new_r public.racks%rowtype;
  v_project uuid;
  v_trailer uuid;
  v_delivery uuid;
  v_destination text;
  v_trailer_no text;
begin
  if not public.can_edit() then raise exception 'Editor permission required'; end if;
  if p_at is null or p_at>now()+interval '2 minutes' then raise exception 'Invalid future operation time';end if;
  if p_data is null then p_data:='{}'::jsonb;end if;
  select * into r from public.racks where number=p_no for update;
  if not found then raise exception 'Rack not found';end if;
  if p_action='load' then
    if r.status<>'available' or r.location !~* '^(factory[[:space:]]*-[[:space:]]*)?icph([[:space:]]|$)' then
      raise exception 'Rack must be Available and physically located at ICPH before loading';end if;
    v_project:=nullif(p_data->>'project_id','')::uuid;
    if v_project is null or not exists(select 1 from public.projects where id=v_project and is_active) then raise exception 'Valid project required';end if;
    update public.racks set status='occupied',location='Factory - ICPH',project_id=v_project,
      block=coalesce(p_data->>'block',''),floor=coalesce(p_data->>'floor',''),zone=coalesce(p_data->>'zone',''),
      notes=coalesce(p_data->>'notes',''),photos=coalesce(p_data->'photos','[]'::jsonb),trailer_id=null,
      loaded_at=p_at,dispatched_at=null,unloaded_at=null,available_at=null,status_since=p_at,last_delivery_id=null,
      updated_at=now() where number=p_no;
  elsif p_action='update' then
    if r.status='occupied' and p_data ? 'project_id' and not exists(
      select 1 from public.projects where id=nullif(p_data->>'project_id','')::uuid and is_active
    ) then raise exception 'Occupied racks require one valid project';end if;
    if p_data ? 'location' and nullif(trim(p_data->>'location'),'') is not null then
      if r.status='out' and (p_data->>'location') ~* '^(factory[[:space:]]*-[[:space:]]*)?icph([[:space:]]|$)' then
        raise exception 'Use Return to ICPH after unloading to update factory location';
      end if;
      if r.status<>'out' and (p_data->>'location') !~* '^(factory[[:space:]]*-[[:space:]]*)?icph([[:space:]]|$)' then
        raise exception 'An in-factory rack must keep an ICPH location';
      end if;
    end if;
    update public.racks set
      project_id=case when r.status <> 'available' and r.status <> 'out' and p_data ? 'project_id' then nullif(p_data->>'project_id','')::uuid else project_id end,
      block=case when r.status <> 'available' and r.status <> 'out' then coalesce(p_data->>'block',block) else block end,
      floor=case when r.status <> 'available' and r.status <> 'out' then coalesce(p_data->>'floor',floor) else floor end,
      zone=case when r.status <> 'available' and r.status <> 'out' then coalesce(p_data->>'zone',zone) else zone end,
      notes=case when r.status <> 'out' then coalesce(p_data->>'notes',notes) else notes end,
      photos=coalesce(p_data->'photos',photos),
      location=coalesce(nullif(p_data->>'location',''),location),
      updated_at=now() where number=p_no;
  elsif p_action='dispatch' then
    if r.status<>'occupied' or r.location !~* '^(factory[[:space:]]*-[[:space:]]*)?icph([[:space:]]|$)' then raise exception 'Only occupied racks at ICPH can be dispatched';end if;
    if r.loaded_at is not null and p_at<r.loaded_at then raise exception 'Dispatch time cannot precede loading completion';end if;
    v_trailer:=nullif(p_data->>'trailer_id','')::uuid;
    select trailer_no into v_trailer_no from public.trailers where id=v_trailer and is_active;
    if v_trailer_no is null then raise exception 'Valid trailer required';end if;
    -- Serialise trailer dispatches: only ONE loaded rack per trailer until unloading.
    perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtext(v_trailer::text)::bigint);
    if exists(select 1 from public.racks where number<>p_no and status='out' and unloaded_at is null and trailer_id=v_trailer) then
      raise exception 'This trailer already carries another rack; confirm unloading before reuse';
    end if;
    select coalesce(nullif(p_data->>'site_location',''),concat_ws(' - ',nullif(code,''),name))
      into v_destination from public.projects where id=r.project_id;
    insert into public.deliveries(rack_number,project_id,trailer_id,block,floor,zone,notes,photos,site_location,departed_at)
      values(p_no,r.project_id,v_trailer,r.block,r.floor,r.zone,r.notes,r.photos,coalesce(v_destination,''),p_at)
      returning id into v_delivery;
    update public.racks set status='out',trailer_id=v_trailer,location=coalesce(nullif(p_data->>'location',''),'On trailer - '||v_trailer_no),
      dispatched_at=p_at,unloaded_at=null,status_since=p_at,last_delivery_id=v_delivery,updated_at=now()
      where number=p_no;
  elsif p_action='unload' then
    if r.status<>'out' or r.unloaded_at is not null then raise exception 'Rack is not awaiting unloading';end if;
    select * into d from public.deliveries where id=r.last_delivery_id for update;
    if not found then raise exception 'Current delivery is missing';end if;
    if p_at<d.departed_at then raise exception 'Unloading time cannot precede dispatch';end if;
    update public.deliveries set unloaded_at=p_at where id=d.id;
    v_delivery:=d.id;
    update public.racks set unloaded_at=p_at,location=coalesce(nullif(p_data->>'location',''),nullif(d.site_location,''),'Project site'),
      status_since=p_at,updated_at=now() where number=p_no;
  elsif p_action='return' then
    if r.status<>'out' or r.unloaded_at is null then raise exception 'Confirm unloading before returning the empty rack to ICPH';end if;
    select * into d from public.deliveries where id=r.last_delivery_id for update;
    if not found then raise exception 'Current delivery is missing';end if;
    if d.unloaded_at is null or p_at<d.departed_at or p_at<d.unloaded_at then raise exception 'Return cannot precede unloading';end if;
    update public.deliveries set returned_at=p_at where id=d.id;
    v_delivery:=d.id;
    update public.racks set status='available',location='Factory - ICPH',project_id=null,block='',floor='',zone='',notes='',photos='[]'::jsonb,
      trailer_id=null,loaded_at=null,dispatched_at=null,unloaded_at=null,available_at=p_at,status_since=p_at,last_delivery_id=null,
      updated_at=now() where number=p_no;
  else
    raise exception 'Unsupported rack operation: %',p_action;
  end if;
  select * into new_r from public.racks where number=p_no;
  insert into public.rack_events(rack_number,event_type,occurred_at,project_id,trailer_id,delivery_id,payload,changed_by)
    values(p_no,p_action,p_at,coalesce(r.project_id,new_r.project_id),coalesce(r.trailer_id,new_r.trailer_id),v_delivery,
      jsonb_build_object('before',to_jsonb(r),'after',to_jsonb(new_r)),auth.uid());
end;$$;

-- Corrections are audited separately and constrained between adjacent recorded events.
create or replace function public.correct_event_time(p_event_id uuid,p_new_at timestamptz,p_reason text default 'Time correction')
returns void language plpgsql security definer set search_path = '' as $$
declare
  e public.rack_events%rowtype;
  v_prev timestamptz;v_next timestamptz;
  old_at timestamptz;
begin
  if not public.can_edit() then raise exception 'Editor permission required';end if;
  if p_new_at is null or p_new_at>now()+interval '2 minutes' then raise exception 'Timestamp cannot be in the future';end if;
  select * into e from public.rack_events where id=p_event_id for update;
  if not found then raise exception 'Event not found';end if;
  select occurred_at into v_prev from public.rack_events
    where rack_number=e.rack_number and (created_at<e.created_at or (created_at=e.created_at and id<e.id))
    order by created_at desc,id desc limit 1;
  select occurred_at into v_next from public.rack_events
    where rack_number=e.rack_number and (created_at>e.created_at or (created_at=e.created_at and id>e.id))
    order by created_at asc,id asc limit 1;
  if v_prev is not null and p_new_at<v_prev then raise exception 'Time precedes previous event';end if;
  if v_next is not null and p_new_at>v_next then raise exception 'Time follows next event';end if;
  old_at:=e.occurred_at;
  update public.rack_events set occurred_at=p_new_at where id=e.id;
  if e.event_type='load' then
    update public.racks set loaded_at=p_new_at,status_since=case when status='occupied' and status_since=old_at then p_new_at else status_since end
      where number=e.rack_number and loaded_at=old_at;
  elsif e.event_type='dispatch' then
    update public.deliveries set departed_at=p_new_at where id=e.delivery_id;
    update public.racks set dispatched_at=p_new_at,status_since=case when status='out' and unloaded_at is null and status_since=old_at then p_new_at else status_since end
      where number=e.rack_number and dispatched_at=old_at;
  elsif e.event_type='unload' then
    update public.deliveries set unloaded_at=p_new_at where id=e.delivery_id;
    update public.racks set unloaded_at=p_new_at,status_since=case when status='out' and status_since=old_at then p_new_at else status_since end
      where number=e.rack_number and unloaded_at=old_at;
  elsif e.event_type='return' then
    update public.deliveries set returned_at=p_new_at where id=e.delivery_id;
    update public.racks set available_at=p_new_at,status_since=p_new_at
      where number=e.rack_number and status='available' and available_at=old_at;
  end if;
  insert into public.event_corrections(event_id,old_at,new_at,reason,changed_by)
    values(e.id,old_at,p_new_at,coalesce(nullif(trim(p_reason),''),'Time correction'),auth.uid());
end;$$;

revoke all on function public.transition_rack(integer,text,timestamptz,jsonb) from public;
revoke all on function public.correct_event_time(uuid,timestamptz,text) from public;
grant execute on function public.transition_rack(integer,text,timestamptz,jsonb) to authenticated;
grant execute on function public.correct_event_time(uuid,timestamptz,text) to authenticated;

-- Private photo bucket with signed links only (do NOT make it public).
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
  values('rack-photos','rack-photos',false,4194304,array['image/jpeg','image/png','image/webp','image/gif'])
  on conflict (id) do nothing;
create policy "Staff view rack photos" on storage.objects for select to authenticated
  using (bucket_id='rack-photos' and public.is_staff());
create policy "Editors upload rack photos" on storage.objects for insert to authenticated
  with check (bucket_id='rack-photos' and public.can_edit());

-- Enable postgres_changes events for realtime staff dashboards.
do $$
declare t text;
begin
  foreach t in array array['racks','rack_events','deliveries','projects','trailers'] loop
    if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename=t) then
      execute format('alter publication supabase_realtime add table public.%I',t);
    end if;
  end loop;
end$$;

-- After creating a user under Authentication > Users, activate the account:
-- insert into public.staff_roles(user_id,role)
-- select id,'admin' from auth.users where email='your.admin@company.com'
-- on conflict (user_id) do update set role=excluded.role;
-- For view-only staff use 'viewer'; for supervisors who update racks use 'editor'.
