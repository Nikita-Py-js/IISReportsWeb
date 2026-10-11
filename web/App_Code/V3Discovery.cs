// Discovery inventory contains no credentials. Only the elevated local publisher writes it.
// C# 5, .NET Framework. Shared by the web application and Windows agent.
using System;
using System.Collections.Generic;
using System.Data;
using System.Data.SqlClient;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;
using System.Web.Script.Serialization;

namespace IISReports.V3
{
    public sealed class InventorySite
    {
        public int siteId;
        public string name, rootPath, status, message;
        public bool available;
    }
    public sealed class InventorySnapshot
    {
        public int version;
        public string machineName, generatedUtc, error;
        public bool success;
        public InventorySite[] sites;
    }
    public sealed class SourceChange
    {
        public int id, revision;
        public bool? enabled;
    }
    public sealed class SourcesEdit { public SourceChange[] changes; }
    public sealed class SourceConflictException : Exception
    { public SourceConflictException() : base("Source settings changed in another session. Reload and try again.") { } }
    public sealed class SourcePausedException : Exception
    { public SourcePausedException() : base("Source monitoring is disabled or its log directory is unavailable. History and checkpoints are retained.") { } }

    public static class SourceSelection
    {
        public static SourceChange[] Validate(SourceChange[] changes)
        {
            if(changes==null || changes.Length==0 || changes.Length>1000)
                throw new ArgumentException("Provide between 1 and 1000 source changes.");
            var ids=new HashSet<int>();
            foreach(var x in changes)
                if(x==null || x.id<1 || x.revision<1 || !x.enabled.HasValue || !ids.Add(x.id))
                    throw new ArgumentException("Each source needs a unique positive id, revision and an explicit boolean enabled.");
            return changes.OrderBy(x=>x.id).ToArray();
        }
        public static void Save(SqlConnection c,SourceChange[] changes,string actor)
        {
            var ordered=Validate(changes);
            using(var tx=c.BeginTransaction())
            {
                foreach(var x in ordered)
                {
                    int n=Store.Exec(c,tx,@"UPDATE ir3.Sources SET Enabled=@on,Revision=Revision+1
 WHERE Id=@id AND Revision=@revision;","@on",x.enabled.Value,"@id",x.id,"@revision",x.revision);
                    if(n!=1)throw new SourceConflictException();
                    Store.Audit(c,tx,actor,"source-monitoring",x.id.ToString(CultureInfo.InvariantCulture),x.enabled.Value?"enabled":"disabled");
                }
                tx.Commit();
            }
        }
        public static bool CanImport(SqlConnection c,SqlTransaction tx,int sourceId,bool lockRow)
        {
            string hint=lockRow?" WITH(UPDLOCK,HOLDLOCK)":"";
            object result=Store.Scalar(c,tx,"SELECT CASE WHEN Enabled=1 AND (AutoDiscovered=0 OR Available=1) THEN 1 ELSE 0 END FROM ir3.Sources"+hint+" WHERE Id=@id","@id",sourceId);
            return Store.Long(result)==1;
        }
        public static void RequireImport(SqlConnection c,SqlTransaction tx,int sourceId,bool lockRow)
        {if(!CanImport(c,tx,sourceId,lockRow))throw new SourcePausedException();}
    }

    public sealed class SourceDiscovery
    {
        private readonly SqlConnection connection;
        private string appliedHash;
        public SourceDiscovery(SqlConnection c) {connection=c;}
        public static bool Enabled {get{return string.Equals(Settings.Get("IISReportsAutoDiscoveryEnabled","true"),"true",StringComparison.OrdinalIgnoreCase);}}
        public static string ManifestPath {get{return Environment.ExpandEnvironmentVariables(Settings.Get("IISReportsDiscoveryManifest",@"%ProgramData%\IISReports\Discovery\sites.json"));}}
        public static string CanonicalRoot(string path)
        {
            // Local drive paths and UNC paths can be represented; only local supported paths are importable.
            if(string.IsNullOrWhiteSpace(path)||path.Length>1024)throw new ArgumentException("Invalid inventory log path.");
            string p=path.Trim().Replace('/','\\').TrimEnd('\\');
            if(!(p.Length>=3&&char.IsLetter(p[0])&&p[1]==':'&&p[2]=='\\')&&!p.StartsWith(@"\\",StringComparison.Ordinal))
                throw new ArgumentException("Inventory paths must be absolute Windows paths.");
            if(p.IndexOf('\0')>=0||p.IndexOf('*')>=0||p.IndexOf('?')>=0||p.IndexOf('%')>=0||
                p.Split('\\').Any(x=>x==".."||x=="."))throw new ArgumentException("Unsafe inventory path.");
            return p.ToUpperInvariant();
        }
        public static byte[] Key(string machine,int siteId,string path)
        {return Hashing.Text(machine.ToUpperInvariant()+"\n"+siteId.ToString(CultureInfo.InvariantCulture)+"\n"+CanonicalRoot(path));}
        public static DateTime Validate(InventorySnapshot snapshot,string machine,DateTime now,int maxAgeSeconds)
        {
            if(snapshot==null||snapshot.version!=1||snapshot.sites==null||snapshot.sites.Length>10000)
                throw new InvalidDataException("Unsupported or incomplete IIS inventory.");
            if(!string.Equals(snapshot.machineName,machine,StringComparison.OrdinalIgnoreCase))
                throw new InvalidDataException("Inventory belongs to a different machine. Use one IIS server/agent per database.");
            if(!snapshot.success)throw new InvalidDataException("IIS inventory publisher failed: "+Settings.Clip(snapshot.error,700));
            DateTime stamp;
            if(!DateTime.TryParse(snapshot.generatedUtc,CultureInfo.InvariantCulture,DateTimeStyles.AssumeUniversal|DateTimeStyles.AdjustToUniversal,out stamp)||
                stamp>now.AddMinutes(5)||(now-stamp).TotalSeconds>maxAgeSeconds)
                throw new InvalidDataException("IIS inventory is stale or has an invalid timestamp. Check IISReports-DiscoverSites scheduled task.");
            var ids=new HashSet<int>();
            foreach(var site in snapshot.sites)
            {
                if(site==null||site.siteId<1||!ids.Add(site.siteId)||string.IsNullOrWhiteSpace(site.name)||site.name.Length>256||
                    string.IsNullOrWhiteSpace(site.status)||site.status.Length>40||(site.message??"").Length>1024)
                    throw new InvalidDataException("Invalid or duplicate IIS site in inventory.");
                string path=CanonicalRoot(site.rootPath);
                if(site.available&&(path.StartsWith(@"\\",StringComparison.Ordinal)||!new[]{"ready","logging_disabled"}.Contains(site.status)))
                    throw new InvalidDataException("Only supported local W3C file sources can be marked available.");
            }
            return stamp;
        }
        public bool Sync()
        {
            if(!Enabled)
            {
                Store.Exec(connection,null,@"IF NOT EXISTS(SELECT 1 FROM ir3.DiscoveryState WHERE Id=1) INSERT ir3.DiscoveryState(Id) VALUES(1);
 UPDATE ir3.DiscoveryState SET State='disabled',LastAttemptUtc=SYSUTCDATETIME(),LastError=NULL WHERE Id=1;");
                return true;
            }
            try
            {
                byte[] bytes;
                using(var f=new FileStream(ManifestPath,FileMode.Open,FileAccess.Read,FileShare.ReadWrite|FileShare.Delete))
                {
                    if(f.Length>4*1024*1024)throw new InvalidDataException("Inventory exceeds 4 MiB.");
                    bytes=new byte[checked((int)f.Length)];int n=0;
                    while(n<bytes.Length){int r=f.Read(bytes,n,bytes.Length-n);if(r==0)throw new IOException("Incomplete inventory.");n+=r;}
                }
                string json=new UTF8Encoding(false,true).GetString(bytes).TrimStart('\uFEFF');
                var snapshot=new JavaScriptSerializer{MaxJsonLength=4*1024*1024}.Deserialize<InventorySnapshot>(json);
                DateTime stamp=Validate(snapshot,Environment.MachineName,DateTime.UtcNow,Settings.Int("IISReportsDiscoveryMaxAgeSeconds",600,120,86400));
                string hash=Convert.ToBase64String(Hashing.Bytes(bytes,0,bytes.Length));
                if(hash==appliedHash)return true;
                Apply(connection,snapshot,stamp);appliedHash=hash;return true;
            }
            catch(Exception ex)
            {
                Store.Exec(connection,null,@"IF NOT EXISTS(SELECT 1 FROM ir3.DiscoveryState WHERE Id=1) INSERT ir3.DiscoveryState(Id) VALUES(1);
 UPDATE ir3.DiscoveryState SET State='error',LastAttemptUtc=SYSUTCDATETIME(),LastError=@e WHERE Id=1;","@e",Settings.Clip(ex.Message,1024));
                // Do not disable previously discovered sources on a failed/incomplete snapshot.
                return false;
            }
        }
        public static void Apply(SqlConnection c,InventorySnapshot snapshot,DateTime stamp)
        {
            // Caller validates the snapshot before this transaction. Public for SQL integration tests.
            using(var tx=c.BeginTransaction(IsolationLevel.Serializable))
            {
                var found=new List<int>();int added=0;
                foreach(var site in snapshot.sites.OrderBy(x=>x.siteId))
                {
                    string keyPath=CanonicalRoot(site.rootPath);byte[] key=Key(snapshot.machineName,site.siteId,keyPath);
                    var existing=Store.Rows(c,tx,@"SELECT * FROM ir3.Sources WITH(UPDLOCK,HOLDLOCK)
 WHERE DiscoveryKey=@key OR (SiteId=@site AND UPPER(REPLACE(RootPath,'/','\'))=@root)
 ORDER BY Id;","@key",key,"@site",site.siteId,"@root",keyPath);
                    if(existing.Count>1)throw new InvalidDataException("Duplicate source registrations for SiteId "+site.siteId+". Resolve duplicates before automatic discovery; nothing was removed.");
                    int id;
                    if(existing.Count==0)
                    {
                        // Carry a previous per-site monitoring choice across a log directory change.
                        object prior=Store.Scalar(c,tx,@"SELECT TOP(1) Enabled FROM ir3.Sources WITH(UPDLOCK,HOLDLOCK)
 WHERE SiteId=@site ORDER BY CASE WHEN Available=1 THEN 0 ELSE 1 END,Id DESC;","@site",site.siteId);
                        bool enabled=prior==null||Store.Bool(prior);
                        id=Store.Num(Store.Scalar(c,tx,@"INSERT ir3.Sources(Name,SiteId,RootPath,Enabled,AutoDiscovered,DiscoveryKey)
 OUTPUT inserted.Id VALUES(@name,@site,@root,@on,1,@key);","@name",Settings.Clip(site.name,128),"@site",site.siteId,"@root",site.rootPath.Trim().TrimEnd('\\'),"@on",enabled,"@key",key));
                        added++;Store.Audit(c,tx,"agent:"+snapshot.machineName,"source-discovered",id.ToString(),"SiteId="+site.siteId);
                    }
                    else id=Store.Num(existing[0]["Id"]);
                    // Crucially, do NOT assign Enabled, Name or Revision here.
                    Store.Exec(c,tx,@"UPDATE ir3.Sources SET AutoDiscovered=1,DiscoveryKey=@key,IisName=@name,
 Available=@available,DiscoveryStatus=@status,DiscoveryMessage=@message,LastDiscoveredUtc=@stamp WHERE Id=@id;",
                        "@key",key,"@name",site.name,"@available",site.available,"@status",site.status,"@message",site.message,"@stamp",stamp,"@id",id);
                    found.Add(id);
                }
                // Only retire sources after a complete, successful snapshot. Preserve their Enabled choice and all history.
                var current=Store.Rows(c,tx,"SELECT Id FROM ir3.Sources WITH(UPDLOCK,HOLDLOCK) WHERE AutoDiscovered=1");
                var keep=new HashSet<int>(found);
                foreach(var row in current)
                {
                    int id=Store.Num(row["Id"]);if(keep.Contains(id))continue;
                    Store.Exec(c,tx,@"UPDATE ir3.Sources SET Available=0,DiscoveryStatus='not_in_iis',
 DiscoveryMessage='Site removed or log directory changed. History retained.' WHERE Id=@id;","@id",id);
                }
                Store.Exec(c,tx,@"IF NOT EXISTS(SELECT 1 FROM ir3.DiscoveryState WHERE Id=1) INSERT ir3.DiscoveryState(Id) VALUES(1);
 UPDATE ir3.DiscoveryState SET MachineName=@machine,State='ok',LastAttemptUtc=SYSUTCDATETIME(),LastSuccessUtc=SYSUTCDATETIME(),
 SnapshotUtc=@stamp,LastError=NULL,SitesFound=@count,SourcesAdded=@added WHERE Id=1;",
                    "@machine",snapshot.machineName,"@stamp",stamp,"@count",snapshot.sites.Length,"@added",added);
                tx.Commit();
            }
        }
    }
}
