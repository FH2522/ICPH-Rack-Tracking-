import test from 'node:test';
import assert from 'node:assert/strict';
import {initialData,localTransition,canLoadRack,displayStatus,FACTORY} from '../src/data.js';

const setup=()=>{
  const d=initialData();
  d.trailers=[{id:'trailer-1',trailer_no:'TR-001',is_active:true},{id:'trailer-2',trailer_no:'TR-002',is_active:true}];
  return d;
};
const load=(d,n=1)=>localTransition(d,n,'load',{project_id:d.projects[0].id,block:'200A',floor:'03F',zone:'S1'});
const dispatch=(d,n=1,tid='trailer-1')=>localTransition(d,n,'dispatch',{trailer_id:tid,site_location:'Bedok site'});

test('40 racks initially ready to load from ICPH',()=>{
  const d=setup();assert.equal(d.racks.length,40);
  assert.equal(d.racks.filter(canLoadRack).length,40);
  assert.equal(d.racks[0].location,FACTORY);
});

test('unloaded rack is visually empty but cannot reload until physical return',()=>{
  let d=load(setup());
  assert.equal(d.racks[0].status,'occupied');
  d=dispatch(d);
  assert.equal(d.racks[0].status,'out');
  assert.equal(d.deliveries.length,1);
  assert.equal(displayStatus(d.racks[0]),'out');
  assert.throws(()=>localTransition(d,1,'return'),/Confirm unloading/);
  d=localTransition(d,1,'unload',{location:'Bedok N8C14 Site'});
  assert.equal(displayStatus(d.racks[0]),'empty');
  assert.equal(d.racks[0].location,'Bedok N8C14 Site');
  assert.equal(canLoadRack(d.racks[0]),false);
  assert.throws(()=>load(d),/physically located at ICPH/);
  assert.throws(()=>localTransition(d,1,'update',{location:FACTORY}),/Use Return to ICPH/);
  d=localTransition(d,1,'return');
  assert.equal(d.racks[0].status,'available');
  assert.equal(d.racks[0].location,FACTORY);
  assert.equal(canLoadRack(d.racks[0]),true);
  assert.ok(d.deliveries[0].returned_at);
  assert.equal(d.deliveries[0].project_id,d.projects[0].id);
  assert.equal(d.deliveries[0].block,'200A');
  d=load(d);
  assert.equal(d.racks[0].status,'occupied');
  assert.equal(d.deliveries.length,1);
});

test('one trailer cannot carry two racks simultaneously, but it is reusable once unloaded',()=>{
  let d=load(setup(),1);
  d=load(d,2);
  d=dispatch(d,1,'trailer-1');
  assert.throws(()=>dispatch(d,2,'trailer-1'),/already carries another rack/);
  d=localTransition(d,1,'unload');
  d=dispatch(d,2,'trailer-1');
  assert.equal(d.deliveries.length,2);
  assert.equal(d.deliveries[0].rack_number,2);
  assert.equal(d.deliveries[1].rack_number,1);
});

test('one rack has one project and one trailer in each independent delivery snapshot',()=>{
  let d=load(setup());
  d=dispatch(d);
  assert.equal(d.deliveries[0].trailer_id,'trailer-1');
  assert.equal(d.deliveries[0].project_id,d.projects[0].id);
  assert.equal(d.deliveries[0].block,'200A');
  assert.equal(d.deliveries[0].floor,'03F');
  assert.equal(d.deliveries[0].zone,'S1');
  assert.ok(!('quantity' in d.deliveries[0]));
  d=localTransition(d,1,'unload');
  d=localTransition(d,1,'return');
  d=localTransition(d,1,'load',{project_id:d.projects[1].id});
  assert.equal(d.deliveries[0].project_id,d.projects[0].id);
  assert.equal(d.racks[0].project_id,d.projects[1].id);
});

test('not possible to dispatch unoccupied rack or use fake off-site location in ICPH',()=>{
  let d=setup();
  assert.throws(()=>dispatch(d),/Only occupied/);
  assert.throws(()=>localTransition(d,1,'update',{location:'Outside - Bedok'}),/in-factory rack/);
  d=load(d);
  assert.throws(()=>localTransition(d,1,'update',{location:'Outside - Bedok'}),/in-factory rack/);
});
