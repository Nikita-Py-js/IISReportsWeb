using System;
using System.IO;
using System.Data.SqlClient;
using System.Text;
using IISReports.V3;
public static class SqlIntegrationTests
{
    private static int passed;
    private static void Check(bool ok,string name){if(!ok)throw new Exception(name);passed++;Console.WriteLine("PASS "+name);}
    private static long Count(SqlConnection c,string table,long gen)
    {return Store.Long(Store.Scalar(c,null,"SELECT COUNT_BIG(*) FROM "+table+" WHERE GenerationId=@g","@g",gen));}
    public static int Main()
    {
        string conn=Environment.GetEnvironmentVariable("IISREPORTS_TEST_CONNSTR");
        if(string.IsNullOrWhiteSpace(conn)){Console.Error.WriteLine("Run tools/Test-Sql.ps1 with the protected agent config.");return 2;}
        var builder=new SqlConnectionStringBuilder(conn);builder.Pooling=false;
        string dir=Path.Combine(Path.GetTempPath(),"IISReportsV3-tests-"+Guid.NewGuid().ToString("N"));Directory.CreateDirectory(dir);
        int source=0;string incidentKey=null;
        using(var c=new SqlConnection(builder.ConnectionString))
        {
            try
            {
                c.Open();Store.CheckSchema(c);
                int locked=Convert.ToInt32(Store.Scalar(c,null,"DECLARE @r int; EXEC @r=sys.sp_getapplock @Resource=N'IISReports.v3.agent',@LockMode='Exclusive',@LockOwner='Session',@LockTimeout=0; SELECT @r;"));
                if(locked<0)throw new Exception("Stop the real agent before integration tests; no test rows have been created.");
                source=Store.Num(Store.Scalar(c,null,"INSERT ir3.Sources(Name,SiteId,RootPath) OUTPUT inserted.Id VALUES(@n,999999,@p)","@n","Integration test "+DateTime.UtcNow.ToString("o"),"@p",dir));
                string path=Path.Combine(dir,"u_ex261011.log");
                string header="#Fields: date time cs-method cs-uri-stem sc-status time-taken\r\n";
                string row="2026-10-11 18:00:00 GET /test 200 12\r\n";
                var utf8=new UTF8Encoding(false);File.WriteAllText(path,header+row+row,utf8);
                var engine=new ImportEngine(c,null);Check(engine.Scan(source),"initial source scan");
                long file=Store.Long(Store.Scalar(c,null,"SELECT Id FROM ir3.Files WHERE SourceId=@s","@s",source));
                long gen=Store.Long(Store.Scalar(c,null,"SELECT ActiveGenerationId FROM ir3.Files WHERE Id=@f","@f",file));
                Check(Count(c,"ir3.Requests",gen)==2,"equal-text rows retain distinct offsets");
                engine.Scan(source);Check(Count(c,"ir3.Requests",gen)==2,"second scan does not duplicate");
                SourceSelection.Save(c,new[]{new SourceChange{id=source,revision=1,enabled=false}},"integration-test");
                File.AppendAllText(path,row,utf8);engine.Scan(source);
                Check(Count(c,"ir3.Requests",gen)==2,"paused source does not import appended lines");
                bool conflict=false;try{SourceSelection.Save(c,new[]{new SourceChange{id=source,revision=1,enabled=true}},"integration-test");}catch(SourceConflictException){conflict=true;}
                Check(conflict&&!Store.Bool(Store.Scalar(c,null,"SELECT Enabled FROM ir3.Sources WHERE Id=@s","@s",source)),"stale revision cannot override source pause");
                bool stopped=false;try{engine.ImportFile(file,true,0);}catch(SourcePausedException){stopped=true;}
                Check(stopped&&Count(c,"ir3.Requests",gen)==2,"replay cannot bypass source pause");
                SourceSelection.Save(c,new[]{new SourceChange{id=source,revision=2,enabled=true}},"integration-test");
                engine.Scan(source);Check(Count(c,"ir3.Requests",gen)==3,"source resumes from saved offset exactly once");
                File.AppendAllText(path,row.TrimEnd('\r','\n'),utf8);engine.Scan(source);
                Check(Count(c,"ir3.Requests",gen)==3,"partial line deferred");
                File.AppendAllText(path,"\r\n",utf8);engine.Scan(source);
                Check(Count(c,"ir3.Requests",gen)==4,"partial line completed exactly once");
                File.AppendAllText(path,"malformed record\r\n",utf8);engine.Scan(source);
                Check(Count(c,"ir3.RawEvents",gen)==5&&Count(c,"ir3.Requests",gen)==4,"parse failure retained in quarantine");
                long oldOffset=Store.Long(Store.Scalar(c,null,"SELECT CommittedOffset FROM ir3.Generations WHERE Id=@g","@g",gen));
                engine.Verify(file);long next;engine.ImportFile(file,true,0,oldOffset,out next);
                Check(next==oldOffset&&Count(c,"ir3.Requests",gen)==4&&Count(c,"ir3.RawEvents",gen)==5,"replay is idempotent");
                File.SetLastWriteTimeUtc(path,DateTime.UtcNow.AddDays(-3));engine.Scan(source);
                Check(Count(c,"ir3.Requests",gen)==4,"mtime-only change does not reject unchanged bytes");
                byte[] original=File.ReadAllBytes(path),changed=(byte[])original.Clone();changed[Encoding.UTF8.GetByteCount(header)+21]=(byte)'X';File.WriteAllBytes(path,changed);
                bool detected=false;try{engine.Verify(file);}catch(InvalidDataException){detected=true;}
                Check(detected&&Count(c,"ir3.Requests",gen)==4,"content change detected; committed history retained");
                File.WriteAllBytes(path,original);engine.Verify(file);
                Guid job=Guid.NewGuid();Store.Exec(c,null,"INSERT ir3.Jobs(Id,Kind,FileId,RequestedBy) VALUES(@id,'new-generation',@f,'integration-test')","@id",job,"@f",file);
                engine.NewGeneration(file,job);engine.NewGeneration(file,job);
                long newGen=Store.Long(Store.Scalar(c,null,"SELECT ActiveGenerationId FROM ir3.Files WHERE Id=@f","@f",file));
                Check(newGen!=gen&&Store.Long(Store.Scalar(c,null,"SELECT COUNT(*) FROM ir3.Generations WHERE FileId=@f","@f",file))==2,"new generation is restart-idempotent");
                engine.Scan(source);
                Check(Count(c,"ir3.Requests",gen)==4&&Count(c,"ir3.Requests",newGen)==4&&Count(c,"ir3.CurrentRequests",gen)==0,"prior generation archived without double counting");
                Store.Exec(c,null,"UPDATE ir3.Jobs SET State='done',FinishedUtc=SYSUTCDATETIME() WHERE Id=@id","@id",job);
                string key="test:"+Guid.NewGuid().ToString("N");incidentKey=key;
                using(var tx=c.BeginTransaction()){Incidents.Observe(c,tx,key,"Test rollback","Must not persist",true);tx.Rollback();}
                Check(Store.Long(Store.Scalar(c,null,"SELECT COUNT(*) FROM ir3.Incidents WHERE EntityKey=@k","@k",key))==0,"incident transaction rollback");
                using(var tx=c.BeginTransaction()){Incidents.Observe(c,tx,key,"Test incident","first",true);Incidents.Observe(c,tx,key,"Test incident","continued",true);tx.Commit();}
                Guid incident=(Guid)Store.Scalar(c,null,"SELECT Id FROM ir3.Incidents WHERE EntityKey=@k","@k",key);
                Check(Store.Long(Store.Scalar(c,null,"SELECT COUNT(*) FROM ir3.NotificationOutbox WHERE IncidentId=@i","@i",incident))==1,"ongoing incident creates one open notification");
                using(var tx=c.BeginTransaction()){Incidents.Observe(c,tx,key,"Test incident","recovered",false);tx.Commit();}
                Check(Store.Long(Store.Scalar(c,null,"SELECT COUNT(*) FROM ir3.NotificationOutbox WHERE IncidentId=@i","@i",incident))==2,"recovery event queued atomically");
                // Prevent tests from sending external messages when the agent starts again.
                Store.Exec(c,null,"UPDATE ir3.NotificationOutbox SET State='cancelled',LastError='Integration test: deliberately not delivered.' WHERE IncidentId=@i","@i",incident);
                Console.WriteLine("PASS TOTAL "+passed+". Fixture retained at "+dir);return 0;
            }
            catch(Exception ex){Console.Error.WriteLine("FAIL "+ex.Message);return 1;}
            finally
            {
                if(incidentKey!=null&&c.State==System.Data.ConnectionState.Open)
                    try{Store.Exec(c,null,"UPDATE o SET State='cancelled',LastError='Integration test: deliberately not delivered.' FROM ir3.NotificationOutbox o JOIN ir3.Incidents i ON i.Id=o.IncidentId WHERE i.EntityKey=@k","@k",incidentKey);}catch{}
                if(source>0&&c.State==System.Data.ConnectionState.Open)
                    try{Store.Exec(c,null,"UPDATE ir3.Sources SET Enabled=0 WHERE Id=@s","@s",source);}catch{}
                // No dbo data is changed. Test rows and source files remain for inspection.
            }
        }
    }
}
