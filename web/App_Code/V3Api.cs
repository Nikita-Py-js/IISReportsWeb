using System;
using System.Collections.Generic;
using System.Data;
using System.Data.SqlClient;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;
using System.Web;
using System.Web.Script.Serialization;
using IISReports.V3;

namespace IISReports
{
    public sealed class CheckEdit
    {
        public string id, name, url, containsText, jsonKey, jsonValue, mutedUntilUtc;
        public bool enabled;
        public int revision, expectedStatus, intervalSeconds, timeoutSeconds, maxLatencyMs, failAfter, recoverAfter;
    }
    public sealed class RuleEdit
    {
        public string id, name, metric, mutedUntilUtc;
        public bool enabled;public int revision, siteId, windowMinutes, minSamples, failAfter, recoverAfter;public double threshold;
    }
    public static class V3Api
    {
        private static readonly HashSet<string> Writes=new HashSet<string>(new[]{"refresh","job-create","check-save","rule-save","incident-action","notification-test","notification-retry","sources-save"},StringComparer.Ordinal);
        public static bool Handles(string action)
        {
            return Writes.Contains(action)||new[]{"whoami","csrf","health","diag","agent","sources","generations","jobs","checks","check-results","rules","incidents","incident-events","notifications","raw-event","parse-errors","audit"}.Contains(action);
        }
        public static object Run(HttpContext ctx,string action)
        {
            if(action=="whoami")
            {
                if(!AccessControl.Authenticated(ctx)&&!(AccessControl.Mode=="local"&&AccessControl.Local(ctx)))
                    ctx.Response.StatusCode=401;
                return AccessControl.IdentityInfo(ctx);
            }
            AccessControl.RequireRead(ctx);
            if(Writes.Contains(action))AccessControl.RequirePost(ctx);
            else if(ctx.Request.HttpMethod!="GET")throw new ApiFailure(405,"get_required","Use GET for this endpoint.");
            if(action=="csrf")return new{token=AccessControl.Token(ctx),security=AccessControl.IdentityInfo(ctx)};
            if(action=="health")return Health(ctx,false);
            if(action=="diag"){AccessControl.RequireEditor(ctx);return Health(ctx,true);}
            using(var c=Store.Open())
            {
                Store.CheckSchema(c);
                if(action=="agent")return Store.Iso(Store.Rows(c,null,"SELECT * FROM ir3.AgentState"));
                if(action=="incidents")return Store.Iso(Store.Rows(c,null,"SELECT TOP(200) * FROM ir3.Incidents ORDER BY CASE WHEN Active=1 THEN 0 ELSE 1 END,OpenedUtc DESC"));
                if(action=="incident-events")return Store.Iso(Store.Rows(c,null,"SELECT TOP(500) * FROM ir3.IncidentEvents WHERE IncidentId=@id ORDER BY AtUtc DESC","@id",GuidArg(ctx,"id")));
                if(action=="checks")return Store.Iso(Store.Rows(c,null,"SELECT * FROM ir3.Checks ORDER BY Name"));
                if(action=="check-results")return Store.Iso(Store.Rows(c,null,"SELECT TOP(200) * FROM ir3.CheckResults WHERE CheckId=@id ORDER BY StartedUtc DESC","@id",GuidArg(ctx,"id")));
                if(action=="rules")return Store.Iso(Store.Rows(c,null,@"SELECT r.*,s.LastValue,s.LastSamples,s.LastEvaluatedUtc,s.LastMessage FROM ir3.AlertRules r LEFT JOIN ir3.AlertState s ON s.RuleId=r.Id ORDER BY r.Name"));
                AccessControl.RequireEditor(ctx); // Operational paths/raw history and every write are operator-only.
                if(action=="sources")return Sources(c);
                if(action=="sources-save")
                {
                    var body=Body<SourcesEdit>(ctx);
                    try { SourceSelection.Save(c,body.changes,AccessControl.Principal(ctx)); }
                    catch(ArgumentException ex){throw new ApiFailure(400,"invalid_sources",ex.Message);}
                    catch(SourceConflictException ex){throw new ApiFailure(409,"revision_conflict",ex.Message);}
                    return new {ok=true,changed=body.changes.Length,message="Monitoring choice saved. Completed imports and historical data are retained."};
                }
                if(action=="generations")return Store.Iso(Store.Rows(c,null,@"SELECT g.*,CASE WHEN g.Id=f.ActiveGenerationId THEN CAST(1 AS bit) ELSE CAST(0 AS bit) END AS IsActive
 FROM ir3.Generations g JOIN ir3.Files f ON f.Id=g.FileId WHERE g.FileId=@id ORDER BY g.Number DESC","@id",LongArg(ctx,"fileId")));
                if(action=="jobs")return Store.Iso(Store.Rows(c,null,"SELECT TOP(100) * FROM ir3.Jobs ORDER BY RequestedUtc DESC"));
                if(action=="notifications")return Store.Iso(Store.Rows(c,null,"SELECT TOP(200) Id,IncidentId,CreatedUtc,Kind,State,Attempts,NextAttemptUtc,SentUtc,LastError,HttpStatus FROM ir3.NotificationOutbox ORDER BY CreatedUtc DESC"));
                if(action=="audit")return Store.Iso(Store.Rows(c,null,"SELECT TOP(200) * FROM ir3.AuditEvents ORDER BY Id DESC"));
                if(action=="raw-event")return Store.Iso(Store.Rows(c,null,@"SELECT r.*,f.FullPath,g.Number AS GenerationNumber FROM ir3.RawEvents r JOIN ir3.Generations g ON g.Id=r.GenerationId JOIN ir3.Files f ON f.Id=g.FileId WHERE r.Id=@id","@id",LongArg(ctx,"id")));
                if(action=="parse-errors")return Store.Iso(Store.Rows(c,null,@"SELECT TOP(200) r.Id,r.GenerationId,r.ByteOffset,r.LineNumber,r.ParseError,r.ImportedUtc,f.FullPath FROM ir3.RawEvents r JOIN ir3.Generations g ON g.Id=r.GenerationId JOIN ir3.Files f ON f.Id=g.FileId WHERE r.ParseError IS NOT NULL ORDER BY r.Id DESC"));
                if(action=="refresh"||action=="job-create")
                {
                    var body=action=="refresh"?new Dictionary<string,object>():Body<Dictionary<string,object>>(ctx);
                    string kind=action=="refresh"?"scan":Value(body,"kind");long file=0;
                    if(!new[]{"scan","verify","replay","new-generation"}.Contains(kind))throw new ApiFailure(400,"invalid_job","Unsupported job type.");
                    if(kind!="scan")
                    {
                        if(!long.TryParse(Value(body,"fileId"),out file)||file<1)throw new ApiFailure(400,"file_required","A registered fileId is required.");
                        if(Store.Long(Store.Scalar(c,null,"SELECT COUNT(*) FROM ir3.Files WHERE Id=@id","@id",file))!=1)throw new ApiFailure(404,"file_not_found","Registered file not found.");
                        if(kind!="verify")
                        {
                            int sourceId=Store.Num(Store.Scalar(c,null,"SELECT SourceId FROM ir3.Files WHERE Id=@id","@id",file));
                            if(!SourceSelection.CanImport(c,null,sourceId,false))throw new ApiFailure(409,"source_disabled","Enable this available source before replay/new-version jobs.");
                        }
                    }
                    Guid id=Guid.NewGuid();
                    using(var tx=c.BeginTransaction())
                    {
                        Store.Exec(c,tx,"INSERT ir3.Jobs(Id,Kind,FileId,RequestedBy) VALUES(@id,@k,@f,@a)","@id",id,"@k",kind,"@f",file>0?(object)file:null,"@a",AccessControl.Principal(ctx));
                        Store.Audit(c,tx,AccessControl.Principal(ctx),"job-create",id.ToString(),kind+" fileId="+file);tx.Commit();
                    }
                    ctx.Response.StatusCode=202;return new{ok=true,queued=true,jobId=id.ToString("D"),message="Queued. The Windows agent must be running."};
                }
                if(action=="check-save")return SaveCheck(c,ctx,Body<CheckEdit>(ctx));
                if(action=="rule-save")return SaveRule(c,ctx,Body<RuleEdit>(ctx));
                if(action=="incident-action")
                {
                    var body=Body<Dictionary<string,object>>(ctx);Guid id=ParseGuid(Value(body,"id"));
                    Incidents.Manual(c,id,Value(body,"action"),AccessControl.Principal(ctx));return new{ok=true};
                }
                if(action=="notification-test")
                {
                    Guid id=Guid.NewGuid();using(var tx=c.BeginTransaction())
                    {
                        Incidents.Enqueue(c,tx,id,null,"test","IIS Reports v3 delivery test requested by "+AccessControl.Principal(ctx));
                        Store.Audit(c,tx,AccessControl.Principal(ctx),"notification-test",id.ToString(),"Queued only; delivery runs in the agent.");tx.Commit();
                    }
                    ctx.Response.StatusCode=202;return new{ok=true,eventId=id.ToString(),message="Test queued. Configure the agent webhook to enable delivery."};
                }
                if(action=="notification-retry")
                {
                    var b=Body<Dictionary<string,object>>(ctx);Guid id=ParseGuid(Value(b,"id"));
                    using(var tx=c.BeginTransaction())
                    {
                        int n=Store.Exec(c,tx,"UPDATE ir3.NotificationOutbox SET State='pending',Attempts=0,NextAttemptUtc=SYSUTCDATETIME() WHERE Id=@id AND State='failed'","@id",id);
                        if(n!=1)throw new ApiFailure(409,"state_changed","Only failed notifications can be retried manually.");
                        Store.Audit(c,tx,AccessControl.Principal(ctx),"notification-retry",id.ToString(),"");tx.Commit();
                    }
                    return new{ok=true};
                }
            }
            throw new ApiFailure(404,"unknown_action","Unknown v3 action.");
        }
        public static object Health(HttpContext ctx,bool detail)
        {
            try
            {
                using(var c=Store.Open())
                {
                    Store.CheckSchema(c);var agents=Store.Rows(c,null,"SELECT * FROM ir3.AgentState WHERE Id=1");
                    long total=Store.Long(Store.Scalar(c,null,"SELECT COUNT_BIG(*) FROM ir3.CurrentRequests"));
                    double? age=agents.Count==0?(double?)null:(DateTime.UtcNow-DateTime.SpecifyKind((DateTime)agents[0]["HeartbeatUtc"],DateTimeKind.Utc)).TotalSeconds;
                    bool online=age.HasValue&&age.Value<120&&Store.Str(agents[0]["State"])!="stopped";
                    long failures=Store.Long(Store.Scalar(c,null,"SELECT COUNT(*) FROM ir3.Sources WHERE Enabled=1 AND (AutoDiscovered=0 OR Available=1) AND LastError IS NOT NULL"));
                    long queued=Store.Long(Store.Scalar(c,null,"SELECT COUNT(*) FROM ir3.Jobs WHERE State IN('queued','running')"));
                    var discovery=Store.Rows(c,null,"SELECT * FROM ir3.DiscoveryState WHERE Id=1");
                    bool discoveryWarning=discovery.Count==0 || Store.Str(discovery[0]["State"])=="error";
                    bool agentWarning=(agents.Count>0&&Store.Str(agents[0]["State"])=="warning")||discoveryWarning;
                    string status=!online?"stale":failures>0||agentWarning?"warn":"ok";
                    // Endpoint is informative JSON; consumers must inspect healthy/status, not HTTP 200 alone.
                    return new {status=status,healthy=online&&failures==0&&!agentWarning,version="3.1.0",dbConnected=true,schemaInitialized=true,
                        databaseError=(string)null,totalEntries=total,dbEntries=total,agentOnline=online,heartbeatAgeSeconds=age,
                        queuedJobs=queued,failedSources=failures,discoveryHealthy=!discoveryWarning,lastParsed=agents.Count==0?null:IsoDate(agents[0]["LastSuccessfulScanUtc"]),
                        errors=failures==0?new string[0]:new[]{"Some sources require attention. Open Sources."},
                        agent=detail?Store.Iso(agents):null,identity=detail?AccessControl.IdentityInfo(ctx):null,
                        storage="ir3.CurrentRequests; legacy dbo tables are retained but not combined",sources=detail?Store.Iso(Store.Rows(c,null,"SELECT * FROM ir3.Sources")):null};
                }
            }
            catch(Exception ex)
            {
                ctx.Response.StatusCode=503;
                return new{status="stale",healthy=false,version="3.1.0",dbConnected=false,schemaInitialized=false,
                    databaseError=detail?ex.Message:"Database/schema unavailable. An operator can inspect action=diag.",security=AccessControl.IdentityInfo(ctx)};
            }
        }
        private static string IsoDate(object v){return v is DateTime?Settings.Utc((DateTime)v):null;}
        private static object Sources(SqlConnection c)
        {
            var rows=Store.Rows(c,null,@"SELECT TOP(2000) f.Id AS fileId,f.FullPath AS path,s.Id AS sourceId,s.Enabled AS monitoring,s.SiteId AS siteId,f.Status AS status,
 f.ObservedSize AS size,g.CommittedOffset AS position,g.Id AS generationId,g.Number AS generation,
 g.LastImportUtc AS lastParsed,g.LastVerifiedUtc AS verifiedUtc,g.VerificationStatus AS verification,
 f.LastError AS error,ISNULL(x.n,0) AS dbRows,ISNULL(x.bad,0) AS parseErrors
 FROM ir3.Files f JOIN ir3.Sources s ON s.Id=f.SourceId JOIN ir3.Generations g ON g.Id=f.ActiveGenerationId
 OUTER APPLY(SELECT COUNT_BIG(*) AS n,SUM(CASE WHEN ParseError IS NOT NULL THEN CONVERT(bigint,1) ELSE 0 END) AS bad FROM ir3.RawEvents WHERE GenerationId=g.Id)x
 ORDER BY f.Id");
            return new {files=Store.Iso(rows),sources=Store.Iso(Store.Rows(c,null,"SELECT * FROM ir3.Sources ORDER BY SiteId,Id")),discovery=Store.Iso(Store.Rows(c,null,"SELECT * FROM ir3.DiscoveryState WHERE Id=1")),
                total=Store.Long(Store.Scalar(c,null,"SELECT COUNT_BIG(*) FROM ir3.Files")),shown=rows.Count,
                integrityScope="Each scan checks first/last committed chunks; Verify hashes ALL committed chunks. New uncommitted bytes are not verified against a previous version."};
        }
        public static T Body<T>(HttpContext ctx) where T:class
        {
            if(!(ctx.Request.ContentType??"").StartsWith("application/json",StringComparison.OrdinalIgnoreCase))throw new ApiFailure(415,"json_required","Use Content-Type: application/json.");
            if(ctx.Request.ContentLength>65536)throw new ApiFailure(413,"body_too_large","JSON body limit is 64 KiB.");
            byte[] buffer=new byte[65537];int n=0,read;
            while(n<buffer.Length&&(read=ctx.Request.InputStream.Read(buffer,n,buffer.Length-n))>0)n+=read;
            if(n>65536)throw new ApiFailure(413,"body_too_large","JSON body limit is 64 KiB.");
            try
            {
                string text=new UTF8Encoding(false,true).GetString(buffer,0,n);
                T data=new JavaScriptSerializer {MaxJsonLength=65536}.Deserialize<T>(text);
                if(data==null)throw new FormatException();return data;
            }
            catch(Exception){throw new ApiFailure(400,"invalid_json","UTF-8 JSON does not match the expected object.");}
        }
        private static string Value(Dictionary<string,object> b,string key){object v;return b!=null&&b.TryGetValue(key,out v)?Store.Str(v):"";}
        private static Guid ParseGuid(string s){Guid id;if(!Guid.TryParse(s,out id)||id==Guid.Empty)throw new ApiFailure(400,"invalid_id","A valid nonempty GUID is required.");return id;}
        private static Guid GuidArg(HttpContext ctx,string name){return ParseGuid(ctx.Request.QueryString[name]);}
        private static long LongArg(HttpContext ctx,string name){long n;if(!long.TryParse(ctx.Request.QueryString[name],out n)||n<1)throw new ApiFailure(400,"invalid_id","A positive numeric id is required.");return n;}
        private static DateTime? Muted(string s)
        {if(string.IsNullOrWhiteSpace(s))return null;DateTime d;if(!DateTime.TryParse(s,CultureInfo.InvariantCulture,DateTimeStyles.AssumeUniversal|DateTimeStyles.AdjustToUniversal,out d))throw new ApiFailure(400,"invalid_time","Use an ISO UTC timestamp.");return d;}
        private static void Range(int n,int min,int max,string key){if(n<min||n>max)throw new ApiFailure(400,"invalid_value",key+" must be in ["+min+","+max+"].");}
        private static string Required(string value,int max,string name)
        {if(string.IsNullOrWhiteSpace(value)||value.Length>max)throw new ApiFailure(400,"invalid_value",name+" is required, maximum "+max+" characters.");return value.Trim();}
        private static object SaveCheck(SqlConnection c,HttpContext ctx,CheckEdit b)
        {
            string name=Required(b.name,128,"name"),url=Required(b.url,2048,"url");
            try{NetworkPolicy.Validate(url,false);}catch(ArgumentException ex){throw new ApiFailure(400,"destination_not_allowed",ex.Message);}
            Range(b.expectedStatus,100,599,"expectedStatus");Range(b.intervalSeconds,10,86400,"intervalSeconds");Range(b.timeoutSeconds,1,30,"timeoutSeconds");
            Range(b.maxLatencyMs,1,30000,"maxLatencyMs");Range(b.failAfter,1,100,"failAfter");Range(b.recoverAfter,1,100,"recoverAfter");
            if((b.containsText??"").Length>256||(b.jsonKey??"").Length>128||(b.jsonValue??"").Length>256)throw new ApiFailure(400,"invalid_value","Content matcher is too long.");
            bool fresh=string.IsNullOrWhiteSpace(b.id);Guid id=fresh?Guid.NewGuid():ParseGuid(b.id);DateTime? mute=Muted(b.mutedUntilUtc);
            using(var tx=c.BeginTransaction())
            {
                object[] args={"@id",id,"@name",name,"@url",url,"@enabled",b.enabled,"@status",b.expectedStatus,"@contains",b.containsText,"@key",b.jsonKey,"@value",b.jsonValue,
                    "@interval",b.intervalSeconds,"@timeout",b.timeoutSeconds,"@latency",b.maxLatencyMs,"@fail",b.failAfter,"@recover",b.recoverAfter,"@mute",mute.HasValue?(object)mute.Value:null,"@rev",b.revision};
                string sql=fresh?@"INSERT ir3.Checks(Id,Name,Url,Enabled,ExpectedStatus,ContainsText,JsonKey,JsonValue,IntervalSeconds,TimeoutSeconds,MaxLatencyMs,FailAfter,RecoverAfter,MutedUntilUtc)
VALUES(@id,@name,@url,@enabled,@status,@contains,@key,@value,@interval,@timeout,@latency,@fail,@recover,@mute)":
@"UPDATE ir3.Checks SET Name=@name,Url=@url,Enabled=@enabled,ExpectedStatus=@status,ContainsText=@contains,JsonKey=@key,JsonValue=@value,
IntervalSeconds=@interval,TimeoutSeconds=@timeout,MaxLatencyMs=@latency,FailAfter=@fail,RecoverAfter=@recover,MutedUntilUtc=@mute,
Revision=Revision+1,BadCount=0,GoodCount=0,NextDueUtc=SYSUTCDATETIME() WHERE Id=@id AND Revision=@rev";
                if(Store.Exec(c,tx,sql,args)!=1)throw new ApiFailure(409,"revision_conflict","Check changed. Reload before saving.");
                Store.Audit(c,tx,AccessControl.Principal(ctx),"check-save",id.ToString(),name);tx.Commit();
            }
            return new{ok=true,id=id.ToString("D")};
        }
        private static object SaveRule(SqlConnection c,HttpContext ctx,RuleEdit b)
        {
            string name=Required(b.name,128,"name");
            if(!new[]{"5xx_count","5xx_percent","p95_ms","auth_failures","requests","import_stale_minutes"}.Contains(b.metric))throw new ApiFailure(400,"invalid_metric","Unknown metric.");
            if(double.IsNaN(b.threshold)||double.IsInfinity(b.threshold)||b.threshold<0||b.threshold>1e12)throw new ApiFailure(400,"invalid_threshold","Threshold is invalid.");
            Range(b.windowMinutes,1,1440,"windowMinutes");Range(b.minSamples,1,1000000000,"minSamples");Range(b.failAfter,1,100,"failAfter");Range(b.recoverAfter,1,100,"recoverAfter");Range(b.siteId,0,int.MaxValue,"siteId");
            bool fresh=string.IsNullOrWhiteSpace(b.id);Guid id=fresh?Guid.NewGuid():ParseGuid(b.id);DateTime? mute=Muted(b.mutedUntilUtc);
            using(var tx=c.BeginTransaction())
            {
                object[] args={"@id",id,"@name",name,"@metric",b.metric,"@enabled",b.enabled,"@site",b.siteId==0?null:(object)b.siteId,"@window",b.windowMinutes,"@threshold",b.threshold,"@samples",b.minSamples,"@fail",b.failAfter,"@recover",b.recoverAfter,"@mute",mute.HasValue?(object)mute.Value:null,"@rev",b.revision};
                string sql=fresh?@"INSERT ir3.AlertRules(Id,Name,Metric,Enabled,SiteId,WindowMinutes,Threshold,MinSamples,FailAfter,RecoverAfter,MutedUntilUtc)
 VALUES(@id,@name,@metric,@enabled,@site,@window,@threshold,@samples,@fail,@recover,@mute)":
@"UPDATE ir3.AlertRules SET Name=@name,Metric=@metric,Enabled=@enabled,SiteId=@site,WindowMinutes=@window,Threshold=@threshold,
MinSamples=@samples,FailAfter=@fail,RecoverAfter=@recover,MutedUntilUtc=@mute,Revision=Revision+1 WHERE Id=@id AND Revision=@rev";
                if(Store.Exec(c,tx,sql,args)!=1)throw new ApiFailure(409,"revision_conflict","Rule changed. Reload before saving.");
                Store.Exec(c,tx,@"IF NOT EXISTS(SELECT 1 FROM ir3.AlertState WHERE RuleId=@id) INSERT ir3.AlertState(RuleId) VALUES(@id);
 UPDATE ir3.AlertState SET BadCount=0,GoodCount=0,NextDueUtc=SYSUTCDATETIME() WHERE RuleId=@id;","@id",id);
                Store.Audit(c,tx,AccessControl.Principal(ctx),"rule-save",id.ToString(),name);tx.Commit();
            }
            return new{ok=true,id=id.ToString("D")};
        }
    }
}
