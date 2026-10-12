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
                identity={'mode':'windows','identity':'TEST\\Operator','isAuthenticated':True,'authenticationType':'Negotiate','canRead':state['read'],'canEdit':state['editor'],'denialCode':None if state['read'] else 'reader_role_required','processIdentity':'IIS APPPOOL\\IISReports','version':'3.1.1'}
                lists={'clients','users','targets','methods','user-agents','referers','slow-requests','slow-urls','errors-5xx-by-url','check-results','incident-events','audit','parse-errors'}
                if handler.request.method=='POST':
                    state['posts'].append((action,json.loads(handler.request.post_data or '{}'),handler.request.headers.get('x-iisreports-request')))
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
                    else:code=200;data={'ok':True,'id':UUID,'rowsProcessed':7,'filesProcessed':2,'pendingFiles':1,'errors':[]}
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
                elif action=='sources':data={'files':[{'fileId':1,'sourceId':1,'path':'C:\\logs\\test.log','generation':1,'generationId':1,'status':'ok','size':99,'position':99,'dbRows':3,'parseErrors':0,'verification':'ok','verifiedUtc':NOW,'error':None}], 'sources':state['sources'],'discovery':{'mode':'directories','roots':['C:\\logs'],'errors':[]},'total':1,'shown':1,'integrityScope':'All chunks checked by Verify'}
                elif action=='generations':data=[{'Id':1,'Number':1,'IsActive':True}]
                elif action=='checks':data=[{'Id':UUID,'Name':XSS,'Url':'https://allowed.test/health','Enabled':True,'Revision':1,'ExpectedStatus':200,'IntervalSeconds':60,'TimeoutSeconds':10,'MaxLatencyMs':5000,'FailAfter':3,'RecoverAfter':2,'LastSuccess':True,'LastCheckUtc':NOW,'LastMessage':'ok'}]
                elif action=='rules':data=[{'Id':UUID,'Name':'rule','Metric':'5xx_percent','Threshold':5,'Enabled':True,'SiteId':None,'WindowMinutes':5,'MinSamples':100,'FailAfter':2,'RecoverAfter':2,'Revision':1,'LastValue':0,'LastSamples':100,'LastMessage':'ok'}]
                elif action=='runtime':data={'mode':'web-request','totalEntries':1177,'lastParsed':NOW,'lastRefresh':[]}
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
        page.wait_for_function("!refreshing")
        ok('startup imports via POST',any(x[0]=='refresh' and x[2]=='1' for x in state['posts']))
        ok('no CSRF token request',state['tokenCalls']==0)
        ok('saved site filter restored',page.locator('#site-select').input_value()=='2')
        ok('daily percentages use total','57.4%' in page.locator('#daily-body').inner_text())
        ok('no Windows auth tab',page.locator('#tabs [data-tab="access"]').count()==0)
        tabs=page.locator('#tabs button').evaluate_all('(els)=>els.map(e=>e.dataset.tab)')
        for tab in tabs:
            page.click(f'#tabs button[data-tab="{tab}"]');page.wait_for_timeout(80)
            ok('tab '+tab,page.locator('#tab-'+tab).is_visible())
        ok('all tabs without JS errors',not errors)
        ok('rendered error panel hidden',not page.locator('#api-error').is_visible())
        page.click('#tabs [data-tab="sources"]');page.wait_for_timeout(100)
        ok('source checkboxes present',page.locator('[data-source-id]').count()==3)
        ok('source names escaped',page.locator('#source-roots img').count()==0)
        page.locator('[data-source-id="1"]').uncheck()
        ok('not saved until explicit click',state['sources'][0]['Enabled'] is True)
        page.evaluate('loadSources()')
        ok('unsaved changes retained',not page.locator('[data-source-id="1"]').is_checked())
        page.click('#sources-save');page.wait_for_timeout(120)
        ok('explicit false sent with custom header',state['posts'][-1][0]=='sources-save' and state['posts'][-1][1]['changes'][0]['enabled'] is False and state['posts'][-1][2]=='1')
        ok('pause stored',not state['sources'][0]['Enabled'])
        page.locator('[data-source-id="1"]').check();page.click('#sources-save');page.wait_for_timeout(100)
        ok('resume stored',state['sources'][0]['Enabled'])
        page.locator('#source-search').fill('FutureSite')
        page.click('#sources-disable-visible')
        ok('bulk action only visible',page.evaluate('[...sourceSettings.draft.keys()]')==[3])
        page.click('#sources-save');page.wait_for_timeout(100)
        ok('hidden sources unchanged',state['sources'][1]['Enabled'] is True)
        page.locator('#source-search').fill('')
        page.locator('[data-source-id="1"]').uncheck();state['sourceConflict']=True
        page.click('#sources-save');page.wait_for_timeout(120)
        ok('revision conflict retains true server state',state['sources'][0]['Enabled'] is True)
        page.evaluate('clearError()')
        ok('no Replay action without worker',page.locator('[data-v3-action="replay"]').count()==0)
        page.evaluate("detail('Raw', '<img src=x onerror=window.pwned=1>')")
        ok('raw event displayed as text',page.locator('#detail-body img').count()==0)
        page.locator('#v3-dialog').evaluate('(e)=>e.close()')
        page.click('#tabs [data-tab="checks"]');page.wait_for_timeout(80)
        ok('check name escaped',page.locator('#checks-table img').count()==0)
        page.click('[data-v3-action="new-check"]')
        page.locator('#check-form [data-key="name"]').fill('Manual check')
        page.locator('#check-form [data-key="url"]').fill('https://allowed.test/')
        page.locator('#check-form [type="submit"]').click();page.wait_for_timeout(100)
        ok('check editor sends typed values',state['posts'][-1][0]=='check-save' and state['posts'][-1][1]['expectedStatus']==200)
        page.click('#tab-checks [data-v3-action="run-monitoring"]');page.wait_for_timeout(100)
        ok('manual monitoring is explicit POST',state['posts'][-1][0]=='monitor')
        page.click('#tabs [data-tab="alerts"]');page.wait_for_timeout(80)
        page.click('[data-v3-action="edit-rule"]')
        ok('all-site rule displays zero',page.locator('#rule-form [data-key="siteId"]').input_value()=='0')
        page.locator('#rule-form [type="submit"]').click();page.wait_for_timeout(80)
        ok('rule editor uses POST',state['posts'][-1][0]=='rule-save')
        page.locator('#auto-refresh').uncheck()
        ok('auto-import can be disabled',not page.locator('#auto-refresh').is_checked())
        page.click('#tabs [data-tab="sources"]');page.wait_for_timeout(100)
        state['sources'][1]['Name']='API website'
        page.evaluate("clearError(); sourceSettings.draft.clear()")
        page.evaluate('loadSources()');page.wait_for_timeout(2200)
        page.screenshot(path=str(ROOT/'tests/sources.png'),full_page=True)
        ok('no executed injected HTML',page.evaluate('window.pwned===undefined'))
        ok('all tests without browser runtime errors',not errors)
        browser.close()
    (ROOT/'tests/browser-results.json').write_text(json.dumps({'scope':'Chromium with mocked API, NOT live IIS/SQL','checks':results},ensure_ascii=False,indent=2))
    print('PASS',len(results),'browser tests')

if __name__=='__main__':
    ap=argparse.ArgumentParser();ap.add_argument('--chromium',default='/usr/bin/chromium')
    run(ap.parse_args().chromium)
