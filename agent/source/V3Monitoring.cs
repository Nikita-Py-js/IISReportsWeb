using System;
using System.Collections.Generic;
using System.Data;
using System.Data.SqlClient;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Net;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;

namespace IISReports.V3
{
    public static class NetworkPolicy
    {
        public static Uri Validate(string value,bool webhook)
        {
            Uri uri;
            if(!Uri.TryCreate(value,UriKind.Absolute,out uri)||!string.IsNullOrEmpty(uri.UserInfo)||!string.IsNullOrEmpty(uri.Fragment))
                throw new ArgumentException("Use an absolute URL without credentials or fragment.");
            bool httpAllowed=!webhook && Settings.Get("IISReportsAllowHttpChecks","false")=="true";
            if(uri.Scheme!="https" && !(httpAllowed&&uri.Scheme=="http"))throw new ArgumentException("HTTPS is required (HTTP checks require an explicit server setting).");
            string host=uri.IdnHost.TrimEnd('.').ToLowerInvariant();
            string key=webhook?"IISReportsWebhookHosts":"IISReportsCheckHosts";
            var allowed=Settings.Get(key,"").Split(new[]{',',';'},StringSplitOptions.RemoveEmptyEntries).Select(x=>x.Trim().TrimEnd('.').ToLowerInvariant());
            if(!allowed.Contains(host))throw new ArgumentException("Destination host is not present in "+key+".");
            var ports=Settings.Get(webhook?"IISReportsWebhookPorts":"IISReportsCheckPorts",webhook?"443":"80,443").Split(',');
            if(!ports.Any(x=>x.Trim()==uri.Port.ToString(CultureInfo.InvariantCulture)))throw new ArgumentException("Destination port is not allowed.");
            return uri;
        }
        public static HttpWebRequest Request(Uri uri,int timeout)
        {
            var request=(HttpWebRequest)WebRequest.Create(uri);
            request.AllowAutoRedirect=false;request.Proxy=null;request.UseDefaultCredentials=false;request.Credentials=null;
            request.Timeout=timeout*1000;request.ReadWriteTimeout=timeout*1000;request.UserAgent="IISReports/3.0";
            request.AutomaticDecompression=DecompressionMethods.GZip|DecompressionMethods.Deflate;
            return request;
        }
    }
    public sealed class ProbeResult
    { public DateTime StartedUtc,FinishedUtc;public bool Success;public int? HttpStatus;public long ElapsedMs;public string Detail; }
    public static class Probes
    {
        public static ProbeResult Run(Dictionary<string,object> check)
        {
            var result=new ProbeResult { StartedUtc=DateTime.UtcNow,Detail="" };
            var watch=Stopwatch.StartNew();HttpWebRequest request=null;
            try
            {
                var uri=NetworkPolicy.Validate(Store.Str(check["Url"]),false);
                int seconds=Store.Num(check["TimeoutSeconds"]);request=NetworkPolicy.Request(uri,seconds);
                using(var timer=new Timer(delegate { try { request.Abort(); } catch { } },null,seconds*1000,Timeout.Infinite))
                {
                    HttpWebResponse response;
                    try { response=(HttpWebResponse)request.GetResponse(); }
                    catch(WebException e) { response=e.Response as HttpWebResponse; if(response==null)throw; }
                    using(response)
                    {
                        result.HttpStatus=(int)response.StatusCode;
                        string body;
                        using(var stream=response.GetResponseStream())using(var data=new MemoryStream())
                        {
                            byte[] buffer=new byte[8192];int count;
                            while((count=stream.Read(buffer,0,buffer.Length))>0)
                            { if(data.Length+count>256*1024)throw new InvalidDataException("Response exceeds the 256 KiB check limit.");data.Write(buffer,0,count); }
                            body=Encoding.UTF8.GetString(data.ToArray());
                        }
                        bool content=string.IsNullOrEmpty(Store.Str(check["ContainsText"]))||body.Contains(Store.Str(check["ContainsText"]));
                        if(!string.IsNullOrWhiteSpace(Store.Str(check["JsonKey"])))
                        {
                            var json=new JavaScriptSerializer {MaxJsonLength=256*1024}.DeserializeObject(body) as Dictionary<string,object>;
                            object value;content=content&&json!=null&&json.TryGetValue(Store.Str(check["JsonKey"]),out value)&&
                                string.Equals(Store.Str(value),Store.Str(check["JsonValue"]),StringComparison.Ordinal);
                        }
                        result.Success=result.HttpStatus==Store.Num(check["ExpectedStatus"])&&content&&watch.ElapsedMilliseconds<=Store.Num(check["MaxLatencyMs"]);
                        result.Detail=result.Success?"Expected status, content and latency matched.":"Status, content or latency did not match.";
                    }
                }
            }
            catch(WebException ex){result.Detail="Network failure: "+ex.Status;}
            catch(Exception ex){result.Detail=Settings.Clip(ex is ArgumentException||ex is InvalidDataException?ex.Message:"Probe failed: "+ex.GetType().Name,512);}
            watch.Stop();result.ElapsedMs=watch.ElapsedMilliseconds;result.FinishedUtc=DateTime.UtcNow;return result;
        }
    }

    public static class Incidents
    {
        // State + event + outbox are committed together by the caller's transaction.
        public static void Observe(SqlConnection c,SqlTransaction tx,string key,string title,string detail,bool breached)
        {
            var current=Store.Rows(c,tx,"SELECT TOP(1) * FROM ir3.Incidents WITH(UPDLOCK,HOLDLOCK) WHERE EntityKey=@k AND Active=1","@k",key);
            DateTime now=DateTime.UtcNow;
            if(breached)
            {
                if(current.Count>0)
                { Store.Exec(c,tx,"UPDATE ir3.Incidents SET UpdatedUtc=@t,Detail=@d WHERE Id=@id","@t",now,"@d",Settings.Clip(detail,2048),"@id",(Guid)current[0]["Id"]);return; }
                Guid id=Guid.NewGuid();Store.Exec(c,tx,@"INSERT ir3.Incidents(Id,EntityKey,Title,State,Active,OpenedUtc,UpdatedUtc,Detail)
 VALUES(@id,@key,@title,'open',1,@now,@now,@d)","@id",id,"@key",key,"@title",Settings.Clip(title,256),"@now",now,"@d",Settings.Clip(detail,2048));
                Event(c,tx,id,"opened","agent",title+": "+detail,true);
            }
            else if(current.Count>0)
            {
                Guid id=(Guid)current[0]["Id"];Store.Exec(c,tx,"UPDATE ir3.Incidents SET State='resolved',Active=0,ResolvedUtc=@t,UpdatedUtc=@t,Detail=@d WHERE Id=@id","@t",now,"@d",Settings.Clip(detail,2048),"@id",id);
                Event(c,tx,id,"resolved","agent",title+": "+detail,true);
            }
        }
        public static void Event(SqlConnection c,SqlTransaction tx,Guid incidentId,string kind,string actor,string detail,bool notify)
        {
            Guid id=Guid.NewGuid();DateTime now=DateTime.UtcNow;
            Store.Exec(c,tx,"INSERT ir3.IncidentEvents(Id,IncidentId,AtUtc,Kind,Actor,Detail) VALUES(@id,@inc,@t,@kind,@a,@d)",
                "@id",id,"@inc",incidentId,"@t",now,"@kind",kind,"@a",Settings.Clip(actor,256),"@d",Settings.Clip(detail,2048));
            if(notify)Enqueue(c,tx,id,incidentId,kind,detail);
        }
        public static void Enqueue(SqlConnection c,SqlTransaction tx,Guid id,Guid? incidentId,string kind,string detail)
        {
            var payload=new {eventId=id.ToString("D"),incidentId=incidentId.HasValue?incidentId.Value.ToString("D"):null,kind=kind,atUtc=Settings.Utc(DateTime.UtcNow),message=Settings.Clip(detail,2048)};
            Store.Exec(c,tx,"INSERT ir3.NotificationOutbox(Id,IncidentId,CreatedUtc,Kind,Payload) VALUES(@id,@inc,@t,@k,@p)",
                "@id",id,"@inc",incidentId.HasValue?(object)incidentId.Value:null,"@t",DateTime.UtcNow,"@k",kind,"@p",Settings.Json(payload));
        }
        public static void Manual(SqlConnection c,Guid id,string action,string actor)
        {
            using(var tx=c.BeginTransaction())
            {
                int n;
                if(action=="ack")n=Store.Exec(c,tx,"UPDATE ir3.Incidents SET State='acknowledged',AcknowledgedBy=@a,UpdatedUtc=@t WHERE Id=@id AND State='open'","@a",actor,"@t",DateTime.UtcNow,"@id",id);
                else if(action=="close")n=Store.Exec(c,tx,"UPDATE ir3.Incidents SET State='closed',UpdatedUtc=@t WHERE Id=@id AND State='resolved'","@t",DateTime.UtcNow,"@id",id);
                else if(action=="cancel")n=Store.Exec(c,tx,"UPDATE ir3.Incidents SET State='closed',Active=0,UpdatedUtc=@t,Detail='Closed manually; recovery was not verified.' WHERE Id=@id AND Active=1","@t",DateTime.UtcNow,"@id",id);
                else throw new ArgumentException("Supported incident actions: ack, close, cancel.");
                if(n!=1)throw new InvalidOperationException("Incident state changed or the requested transition is not allowed.");
                Event(c,tx,id,action,actor,"Operator transition",false);Store.Audit(c,tx,actor,"incident-"+action,id.ToString(),"");tx.Commit();
            }
        }
    }

    public sealed class MonitorEngine
    {
        private readonly SqlConnection c;private readonly Action beat;
        public MonitorEngine(SqlConnection connection,Action heartbeat){c=connection;beat=heartbeat;}
        private void Beat(){if(beat!=null)beat();}
        public void RunChecks()
        {
            var checks=Store.Rows(c,null,"SELECT TOP(10) * FROM ir3.Checks WHERE Enabled=1 AND NextDueUtc<=SYSUTCDATETIME() ORDER BY NextDueUtc");
            foreach(var check in checks)
            {
                Beat();var result=Probes.Run(check);Guid id=(Guid)check["Id"];
                using(var tx=c.BeginTransaction())
                {
                    Store.Exec(c,tx,@"INSERT ir3.CheckResults(CheckId,StartedUtc,FinishedUtc,Success,HttpStatus,ElapsedMs,Detail)
 VALUES(@id,@start,@end,@ok,@http,@ms,@d)","@id",id,"@start",result.StartedUtc,"@end",result.FinishedUtc,"@ok",result.Success,"@http",result.HttpStatus.HasValue?(object)result.HttpStatus.Value:null,"@ms",result.ElapsedMs,"@d",result.Detail);
                    // An edit while the HTTP request was in flight invalidates its state transition.
                    var nowRows=Store.Rows(c,tx,"SELECT * FROM ir3.Checks WITH(UPDLOCK) WHERE Id=@id","@id",id);var current=nowRows[0];
                    if(Store.Num(current["Revision"])!=Store.Num(check["Revision"])||!Store.Bool(current["Enabled"])) {tx.Commit();continue;}
                    int good=result.Success?Math.Min(10000,Store.Num(current["GoodCount"])+1):0;
                    int bad=result.Success?0:Math.Min(10000,Store.Num(current["BadCount"])+1);
                    Store.Exec(c,tx,@"UPDATE ir3.Checks SET BadCount=@b,GoodCount=@g,LastCheckUtc=@now,LastSuccess=@ok,
LastMessage=@d,NextDueUtc=DATEADD(SECOND,IntervalSeconds,@now) WHERE Id=@id",
                        "@b",bad,"@g",good,"@now",result.FinishedUtc,"@ok",result.Success,"@d",result.Detail,"@id",id);
                    bool muted=current["MutedUntilUtc"]!=null&&(DateTime)current["MutedUntilUtc"]>DateTime.UtcNow;
                    if(!muted && (bad>=Store.Num(current["FailAfter"])||good>=Store.Num(current["RecoverAfter"])))
                        Incidents.Observe(c,tx,"check:"+id.ToString("D"),Store.Str(current["Name"]),result.Detail+" HTTP="+(result.HttpStatus.HasValue?result.HttpStatus.Value.ToString():"none")+" ms="+result.ElapsedMs,bad>0);
                    tx.Commit();
                }
            }
        }
        public void EvaluateRules()
        {
            Store.Exec(c,null,"INSERT ir3.AlertState(RuleId) SELECT r.Id FROM ir3.AlertRules r WHERE NOT EXISTS(SELECT 1 FROM ir3.AlertState s WHERE s.RuleId=r.Id)");
            var rules=Store.Rows(c,null,@"SELECT r.*,s.BadCount,s.GoodCount FROM ir3.AlertRules r JOIN ir3.AlertState s ON s.RuleId=r.Id
 WHERE r.Enabled=1 AND s.NextDueUtc<=SYSUTCDATETIME() ORDER BY s.NextDueUtc");
            foreach(var rule in rules)
            {
                Beat();Guid id=(Guid)rule["Id"];double value=0;long samples=0;string metric=Store.Str(rule["Metric"]);
                DateTime now=DateTime.UtcNow;
                DateTime end=new DateTime(now.Year,now.Month,now.Day,now.Hour,now.Minute,0,DateTimeKind.Utc);
                DateTime start=end.AddMinutes(-Store.Num(rule["WindowMinutes"]));
                if(metric=="import_stale_minutes")
                {
                    object last=Store.Scalar(c,null,"SELECT LastSuccessfulScanUtc FROM ir3.AgentState WHERE Id=1");
                    value=last==null?1000000:Math.Max(0,(now-DateTime.SpecifyKind((DateTime)last,DateTimeKind.Utc)).TotalMinutes);samples=1;
                }
                else
                {
                    string site=rule["SiteId"]==null?"":" AND SiteId=@site";
                    string expression=metric=="5xx_count"||metric=="5xx_percent"?"SUM(CASE WHEN Status BETWEEN 500 AND 599 THEN CONVERT(bigint,1) ELSE 0 END)":
                        metric=="auth_failures"?"SUM(CASE WHEN Status IN(401,403) THEN CONVERT(bigint,1) ELSE 0 END)":"COUNT_BIG(*)";
                    var data=Store.Rows(c,null,"SELECT COUNT_BIG(*) AS N,"+expression+" AS V FROM ir3.CurrentRequests WHERE Ts>=@start AND Ts<@end"+site,
                        "@start",start,"@end",end,"@site",rule["SiteId"]);
                    samples=Store.Long(data[0]["N"]);value=Store.Long(data[0]["V"]);
                    if(metric=="5xx_percent")value=samples==0?0:100.0*value/samples;
                    if(metric=="p95_ms"&&samples>0)
                    {
                        object v=Store.Scalar(c,null,@"SELECT TOP(1) PERCENTILE_CONT(0.95) WITHIN GROUP(ORDER BY TimeMs) OVER()
 FROM ir3.CurrentRequests WHERE Ts>=@start AND Ts<@end"+site,"@start",start,"@end",end,"@site",rule["SiteId"]);
                        value=Convert.ToDouble(v,CultureInfo.InvariantCulture);
                    }
                }
                bool enough=samples>=Store.Num(rule["MinSamples"]);bool breached=value>Convert.ToDouble(rule["Threshold"],CultureInfo.InvariantCulture);
                string detail=metric+"="+value.ToString("0.###",CultureInfo.InvariantCulture)+"; samples="+samples+"; window=["+Settings.Utc(start)+","+Settings.Utc(end)+")";
                using(var tx=c.BeginTransaction())
                {
                    var current=Store.Rows(c,tx,"SELECT * FROM ir3.AlertRules WITH(UPDLOCK) WHERE Id=@id","@id",id)[0];
                    if(Store.Num(current["Revision"])!=Store.Num(rule["Revision"])||!Store.Bool(current["Enabled"])) {tx.Commit();continue;}
                    int bad=enough&&breached?Math.Min(10000,Store.Num(rule["BadCount"])+1):0;
                    int good=enough&&!breached?Math.Min(10000,Store.Num(rule["GoodCount"])+1):0;
                    Store.Exec(c,tx,@"UPDATE ir3.AlertState SET BadCount=@b,GoodCount=@g,LastValue=@v,LastSamples=@n,
LastEvaluatedUtc=@t,LastMessage=@d,NextDueUtc=DATEADD(MINUTE,1,@end) WHERE RuleId=@id",
                        "@b",bad,"@g",good,"@v",value,"@n",samples,"@t",now,"@d",enough?detail:"Insufficient samples; existing incident is not resolved.","@end",end,"@id",id);
                    bool muted=current["MutedUntilUtc"]!=null&&(DateTime)current["MutedUntilUtc"]>now;
                    if(!muted&&enough&&(bad>=Store.Num(current["FailAfter"])||good>=Store.Num(current["RecoverAfter"])))
                        Incidents.Observe(c,tx,"rule:"+id.ToString("D"),Store.Str(current["Name"]),detail,breached);
                    tx.Commit();
                }
            }
        }
        public void Deliver()
        {
            string url=Settings.Get("IISReportsWebhookUrl","");
            if(url.Length==0)return; // Queue remains durable; nothing is reported as sent.
            Uri uri;
            try {uri=NetworkPolicy.Validate(url,true);}
            catch(ArgumentException)
            {
                Store.Exec(c,null,"UPDATE ir3.AgentState SET State='warning',LastError='Webhook destination is not allowed by agent network policy.' WHERE Id=1;");
                return;
            }
            foreach(var row in Store.Rows(c,null,"SELECT TOP(10) * FROM ir3.NotificationOutbox WHERE State='pending' AND NextAttemptUtc<=SYSUTCDATETIME() ORDER BY CreatedUtc"))
            {
                Beat();Guid id=(Guid)row["Id"];int attempts=Store.Num(row["Attempts"])+1;int? status=null;string error=null;
                Store.Exec(c,null,"UPDATE ir3.NotificationOutbox SET State='sending',Attempts=@n WHERE Id=@id","@n",attempts,"@id",id);
                try
                {
                    var req=NetworkPolicy.Request(uri,15);req.Method="POST";req.ContentType="application/json; charset=utf-8";
                    req.Headers["X-IISReports-EventId"]=id.ToString("D");
                    byte[] payload=Encoding.UTF8.GetBytes(Store.Str(row["Payload"]));req.ContentLength=payload.Length;
                    using(var timer=new Timer(delegate{try{req.Abort();}catch{}},null,15000,Timeout.Infinite))
                    {
                        using(var output=req.GetRequestStream())output.Write(payload,0,payload.Length);
                        using(var response=(HttpWebResponse)req.GetResponse())status=(int)response.StatusCode;
                    }
                    if(!status.HasValue||status.Value<200||status.Value>=300)error="Non-success HTTP response.";
                }
                catch(WebException ex)
                {
                    using(var response=ex.Response as HttpWebResponse)if(response!=null)status=(int)response.StatusCode;
                    error="Delivery transport: "+ex.Status; // Do not log a secret URL or response body.
                }
                catch(Exception ex){error="Delivery failure: "+ex.GetType().Name;}
                if(error==null)
                    Store.Exec(c,null,"UPDATE ir3.NotificationOutbox SET State='sent',SentUtc=@t,LastError=NULL,HttpStatus=@s WHERE Id=@id","@t",DateTime.UtcNow,"@s",status.HasValue?(object)status.Value:null,"@id",id);
                else
                {
                    int delay=Math.Min(3600,10*(1<<Math.Min(attempts,8)));
                    Store.Exec(c,null,"UPDATE ir3.NotificationOutbox SET State=@state,LastError=@e,HttpStatus=@s,NextAttemptUtc=DATEADD(SECOND,@delay,SYSUTCDATETIME()) WHERE Id=@id",
                        "@state",attempts>=8?"failed":"pending","@e",error,"@s",status.HasValue?(object)status.Value:null,"@delay",delay,"@id",id);
                }
            }
        }
    }
}
