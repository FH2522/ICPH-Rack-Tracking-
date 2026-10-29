-- ICPH Rack Tracker v1.1 update for existing Supabase projects.
-- Safe to run again; preserves existing rack, history and delivery records.
-- Deploy updated frontend as well.

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

