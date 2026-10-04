/** Portable member metadata. Caller adds returned predicate to the document CAS. */
const fail=(error:string):never=>{throw Response.json({error},{status:400});};
const hex=/^[a-fA-F0-9]{32}$/;
const account=/^[a-zA-Z0-9-]{1,80}$/;
function assignments(content:string):Set<string>{
 let schema:any[]|undefined;const tasks:string[]=[];let fence:string|undefined,width=0;
 for(const line of content.split('\n')){
  const trimmed=line.trim();const marker=/^(`{3,}|~{3,})/.exec(trimmed);
  if(fence){if(marker&&marker[1][0]===fence&&marker[1].length>=width&&/^(`+|~+)\s*$/.test(trimmed))fence=undefined;continue;}
  if(marker){fence=marker[1][0];width=marker[1].length;continue;}
  if(line.includes('<!-- doin:properties=')){
   const match=/^<!-- doin:properties=(.+) -->$/.exec(trimmed);if(!match||schema)fail('invalid_property_metadata');
   try{schema=JSON.parse(match[1]);}catch{fail('invalid_property_metadata');}
   if(!Array.isArray(schema)||schema.length>64)fail('invalid_property_metadata');
   const ids=new Set<string>(),names=new Set<string>();for(const p of schema){
    if(!p||typeof p.id!=='string'||!hex.test(p.id)||typeof p.name!=='string'||!p.name.trim()||p.name!==p.name.trim()||new TextEncoder().encode(p.name).length>120||/[\x00-\x1f\x7f]/.test(p.name)||ids.has(p.id)||names.has(p.name)||!['text','number','date','single_select','multi_select','boolean','member'].includes(p.kind)||!Array.isArray(p.options)||p.options.length>128)fail('invalid_property_metadata');if(!['single_select','multi_select'].includes(p.kind)&&p.options.length)fail('invalid_property_metadata');const optionIds=new Set<string>(),optionNames=new Set<string>();for(const option of p.options){if(!option||typeof option.id!=='string'||!hex.test(option.id)||optionIds.has(option.id)||typeof option.name!=='string'||!option.name.trim()||option.name!==option.name.trim()||new TextEncoder().encode(option.name).length>120||/[\x00-\x1f\x7f]/.test(option.name)||optionNames.has(option.name))fail('invalid_property_metadata');optionIds.add(option.id);optionNames.add(option.name);}
    const cache=p.members??[];if(!Array.isArray(cache)||cache.length>128)fail('invalid_property_metadata');const cached=new Set<string>();for(const member of cache){if(!member||typeof member.id!=='string'||!account.test(member.id)||cached.has(member.id)||typeof member.name!=='string'||!member.name.trim()||member.name!==member.name.trim()||new TextEncoder().encode(member.name).length>120||/[\x00-\x1f\x7f]/.test(member.name))fail('invalid_property_metadata');cached.add(member.id);}
    if(p.id==='00000000000000000000000000000001'&&p.kind!=='member')fail('invalid_assignee_schema');ids.add(p.id);names.add(p.name);
   }
  }
  if(/^\s*[-*]\s+\[[ xX]\](?:\s|$)/.test(line))tasks.push(line);
 }
 const members=new Set((schema??[]).filter(p=>p.kind==='member').map(p=>p.id));const result=new Set<string>(),taskIds=new Set<string>();
 for(const line of tasks){
  const ids=[...line.matchAll(/<!-- doin:task=([a-fA-F0-9]{32}) -->/g)];if(ids.length>1||line.includes('<!-- doin:task=')&&ids.length!==1||ids.length&&taskIds.has(ids[0][1]))fail('invalid_assignee_task_identity');if(ids.length)taskIds.add(ids[0][1]);
  const values=[...line.matchAll(/<!-- doin:values=(.*?) -->/g)];if(values.length>1||line.includes('<!-- doin:values=')&&values.length!==1)fail('invalid_property_metadata');
  if(!values.length)continue;let data:any;try{data=JSON.parse(values[0][1]);}catch{fail('invalid_property_metadata');}
  if(!data||typeof data!=='object'||Array.isArray(data)||Object.keys(data).length>64)fail('invalid_property_metadata');
  const assigned=Object.entries(data).filter(([id])=>members.has(id));if(!assigned.length)continue;
  if(ids.length!==1)fail('invalid_assignee_task_identity');
  for(const [property,value]of assigned){if(typeof value!=='string'||!account.test(value))fail('invalid_assignee');result.add(JSON.stringify([ids[0][1],property,value]));}
 }
 return result;
}
export function assignmentChanges(previous:string,next:string):string[]{
 const old=assignments(previous),current=assignments(next),changed=new Set<string>();
 for(const key of current)if(!old.has(key))changed.add(JSON.parse(key)[2]);
 if(changed.size>10000)fail('assignee_limit');return [...changed];
}
export const assignmentGuard=` AND NOT EXISTS(SELECT 1 FROM json_each(?) candidate WHERE NOT EXISTS(SELECT 1 FROM team_members assignee JOIN accounts account ON account.id=assignee.account_id WHERE assignee.team_id=? AND assignee.account_id=candidate.value AND account.closing_at IS NULL AND (assignee.role IN ('owner','admin') OR EXISTS(SELECT 1 FROM team_folder_grants ag JOIN ancestors ap ON ap.id=ag.folder_id WHERE ag.team_id=assignee.team_id AND ag.account_id=assignee.account_id))))`;
