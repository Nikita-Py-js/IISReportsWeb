/* IIS Reports v3: operations UI. No external scripts, no credentials in storage. */
let tokenRequest = null;
const v3Cache = { checks: [], rules: [] };

async function renewToken() {
  if (!tokenRequest) tokenRequest = api('csrf', null, { noSite:true }).then(data => {
    csrfToken=data.token; accessInfo=data.security || {}; applyAccess(); return data;
  }).finally(() => { tokenRequest=null; });
  return tokenRequest;
}
async function api(action, params, opts={}) {
  const query=Object.assign({ action },params || {});
  if(!opts.noSite && $('site-select').value!=='0') query.siteId=$('site-select').value;
  const method=opts.method || 'GET';
  if(method==='POST' && !csrfToken) await renewToken();
  const headers=method==='POST' ? {'Content-Type':'application/json; charset=utf-8','X-IISReports-CSRF':csrfToken} : {};
  const controller=new AbortController();
  const timer=setTimeout(()=>controller.abort(),120000);
  let response, data;
  try {
    response=await fetch('Reports.ashx?'+new URLSearchParams(query),{method,headers,credentials:'same-origin',cache:'no-store',
      body:method==='POST'?JSON.stringify(opts.body || {}):undefined,signal:controller.signal});
    const text=await response.text();
    try { data=JSON.parse(text); }
    catch (_) { throw new Error(`${action}: HTTP ${response.status}. IIS returned non-JSON. Check Windows Authentication and IIS logs.`); }
  } finally { clearTimeout(timer); }
  if(!response.ok || data?.error) {
    const code=data?.code || '';
    // Retry only an explicit token rejection, which occurs BEFORE any state mutation.
    if(method==='POST' && !opts.retried && ['csrf_expired','csrf_invalid','csrf_missing'].includes(code)) {
      csrfToken=''; await renewToken(); return api(action,params,{...opts,retried:true});
    }
    const error=new Error(`${action}: HTTP ${response.status} [${code||'request_failed'}]. ${data?.error||data?.databaseError||'Access denied'}`);
    error.code=code;error.details=data;throw error;
  }
  return data;
}
function applyAccess() {
  document.querySelectorAll('.operator-only').forEach(el=>{el.style.display=accessInfo.canEdit?'inline-block':'none';});
  const sourceTab=document.querySelector('#tabs button[data-tab="sources"]');
  if(sourceTab)sourceTab.hidden=!accessInfo.canEdit;
  document.querySelectorAll('.toolbar button[onclick="refresh()"]')
    .forEach(el=>{el.disabled=!accessInfo.canEdit;el.title='Queue a scan in the Windows agent';});
}
async function loadAccess(){await renewToken();}
function v3Button(action,id,label) {
  return `<button class="ghost v3-small" type="button" data-v3-action="${esc(action)}" data-id="${esc(id)}">${esc(label)}</button>`;
}
function v3Table(target,rows,columns) {
  const head=columns.map(c=>`<th>${esc(c[0])}</th>`).join('');
  const body=rows.map(r=>'<tr>'+columns.map(c=>`<td>${typeof c[1]==='function'?c[1](r):esc(r[c[1]]??'\u2014')}</td>`).join('')+'</tr>').join('');
  $(target).innerHTML=`<table><thead><tr>${head}</tr></thead><tbody>${body||emptyRow(columns.length)}</tbody></table>`;
}
function detail(title,value) {
  $('detail-title').textContent=title;
  $('detail-body').textContent=typeof value==='string'?value:JSON.stringify(value,null,2);
  $('v3-dialog').showModal();
}
const checkFields=[
 ['name','\u041d\u0430\u0437\u0432\u0430\u043d\u0438\u0435','text'],['url','URL (GET)','url'],['enabled','\u0412\u043a\u043b\u044e\u0447\u0435\u043d\u043e','checkbox'],
 ['expectedStatus','HTTP status','number',100,599],['intervalSeconds','\u0418\u043d\u0442\u0435\u0440\u0432\u0430\u043b, \u0441','number',10,86400],
 ['timeoutSeconds','Timeout, \u0441','number',1,30],['maxLatencyMs','\u041f\u043e\u0440\u043e\u0433 \u0437\u0430\u0434\u0435\u0440\u0436\u043a\u0438, \u043c\u0441','number',1,30000],
 ['failAfter','\u0421\u0431\u043e\u0435\u0432 \u043f\u043e\u0434\u0440\u044f\u0434','number',1,100],['recoverAfter','\u0423\u0441\u043f\u0435\u0445\u043e\u0432 \u0434\u043b\u044f \u0432\u043e\u0441\u0441\u0442\u0430\u043d\u043e\u0432\u043b\u0435\u043d\u0438\u044f','number',1,100],
 ['containsText','\u0422\u0435\u043a\u0441\u0442 \u0432 \u043e\u0442\u0432\u0435\u0442\u0435 (\u043e\u043f\u0446\u0438\u044f)','text'],['jsonKey','JSON: \u043a\u043b\u044e\u0447 \u0432\u0435\u0440\u0445\u043d\u0435\u0433\u043e \u0443\u0440\u043e\u0432\u043d\u044f','text'],
 ['jsonValue','JSON: \u043e\u0436\u0438\u0434\u0430\u0435\u043c\u043e\u0435 \u0437\u043d\u0430\u0447\u0435\u043d\u0438\u0435','text'],['mutedUntilUtc','\u041f\u0430\u0443\u0437\u0430 \u0430\u043b\u0435\u0440\u0442\u043e\u0432 \u0434\u043e (ISO UTC)','text']
];
const ruleFields=[
 ['name','\u041d\u0430\u0437\u0432\u0430\u043d\u0438\u0435','text'],['metric','\u041c\u0435\u0442\u0440\u0438\u043a\u0430','select',['5xx_count','5xx_percent','p95_ms','auth_failures','requests','import_stale_minutes']],
 ['enabled','\u0412\u043a\u043b\u044e\u0447\u0435\u043d\u043e','checkbox'],['siteId','Site ID (0 = all)','number',0,2147483647],
 ['windowMinutes','\u041e\u043a\u043d\u043e, \u043c\u0438\u043d','number',1,1440],['threshold','\u041f\u043e\u0440\u043e\u0433 (\u043c\u0435\u0442\u0440\u0438\u043a\u0430 > \u043f\u043e\u0440\u043e\u0433)','number',0,1e12],
 ['minSamples','\u041c\u0438\u043d. \u0432\u044b\u0431\u043e\u0440\u043a\u0430','number',1,1e9],['failAfter','\u041d\u0430\u0440\u0443\u0448\u0435\u043d\u0438\u0439 \u043f\u043e\u0434\u0440\u044f\u0434','number',1,100],
 ['recoverAfter','\u0423\u0441\u043f\u0435\u0448\u043d\u044b\u0445 \u043e\u0446\u0435\u043d\u043e\u043a \u0434\u043b\u044f \u0432\u043e\u0441\u0441\u0442\u0430\u043d\u043e\u0432\u043b\u0435\u043d\u0438\u044f','number',1,100],
 ['mutedUntilUtc','\u041f\u0430\u0443\u0437\u0430 \u0434\u043e (ISO UTC)','text']
];
function editor(kind,record={}) {
  if(!accessInfo.canEdit)throw new Error('Operator role required');
  const defs=kind==='check'?checkFields:ruleFields;
  const form=$(kind+'-form');
  const values=Object.fromEntries(Object.entries(record).map(([k,v])=>[k[0].toLowerCase()+k.slice(1),v]));
  if(kind==='rule' && (values.siteId===null||values.siteId===undefined))values.siteId=0;
  form.innerHTML='<h3>'+esc(values.id?'Edit':'New '+kind)+'</h3><div class="v3-form-grid">'+defs.map(([key,label,type,min,max])=>{
    const val=values[key]??'';
    if(type==='select')return `<label>${esc(label)}<select data-key="${key}">${min.map(x=>`<option value="${x}" ${x===val?'selected':''}>${x}</option>`).join('')}</select></label>`;
    return `<label>${esc(label)}<input data-key="${key}" type="${type}" ${type==='checkbox'?(val?'checked':''):`value="${esc(val)}"`}
      ${type==='number'?`min="${min}" max="${max}" step="${key==='threshold'?'any':1}" required`:''}
      ${['name','url'].includes(key)?'required':''}></label>`;
  }).join('')+'</div><button type="submit">\u0421\u043e\u0445\u0440\u0430\u043d\u0438\u0442\u044c</button> <button type="button" class="ghost" data-cancel>\u041e\u0442\u043c\u0435\u043d\u0430</button>';
  form.hidden=false;
  form.querySelector('[data-cancel]').onclick=()=>{form.hidden=true;};
  form.onsubmit=async event=>{
    event.preventDefault();if(!form.reportValidity())return;
    const body={id:values.id||null,revision:Number(values.revision||0)};
    defs.forEach(([key,,type])=>{const field=form.querySelector(`[data-key="${key}"]`);body[key]=type==='checkbox'?field.checked:type==='number'?Number(field.value):field.value.trim();});
    const save=form.querySelector('[type="submit"]');save.disabled=true;
    try {await api(kind+'-save',null,{noSite:true,method:'POST',body});form.hidden=true;flash('\u0421\u043e\u0445\u0440\u0430\u043d\u0435\u043d\u043e');if(kind==='check')await loadV3Tab('checks');else await loadAlerts();}
    catch(error){showError(error);}finally{save.disabled=false;}
  };
  form.scrollIntoView({behavior:'smooth',block:'center'});
}
async function loadAlerts() {
  const rows=await api('rules',null,{noSite:true});v3Cache.rules=rows;
  v3Table('rules-table',rows,[['\u041f\u0440\u0430\u0432\u0438\u043b\u043e','Name'],['\u0412\u043a\u043b.',r=>esc(r.Enabled)],['\u041c\u0435\u0442\u0440\u0438\u043a\u0430','Metric'],['\u041f\u043e\u0440\u043e\u0433','Threshold'],['\u041e\u043a\u043d\u043e, \u043c\u0438\u043d','WindowMinutes'],['\u0417\u043d\u0430\u0447\u0435\u043d\u0438\u0435','LastValue'],['\u0412\u044b\u0431\u043e\u0440\u043a\u0430','LastSamples'],['\u0420\u0435\u0437\u0443\u043b\u044c\u0442\u0430\u0442','LastMessage'],['',r=>accessInfo.canEdit?v3Button('edit-rule',r.Id,'Edit'):'']]);
}

const sourceSettings = { rows: [], draft: new Map(), busy: false, loadSequence: 0 };
const discoveryLabels = {
  ready:'Готов', logging_disabled:'Журналирование в IIS выключено',
  waiting_directory:'Ожидание каталога журналов', path_or_acl_error:'Путь или права доступа',
  central_unsupported:'Централизованные логи не поддерживаются', format_unsupported:'Нужен формат W3C',
  etw_only:'Нет записи W3C в файл', not_in_iis:'Удалён из IIS / путь изменён'
};
function visibleSourceRows() {
  const q=$('source-search').value.trim().toLocaleLowerCase();
  return sourceSettings.rows.filter(r=>!q || `${r.Name} ${r.IisName||''} ${r.SiteId} ${r.RootPath}`.toLocaleLowerCase().includes(q));
}
function renderSourceSettings() {
  const rows=visibleSourceRows();
  const draft=sourceSettings.draft;
  $('sources-save').disabled=sourceSettings.busy || !draft.size;
  $('sources-enable-visible').disabled=sourceSettings.busy || !rows.length;
  $('sources-disable-visible').disabled=sourceSettings.busy || !rows.length;
  $('sources-reload').disabled=sourceSettings.busy;
  $('source-selection-status').textContent=
    `Источников: ${sourceSettings.rows.length}; видно: ${rows.length}; включено в базе: ${sourceSettings.rows.filter(r=>r.Enabled).length}. `+
    (draft.size?`Несохранённых изменений: ${draft.size}.`:'Выбор сохранён в MSSQL.');
  $('source-roots').innerHTML='<table><thead><tr><th>Мониторить</th><th>Сайт / ID</th><th>Каталог</th><th>Состояние</th><th>Последний импорт UTC</th></tr></thead><tbody>'+
    (rows.map(r=>{
      const checked=draft.has(r.Id)?draft.get(r.Id):Boolean(r.Enabled);
      const available=!r.AutoDiscovered || r.Available;
      const title=(discoveryLabels[r.DiscoveryStatus]||r.DiscoveryStatus||'Ручной источник');
      return `<tr class="${draft.has(r.Id)?'source-dirty':''}">
        <td><input type="checkbox" data-source-id="${Number(r.Id)}" aria-label="Мониторить ${esc(r.Name)}" ${checked?'checked':''} ${sourceSettings.busy?'disabled':''}></td>
        <td><b>${esc(r.Name)}</b><br><span class="hint">ID ${Number(r.SiteId)}${r.IisName&&r.IisName!==r.Name?' · IIS: '+esc(r.IisName):''}</span></td>
        <td class="mono">${esc(r.RootPath)}</td>
        <td><span class="badge ${r.Enabled&&available?'ok':'warn'}">${r.Enabled?(available?'Импорт включён':'Включён, ожидает источник'):'Импорт на паузе'}</span>
          <div class="hint">${esc(title)}</div><div class="v3-problem">${esc(r.DiscoveryMessage||'')}</div>
          <div class="v3-problem">${esc(r.LastError||'')}</div></td>
        <td>${fmt(r.LastScanUtc)}</td></tr>`;
    }).join('')||emptyRow(5))+'</tbody></table>';
}
function stageSource(id,value) {
  const row=sourceSettings.rows.find(r=>r.Id===id);
  if(!row || sourceSettings.busy)return;
  if(Boolean(row.Enabled)===value)sourceSettings.draft.delete(id);else sourceSettings.draft.set(id,value);
}
async function saveSourceSettings() {
  if(sourceSettings.busy||!sourceSettings.draft.size)return;
  if(!accessInfo.canEdit)throw new Error('Требуются права редактора.');
  const changes=[...sourceSettings.draft].map(([id,enabled])=>({id,enabled,revision:Number(sourceSettings.rows.find(r=>r.Id===id).Revision)}));
  if(changes.length>1000){showError(new Error('Сохраните не более 1000 источников за один раз; используйте фильтр.'));return;}
  sourceSettings.busy=true;renderSourceSettings();
  try {
    await api('sources-save',null,{noSite:true,method:'POST',body:{changes}});
    sourceSettings.draft.clear();clearError();
    flash('Выбор сохранён. История не удаляется.');
    await loadSources();
  } catch(error) {
    if(error.code==='revision_conflict') {
      sourceSettings.draft.clear();
      await loadSources();
      showError(new Error('Выбор изменён в другой сессии. Список обновлён; повторите нужные изменения.'));
    } else showError(error);
  } finally {sourceSettings.busy=false;renderSourceSettings();}
}
async function loadSources() {
  const sequence=++sourceSettings.loadSequence;
  const x=await api('sources',null,{noSite:true});
  if(sequence!==sourceSettings.loadSequence)return;
  // Never overwrite unsaved checkbox edits during a periodic refresh.
  if(!sourceSettings.draft.size)sourceSettings.rows=x.sources||[];
  sourcesSnapshot=x.files||[];
  const d=(x.discovery||[])[0];
  $('discovery-state').textContent=d
    ? `Обнаружение: ${d.State==='ok'?'работает':d.State}. Снимок IIS: ${fmt(d.SnapshotUtc)}. Сайтов: ${d.SitesFound??0}. ${d.LastError||''}`
    : 'Ожидание первого снимка IIS. Проверьте задачу IISReports-DiscoverSites и службу агента.';
  $('discovery-state').className=!d||d.State==='error'?'v3-problem':'hint';
  renderSourceSettings();
  $('sources-summary').textContent=`Файлов: ${x.total}; показано: ${x.shown}. Проверка целостности не удаляет историю.`;
  $('sources-body').innerHTML=sourcesSnapshot.map(r=>{
    const source=sourceSettings.rows.find(s=>s.Id===r.sourceId);
    const canImport=source&&source.Enabled&&(!source.AutoDiscovered||source.Available);
    return `<tr>
    <td class="mono">${esc(r.path)}<br><span class="v3-problem">${esc(r.error)}</span></td><td>${r.generation}</td><td>${esc(r.status)}</td>
    <td>${num(r.position)} / ${num(r.size)}</td><td>${num(r.dbRows)} / ${num(r.parseErrors)}</td><td>${esc(r.verification||'—')}<br>${fmt(r.verifiedUtc)}</td>
    <td>${v3Button('verify',r.fileId,'Verify')}${canImport?v3Button('replay',r.fileId,'Replay'):''}${v3Button('generations',r.fileId,'Versions')}${canImport?v3Button('new-generation',r.fileId,'New version'):''}</td></tr>`;
  }).join('')||emptyRow(7);
}
$('source-search').addEventListener('input',renderSourceSettings);
$('source-roots').addEventListener('change',event=>{
  const box=event.target.closest('[data-source-id]');
  if(box){stageSource(Number(box.dataset.sourceId),box.checked);renderSourceSettings();}
});
$('sources-save').addEventListener('click',()=>saveSourceSettings().catch(showError));
$('sources-reload').addEventListener('click',async()=>{
  if(sourceSettings.draft.size&&!confirm('Отменить несохранённый выбор и перечитать список?'))return;
  sourceSettings.draft.clear();try{await loadSources();}catch(error){showError(error);}
});
$('sources-enable-visible').addEventListener('click',()=>{visibleSourceRows().forEach(r=>stageSource(r.Id,true));renderSourceSettings();});
$('sources-disable-visible').addEventListener('click',()=>{visibleSourceRows().forEach(r=>stageSource(r.Id,false));renderSourceSettings();});
async function loadV3Tab(name) {
  if(name==='access') {
    // Own identity is available even before role authorization succeeds.
    const r=await fetch('Reports.ashx?action=whoami',{credentials:'same-origin',cache:'no-store'});
    const text=await r.text();let data;try{data=JSON.parse(text);}catch{data={httpStatus:r.status,message:'IIS returned non-JSON. Check authentication settings.'};}
    $('access-info').textContent=JSON.stringify(data,null,2);return data;
  }
  if(name==='agent') {
    const [state,health]=await Promise.all([api('agent',null,{noSite:true}),api('health',null,{noSite:true})]);
    $('agent-status').innerHTML=`<p><b>${health.agentOnline?'Online':'Offline / stale'}</b> | Heartbeat: ${esc(health.heartbeatAgeSeconds)} s | Pending jobs: ${num(health.queuedJobs)}</p><pre class="v3-pre"></pre>`;
    $('agent-status').querySelector('pre').textContent=JSON.stringify(state,null,2);return;
  }
  if(name==='checks') {
    const rows=await api('checks',null,{noSite:true});v3Cache.checks=rows;
    v3Table('checks-table',rows,[['\u041f\u0440\u043e\u0432\u0435\u0440\u043a\u0430','Name'],['URL','Url'],['\u0412\u043a\u043b.',r=>esc(r.Enabled)],['\u0423\u0441\u043f\u0435\u0445',r=>esc(r.LastSuccess??'\u2014')],['\u041f\u043e\u0441\u043b\u0435\u0434\u043d\u044f\u044f UTC',r=>fmt(r.LastCheckUtc)],['\u0420\u0435\u0437\u0443\u043b\u044c\u0442\u0430\u0442','LastMessage'],['',r=>v3Button('check-results',r.Id,'History')+(accessInfo.canEdit?v3Button('edit-check',r.Id,'Edit'):'')]]);return;
  }
  if(name==='incidents') {
    const rows=await api('incidents',null,{noSite:true});
    v3Table('incidents-table',rows,[['\u0418\u043d\u0446\u0438\u0434\u0435\u043d\u0442','Title'],['\u0421\u0442\u0430\u0442\u0443\u0441','State'],['\u041d\u0430\u0447\u0430\u043b\u043e UTC',r=>fmt(r.OpenedUtc)],['\u0414\u0435\u0442\u0430\u043b\u0438','Detail'],['',r=>v3Button('incident-events',r.Id,'Events')+(accessInfo.canEdit?(
      (r.State==='open'?v3Button('ack',r.Id,'Acknowledge'):'')+(r.State==='resolved'?v3Button('close',r.Id,'Close'):'')+(r.Active?v3Button('cancel',r.Id,'Close manually'):'')):'')]]);return;
  }
  if(name==='queue') {
    const [jobs,messages]=await Promise.all([api('jobs',null,{noSite:true}),api('notifications',null,{noSite:true})]);
    v3Table('jobs-table',jobs,[['\u0422\u0438\u043f','Kind'],['\u0421\u0442\u0430\u0442\u0443\u0441','State'],['\u041f\u043e\u043b\u044c\u0437\u043e\u0432\u0430\u0442\u0435\u043b\u044c','RequestedBy'],['\u041d\u0430\u0447\u0430\u043b\u043e UTC',r=>fmt(r.RequestedUtc)],['\u041f\u0440\u043e\u0433\u0440\u0435\u0441\u0441','ProgressOffset'],['\u0420\u0435\u0437\u0443\u043b\u044c\u0442\u0430\u0442','Result']]);
    v3Table('outbox-table',messages,[['Event ID','Id'],['\u0422\u0438\u043f','Kind'],['\u0421\u0442\u0430\u0442\u0443\u0441','State'],['\u041f\u043e\u043f\u044b\u0442\u043a\u0438','Attempts'],['HTTP','HttpStatus'],['\u041e\u0448\u0438\u0431\u043a\u0430','LastError'],['',r=>r.State==='failed'?v3Button('retry',r.Id,'Retry'):'']]);return;
  }
}
document.addEventListener('click',async event=>{
  const el=event.target.closest('[data-v3-action]');if(!el)return;
  const action=el.dataset.v3Action,id=el.dataset.id;el.disabled=true;
  try {
    if(action==='renew-csrf'){await renewToken();flash('CSRF token renewed');await loadV3Tab('access');}
    else if(action==='new-check')editor('check',{enabled:true,expectedStatus:200,intervalSeconds:60,timeoutSeconds:10,maxLatencyMs:5000,failAfter:3,recoverAfter:2});
    else if(action==='new-rule')editor('rule',{enabled:true,metric:'5xx_percent',siteId:0,windowMinutes:5,threshold:5,minSamples:100,failAfter:2,recoverAfter:2});
    else if(action==='edit-check')editor('check',v3Cache.checks.find(x=>x.Id===id));
    else if(action==='edit-rule')editor('rule',v3Cache.rules.find(x=>x.Id===id));
    else if(['verify','replay','new-generation'].includes(action)) {
      const message=action==='new-generation'?'Create a NEW active file version? Old raw data stays archived and is excluded from current charts.':`Queue ${action} for file ${id}?`;
      if(confirm(message)){await api('job-create',null,{noSite:true,method:'POST',body:{kind:action,fileId:Number(id)}});flash('Queued in Windows agent');}
    }
    else if(['ack','close','cancel'].includes(action)) {
      if(action!=='cancel'||confirm('Close manually without verified recovery? The rule may open another incident if the failure continues.')){
        await api('incident-action',null,{noSite:true,method:'POST',body:{id,action}});await loadV3Tab('incidents');
      }
    }
    else if(action==='test-notification'){await api('notification-test',null,{noSite:true,method:'POST'});flash('Test queued, not yet delivered');await loadV3Tab('queue');}
    else if(action==='retry'){await api('notification-retry',null,{noSite:true,method:'POST',body:{id}});await loadV3Tab('queue');}
    else if(action==='raw')detail('Raw event',await api('raw-event',{id},{noSite:true}));
    else if(action==='generations')detail('File generations',await api('generations',{fileId:id},{noSite:true}));
    else if(action==='parse-errors')detail('Parse failures',await api('parse-errors',null,{noSite:true}));
    else if(['check-results','incident-events'].includes(action))detail(action,await api(action,{id},{noSite:true}));
  }catch(error){showError(error);}finally{el.disabled=false;}
});
(async function startV3(){
  try {
    const own=await loadV3Tab('access');accessInfo=own;applyAccess();
    if(!own.canRead){switchTab('access');throw new Error(`Windows / access: ${own.denialCode||'authentication_required'}. See tools/Enable-WindowsAuth.ps1; use the identity shown in whoami.`);}
    await loadAccess();await loadSites();
    const initialTab=new URLSearchParams(location.hash.slice(1)).get('tab')||'overview';readStateFromHash();
    await loadAll();switchTab(initialTab);await loadHealth();
  }catch(error){showError(error);}
  setInterval(async()=>{
    if(!accessInfo.canRead||refreshing||document.hidden)return;
    try {
      await loadHealth();const active=document.querySelector('#tabs button.active')?.dataset.tab;
      if(active==='overview'){await loadSites();await loadOverview();}
      else if(active==='sources'&&!sourceSettings.busy&&!sourceSettings.draft.size)await loadSources();
      else if(['agent','incidents','queue'].includes(active))await loadV3Tab(active);
    }catch(error){showError(error);}
  },30000);
})();
