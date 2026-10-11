"""Browser integration with mocked JSON API; NOT a live IIS/SQL or CSRF security test.
Run: python tests/browser_smoke.py --chromium /path/to/chromium
Requires playwright (Python). All network responses are intercepted locally.
"""
import argparse, json, re
from types import SimpleNamespace
from pathlib import Path
from urllib.parse import urlparse, parse_qs
from playwright.sync_api import sync_playwright

ROOT=Path(__file__).resolve().parents[1]
NOW='2026-10-11T18:00:00Z'
UUID='11111111-1111-1111-1111-111111111111'
XSS='<img src=x onerror="window.pwned=1">'

def run(binary):
    results=[]
    with sync_playwright() as p:
        browser=p.chromium.launch(headless=True,executable_path=binary)
        page=browser.new_page(viewport={'width':1440,'height':1000})
        errors=[]; page.on('pageerror',lambda e: errors.append(str(e)))
        state={'editor':True,'read':True,'deny':None,'expire':False,'tokenCalls':0,'posts':[],'sourceConflict':False,'sources':[{'Id':1,'SiteId':1,'Name':'Primary','RootPath':'C:\\logs\\W3SVC1','Enabled':True,'Revision':1,'AutoDiscovered':True,'Available':True,'DiscoveryStatus':'ready','LastScanUtc':NOW},{'Id':2,'SiteId':2,'Name':XSS,'RootPath':'D:\\logs\\W3SVC2','Enabled':True,'Revision':1,'AutoDiscovered':True,'Available':True,'DiscoveryStatus':'ready','LastScanUtc':NOW},{'Id':3,'SiteId':3,'Name':'FutureSite','RootPath':'C:\\logs\\W3SVC3','Enabled':True,'Revision':1,'AutoDiscovered':True,'Available':False,'DiscoveryStatus':'waiting_directory','LastScanUtc':None}]}
        def route(handler):
            url=urlparse(handler.request.url)
            if url.path.endswith('Reports.ashx'):
                action=parse_qs(url.query).get('action',[''])[0];code=200
                identity={'mode':'windows','identity':'TEST\\Operator','isAuthenticated':True,'authenticationType':'Negotiate','canRead':state['read'],'canEdit':state['editor'],'denialCode':None if state['read'] else 'reader_role_required','processIdentity':'IIS APPPOOL\\IISReports','version':'3.1.0'}
                lists={'clients','users','targets','methods','user-agents','referers','slow-requests','slow-urls','errors-5xx-by-url','check-results','incident-events','audit','parse-errors'}
                if handler.request.method=='POST':
                    state['posts'].append((action,json.loads(handler.request.post_data or '{}'),handler.request.headers.get('x-iisreports-csrf')))
                    if state['expire']:
                        state['expire']=False;code=403;data={'error':'Expired token','code':'csrf_expired'}
                    elif state['deny']:
                        code=403;data={'error':'Denied','code':state['deny']}
                    elif action=='sources-save':
                        changes=json.loads(handler.request.post_data)['changes']
                        mismatch=state['sourceConflict'] or any(not any(r['Id']==x['id'] and r['Revision']==x['revision'] for r in state['sources']) for x in changes)
                        if mismatch:code=409;data={'code':'revision_conflict','error':'Reload source settings'};state['sourceConflict']=False
                        else:
                            for change in changes:
                                row=next(r for r in state['sources'] if r['Id']==change['id']);row['Enabled']=change['enabled'];row['Revision']+=1
                            data={'ok':True,'changed':len(changes)}
                    else:code=202 if action in ('refresh','job-create') else 200;data={'ok':True,'id':UUID}
                elif action=='whoami':data=identity
                elif action=='csrf':state['tokenCalls']+=1;data={'token':'test-token-'+str(state['tokenCalls']),'security':identity}
                elif action=='sites':data=[{'siteId':1,'name':'Main','requests':1177},{'siteId':2,'name':'Two','requests':1177}]
                elif action=='health':data={'status':'ok','agentOnline':True,'heartbeatAgeSeconds':2,'totalEntries':1177,'queuedJobs':0,'lastParsed':NOW,'errors':[]}
                elif action=='overview':data={'total':1177,'uniqueIps':77,'uniqueUsers':3,'uniqueTargets':333,'status2xx':680,'status3xx':7,'status4xx':477,'status5xx':13,'firstSeen':NOW,'lastSeen':NOW,'lastParsed':NOW,'avgTimeMs':189.8}
                elif action=='timeline':data={'byHour':[{'hour':i,'count':i*3} for i in range(24)],'byDay':[{'date':'2026-10-10','count':501},{'date':'2026-10-11','count':676}]}
                elif action=='status-codes':data=[{'status':404,'count':373,'percent':31.69}]
                elif action=='response-times':data={'avg':10,'p95':20,'histogram':[]}
                elif action in lists:data=[]
                elif action=='security':data={'top4xx':[],'topAuth':[],'sensitivePaths':[],'suspiciousUa':[]}
                elif action=='error-diagnostics':data={'codes':[],'urls404':[],'urls5xx':[],'referers404':[]}
                elif action=='performance':data={'bucketMinutes':1,'points':[{'ts':NOW,'requests':3,'status4xx':1,'status5xx':0,'avgMs':20,'p95Ms':30,'peakRps':2,'avgRps':.05,'rpm':3}]}
                elif action=='comparison':data={k:{'from':NOW,'to':NOW,'requests':100,'errors4xx':4,'errors5xx':1,'avgMs':20,'p95Ms':40} for k in ('previous','current')}
                elif action=='bots':data={'asnRanges':0,'rows':[]}
                elif action=='sources':data={'files':[{'fileId':1,'sourceId':1,'path':'C:\\logs\\test.log','generation':1,'generationId':1,'status':'ok','size':99,'position':99,'dbRows':3,'parseErrors':0,'verification':'ok','verifiedUtc':NOW,'error':None}], 'sources':state['sources'],'discovery':[{'State':'ok','SitesFound':3,'SnapshotUtc':NOW}],'total':1,'shown':1,'integrityScope':'All chunks checked by Verify'}
                elif action=='generations':data=[{'Id':1,'Number':1,'IsActive':True}]
                elif action=='checks':data=[{'Id':UUID,'Name':XSS,'Url':'https://allowed.test/health','Enabled':True,'Revision':1,'ExpectedStatus':200,'IntervalSeconds':60,'TimeoutSeconds':10,'MaxLatencyMs':5000,'FailAfter':3,'RecoverAfter':2,'LastSuccess':True,'LastCheckUtc':NOW,'LastMessage':'ok'}]
                elif action=='rules':data=[{'Id':UUID,'Name':'rule','Metric':'5xx_percent','Threshold':5,'Enabled':True,'SiteId':None,'WindowMinutes':5,'MinSamples':100,'FailAfter':2,'RecoverAfter':2,'Revision':1,'LastValue':0,'LastSamples':100,'LastMessage':'ok'}]
                elif action=='agent':data=[{'State':'running','HeartbeatUtc':NOW}]
                elif action=='incidents':data=[{'Id':UUID,'Title':'Test','State':'open','Active':True,'OpenedUtc':NOW,'Detail':XSS}]
                elif action=='jobs':data=[{'Id':UUID,'Kind':'scan','State':'done','RequestedBy':'TEST\\Operator','RequestedUtc':NOW,'ProgressOffset':99,'Result':'ok'}]
                elif action=='notifications':data=[{'Id':UUID,'Kind':'opened','State':'failed','Attempts':8,'HttpStatus':500,'LastError':'test'}]
                elif action=='raw-event':data=[{'RawText':XSS,'Id':1}]
                elif action=='logs':data={'total':1,'page':1,'pageSize':100,'items':[{'timestamp':NOW,'siteId':1,'siteName':'Main','clientIp':'192.0.2.1','countryCode':'','userName':'Anonymous','method':'GET','target':XSS,'status':404,'timeMs':2,'userAgent':XSS,'rawEventId':1}]}
                else:raise AssertionError('Unexpected API: '+action)
                handler.fulfill(status=code,content_type='application/json',body=json.dumps(data));return
            name=url.path.rsplit('/',1)[-1] or 'index.html';path=ROOT/'web'/name
            if path.is_file():handler.fulfill(content_type={'html':'text/html','js':'application/javascript','css':'text/css'}[path.suffix[1:]],body=path.read_text(encoding='utf-8-sig'))
            else:handler.fulfill(status=404,body='')
        def mocked_fetch(url, options):
            result={}
            request=SimpleNamespace(url=url,method=options.get('method','GET'),post_data=options.get('body'),headers={k.lower():v for k,v in options.get('headers',{}).items()})
            class Handler:
                def __init__(self): self.request=request
                def fulfill(self,**kwargs): result.update(kwargs)
            route(Handler())
            return {'status':result.get('status',200),'body':result.get('body','')}
        def load_page():
            nonlocal page
            page=browser.new_page(viewport={'width':1440,'height':1000})
            page.on('pageerror',lambda e: errors.append(str(e)))
            page.expose_function('__mockFetch',mocked_fetch)
            page.evaluate("""() => {
              history.replaceState(null, '', '#site=2');
              window.fetch=async (url,opts={})=>{
                const r=await window.__mockFetch(String(url),opts);
                return new Response(r.body,{status:r.status,headers:{'Content-Type':'application/json'}});
              };
            }""")
            html=(ROOT/'web/index.html').read_text(encoding='utf-8-sig')
            html=html.replace('<script src="v3.js"></script>','<script>'+(ROOT/'web/v3.js').read_text()+'</script>')
            html=html.replace('<link rel="stylesheet" href="v3.css">','<style>'+(ROOT/'web/v3.css').read_text()+'</style>')
            page.set_content(html)
        page.close();load_page();page.wait_for_function("document.querySelector('#kpis').textContent.includes('1177')")
        def ok(name,condition=True):
            assert condition,name
            results.append({'test':name,'status':'PASS'})
        ok('startup renders overview with stored site',page.locator('#site-select').input_value()=='2')
        ok('daily share uses total, not maximum','57.4%' in page.locator('#daily-body').inner_text())
        tabs=page.locator('#tabs button').evaluate_all('(els)=>els.map(e=>e.dataset.tab)')
        for tab in tabs:
            page.click(f'#tabs button[data-tab="{tab}"]');page.wait_for_timeout(40)
            ok('tab '+tab,page.locator('#tab-'+tab).is_visible())
        ok('all tabs without JavaScript errors',not errors)
        page.click('#tabs button[data-tab="checks"]');page.wait_for_timeout(60)
        ok('check name HTML escaped',page.locator('#checks-table img').count()==0 and page.evaluate('window.pwned===undefined'))
        page.click('[data-v3-action="new-check"]');page.locator('#check-form [data-key="name"]').fill('Synthetic check');page.locator('#check-form [data-key="url"]').fill('https://allowed.test/health')
        page.locator('#check-form [type="submit"]').click();page.wait_for_timeout(80)
        ok('check editor sends typed JSON and CSRF',state['posts'][-1][0]=='check-save' and state['posts'][-1][1]['expectedStatus']==200 and bool(state['posts'][-1][2]))
        page.click('#tabs button[data-tab="alerts"]');page.wait_for_timeout(60);page.click('[data-v3-action="edit-rule"]')
        ok('all-sites rule opens as site 0',page.locator('#rule-form [data-key="siteId"]').input_value()=='0')
        page.locator('#rule-form [type="submit"]').click();page.wait_for_timeout(60)
        ok('rule editor preserves revision',state['posts'][-1][0]=='rule-save' and state['posts'][-1][1]['revision']==1)
        state['expire']=True;before=len(state['posts']);tokens=state['tokenCalls']
        page.evaluate("api('refresh',null,{method:'POST',noSite:true})")
        ok('expired CSRF retried exactly once',len(state['posts'])==before+2 and state['tokenCalls']==tokens+1)
        state['deny']='csrf_origin';before=len(state['posts']);tokens=state['tokenCalls']
        error=page.evaluate("api('refresh',null,{method:'POST',noSite:true}).then(()=>'',e=>e.code)")
        ok('origin denial not retried',error=='csrf_origin' and len(state['posts'])==before+1 and state['tokenCalls']==tokens)
        state['deny']=None
        page.evaluate("detail('Raw event', '<img src=x onerror=window.pwned=1>')")
        ok('raw line dialog is text only',page.locator('#detail-body img').count()==0)
        page.locator('#v3-dialog').evaluate('(e)=>e.close()')
        page.click('#tabs button[data-tab="sources"]');page.wait_for_timeout(100)
        ok('monitoring checkboxes for every source including no-log site',page.locator('#source-roots [data-source-id]').count()==3)
        ok('source names are HTML escaped',page.locator('#source-roots img').count()==0 and page.evaluate('window.pwned===undefined'))
        page.locator('[data-source-id="1"]').uncheck()
        ok('checkbox edits are not sent before Save',state['sources'][0]['Enabled'] is True and not page.locator('#sources-save').is_disabled())
        page.evaluate('loadSources()')
        ok('refresh preserves unsaved source choice',not page.locator('[data-source-id="1"]').is_checked())
        page.click('#sources-save');page.wait_for_timeout(120)
        ok('source save sends explicit false revision and CSRF',state['posts'][-1][0]=='sources-save' and state['posts'][-1][1]['changes']==[{'id':1,'enabled':False,'revision':1}] and bool(state['posts'][-1][2]))
        ok('source pause survives server reload',state['sources'][0]['Enabled'] is False and not page.locator('[data-source-id="1"]').is_checked())
        ok('saved state has no pending changes',page.locator('#sources-save').is_disabled())
        ok('paused source cannot request replay from UI',page.locator('#sources-body [data-v3-action="replay"]').count()==0)
        page.locator('#source-search').fill('FutureSite')
        page.click('#sources-disable-visible')
        ok('bulk selection applies only to visible rows',page.evaluate('[...sourceSettings.draft.keys()]')==[3])
        page.click('#sources-save');page.wait_for_timeout(100)
        ok('bulk save does not change hidden sources',state['sources'][1]['Enabled'] is True and state['sources'][2]['Enabled'] is False)
        page.locator('#source-search').fill('')
        page.locator('[data-source-id="1"]').check();state['sourceConflict']=True
        page.click('#sources-save');page.wait_for_timeout(150)
        ok('revision conflict reloads server state without false success',state['sources'][0]['Enabled'] is False and not page.locator('[data-source-id="1"]').is_checked())
        page.locator('[data-source-id="1"]').check();state['deny']='editor_role_required'
        page.click('#sources-save');page.wait_for_timeout(120)
        ok('source save failure preserves draft for retry',state['sources'][0]['Enabled'] is False and page.evaluate('sourceSettings.draft.has(1)'))
        state['deny']=None;page.click('#sources-save');page.wait_for_timeout(120)
        ok('re-enable persists monitoring and restores replay action',state['sources'][0]['Enabled'] and page.locator('#sources-body [data-v3-action="replay"]').count()==1)
        state['sources'][1]['Name']='API website'
        state['sources'][1]['Enabled']=False
        state['sources'][2]['Enabled']=True
        page.evaluate("clearError(); document.querySelector('#site-select').value='0'; sourceSettings.draft.clear();")
        page.evaluate("loadSources()")
        page.wait_for_timeout(2200)
        page.screenshot(path=str(ROOT/'tests/sources-preview.png'),full_page=True)
        state['editor']=False;page.close();load_page();page.wait_for_function("accessInfo.canRead && !accessInfo.canEdit");page.wait_for_timeout(100)
        ok('reader cannot see write controls',page.locator('[data-v3-action="new-check"]').is_hidden() and page.locator('#tabs [data-tab="queue"]').is_hidden())
        state['read']=False;page.close();load_page();page.wait_for_function("document.querySelector('#tab-access').hidden===false")
        ok('role denied shown separately from CSRF','reader_role_required' in page.locator('#access-info').inner_text())
        ok('no unhandled browser errors',not errors)
        browser.close()
    report={'suite':'Chromium + mocked API, no IIS/SQL execution','tests':results,'passed':len(results),'browserErrors':errors}
    out=ROOT/'tests/browser-results.json';out.write_text(json.dumps(report,ensure_ascii=False,indent=2))
    print(json.dumps(report,indent=2))

if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--chromium',default='/usr/bin/chromium');run(parser.parse_args().chromium)
