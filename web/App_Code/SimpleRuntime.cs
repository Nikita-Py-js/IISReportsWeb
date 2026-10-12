// IIS-only runtime. Work is performed inside an explicit HTTP POST, never on a timer
// or a background thread. Each committed batch and its checkpoint are atomic.
using System;
using System.Collections.Generic;
using System.Data;
using System.Data.SqlClient;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text.RegularExpressions;
using System.Threading;
using System.Web;
using IISReports.V3;
namespace IISReports
{
    public static class SimpleRuntime
    {
        private static readonly object Gate=new object();
        private static string[] lastDiscoveryErrors=new string[0];
        public static string[] DiscoveryErrors {get{return lastDiscoveryErrors;}}
        public static string[] LogRoots
        {
            get{return Settings.Get("LogRoots",@"C:\inetpub\logs\LogFiles").Split(new[]{';'},StringSplitOptions.RemoveEmptyEntries)
                .Select(x=>Environment.ExpandEnvironmentVariables(x.Trim())).Distinct(StringComparer.OrdinalIgnoreCase).ToArray();}
        }
        public static string Canonical(string path){return Path.GetFullPath(path).TrimEnd(Path.DirectorySeparatorChar,Path.AltDirectorySeparatorChar);}
        public static int SiteId(string path)
        {int id;var m=Regex.Match(Path.GetFileName(path.TrimEnd('\\','/'))??"",@"^W3SVC(\d+)$",RegexOptions.IgnoreCase);return m.Success&&int.TryParse(m.Groups[1].Value,out id)?id:0;}
        public static void Discover(SqlConnection c)
        {
            SiteNames.LoadIfChanged();
            var errors=new List<string>();var found=new Dictionary<string,int>(StringComparer.OrdinalIgnoreCase);
            foreach(string root in LogRoots)
            {
                try
                {
                    string full=Canonical(root);int id=SiteId(full);
                    // Enumerate rather than Exists, to retain a useful access-denied diagnostic.
                    if(id>0){Directory.GetFiles(full,"*.log");found[full]=id;}
                    else foreach(string p in Directory.GetDirectories(full,"W3SVC*",SearchOption.TopDirectoryOnly))
                    {int n=SiteId(p);if(n>0 && (File.GetAttributes(p)&FileAttributes.ReparsePoint)==0)found[Canonical(p)]=n;}
                }
                catch(Exception ex){errors.Add(root+": "+ex.Message);}
            }
            using(var tx=c.BeginTransaction(IsolationLevel.Serializable))
            {
                foreach(var item in found)
                {
                    var existing=Store.Rows(c,tx,"SELECT Id FROM ir3.Sources WITH(UPDLOCK,HOLDLOCK) WHERE SiteId=@id AND UPPER(REPLACE(RootPath,'/','\\'))=@p",
                        "@id",item.Value,"@p",item.Key.ToUpperInvariant());
                    if(existing.Count==0)
                    {
                        Store.Exec(c,tx,@"INSERT ir3.Sources(Name,SiteId,RootPath,Enabled,AutoDiscovered,Available,DiscoveryStatus,LastDiscoveredUtc)
 VALUES(@n,@id,@p,1,0,1,'ready',SYSUTCDATETIME());","@n",Settings.Clip(SiteNames.Get(item.Value),128),"@id",item.Value,"@p",item.Key);
                    }
                }
                tx.Commit();
            }
            // Existing custom source roots and disabled sources remain registered.
            // Discovery NEVER changes the operator's Enabled selection or deletes history.
            foreach(var row in Store.Rows(c,null,"SELECT Id,RootPath,SiteId FROM ir3.Sources"))
            {
                string path=Store.Str(row["RootPath"]);bool available=false;string message=null;
                try {using(var e=Directory.EnumerateFileSystemEntries(path).GetEnumerator()){e.MoveNext();}available=true;}
                catch(Exception ex){message=ex.Message;}
                Store.Exec(c,null,@"UPDATE ir3.Sources SET Available=@a,AutoDiscovered=1,DiscoveryStatus=@s,
 DiscoveryMessage=@e,LastDiscoveredUtc=SYSUTCDATETIME() WHERE Id=@id", "@a",available,
                    "@s",available?"ready":"path_or_acl_error","@e",Settings.Clip(message,1024),"@id",Store.Num(row["Id"]));
            }
            lastDiscoveryErrors=errors.ToArray();
        }
        private static SqlConnection WorkConnection()
        {
            var b=new SqlConnectionStringBuilder(Settings.ConnectionString);b.Pooling=false;
            var c=new SqlConnection(b.ConnectionString);
            try
            {
                c.Open();Store.CheckSchema(c);
                // Same lock as v3's old agent: running old and new importers together is not allowed.
                long got=Store.Long(Store.Scalar(c,null,@"DECLARE @r int; EXEC @r=sys.sp_getapplock @Resource=N'IISReports.v3.agent',
 @LockMode='Exclusive',@LockOwner='Session',@LockTimeout=0;SELECT @r;"));
                if(got<0)throw new ApiFailure(409,"import_busy","Import is already running. If an old IISReportsAgentV3 service is running, stop it before using Simple.");
                return c;
            }
            catch{c.Dispose();throw;}
        }
        public static object Refresh()
        {
            if(!Monitor.TryEnter(Gate))return new{ok=true,busy=true,message="Another refresh is running."};
            try
            {
                using(var c=WorkConnection())
                {
                    Discover(c);var watch=Stopwatch.StartNew();int files=0;long rows=0;var errors=new List<string>(DiscoveryErrors);
                    Guid run=Guid.NewGuid();
                    Store.Exec(c,null,"INSERT ir3.ImportRuns(Id,StartedUtc,Kind,Status) VALUES(@id,SYSUTCDATETIME(),'web','running')","@id",run);
                    try
                    {
                        var engine=new ImportEngine(c,null);
                        // Read directory metadata first. This is not an IIS config snapshot and has no expiry.
                        foreach(var s in Store.Rows(c,null,"SELECT Id,RootPath FROM ir3.Sources WHERE Enabled=1 AND Available=1 ORDER BY Id"))
                        {
                            int sid=Store.Num(s["Id"]);string root=Store.Str(s["RootPath"]);DateTime began=DateTime.UtcNow;
                            try
                            {
                                foreach(string p in ImportEngine.Enumerate(root))engine.Register(sid,p);
                                Store.Exec(c,null,@"UPDATE ir3.Files SET Status='missing',LastError='File is missing; imported history retained.'
 WHERE SourceId=@id AND LastSeenUtc<@t;UPDATE ir3.Sources SET LastScanUtc=SYSUTCDATETIME(),LastError=NULL WHERE Id=@id;","@id",sid,"@t",began);
                            }
                            catch(Exception ex)
                            {
                                errors.Add(root+": "+ex.Message);Store.Exec(c,null,"UPDATE ir3.Sources SET LastError=@e WHERE Id=@id","@e",Settings.Clip(ex.Message,1024),"@id",sid);
                            }
                        }
                        int limit=Settings.Int("ImportBatchesPerRequest",12,1,200);
                        // LastVerifiedUtc here is the time of the most recent first/last-block check.
                        // Ordering ensures a large file or a failing file cannot starve other sources.
                        var candidates=Store.Rows(c,null,@"SELECT TOP(@max) f.Id FROM ir3.Files f JOIN ir3.Generations g ON g.Id=f.ActiveGenerationId
 JOIN ir3.Sources s ON s.Id=f.SourceId WHERE s.Enabled=1 AND s.Available=1
 AND f.Status NOT IN ('changed','missing') AND (f.ObservedSize>g.CommittedOffset OR f.Status IN ('new','pending','error'))
 ORDER BY ISNULL(g.LastVerifiedUtc,CONVERT(datetime2,'19000101')),f.Id;","@max",limit);
                        foreach(var f in candidates)
                        {
                            if(files>0 && watch.Elapsed.TotalSeconds>=Settings.Int("ImportSecondsPerRequest",12,2,60))break;
                            long id=Store.Long(f["Id"]);
                            try {rows+=engine.ImportFile(id,false,0);}
                            catch(SourcePausedException){}
                            catch(Exception ex)
                            {
                                errors.Add("File #"+id+": "+ex.Message);
                                Store.Exec(c,null,"UPDATE ir3.Files SET Status=@s,LastError=@e WHERE Id=@id","@s",ex is InvalidDataException?"changed":"error","@e",Settings.Clip(ex.Message,1024),"@id",id);
                            }
                            finally{Store.Exec(c,null,"UPDATE g SET LastVerifiedUtc=SYSUTCDATETIME() FROM ir3.Generations g JOIN ir3.Files f ON f.ActiveGenerationId=g.Id WHERE f.Id=@id","@id",id);}
                            files++;
                        }
                        // Rules operate on ingested data only. No outgoing HTTP during normal refresh.
                        if(Settings.Get("EvaluateRules","true")=="true")
                            try{new MonitorEngine(c,null).EvaluateRules();}catch(Exception ex){errors.Add("Rules: "+ex.Message);}
                        Store.Exec(c,null,"UPDATE ir3.ImportRuns SET FinishedUtc=SYSUTCDATETIME(),Status=@s,RowsProcessed=@n,Detail=@d WHERE Id=@id",
                            "@s",errors.Count==0?"ok":"warning","@n",rows,"@d",Settings.Clip(string.Join("\n",errors),2048),"@id",run);
                        long pending=Store.Long(Store.Scalar(c,null,@"SELECT COUNT_BIG(*) FROM ir3.Files f JOIN ir3.Generations g ON g.Id=f.ActiveGenerationId
 JOIN ir3.Sources s ON s.Id=f.SourceId WHERE s.Enabled=1 AND s.Available=1 AND f.Status IN ('new','pending') AND f.ObservedSize>g.CommittedOffset"));
                        return new{ok=true,busy=false,rowsProcessed=rows,filesProcessed=files,pendingFiles=pending,
                            elapsedSeconds=Math.Round(watch.Elapsed.TotalSeconds,1),errors=errors.ToArray(),lastParsed=Store.LastImport(),mode="web-request"};
                    }
                    catch(Exception ex)
                    {Store.Exec(c,null,"UPDATE ir3.ImportRuns SET Status='failed',FinishedUtc=SYSUTCDATETIME(),Detail=@e WHERE Id=@id","@id",run,"@e",Settings.Clip(ex.Message,2048));throw;}
                }
            }
            finally{Monitor.Exit(Gate);}
        }
        public static object RunMonitoring()
        {
            using(var c=WorkConnection())
            {var monitor=new MonitorEngine(c,null);monitor.RunChecks();monitor.EvaluateRules();monitor.Deliver();return new{ok=true,message="One monitoring pass finished. No background worker was started."};}
        }
        public static object FileAction(long id,string action)
        {
            using(var c=WorkConnection())
            {
                var engine=new ImportEngine(c,null);
                if(action=="verify")engine.Verify(id);
                else throw new ApiFailure(400,"unsupported_action","Simple supports verification only. File replacement/replay is a separate maintenance operation; history was not changed.");
                return new{ok=true};
            }
        }
        public static object Health(HttpContext ctx,bool detail)
        {
            using(var c=Store.Open())
            {
                Store.CheckSchema(c);var last=Store.Rows(c,null,"SELECT TOP(1) StartedUtc,FinishedUtc,Status,RowsProcessed,Detail FROM ir3.ImportRuns WHERE Kind='web' ORDER BY StartedUtc DESC");
                long count=Store.Long(Store.Scalar(c,null,"SELECT COUNT_BIG(*) FROM ir3.CurrentRequests"));
                long bad=Store.Long(Store.Scalar(c,null,"SELECT COUNT_BIG(*) FROM ir3.Files f JOIN ir3.Sources s ON s.Id=f.SourceId WHERE s.Enabled=1 AND f.Status IN ('error','changed')"));
                long unavailable=Store.Long(Store.Scalar(c,null,"SELECT COUNT_BIG(*) FROM ir3.Sources WHERE Enabled=1 AND Available=0"));
                bool healthy=bad==0&&unavailable==0&&DiscoveryErrors.Length==0;
                return new{status=healthy?"ok":"warn",healthy=healthy,mode="web-request",version="3.2.0-simple",dbConnected=true,schemaInitialized=true,
                    totalEntries=count,dbEntries=count,lastParsed=Store.LastImport(),failedFiles=bad,unavailableSources=unavailable,errors=DiscoveryErrors,
                    lastRefresh=Store.Iso(last),logRoots=detail?LogRoots:null,identity=detail?AccessControl.IdentityInfo(ctx):null,
                    note="No background collection. Refresh imports data; existing history remains readable."};
            }
        }
    }
}
