using System;
using System.Collections.Generic;
using System.Data;
using System.Data.SqlClient;
using System.IO;
using System.Linq;
using System.Text;

namespace IISReports.V3
{
    public sealed class ImportEngine
    {
        private readonly SqlConnection c;
        private readonly Action heartbeat;
        public ImportEngine(SqlConnection connection, Action beat) { c=connection; heartbeat=beat; }
        private void Beat() { if(heartbeat!=null)heartbeat(); }
        public static IEnumerable<string> Enumerate(string root)
        {
            var pending=new Stack<string>();pending.Push(Path.GetFullPath(root));
            while(pending.Count>0)
            {
                string dir=pending.Pop();
                if((File.GetAttributes(dir)&FileAttributes.ReparsePoint)!=0)throw new IOException("Reparse-point source directories are not supported.");
                foreach(string file in Directory.GetFiles(dir,"*.log"))
                    if((File.GetAttributes(file)&FileAttributes.ReparsePoint)==0)yield return Path.GetFullPath(file);
                foreach(string child in Directory.GetDirectories(dir))
                    if((File.GetAttributes(child)&FileAttributes.ReparsePoint)==0)pending.Push(child);
            }
        }
        private static void ValidatePath(string path,string root)
        {
            string full=Path.GetFullPath(path); string basePath=Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar)+Path.DirectorySeparatorChar;
            if(!full.StartsWith(basePath,StringComparison.OrdinalIgnoreCase))throw new IOException("File is outside its registered source root.");
            if((File.GetAttributes(full)&FileAttributes.ReparsePoint)!=0)throw new IOException("Reparse-point files are not supported.");
            for(var d=new DirectoryInfo(Path.GetDirectoryName(full));d!=null;d=d.Parent)
            {
                if((d.Attributes&FileAttributes.ReparsePoint)!=0)throw new IOException("Reparse-point directory in source path.");
                if(string.Equals(d.FullName.TrimEnd(Path.DirectorySeparatorChar)+Path.DirectorySeparatorChar,basePath,StringComparison.OrdinalIgnoreCase))break;
            }
        }
        public long Register(int sourceId,string path)
        {
            if(path.Length>1024)throw new IOException("Source path exceeds 1024 characters.");
            byte[] key=Hashing.Text(path.ToUpperInvariant());var info=new FileInfo(path);
            using(var tx=c.BeginTransaction())
            {
                object found=Store.Scalar(c,tx,"SELECT Id FROM ir3.Files WITH(UPDLOCK,HOLDLOCK) WHERE SourceId=@s AND PathKey=@p","@s",sourceId,"@p",key);
                long id;
                if(found==null)
                {
                    id=Store.Long(Store.Scalar(c,tx,"INSERT ir3.Files(SourceId,PathKey,FullPath) OUTPUT inserted.Id VALUES(@s,@p,@f)","@s",sourceId,"@p",key,"@f",path));
                    CreateGeneration(id,"initial import",tx);
                }
                else id=Store.Long(found);
                Store.Exec(c,tx,"UPDATE ir3.Files SET Status=CASE WHEN Status='changed' THEN Status WHEN Status='missing' OR ObservedSize<>@n OR ObservedMtime<>@m THEN 'pending' ELSE Status END,ObservedSize=@n,ObservedMtime=@m,LastSeenUtc=@t WHERE Id=@id","@n",info.Length,"@m",info.LastWriteTimeUtc,"@t",DateTime.UtcNow,"@id",id);
                tx.Commit();return id;
            }
        }
        private long CreateGeneration(long fileId,string reason,SqlTransaction tx)
        {
            long id=Store.Long(Store.Scalar(c,tx,@"DECLARE @n int=(SELECT ISNULL(MAX(Number),0)+1 FROM ir3.Generations WHERE FileId=@f);
INSERT ir3.Generations(FileId,Number,Reason) OUTPUT inserted.Id VALUES(@f,@n,@r);","@f",fileId,"@r",reason));
            Store.Exec(c,tx,"UPDATE ir3.Files SET ActiveGenerationId=@g,Status='new',LastError=NULL WHERE Id=@f","@g",id,"@f",fileId);
            return id;
        }
        public void NewGeneration(long fileId,Guid jobId)
        {
            var file=FileState(fileId);SourceSelection.RequireImport(c,null,Store.Num(file["SourceId"]),false);ValidatePath(Store.Str(file["FullPath"]),Store.Str(file["RootPath"]));
            using(var tx=c.BeginTransaction())
            {
                SourceSelection.RequireImport(c,tx,Store.Num(file["SourceId"]),true);
                object done=Store.Scalar(c,tx,"SELECT GenerationId FROM ir3.Jobs WITH(UPDLOCK) WHERE Id=@id","@id",jobId);
                if(done==null)
                {
                    long id=CreateGeneration(fileId,"operator requested new generation",tx);
                    Store.Exec(c,tx,"UPDATE ir3.Jobs SET GenerationId=@g WHERE Id=@id","@g",id,"@id",jobId);
                }
                tx.Commit();
            }
        }
        private Dictionary<string,object> FileState(long id)
        {
            var rows=Store.Rows(c,null,@"SELECT f.*,s.SiteId,s.RootPath,g.CommittedOffset,g.LineNumber,g.Fields
 FROM ir3.Files f JOIN ir3.Sources s ON s.Id=f.SourceId JOIN ir3.Generations g ON g.Id=f.ActiveGenerationId WHERE f.Id=@id","@id",id);
            if(rows.Count!=1)throw new InvalidOperationException("Registered file/generation not found.");return rows[0];
        }
        private void CheckChunks(long generationId,FileStream stream,bool all)
        {
            var chunks=Store.Rows(c,null,"SELECT StartOffset,EndOffset,Sha256 FROM ir3.ImportChunks WHERE GenerationId=@g ORDER BY StartOffset,EndOffset","@g",generationId);
            var selected=all?chunks:chunks.Count<=2?chunks:new List<Dictionary<string,object>>{chunks[0],chunks[chunks.Count-1]};
            foreach(var chunk in selected)
            {
                Beat();long start=Store.Long(chunk["StartOffset"]),end=Store.Long(chunk["EndOffset"]);
                if(end>stream.Length || !Hashing.Equal((byte[])chunk["Sha256"],Hashing.Range(stream,start,end)))
                    throw new InvalidDataException("Imported source bytes changed at ["+start+","+end+"). History retained. Restore the original file or explicitly create a new generation.");
            }
        }
        public void Verify(long fileId)
        {
            var f=FileState(fileId);long gen=Store.Long(f["ActiveGenerationId"]);string path=Store.Str(f["FullPath"]);
            try
            {
                ValidatePath(path,Store.Str(f["RootPath"]));
                using(var stream=new FileStream(path,FileMode.Open,FileAccess.Read,FileShare.ReadWrite|FileShare.Delete))
                {
                    if(Store.Long(f["CommittedOffset"])>stream.Length)throw new InvalidDataException("File is shorter than its committed checkpoint.");
                    CheckChunks(gen,stream,true);
                }
                Store.Exec(c,null,"UPDATE ir3.Generations SET LastVerifiedUtc=@t,VerificationStatus='ok' WHERE Id=@g; UPDATE ir3.Files SET Status='verified',LastError=NULL WHERE Id=@f;","@t",DateTime.UtcNow,"@g",gen,"@f",fileId);
            }
            catch(OperationCanceledException){throw;}
            catch(Exception ex)
            {
                Store.Exec(c,null,"UPDATE ir3.Generations SET LastVerifiedUtc=@t,VerificationStatus='failed' WHERE Id=@g; UPDATE ir3.Files SET Status='changed',LastError=@e WHERE Id=@f;","@t",DateTime.UtcNow,"@g",gen,"@f",fileId,"@e",Settings.Clip(ex.Message,1024));throw;
            }
        }
        public long ImportFile(long fileId,bool replay,long replayStart)
        {
            long ignored;return ImportFile(fileId,replay,replayStart,out ignored);
        }
        public long ImportFile(long fileId,bool replay,long replayStart,out long next)
        { return ImportFile(fileId,replay,replayStart,null,out next); }
        public long ImportFile(long fileId,bool replay,long replayStart,long? snapshotEnd,out long next)
        {
            var f=FileState(fileId);string path=Store.Str(f["FullPath"]);long gen=Store.Long(f["ActiveGenerationId"]);
            SourceSelection.RequireImport(c,null,Store.Num(f["SourceId"]),false);
            ValidatePath(path,Store.Str(f["RootPath"]));
            long position=replay?replayStart:Store.Long(f["CommittedOffset"]);
            long line=Store.Long(f["LineNumber"]);string fields=Store.Str(f["Fields"]);
            using(var stream=new FileStream(path,FileMode.Open,FileAccess.Read,FileShare.ReadWrite|FileShare.Delete))
            {
                long size=stream.Length;
                if(Store.Long(f["CommittedOffset"])>size)throw new InvalidDataException("File was truncated. Create a new generation explicitly; old data is retained.");
                CheckChunks(gen,stream,false);
                if(replay)
                {
                    // Recover header and line number from source, not from the current EOF checkpoint.
                    line=0;fields=null;long cursor=0;
                    while(cursor<position)
                    {
                        var prior=W3C.Read(stream,cursor,line,fields,position);
                        if(prior.End<=cursor)throw new InvalidDataException("Replay checkpoint is not on a completed line.");
                        cursor=prior.End;line=prior.LineNumber;fields=prior.Fields;
                    }
                }
                long limit=snapshotEnd.HasValue?Math.Min(size,snapshotEnd.Value):size;
                var batch=W3C.Read(stream,position,line,fields,limit);next=batch.End;
                if(batch.End>position)
                {
                    if(!Hashing.Equal(batch.Hash,Hashing.Range(stream,batch.Start,batch.End)))throw new InvalidDataException("File changed before the import transaction.");
                    SaveBatch(Store.Num(f["SourceId"]),gen,Store.Num(f["SiteId"]),path,batch);
                }
                string status=batch.End<size?"pending":"ok";
                if(batch.End==position && position<size)status="partial-line";
                Store.Exec(c,null,"UPDATE ir3.Files SET Status=@s,LastError=NULL,ObservedSize=@n,ObservedMtime=@m WHERE Id=@id",
                    "@s",status,"@n",size,"@m",File.GetLastWriteTimeUtc(path),"@id",fileId);
                return batch.Records.Count;
            }
        }
        private static readonly string[] RequestColumns={"Ts","SiteId","ServerIp","ServerPort","ClientIp","UserName","Method","UriStem","UriQuery","Status","SubStatus","Win32Status","TimeMs","UserAgent","Referer","LogFile"};
        private void SaveBatch(int sourceId,long generationId,int siteId,string path,ReadBatch batch)
        {
            using(var tx=c.BeginTransaction())
            {
                // Serialize a batch commit with the web pause operation.
                SourceSelection.RequireImport(c,tx,sourceId,true);
                Store.Exec(c,tx,@"CREATE TABLE #ImportStage(ByteOffset bigint NOT NULL,EndOffset bigint NOT NULL,LineNumber bigint NOT NULL,
RawText nvarchar(max) NOT NULL,RawHash binary(32) NOT NULL,ParseError nvarchar(512) NULL,
Ts datetime2(7) NULL,SiteId int NOT NULL,ServerIp nvarchar(45) NULL,ServerPort int NULL,ClientIp nvarchar(45) NULL,
UserName nvarchar(256) NULL,Method nvarchar(16) NULL,UriStem nvarchar(2048) NULL,UriQuery nvarchar(2048) NULL,
Status int NULL,SubStatus int NULL,Win32Status bigint NULL,TimeMs bigint NULL,UserAgent nvarchar(1024) NULL,Referer nvarchar(2048) NULL,LogFile nvarchar(1024) NULL);");
                var table=new DataTable();
                table.Columns.Add("ByteOffset",typeof(long));table.Columns.Add("EndOffset",typeof(long));table.Columns.Add("LineNumber",typeof(long));
                table.Columns.Add("RawText",typeof(string));table.Columns.Add("RawHash",typeof(byte[]));table.Columns.Add("ParseError",typeof(string));
                foreach(string col in RequestColumns)
                    table.Columns.Add(col,col=="Ts"?typeof(DateTime):col=="Win32Status"||col=="TimeMs"?typeof(long):
                        col=="SiteId"||col=="ServerPort"||col=="Status"||col=="SubStatus"?typeof(int):typeof(string));
                foreach(var r in batch.Records)
                    table.Rows.Add(r.Offset,r.End,r.LineNumber,r.Raw,r.Hash,(object)r.Error??DBNull.Value,
                        r.Error==null?(object)r.Timestamp:DBNull.Value,siteId,r.ServerIp,r.ServerPort,r.ClientIp,r.UserName,r.Method,r.UriStem,r.UriQuery,
                        r.Status,r.SubStatus,r.Win32Status,r.TimeMs,r.UserAgent,r.Referer,path);
                using(var copy=new SqlBulkCopy(c,SqlBulkCopyOptions.CheckConstraints,tx))
                {
                    copy.DestinationTableName="#ImportStage";copy.BatchSize=5000;copy.BulkCopyTimeout=120;
                    foreach(DataColumn col in table.Columns)copy.ColumnMappings.Add(col.ColumnName,col.ColumnName);
                    if(table.Rows.Count>0)copy.WriteToServer(table);
                }
                Store.Exec(c,tx,@"IF EXISTS(SELECT 1 FROM ir3.RawEvents r JOIN #ImportStage s ON s.ByteOffset=r.ByteOffset WHERE r.GenerationId=@g AND r.RawHash<>s.RawHash)
 THROW 50001,'Previously imported source bytes differ. Create a new generation, do not overwrite raw history.',1;
UPDATE r SET ParseError=s.ParseError,ParserVersion=@v FROM ir3.RawEvents r JOIN #ImportStage s ON s.ByteOffset=r.ByteOffset WHERE r.GenerationId=@g;
INSERT ir3.RawEvents(GenerationId,ByteOffset,EndOffset,LineNumber,RawText,RawHash,ParseError,ParserVersion)
 SELECT @g,s.ByteOffset,s.EndOffset,s.LineNumber,s.RawText,s.RawHash,s.ParseError,@v FROM #ImportStage s
 WHERE NOT EXISTS(SELECT 1 FROM ir3.RawEvents r WHERE r.GenerationId=@g AND r.ByteOffset=s.ByteOffset);
DELETE r FROM ir3.Requests r JOIN #ImportStage s ON r.ByteOffset=s.ByteOffset WHERE r.GenerationId=@g AND s.ParseError IS NOT NULL;",
                    "@g",generationId,"@v",W3C.ParserVersion);
                string set=string.Join(",",RequestColumns.Select(x=>"r."+x+"=s."+x));
                string cols=string.Join(",",RequestColumns);string vals=string.Join(",",RequestColumns.Select(x=>"s."+x));
                Store.Exec(c,tx,"UPDATE r SET "+set+" FROM ir3.Requests r JOIN #ImportStage s ON s.ByteOffset=r.ByteOffset WHERE r.GenerationId=@g AND s.ParseError IS NULL;"+
                    "INSERT ir3.Requests(GenerationId,ByteOffset,RawEventId,"+cols+") SELECT @g,s.ByteOffset,raw.Id,"+vals+
                    " FROM #ImportStage s JOIN ir3.RawEvents raw ON raw.GenerationId=@g AND raw.ByteOffset=s.ByteOffset WHERE s.ParseError IS NULL AND NOT EXISTS(SELECT 1 FROM ir3.Requests r WHERE r.GenerationId=@g AND r.ByteOffset=s.ByteOffset);",
                    "@g",generationId);
                Store.Exec(c,tx,@"IF NOT EXISTS(SELECT 1 FROM ir3.ImportChunks WHERE GenerationId=@g AND StartOffset=@start AND EndOffset=@end)
 INSERT ir3.ImportChunks(GenerationId,StartOffset,EndOffset,Sha256) VALUES(@g,@start,@end,@hash);
UPDATE ir3.Generations SET CommittedOffset=@end,LineNumber=@line,Fields=@fields,LastImportUtc=@now WHERE Id=@g AND CommittedOffset<=@end;
DROP TABLE #ImportStage;","@g",generationId,"@start",batch.Start,"@end",batch.End,"@hash",batch.Hash,"@line",batch.LineNumber,"@fields",batch.Fields,"@now",DateTime.UtcNow);
                tx.Commit();
            }
        }
    }
}
