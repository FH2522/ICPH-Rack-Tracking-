export const FACTORY = 'Factory - ICPH';
// 'Empty off-site' is a visual cargo state, not re-loadable Available.
export const isICPHLocation = location => /^(?:factory\s*-\s*)?icph(?:\b|$)/i.test(String(location||'').trim());
export const displayStatus = rack => rack.status==='out' && rack.unloaded_at ? 'empty' : rack.status;
export const canLoadRack = rack => rack.status==='available' && isICPHLocation(rack.location);
export const STORE_KEY = 'icph_rack_tracker_demo_v1';
export const TIME_WINDOW_MS = 30 * 24 * 3600 * 1000;
const uid = () => globalThis.crypto?.randomUUID?.() || `id-${Date.now()}-${Math.random().toString(36).slice(2)}`;
export {uid};
export function initialData() {
  const now = new Date().toISOString();
  const projects = [
    ['10108', 'Bedok N8C14'], ['10124', 'New Maitri School'], ['10061', 'Project L'],
    ['', 'CCK 2'], ['', 'QT C33'], ['', 'YISHUN N5C9'],
    ['', 'YISHUN N8C16-17'], ['', 'Tampines N2C24']
  ].map(([code, name]) => ({id: uid(),code,name,is_active:true}));
  return {projects, trailers: [], racks: Array.from({length:40},(_,i)=>({
    number:i+1,status:'available',location:FACTORY,project_id:null,trailer_id:null,
    block:'',floor:'',zone:'',notes:'',photos:[],status_since:now,
    loaded_at:null,dispatched_at:null,unloaded_at:null,available_at:now,last_delivery_id:null,updated_at:now
  })), events: [],deliveries:[], corrections:[]};
}
export function readDemo(){try {let d=JSON.parse(localStorage.getItem(STORE_KEY));if(d?.racks?.length===40)return d;}catch{} const d=initialData();saveDemo(d);return d;}
export function saveDemo(d){localStorage.setItem(STORE_KEY, JSON.stringify(d));}
const fmt = n => String(n).padStart(3,'0');
export const rackLabel = n => `#${fmt(n)}`;
export function elapsed(iso, now=Date.now()) {
  if(!iso) return '—';
  let m=Math.max(0,Math.floor((now-new Date(iso).getTime())/60000));
  const d=Math.floor(m/1440);m%=1440;const h=Math.floor(m/60);const mins=m%60;
  if(d) return `${d}d ${h}h ${mins}m`;
  if(h) return `${h}h ${mins}m`;
  return `${mins}m`;
}
export function dateTime(iso){return iso? new Date(iso).toLocaleString('en-SG',{day:'2-digit',month:'short',year:'numeric',hour:'2-digit',minute:'2-digit',hour12:false}):'—';}
export function dateOnly(iso){return iso?new Date(iso).toLocaleDateString('en-SG',{day:'2-digit',month:'short',year:'numeric'}):'—';}
export function inputDateTime(iso){const d=iso?new Date(iso):new Date();if(Number.isNaN(d.getTime()))return '';return new Date(d.getTime()-d.getTimezoneOffset()*60000).toISOString().slice(0,16);}
export function isoFromInput(s){const d=new Date(s);if(Number.isNaN(d.getTime()))throw new Error('Invalid date/time');if(d.getTime()>Date.now()+120000)throw new Error('Time cannot be in the future');return d.toISOString();}
export function projectName(projects, id){const p=projects.find(p=>p.id===id);return p?(p.code ? `${p.code} - ${p.name}`:p.name):'—';}
export function trailerName(trailers,id){return trailers.find(t=>t.id===id)?.trailer_no||'—';}
export function prune(d){const cut=Date.now()-TIME_WINDOW_MS;d.events=d.events.filter(x=>new Date(x.occurred_at).getTime()>=cut);d.deliveries=d.deliveries.filter(x=>!x.returned_at || new Date(x.returned_at).getTime()>=cut);return d;}
const copy = a => structuredClone(a);
export function localTransition(prev, no, action, payload={}, occurredAt=new Date().toISOString()) {
  const d=copy(prev);const r=d.racks.find(x=>x.number===no);if(!r)throw new Error('Rack not found');
  if(new Date(occurredAt).getTime()>Date.now()+120000)throw new Error('Future timestamps are not allowed');
  const old=copy(r); let deliveryId=null;
  if(action==='load') {
    if(!canLoadRack(r))throw new Error('Rack must be Available and physically located at ICPH before loading');
    if(!payload.project_id)throw new Error('Select a project');
    Object.assign(r,{status:'occupied',location:FACTORY,project_id:payload.project_id,block:payload.block||'',floor:payload.floor||'',zone:payload.zone||'',notes:payload.notes||'',photos:payload.photos||[],trailer_id:null,loaded_at:occurredAt,dispatched_at:null,unloaded_at:null,available_at:null,status_since:occurredAt,last_delivery_id:null});
  } else if(action==='update') {
    if(payload.location!==undefined){
      if(r.status==='out' && isICPHLocation(payload.location))throw new Error('Use Return to ICPH after unloading to update factory location');
      if(r.status!=='out' && !isICPHLocation(payload.location))throw new Error('An in-factory rack must keep an ICPH location');
    }
    if(r.status==='available') {
      Object.assign(r,{notes:payload.notes ?? r.notes,photos:payload.photos ?? r.photos,location:payload.location ?? r.location});
    } else if(r.status==='occupied') {
      if(Object.prototype.hasOwnProperty.call(payload,'project_id') && !d.projects.some(p=>p.id===payload.project_id&&p.is_active!==false))throw new Error('Occupied racks require one valid project');
      for(const key of ['project_id','block','floor','zone','notes','photos','location'])if(Object.prototype.hasOwnProperty.call(payload,key))r[key]=payload[key];
    } else {
      for(const key of ['photos','location'])if(Object.prototype.hasOwnProperty.call(payload,key))r[key]=payload[key];
    }
  } else if(action==='dispatch') {
    if(r.status!=='occupied'||!isICPHLocation(r.location))throw new Error('Only occupied racks at ICPH can be dispatched');
    if(r.loaded_at && new Date(occurredAt)<new Date(r.loaded_at))throw new Error('Dispatch time cannot precede loading completion');
    if(!payload.trailer_id)throw new Error('Select a trailer');
    const t=d.trailers.find(x=>x.id===payload.trailer_id&&x.is_active!==false);if(!t)throw new Error('Trailer not found');
    if(d.racks.some(x=>x.number!==no && x.status==='out' && !x.unloaded_at && x.trailer_id===payload.trailer_id))throw new Error('This trailer already carries another rack. Unload it before reusing the trailer');
    const delivery={id:uid(),rack_number:no,project_id:r.project_id,trailer_id:payload.trailer_id,block:r.block,floor:r.floor,zone:r.zone,notes:r.notes,photos:[...r.photos],site_location:payload.site_location||projectName(d.projects,r.project_id),departed_at:occurredAt,unloaded_at:null,returned_at:null,created_at:new Date().toISOString()};
    d.deliveries.unshift(delivery);deliveryId=delivery.id;
    Object.assign(r,{status:'out',location:payload.location||`On trailer - ${t.trailer_no}`,trailer_id:payload.trailer_id,dispatched_at:occurredAt,unloaded_at:null,status_since:occurredAt,last_delivery_id:delivery.id});
  } else if(action==='unload') {
    if(r.status!=='out'||r.unloaded_at)throw new Error('Rack is not dispatched or has already been unloaded');
    const delivery=d.deliveries.find(x=>x.id===r.last_delivery_id);if(!delivery)throw new Error('Active delivery record not found');
    if(new Date(occurredAt)<new Date(delivery.departed_at))throw new Error('Unloading time cannot precede dispatch');
    delivery.unloaded_at=occurredAt; deliveryId=delivery.id;
    r.unloaded_at=occurredAt; r.location=payload.location || delivery.site_location || 'Project site';r.status_since=occurredAt;
  } else if(action==='return') {
    if(r.status!=='out'||!r.unloaded_at)throw new Error('Confirm unloading before returning the empty rack to ICPH');
    const delivery=d.deliveries.find(x=>x.id===r.last_delivery_id);
    if(new Date(occurredAt)<new Date(r.unloaded_at))throw new Error('Return time cannot precede unloading');
    if(delivery && new Date(occurredAt)<new Date(delivery.departed_at))throw new Error('Return time cannot precede dispatch');
    if(delivery){delivery.returned_at=occurredAt;deliveryId=delivery.id;}
    Object.assign(r,{status:'available',location:FACTORY,project_id:null,block:'',floor:'',zone:'',notes:'',photos:[],trailer_id:null,loaded_at:null,dispatched_at:null,unloaded_at:null,available_at:occurredAt,status_since:occurredAt,last_delivery_id:null});
  } else {throw new Error('Unknown action');}
  r.updated_at=new Date().toISOString();
  d.events.unshift({id:uid(),rack_number:no,event_type:action,occurred_at:occurredAt,created_at:new Date().toISOString(),project_id:old.project_id||r.project_id,trailer_id:old.trailer_id||r.trailer_id,delivery_id:deliveryId,payload:{before:old,after:copy(r)}});
  return prune(d);
}
export function localCorrectEvent(prev,eventId,newAt,reason){
  const d=copy(prev);const events=[...d.events].reverse();const idx=events.findIndex(e=>e.id===eventId);
  if(idx<0)throw new Error('Event not found');const e=events[idx];const previous=events.slice(0,idx).filter(x=>x.rack_number===e.rack_number).pop();const next=events.slice(idx+1).find(x=>x.rack_number===e.rack_number);
  if(previous && new Date(newAt)<new Date(previous.occurred_at))throw new Error('Time precedes the previous event');
  if(next && new Date(newAt)>new Date(next.occurred_at))throw new Error('Time follows the next event');
  const old=e.occurred_at;e.occurred_at=newAt;
  const r=d.racks.find(x=>x.number===e.rack_number);
  if(e.event_type==='load' && r.loaded_at===old){r.loaded_at=newAt;if(r.status==='occupied')r.status_since=newAt;}
  if(e.event_type==='dispatch'){
    const del=d.deliveries.find(x=>x.id===e.delivery_id);if(del)del.departed_at=newAt;
    if(r.status==='out'){r.dispatched_at=newAt;if(!r.unloaded_at)r.status_since=newAt;}
  }
  if(e.event_type==='unload'){
    const del=d.deliveries.find(x=>x.id===e.delivery_id);if(del)del.unloaded_at=newAt;
    if(r.status==='out'){r.unloaded_at=newAt;r.status_since=newAt;}
  }
  if(e.event_type==='return'){
    const del=d.deliveries.find(x=>x.id===e.delivery_id);if(del)del.returned_at=newAt;
    if(r.status==='available' && r.available_at===old){r.available_at=newAt;r.status_since=newAt;}
  }
  d.corrections.push({id:uid(),event_id:eventId,old_at:old,new_at:newAt,reason,changed_at:new Date().toISOString()});return d;
}
export function csvData(deliveries, projects, trailers) {
  const headers=['Rack','Project','Block','Floor','Zone','Trailer','Destination','Dispatched','Unloaded','Returned','Notes'];
  const rows=deliveries.map(d=>[rackLabel(d.rack_number),projectName(projects,d.project_id),d.block,d.floor,d.zone,trailerName(trailers,d.trailer_id),d.site_location,dateTime(d.departed_at),dateTime(d.unloaded_at),dateTime(d.returned_at),d.notes]);
  return [headers,...rows].map(row=>row.map(cell=>`"${String(cell??'').replaceAll('"','""')}"`).join(',')).join('\r\n');
}
