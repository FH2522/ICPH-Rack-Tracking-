import {createClient} from '@supabase/supabase-js';
import {readDemo,saveDemo,localTransition,localCorrectEvent,prune,uid,TIME_WINDOW_MS} from './data';

const url=import.meta.env.VITE_SUPABASE_URL?.trim();
const key=import.meta.env.VITE_SUPABASE_ANON_KEY?.trim();
export const online=Boolean(url&&key);
export const supabase=online?createClient(url,key,{auth:{persistSession:true,autoRefreshToken:true}}):null;
const authError=(error)=>{if(error)throw error;};
const DEMO_EVENT='icph-demo-change';
const changed=()=>window.dispatchEvent(new Event(DEMO_EVENT));
const store=(d)=>{saveDemo(d);changed();return d;};
export async function getSnapshot(){
  if(!online)return prune(readDemo());
  const cutoff=new Date(Date.now()-TIME_WINDOW_MS).toISOString();
  const [r,p,t,e,d]=await Promise.all([
    supabase.from('racks').select('*').order('number'),
    supabase.from('projects').select('*').order('name'),
    supabase.from('trailers').select('*').order('trailer_no'),
    supabase.from('rack_events').select('*').gte('occurred_at',cutoff).order('occurred_at',{ascending:false}).limit(2000),
    supabase.from('deliveries').select('*').or(`returned_at.is.null,returned_at.gte.${cutoff}`).order('departed_at',{ascending:false}).limit(2000)
  ]);
  for(const item of [r,p,t,e,d])authError(item.error);
  return {racks:r.data,projects:p.data,trailers:t.data,events:e.data,deliveries:d.data};
}
export async function transition(no,action,payload={},occurredAt=new Date().toISOString()){
  if(!online)return store(localTransition(readDemo(),no,action,payload,occurredAt));
  const {error}=await supabase.rpc('transition_rack',{p_no:no,p_action:action,p_at:occurredAt,p_data:payload});authError(error);
}
export async function addProject({code,name}){
  name=name.trim();code=code.trim();if(!name)throw new Error('Project name is required');
  if(!online){const d=readDemo();if(d.projects.some(p=>p.name.toLowerCase()===name.toLowerCase()))throw new Error('Project already exists');d.projects.push({id:uid(),code,name,is_active:true});return store(d);}
  const {error}=await supabase.from('projects').insert({code,name});authError(error);
}
export async function addTrailer(trailer_no){
  trailer_no=trailer_no.trim();if(!trailer_no)throw new Error('Trailer number is required');
  if(!online){const d=readDemo();if(d.trailers.some(t=>t.trailer_no.toLowerCase()===trailer_no.toLowerCase()))throw new Error('Trailer already exists');d.trailers.push({id:uid(),trailer_no,is_active:true});return store(d);}
  const {error}=await supabase.from('trailers').insert({trailer_no});authError(error);
}
export async function correctEvent(id,at,reason){
  if(!online)return store(localCorrectEvent(readDemo(),id,at,reason));
  const {error}=await supabase.rpc('correct_event_time',{p_event_id:id,p_new_at:at,p_reason:reason||'Time corrected'});authError(error);
}
export async function savePhotos(no,existing,files){
  const next=[...existing];if(next.length+files.length>8)throw new Error('Maximum 8 photos per rack');
  for(const file of files){
    if(!['image/jpeg','image/png','image/webp','image/gif'].includes(file.type))throw new Error('Use JPG, PNG, WEBP or GIF photos');
    if(file.size>4*1024*1024)throw new Error('Each photo must be below 4 MB');
    if(online){
      const safe=file.name.replace(/[^a-zA-Z0-9._-]/g,'_').slice(-75);
      const path=`racks/${no}/${uid()}-${safe}`;
      const {error}=await supabase.storage.from('rack-photos').upload(path,file,{contentType:file.type,upsert:false});authError(error);
      next.push(path);
    }else{
      next.push(await compressDemoImage(file));
    }
  }
  return next;
}
export async function photoUrl(path){
  if(!path)return '';
  if(!online)return path;
  const {data,error}=await supabase.storage.from('rack-photos').createSignedUrl(path,60*60);authError(error);return data.signedUrl;
}
export function subscribe(onChange){
  if(!online){window.addEventListener(DEMO_EVENT,onChange);return ()=>window.removeEventListener(DEMO_EVENT,onChange);}
  const channel=supabase.channel('rack-tracker-live');
  for(const table of ['racks','rack_events','deliveries','projects','trailers']){
    channel.on('postgres_changes',{event:'*',schema:'public',table},onChange);
  }
  channel.subscribe();return ()=>{supabase.removeChannel(channel);};
}
export async function getSession(){if(!online)return {user:{email:'demo@local',id:'demo'},role:'editor'};
  const {data,error}=await supabase.auth.getSession();authError(error);
  return {user:data.session?.user||null};
}
export async function getRole(){if(!online)return 'editor';const {data,error}=await supabase.from('staff_roles').select('role').eq('user_id',(await supabase.auth.getUser()).data.user.id).maybeSingle();authError(error);return data?.role||null;}
export async function signIn(email,password){const {error}=await supabase.auth.signInWithPassword({email,password});authError(error);}
export async function signOut(){const {error}=await supabase.auth.signOut();authError(error);}

// Browser-local demo compresses photos to avoid quickly exhausting localStorage.
async function compressDemoImage(file){
  const raw=URL.createObjectURL(file);
  try{
    const img=await new Promise((resolve,reject)=>{const el=new Image();el.onload=()=>resolve(el);el.onerror=()=>reject(new Error('Cannot read this image'));el.src=raw;});
    const scale=Math.min(1,750/Math.max(img.width,img.height));
    const canvas=document.createElement('canvas');canvas.width=Math.max(1,Math.round(img.width*scale));canvas.height=Math.max(1,Math.round(img.height*scale));
    canvas.getContext('2d').drawImage(img,0,0,canvas.width,canvas.height);
    return canvas.toDataURL('image/jpeg',.7);
  }finally{URL.revokeObjectURL(raw);}
}
