using System;
using System.Data;
using System.Data.SqlClient;
using System.IO;
using System.ServiceProcess;
using System.Threading;
using IISReports.V3;

[assembly: System.Reflection.AssemblyVersion("3.1.0.0")]
[assembly: System.Reflection.AssemblyFileVersion("3.1.0.0")]

namespace IISReports.Agent
{
    public sealed class Worker
    {
        private readonly ManualResetEvent stop;
        private SqlConnection c;
        public Worker(ManualResetEvent cancellation){stop=cancellation;}
        private void Beat()
        {
            if(stop.WaitOne(0))throw new OperationCanceledException();
            Store.Exec(c,null,"UPDATE ir3.AgentState SET HeartbeatUtc=@t,MachineName=@m,Version='3.1.0' WHERE Id=1","@t",DateTime.UtcNow,"@m",Environment.MachineName);
        }
        public void Run(bool once)
        {
            do
            {
                try
                {
                    // Session-owned application locks require a real logout, not a pooled connection.
                    var builder=new SqlConnectionStringBuilder(Settings.ConnectionString);builder.Pooling=false;
                    using(c=new SqlConnection(builder.ConnectionString))
                    {
                        c.Open();Store.CheckSchema(c);
                        int locked=Convert.ToInt32(Store.Scalar(c,null,@"DECLARE @r int; EXEC @r=sys.sp_getapplock
 @Resource=N'IISReports.v3.agent',@LockMode='Exclusive',@LockOwner='Session',@LockTimeout=0; SELECT @r;"));
                        if(locked<0)throw new InvalidOperationException("Another IISReports v3 agent already owns the database lock.");
                        Store.Exec(c,null,@"IF NOT EXISTS(SELECT 1 FROM ir3.AgentState WHERE Id=1)
 INSERT ir3.AgentState(Id,MachineName,HeartbeatUtc,State,Version) VALUES(1,@m,@now,'starting','3.1.0');
 UPDATE ir3.AgentState SET State='running',LastError=NULL,MachineName=@m,HeartbeatUtc=@now WHERE Id=1;
 UPDATE ir3.Jobs SET State='queued',Result='Resumed after agent restart.' WHERE State='running';
 UPDATE ir3.NotificationOutbox SET State='pending' WHERE State='sending';
 UPDATE ir3.ImportRuns SET Status='interrupted',FinishedUtc=@now,Detail='Agent restarted; committed batches are retained.' WHERE Status='running';",
                            "@m",Environment.MachineName,"@now",DateTime.UtcNow);
                        var imports=new ImportEngine(c,Beat);var monitor=new MonitorEngine(c,Beat);var discovery=new SourceDiscovery(c);DateTime nextScan=DateTime.MinValue;
                        do
                        {
                            Beat();
                            if(DateTime.UtcNow>=nextScan)
                            {
                                bool discovered=discovery.Sync();
                                bool success=imports.Scan() && discovered;
                                Store.Exec(c,null,@"UPDATE ir3.AgentState SET LastScanUtc=@t,
 LastSuccessfulScanUtc=CASE WHEN @ok=1 THEN @t ELSE LastSuccessfulScanUtc END,
 State=@s,LastError=@e WHERE Id=1","@t",DateTime.UtcNow,"@ok",success,"@s",success?"running":"warning","@e",success?null:"Some sources or automatic discovery have errors. Review Sources.");
                                nextScan=DateTime.UtcNow.AddSeconds(Settings.Int("IISReportsScanSeconds",30,5,3600));
                            }
                            ProcessJob(imports);
                            monitor.RunChecks();monitor.EvaluateRules();monitor.Deliver();
                            Beat();
                            if(once)break;
                        }while(!stop.WaitOne(1000));
                        Store.Exec(c,null,"UPDATE ir3.AgentState SET State='stopped',HeartbeatUtc=@t WHERE Id=1","@t",DateTime.UtcNow);
                    }
                    if(once||stop.WaitOne(0))return;
                }
                catch(OperationCanceledException){return;}
                catch(Exception ex)
                {
                    Log(ex.GetType().Name+": "+ex.Message);
                    if(once)throw;
                    if(stop.WaitOne(5000))return;
                }
            }while(!stop.WaitOne(0));
        }
        private void ProcessJob(ImportEngine imports)
        {
            var queued=Store.Rows(c,null,"SELECT TOP(1) * FROM ir3.Jobs WHERE State='queued' ORDER BY RequestedUtc");
            if(queued.Count==0)return;
            var job=queued[0];Guid id=(Guid)job["Id"];string kind=Store.Str(job["Kind"]);long file=Store.Long(job["FileId"]);
            Store.Exec(c,null,"UPDATE ir3.Jobs SET State='running',StartedUtc=COALESCE(StartedUtc,SYSUTCDATETIME()),Attempts=Attempts+1 WHERE Id=@id","@id",id);
            try
            {
                bool complete=true;string result="Completed.";
                if(kind=="scan") { bool ok=imports.Scan();result=ok?"Scan complete.":"Scan complete with source warnings."; }
                else if(kind=="verify")imports.Verify(file);
                else if(kind=="new-generation")imports.NewGeneration(file,id);
                else if(kind=="replay")
                {
                    if(job["GenerationId"]==null)
                    {
                        imports.Verify(file);
                        Store.Exec(c,null,@"UPDATE j SET GenerationId=f.ActiveGenerationId,TargetOffset=g.CommittedOffset
 FROM ir3.Jobs j JOIN ir3.Files f ON f.Id=j.FileId JOIN ir3.Generations g ON g.Id=f.ActiveGenerationId WHERE j.Id=@id;","@id",id);
                        job=Store.Rows(c,null,"SELECT * FROM ir3.Jobs WHERE Id=@id","@id",id)[0];
                    }
                    long active=Store.Long(Store.Scalar(c,null,"SELECT ActiveGenerationId FROM ir3.Files WHERE Id=@f","@f",file));
                    if(active!=Store.Long(job["GenerationId"]))throw new InvalidOperationException("File generation changed while replay was queued.");
                    long next;imports.ImportFile(file,true,Store.Long(job["ProgressOffset"]),Store.Long(job["TargetOffset"]),out next);
                    complete=next>=Store.Long(job["TargetOffset"]);result="Replayed bytes: "+next+" / "+Store.Long(job["TargetOffset"]);
                    Store.Exec(c,null,"UPDATE ir3.Jobs SET ProgressOffset=@p WHERE Id=@id","@p",next,"@id",id);
                }
                else throw new InvalidOperationException("Unknown queued job kind.");
                Store.Exec(c,null,"UPDATE ir3.Jobs SET State=@s,FinishedUtc=@t,Result=@r WHERE Id=@id","@s",complete?"done":"queued","@t",complete?(object)DateTime.UtcNow:null,"@r",result,"@id",id);
            }
            catch(OperationCanceledException){throw;}
            catch(Exception ex)
            { Store.Exec(c,null,"UPDATE ir3.Jobs SET State='failed',FinishedUtc=@t,Result=@e WHERE Id=@id","@t",DateTime.UtcNow,"@e",Settings.Clip(ex.Message,2048),"@id",id); }
        }
        public static void Log(string message)
        {
            string line=DateTime.UtcNow.ToString("o")+" "+message;
            Console.Error.WriteLine(line);
            try
            {
                string dir=Path.Combine(AppDomain.CurrentDomain.BaseDirectory,"logs");Directory.CreateDirectory(dir);
                string path=Path.Combine(dir,"agent-"+DateTime.UtcNow.ToString("yyyyMMdd")+".log");
                File.AppendAllText(path,line+Environment.NewLine);
            }
            catch { }
        }
    }
    public sealed class AgentService:ServiceBase
    {
        private readonly ManualResetEvent stop=new ManualResetEvent(false);private Thread thread;
        public AgentService(){ServiceName="IISReportsAgentV3";CanStop=true;AutoLog=true;}
        protected override void OnStart(string[] args)
        {stop.Reset();thread=new Thread(delegate(){new Worker(stop).Run(false);});thread.IsBackground=true;thread.Start();}
        protected override void OnStop()
        {
            stop.Set();RequestAdditionalTime(120000);
            if(thread!=null&&!thread.Join(115000))Worker.Log("Stop requested; active work exceeded shutdown wait. Uncommitted SQL work will roll back on process exit.");
        }
    }
    public static class Program
    {
        public static int Main(string[] args)
        {
            if(args.Length>0&&(args[0]=="--console"||args[0]=="--once"))
            {
                using(var stop=new ManualResetEvent(false))
                {
                    Console.CancelKeyPress+=delegate(object sender,ConsoleCancelEventArgs e){e.Cancel=true;stop.Set();};
                    try{new Worker(stop).Run(args[0]=="--once");return 0;}catch(Exception ex){Worker.Log(ex.ToString());return 1;}
                }
            }
            ServiceBase.Run(new AgentService());return 0;
        }
    }
}
