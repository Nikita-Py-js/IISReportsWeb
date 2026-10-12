// Persistent source selections and atomic pause/import coordination.
// C# 5, .NET Framework. No inventory publisher or background service.
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

}
